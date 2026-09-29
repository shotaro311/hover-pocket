using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using Microsoft.Win32.SafeHandles;

namespace HoverPocket.Shell.PocketApps;

internal readonly record struct CodexSandboxSetupFileIdentity(
    uint VolumeSerialNumber,
    ulong FileIndex);

internal sealed record CodexSandboxSetupPublisherReadback(
    bool Trusted,
    string? CertificateSha256);

internal interface ICodexSandboxSetupHelperLease : IDisposable
{
    string FullPath { get; }

    CodexSandboxSetupFileIdentity Identity { get; }

    void ValidateIdentity();

    void ValidateProcessImage(string processImagePath);
}

internal interface ICodexSandboxSetupHelperResolver
{
    ICodexSandboxSetupHelperLease Resolve();
}

internal sealed class CodexSandboxSetupHelperResolver : ICodexSandboxSetupHelperResolver
{
    private const uint WtdRevokeWholeChain = 1;
    private const uint WtdRevocationCheckChainExcludeRoot = 0x00000080;
    private const uint WtdDisableMd2Md4 = 0x00002000;

    internal const string MetadataInvalidCode = "GENERATOR_SANDBOX_HELPER_METADATA_INVALID";
    internal const string OriginInvalidCode = "GENERATOR_SANDBOX_HELPER_ORIGIN_INVALID";
    internal const string ObjectInvalidCode = "GENERATOR_SANDBOX_HELPER_OBJECT_INVALID";
    internal const string PublisherInvalidCode = "GENERATOR_SANDBOX_HELPER_PUBLISHER_INVALID";
    internal const string IdentityChangedCode = "GENERATOR_SANDBOX_HELPER_IDENTITY_CHANGED";
    internal const string FixedRelativePath = @"HoverPocket\CodexSandboxSetup\HoverPocket.CodexSandboxSetup.exe";

    private const string CertificateMetadataKey = "HoverPocketPublisherCertificateSha256";
    private static readonly Guid ProgramFilesX64FolderId = new(
        "6D809377-6AF0-444B-8957-A3773F02200E");

    private readonly Func<string> _programFilesPath;
    private readonly Func<string?> _expectedPublisherCertificateSha256;
    private readonly Func<string, CodexSandboxSetupPublisherReadback> _publisherReadback;

    internal static (uint RevocationChecks, uint ProviderFlags) TrustPolicyForVerify => (
        WtdRevokeWholeChain,
        WtdRevocationCheckChainExcludeRoot | WtdDisableMd2Md4);

    public CodexSandboxSetupHelperResolver()
        : this(
            ResolveProgramFilesX64,
            ReadExpectedPublisherCertificateSha256,
            ReadPublisher)
    {
    }

    internal CodexSandboxSetupHelperResolver(
        Func<string> programFilesPath,
        Func<string?> expectedPublisherCertificateSha256,
        Func<string, CodexSandboxSetupPublisherReadback> publisherReadback)
    {
        _programFilesPath = programFilesPath;
        _expectedPublisherCertificateSha256 = expectedPublisherCertificateSha256;
        _publisherReadback = publisherReadback;
    }

    public ICodexSandboxSetupHelperLease Resolve()
    {
        if (!TryNormalizeSha256(
            _expectedPublisherCertificateSha256(),
            out var expectedCertificateSha256))
        {
            throw Failure(MetadataInvalidCode);
        }

        var helperPath = ResolveFixedPath(_programFilesPath());
        CodexSandboxSetupHelperLease? lease = null;
        try
        {
            lease = CodexSandboxSetupHelperLease.Open(helperPath);
            lease.ValidateIdentity();
            var publisher = _publisherReadback(helperPath);
            if (!publisher.Trusted
                || !TryNormalizeSha256(
                    publisher.CertificateSha256,
                    out var actualCertificateSha256)
                || !FixedTimeEquals(
                    expectedCertificateSha256,
                    actualCertificateSha256))
            {
                throw Failure(PublisherInvalidCode);
            }

            lease.ValidateIdentity();
            return lease;
        }
        catch
        {
            lease?.Dispose();
            throw;
        }
    }

    internal static string ResolveFixedPath(string programFilesRoot)
    {
        if (string.IsNullOrWhiteSpace(programFilesRoot)
            || !Path.IsPathFullyQualified(programFilesRoot))
        {
            throw Failure(OriginInvalidCode);
        }

        string root;
        try
        {
            root = Path.GetFullPath(programFilesRoot);
        }
        catch (Exception exception) when (exception is ArgumentException
            or NotSupportedException
            or PathTooLongException)
        {
            throw Failure(OriginInvalidCode);
        }
        if (root.StartsWith("\\\\", StringComparison.Ordinal))
        {
            throw Failure(OriginInvalidCode);
        }

        var helperPath = Path.GetFullPath(Path.Combine(
            root,
            "HoverPocket",
            "CodexSandboxSetup",
            "HoverPocket.CodexSandboxSetup.exe"));
        var expectedPrefix = root.EndsWith(Path.DirectorySeparatorChar)
            ? root
            : root + Path.DirectorySeparatorChar;
        if (!helperPath.StartsWith(expectedPrefix, StringComparison.OrdinalIgnoreCase)
            || !string.Equals(
                Path.GetRelativePath(root, helperPath),
                FixedRelativePath,
                StringComparison.OrdinalIgnoreCase))
        {
            throw Failure(OriginInvalidCode);
        }
        return helperPath;
    }

    private static string ResolveProgramFilesX64()
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException();
        }

        var folderId = ProgramFilesX64FolderId;
        var result = SHGetKnownFolderPath(
            ref folderId,
            flags: 0,
            token: IntPtr.Zero,
            out var rawPath);
        if (result < 0 || rawPath == IntPtr.Zero)
        {
            throw Failure(OriginInvalidCode);
        }
        try
        {
            return Marshal.PtrToStringUni(rawPath)
                ?? throw Failure(OriginInvalidCode);
        }
        finally
        {
            Marshal.FreeCoTaskMem(rawPath);
        }
    }

    private static string? ReadExpectedPublisherCertificateSha256()
    {
        var values = Assembly.GetExecutingAssembly()
            .GetCustomAttributes<AssemblyMetadataAttribute>()
            .Where(attribute => string.Equals(
                attribute.Key,
                CertificateMetadataKey,
                StringComparison.Ordinal))
            .Select(attribute => attribute.Value)
            .ToArray();
        return values.Length == 1 ? values[0] : null;
    }

    private static CodexSandboxSetupPublisherReadback ReadPublisher(string path)
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException();
        }
        if (!VerifyTrust(path))
        {
            return new CodexSandboxSetupPublisherReadback(false, null);
        }

        try
        {
#pragma warning disable SYSLIB0057
            using var certificate = new X509Certificate2(
                X509Certificate.CreateFromSignedFile(path));
#pragma warning restore SYSLIB0057
            return new CodexSandboxSetupPublisherReadback(
                true,
                Convert.ToHexStringLower(SHA256.HashData(certificate.RawData)));
        }
        catch (CryptographicException)
        {
            return new CodexSandboxSetupPublisherReadback(false, null);
        }
    }

    private static bool VerifyTrust(string path)
    {
        var actionId = new Guid("00AAC56B-CD44-11D0-8CC2-00C04FC295EE");
        var pathPointer = Marshal.StringToCoTaskMemUni(path);
        var fileInfoPointer = IntPtr.Zero;
        try
        {
            var fileInfo = new WinTrustFileInfo
            {
                StructSize = (uint)Marshal.SizeOf<WinTrustFileInfo>(),
                FilePath = pathPointer,
            };
            fileInfoPointer = Marshal.AllocCoTaskMem(Marshal.SizeOf<WinTrustFileInfo>());
            Marshal.StructureToPtr(fileInfo, fileInfoPointer, fDeleteOld: false);
            var trustPolicy = TrustPolicyForVerify;
            var trustData = new WinTrustData
            {
                StructSize = (uint)Marshal.SizeOf<WinTrustData>(),
                UiChoice = 2,
                RevocationChecks = trustPolicy.RevocationChecks,
                UnionChoice = 1,
                FileInfo = fileInfoPointer,
                StateAction = 0,
                ProviderFlags = trustPolicy.ProviderFlags,
                UiContext = 0,
            };
            return WinVerifyTrust(
                new IntPtr(-1),
                actionId,
                ref trustData) == 0;
        }
        finally
        {
            if (fileInfoPointer != IntPtr.Zero)
            {
                Marshal.FreeCoTaskMem(fileInfoPointer);
            }
            Marshal.FreeCoTaskMem(pathPointer);
        }
    }

    private static bool TryNormalizeSha256(string? value, out string normalized)
    {
        normalized = string.Empty;
        if (value is null || value.Length != 64)
        {
            return false;
        }
        foreach (var character in value)
        {
            if (!Uri.IsHexDigit(character))
            {
                return false;
            }
        }
        normalized = value.ToLowerInvariant();
        return true;
    }

    private static bool FixedTimeEquals(string left, string right) =>
        CryptographicOperations.FixedTimeEquals(
            System.Text.Encoding.ASCII.GetBytes(left),
            System.Text.Encoding.ASCII.GetBytes(right));

    private static InvalidOperationException Failure(string code) => new(code);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern int SHGetKnownFolderPath(
        ref Guid folderId,
        uint flags,
        IntPtr token,
        out IntPtr path);

    [DllImport("wintrust.dll", ExactSpelling = true, SetLastError = true)]
    private static extern int WinVerifyTrust(
        IntPtr windowHandle,
        [MarshalAs(UnmanagedType.LPStruct)] Guid actionId,
        ref WinTrustData trustData);

    [StructLayout(LayoutKind.Sequential)]
    private struct WinTrustFileInfo
    {
        internal uint StructSize;
        internal IntPtr FilePath;
        internal IntPtr FileHandle;
        internal IntPtr KnownSubject;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct WinTrustData
    {
        internal uint StructSize;
        internal IntPtr PolicyCallbackData;
        internal IntPtr SipClientData;
        internal uint UiChoice;
        internal uint RevocationChecks;
        internal uint UnionChoice;
        internal IntPtr FileInfo;
        internal uint StateAction;
        internal IntPtr StateData;
        internal IntPtr UrlReference;
        internal uint ProviderFlags;
        internal uint UiContext;
        internal IntPtr SignatureSettings;
    }
}

internal sealed class CodexSandboxSetupHelperLease : ICodexSandboxSetupHelperLease
{
    private const uint GenericRead = 0x80000000;
    private const uint FileShareRead = 0x00000001;
    private const uint FileShareWrite = 0x00000002;
    private const uint OpenExisting = 3;
    private const uint FileFlagBackupSemantics = 0x02000000;
    private const uint FileFlagOpenReparsePoint = 0x00200000;
    private const uint FileTypeDisk = 0x0001;

    private readonly IReadOnlyList<PinnedDirectory> _directories;
    private readonly SafeFileHandle _fileHandle;
    private bool _disposed;

    private CodexSandboxSetupHelperLease(
        string fullPath,
        IReadOnlyList<PinnedDirectory> directories,
        SafeFileHandle fileHandle,
        CodexSandboxSetupFileIdentity identity)
    {
        FullPath = fullPath;
        _directories = directories;
        _fileHandle = fileHandle;
        Identity = identity;
    }

    public string FullPath { get; }

    public CodexSandboxSetupFileIdentity Identity { get; }

    internal static CodexSandboxSetupHelperLease Open(string fullPath)
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException();
        }

        var normalized = Path.GetFullPath(fullPath);
        var directoryPath = Path.GetDirectoryName(normalized)
            ?? throw Failure(CodexSandboxSetupHelperResolver.OriginInvalidCode);
        var directories = new List<PinnedDirectory>();
        SafeFileHandle? fileHandle = null;
        var ownershipTransferred = false;
        try
        {
            foreach (var component in EnumerateDirectoryComponents(directoryPath))
            {
                var handle = OpenDirectory(component);
                var transferred = false;
                try
                {
                    var information = ReadInformation(handle);
                    VerifyDirectory(information);
                    directories.Add(new PinnedDirectory(
                        component,
                        handle,
                        IdentityOf(information)));
                    transferred = true;
                }
                finally
                {
                    if (!transferred)
                    {
                        handle.Dispose();
                    }
                }
            }

            fileHandle = OpenRegularFile(normalized);
            var fileInformation = ReadInformation(fileHandle);
            VerifyRegularFile(fileInformation);
            var lease = new CodexSandboxSetupHelperLease(
                normalized,
                directories.ToArray(),
                fileHandle,
                IdentityOf(fileInformation));
            fileHandle = null;
            ownershipTransferred = true;
            return lease;
        }
        catch (InvalidOperationException)
        {
            throw;
        }
        catch (Exception exception) when (exception is IOException
            or UnauthorizedAccessException
            or System.ComponentModel.Win32Exception)
        {
            throw Failure(CodexSandboxSetupHelperResolver.ObjectInvalidCode);
        }
        finally
        {
            fileHandle?.Dispose();
            if (!ownershipTransferred)
            {
                DisposeDirectories(directories);
            }
        }
    }

    public void ValidateIdentity()
    {
        ThrowIfDisposed();
        try
        {
            foreach (var directory in _directories)
            {
                var pinnedInformation = ReadInformation(directory.Handle);
                VerifyDirectory(pinnedInformation);
                if (IdentityOf(pinnedInformation) != directory.Identity)
                {
                    throw Failure(CodexSandboxSetupHelperResolver.IdentityChangedCode);
                }

                using var currentHandle = OpenDirectory(directory.Path);
                var currentInformation = ReadInformation(currentHandle);
                VerifyDirectory(currentInformation);
                if (IdentityOf(currentInformation) != directory.Identity)
                {
                    throw Failure(CodexSandboxSetupHelperResolver.IdentityChangedCode);
                }
            }

            var pinnedFileInformation = ReadInformation(_fileHandle);
            VerifyRegularFile(pinnedFileInformation);
            if (IdentityOf(pinnedFileInformation) != Identity)
            {
                throw Failure(CodexSandboxSetupHelperResolver.IdentityChangedCode);
            }

            using var currentFileHandle = OpenRegularFile(FullPath);
            var currentFileInformation = ReadInformation(currentFileHandle);
            VerifyRegularFile(currentFileInformation);
            if (IdentityOf(currentFileInformation) != Identity)
            {
                throw Failure(CodexSandboxSetupHelperResolver.IdentityChangedCode);
            }
        }
        catch (InvalidOperationException)
        {
            throw;
        }
        catch (Exception exception) when (exception is IOException
            or UnauthorizedAccessException
            or System.ComponentModel.Win32Exception)
        {
            throw Failure(CodexSandboxSetupHelperResolver.IdentityChangedCode);
        }
    }

    public void ValidateProcessImage(string processImagePath)
    {
        ThrowIfDisposed();
        string normalized;
        try
        {
            normalized = NormalizeComparablePath(processImagePath);
        }
        catch (Exception exception) when (exception is ArgumentException
            or NotSupportedException
            or PathTooLongException)
        {
            throw Failure(CodexSandboxSetupHelperResolver.IdentityChangedCode);
        }
        if (!string.Equals(
            NormalizeComparablePath(FullPath),
            normalized,
            StringComparison.OrdinalIgnoreCase))
        {
            throw Failure(CodexSandboxSetupHelperResolver.IdentityChangedCode);
        }

        try
        {
            using var processImageHandle = OpenRegularFile(normalized);
            var information = ReadInformation(processImageHandle);
            VerifyRegularFile(information);
            if (IdentityOf(information) != Identity)
            {
                throw Failure(CodexSandboxSetupHelperResolver.IdentityChangedCode);
            }
        }
        catch (InvalidOperationException)
        {
            throw;
        }
        catch (Exception exception) when (exception is IOException
            or UnauthorizedAccessException
            or System.ComponentModel.Win32Exception)
        {
            throw Failure(CodexSandboxSetupHelperResolver.IdentityChangedCode);
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;
        _fileHandle.Dispose();
        DisposeDirectories(_directories);
    }

    private static IEnumerable<string> EnumerateDirectoryComponents(string directoryPath)
    {
        var root = Path.GetPathRoot(directoryPath)
            ?? throw Failure(CodexSandboxSetupHelperResolver.OriginInvalidCode);
        if (root.StartsWith("\\\\", StringComparison.Ordinal))
        {
            throw Failure(CodexSandboxSetupHelperResolver.OriginInvalidCode);
        }
        yield return root;
        var relative = Path.GetRelativePath(root, directoryPath);
        if (string.Equals(relative, ".", StringComparison.Ordinal))
        {
            yield break;
        }

        var current = root;
        foreach (var segment in relative.Split(
            Path.DirectorySeparatorChar,
            StringSplitOptions.RemoveEmptyEntries))
        {
            current = Path.Combine(current, segment);
            yield return current;
        }
    }

    private static SafeFileHandle OpenDirectory(string path) => OpenHandle(
        path,
        FileShareRead | FileShareWrite,
        FileFlagBackupSemantics | FileFlagOpenReparsePoint);

    private static SafeFileHandle OpenRegularFile(string path) => OpenHandle(
        path,
        FileShareRead,
        FileFlagOpenReparsePoint);

    private static SafeFileHandle OpenHandle(string path, uint shareMode, uint flags)
    {
        var handle = CreateFileW(
            path,
            GenericRead,
            shareMode,
            IntPtr.Zero,
            OpenExisting,
            flags,
            IntPtr.Zero);
        if (!handle.IsInvalid)
        {
            return handle;
        }

        var error = Marshal.GetLastWin32Error();
        handle.Dispose();
        throw new System.ComponentModel.Win32Exception(error);
    }

    private static ByHandleFileInformation ReadInformation(SafeFileHandle handle)
    {
        if (GetFileType(handle) != FileTypeDisk
            || !GetFileInformationByHandle(handle, out var information))
        {
            throw Failure(CodexSandboxSetupHelperResolver.ObjectInvalidCode);
        }
        return information;
    }

    private static void VerifyDirectory(ByHandleFileInformation information)
    {
        var attributes = (FileAttributes)information.FileAttributes;
        if ((attributes & FileAttributes.Directory) == 0
            || (attributes & FileAttributes.ReparsePoint) != 0)
        {
            throw Failure(CodexSandboxSetupHelperResolver.ObjectInvalidCode);
        }
    }

    private static void VerifyRegularFile(ByHandleFileInformation information)
    {
        var attributes = (FileAttributes)information.FileAttributes;
        if ((attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0)
        {
            throw Failure(CodexSandboxSetupHelperResolver.ObjectInvalidCode);
        }
    }

    private static CodexSandboxSetupFileIdentity IdentityOf(
        ByHandleFileInformation information) => new(
            information.VolumeSerialNumber,
            ((ulong)information.FileIndexHigh << 32) | information.FileIndexLow);

    private static string NormalizeComparablePath(string path)
    {
        var candidate = path.StartsWith("\\\\?\\", StringComparison.Ordinal)
            ? path[4..]
            : path;
        return Path.GetFullPath(candidate);
    }

    private static void DisposeDirectories(IEnumerable<PinnedDirectory> directories)
    {
        foreach (var directory in directories.Reverse())
        {
            directory.Handle.Dispose();
        }
    }

    private void ThrowIfDisposed()
    {
        if (_disposed)
        {
            throw new ObjectDisposedException(nameof(CodexSandboxSetupHelperLease));
        }
    }

    private static InvalidOperationException Failure(string code) => new(code);

    private sealed record PinnedDirectory(
        string Path,
        SafeFileHandle Handle,
        CodexSandboxSetupFileIdentity Identity);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandle(
        SafeFileHandle fileHandle,
        out ByHandleFileInformation fileInformation);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint GetFileType(SafeFileHandle fileHandle);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(
        string fileName,
        uint desiredAccess,
        uint shareMode,
        IntPtr securityAttributes,
        uint creationDisposition,
        uint flagsAndAttributes,
        IntPtr templateFile);

    [StructLayout(LayoutKind.Sequential)]
    private struct ByHandleFileInformation
    {
        internal uint FileAttributes;
        internal System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
        internal System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
        internal System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
        internal uint VolumeSerialNumber;
        internal uint FileSizeHigh;
        internal uint FileSizeLow;
        internal uint NumberOfLinks;
        internal uint FileIndexHigh;
        internal uint FileIndexLow;
    }
}
