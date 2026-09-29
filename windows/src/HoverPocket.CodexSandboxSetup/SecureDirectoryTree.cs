using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using Microsoft.Win32.SafeHandles;

namespace HoverPocket.CodexSandboxSetup;

internal enum DirectoryAccessMode
{
    AdminOnly,
    UsersRead,
    SpecificUserRead,
    SpecificUserModify,
}

internal static class SecureDirectoryTree
{
    private const FileOptions BackupSemantics = (FileOptions)0x02000000;
    private const FileOptions OpenReparsePoint = (FileOptions)0x00200000;
    private const int FileAttributeTagInfoClass = 9;

    internal static SafeFileHandle OpenOrCreate(
        string path,
        DirectoryAccessMode accessMode,
        SecurityIdentifier? specificUser = null)
    {
        var fullPath = Path.GetFullPath(path);
        var security = BuildDirectorySecurity(accessMode, specificUser);
        if (!Directory.Exists(fullPath))
        {
            if (File.Exists(fullPath))
            {
                throw new InvalidOperationException("HP_CODEX_SANDBOX_TARGET_OBJECT_INVALID");
            }
            FileSystemAclExtensions.CreateDirectory(security, fullPath);
        }

        return OpenAndApplySecurity(fullPath, security);
    }

    internal static SafeFileHandle CreateNew(
        string path,
        DirectoryAccessMode accessMode,
        SecurityIdentifier? specificUser = null)
    {
        var fullPath = Path.GetFullPath(path);
        if (Directory.Exists(fullPath) || File.Exists(fullPath))
        {
            throw new InvalidOperationException("HP_CODEX_SANDBOX_TARGET_ALREADY_EXISTS");
        }

        var security = BuildDirectorySecurity(accessMode, specificUser);
        FileSystemAclExtensions.CreateDirectory(security, fullPath);
        return OpenAndApplySecurity(fullPath, security);
    }

    private static SafeFileHandle OpenAndApplySecurity(
        string fullPath,
        DirectorySecurity security)
    {
        var handle = File.OpenHandle(
            fullPath,
            FileMode.Open,
            FileAccess.Read,
            FileShare.Read | FileShare.Write,
            BackupSemantics | OpenReparsePoint);
        try
        {
            VerifyDirectoryHandle(handle);
            FileSystemAclExtensions.SetAccessControl(new DirectoryInfo(fullPath), security);
            VerifySecurity(fullPath, security);
            return handle;
        }
        catch
        {
            handle.Dispose();
            throw;
        }
    }

    internal static SafeFileHandle OpenExisting(string path)
    {
        var fullPath = Path.GetFullPath(path);
        var handle = File.OpenHandle(
            fullPath,
            FileMode.Open,
            FileAccess.Read,
            FileShare.Read | FileShare.Write,
            BackupSemantics | OpenReparsePoint);
        try
        {
            VerifyDirectoryHandle(handle);
            return handle;
        }
        catch
        {
            handle.Dispose();
            throw;
        }
    }

    internal static void ApplyDirectorySecurity(
        string path,
        DirectoryAccessMode accessMode,
        SecurityIdentifier? specificUser = null)
    {
        using var handle = OpenOrCreate(path, accessMode, specificUser);
    }

    internal static void ApplyFileSecurity(
        string path,
        DirectoryAccessMode accessMode,
        SecurityIdentifier? specificUser = null)
    {
        var attributes = File.GetAttributes(path);
        if ((attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0)
        {
            throw new InvalidOperationException("HP_CODEX_SANDBOX_TARGET_OBJECT_INVALID");
        }
        var security = BuildFileSecurity(accessMode, specificUser);
        FileSystemAclExtensions.SetAccessControl(new FileInfo(path), security);
    }

    internal static void VerifyAclContract()
    {
        var specificUser = new SecurityIdentifier("S-1-5-21-100-200-300-400");
        VerifySpecificReadRules(BuildDirectorySecurity(
            DirectoryAccessMode.SpecificUserRead,
            specificUser), specificUser);
        VerifySpecificReadRules(BuildFileSecurity(
            DirectoryAccessMode.SpecificUserRead,
            specificUser), specificUser);
    }

    private static void VerifySpecificReadRules(
        FileSystemSecurity security,
        SecurityIdentifier specificUser)
    {
        var rules = security.GetAccessRules(
                includeExplicit: true,
                includeInherited: false,
                typeof(SecurityIdentifier))
            .Cast<FileSystemAccessRule>()
            .ToArray();
        var userRights = rules
            .Where(rule => Equals(rule.IdentityReference, specificUser))
            .Aggregate(
                (FileSystemRights)0,
                (rights, rule) => rights | rule.FileSystemRights);
        var writeRights = FileSystemRights.WriteData
            | FileSystemRights.AppendData
            | FileSystemRights.Delete
            | FileSystemRights.ChangePermissions
            | FileSystemRights.TakeOwnership;
        if ((userRights & FileSystemRights.ReadAndExecute) != FileSystemRights.ReadAndExecute
            || (userRights & writeRights) != 0
            || rules.Any(rule => Equals(rule.IdentityReference, BuiltinUsersSid())))
        {
            throw new InvalidOperationException("HP_CODEX_SANDBOX_ACL_CONTRACT_INVALID");
        }
    }

    private static DirectorySecurity BuildDirectorySecurity(
        DirectoryAccessMode accessMode,
        SecurityIdentifier? specificUser)
    {
        var security = new DirectorySecurity();
        security.SetOwner(BuiltinAdministratorsSid());
        security.SetGroup(BuiltinAdministratorsSid());
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        AddDirectoryRule(security, LocalSystemSid(), FileSystemRights.FullControl);
        AddDirectoryRule(security, BuiltinAdministratorsSid(), FileSystemRights.FullControl);
        switch (accessMode)
        {
            case DirectoryAccessMode.UsersRead:
                AddDirectoryRule(security, BuiltinUsersSid(), FileSystemRights.ReadAndExecute);
                break;
            case DirectoryAccessMode.SpecificUserRead:
                AddDirectoryRule(
                    security,
                    specificUser
                        ?? throw new InvalidOperationException("HP_CODEX_SANDBOX_TARGET_SID_REQUIRED"),
                    FileSystemRights.ReadAndExecute);
                break;
            case DirectoryAccessMode.SpecificUserModify:
                AddDirectoryRule(
                    security,
                    specificUser
                        ?? throw new InvalidOperationException("HP_CODEX_SANDBOX_TARGET_SID_REQUIRED"),
                    FileSystemRights.Modify | FileSystemRights.Synchronize);
                break;
        }
        return security;
    }

    private static FileSecurity BuildFileSecurity(
        DirectoryAccessMode accessMode,
        SecurityIdentifier? specificUser)
    {
        var security = new FileSecurity();
        security.SetOwner(BuiltinAdministratorsSid());
        security.SetGroup(BuiltinAdministratorsSid());
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        AddFileRule(security, LocalSystemSid(), FileSystemRights.FullControl);
        AddFileRule(security, BuiltinAdministratorsSid(), FileSystemRights.FullControl);
        switch (accessMode)
        {
            case DirectoryAccessMode.UsersRead:
                AddFileRule(security, BuiltinUsersSid(), FileSystemRights.ReadAndExecute);
                break;
            case DirectoryAccessMode.SpecificUserRead:
                AddFileRule(
                    security,
                    specificUser
                        ?? throw new InvalidOperationException("HP_CODEX_SANDBOX_TARGET_SID_REQUIRED"),
                    FileSystemRights.ReadAndExecute);
                break;
            case DirectoryAccessMode.SpecificUserModify:
                AddFileRule(
                    security,
                    specificUser
                        ?? throw new InvalidOperationException("HP_CODEX_SANDBOX_TARGET_SID_REQUIRED"),
                    FileSystemRights.Modify | FileSystemRights.Synchronize);
                break;
        }
        return security;
    }

    private static void AddDirectoryRule(
        DirectorySecurity security,
        SecurityIdentifier sid,
        FileSystemRights rights)
    {
        security.AddAccessRule(new FileSystemAccessRule(
            sid,
            rights,
            InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit,
            PropagationFlags.None,
            AccessControlType.Allow));
    }

    private static void AddFileRule(
        FileSecurity security,
        SecurityIdentifier sid,
        FileSystemRights rights)
    {
        security.AddAccessRule(new FileSystemAccessRule(
            sid,
            rights,
            AccessControlType.Allow));
    }

    private static void VerifyDirectoryHandle(SafeFileHandle handle)
    {
        if (!GetFileInformationByHandleEx(
            handle,
            FileAttributeTagInfoClass,
            out var info,
            (uint)Marshal.SizeOf<FileAttributeTagInfo>()))
        {
            throw new InvalidOperationException("HP_CODEX_SANDBOX_TARGET_IDENTITY_UNAVAILABLE");
        }
        if ((info.FileAttributes & (uint)FileAttributes.Directory) == 0
            || (info.FileAttributes & (uint)FileAttributes.ReparsePoint) != 0
            || info.ReparseTag != 0)
        {
            throw new InvalidOperationException("HP_CODEX_SANDBOX_TARGET_REPARSE_REJECTED");
        }
    }

    private static void VerifySecurity(string path, DirectorySecurity expected)
    {
        var actual = FileSystemAclExtensions.GetAccessControl(
            new DirectoryInfo(path),
            AccessControlSections.Owner | AccessControlSections.Group | AccessControlSections.Access);
        if (!actual.AreAccessRulesProtected
            || !Equals(actual.GetOwner(typeof(SecurityIdentifier)), BuiltinAdministratorsSid())
            || !string.Equals(
                actual.GetSecurityDescriptorSddlForm(
                    AccessControlSections.Owner
                    | AccessControlSections.Group
                    | AccessControlSections.Access),
                expected.GetSecurityDescriptorSddlForm(
                    AccessControlSections.Owner
                    | AccessControlSections.Group
                    | AccessControlSections.Access),
                StringComparison.Ordinal))
        {
            throw new InvalidOperationException("HP_CODEX_SANDBOX_TARGET_ACL_MISMATCH");
        }
    }

    private static SecurityIdentifier BuiltinAdministratorsSid() =>
        new(WellKnownSidType.BuiltinAdministratorsSid, domainSid: null);

    private static SecurityIdentifier BuiltinUsersSid() =>
        new(WellKnownSidType.BuiltinUsersSid, domainSid: null);

    private static SecurityIdentifier LocalSystemSid() =>
        new(WellKnownSidType.LocalSystemSid, domainSid: null);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandleEx(
        SafeFileHandle fileHandle,
        int fileInformationClass,
        out FileAttributeTagInfo fileInformation,
        uint bufferSize);

    [StructLayout(LayoutKind.Sequential)]
    private struct FileAttributeTagInfo
    {
        internal uint FileAttributes;
        internal uint ReparseTag;
    }
}
