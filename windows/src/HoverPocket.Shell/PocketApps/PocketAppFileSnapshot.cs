using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace HoverPocket.Shell.PocketApps;

internal readonly record struct PocketAppFileIdentity(
    uint VolumeSerialNumber,
    ulong FileIndex,
    long Size,
    long LastWriteTicks);

internal sealed record PocketAppFileSnapshot(
    string RootDirectory,
    IReadOnlyDictionary<string, byte[]> Files,
    IReadOnlyDictionary<string, PocketAppFileIdentity> Identities)
{
    private const int MaximumInventoryEntries = 256;
    private const int MaximumDirectoryDepth = 16;

    public static PocketAppFileSnapshot Capture(string directory)
    {
        var root = Path.GetFullPath(directory);
        using var rootHandle = OpenDirectory(root);
        var rootIdentity = Identity(rootHandle);
        var rootFinalPath = FinalPath(rootHandle);
        var paths = Inventory(root);
        var files = new Dictionary<string, byte[]>(StringComparer.Ordinal);
        var identities = new Dictionary<string, PocketAppFileIdentity>(StringComparer.Ordinal);
        var total = 0;
        foreach (var relativePath in paths.Order(StringComparer.Ordinal))
        {
            var captured = ReadStable(root, rootFinalPath, relativePath);
            total = checked(total + captured.Data.Length);
            if (captured.Data.Length > PocketAppPackageRuntime.MaximumFileBytes
                || files.Count >= PocketAppPackageRuntime.MaximumFiles
                || total > PocketAppPackageRuntime.MaximumPackageBytes)
            {
                throw new PocketAppPackageRuntimeException("$:package_size");
            }
            files.Add(relativePath, captured.Data);
            identities.Add(relativePath, captured.Identity);
        }

        if (!paths.SetEquals(Inventory(root)) || Identity(rootHandle) != rootIdentity)
        {
            throw new PocketAppPackageRuntimeException("$:package_changed");
        }
        foreach (var relativePath in paths)
        {
            var current = ReadIdentityStable(root, rootFinalPath, relativePath);
            if (current != identities[relativePath])
            {
                throw new PocketAppPackageRuntimeException("$:package_changed");
            }
        }
        return new PocketAppFileSnapshot(root, files, identities);
    }

    public static byte[] ReadFileNoFollow(string rootDirectory, string relativePath, int maximumBytes)
    {
        var root = Path.GetFullPath(rootDirectory);
        using var rootHandle = OpenDirectory(root);
        var rootFinalPath = FinalPath(rootHandle);
        var captured = ReadStable(root, rootFinalPath, relativePath);
        if (captured.Data.Length > maximumBytes)
        {
            throw new PocketAppPackageRuntimeException("$:host_file_size");
        }
        return captured.Data;
    }

    public void Materialize(string directory)
    {
        if (Directory.Exists(directory) || File.Exists(directory))
        {
            throw new PocketAppPackageRuntimeException("$:materialize_exists");
        }
        Directory.CreateDirectory(directory);
        try
        {
            foreach (var item in Files.OrderBy(item => item.Key, StringComparer.Ordinal))
            {
                var target = Path.Combine(directory, item.Key.Replace('/', Path.DirectorySeparatorChar));
                var parent = Path.GetDirectoryName(target) ?? directory;
                Directory.CreateDirectory(parent);
                using var stream = new FileStream(target, FileMode.CreateNew, FileAccess.Write, FileShare.None);
                stream.Write(item.Value);
                stream.Flush(true);
                File.SetAttributes(target, FileAttributes.Normal);
            }
        }
        catch
        {
            try { Directory.Delete(directory, true); } catch { }
            throw;
        }
    }

    private static HashSet<string> Inventory(string root)
    {
        var result = new HashSet<string>(StringComparer.Ordinal);
        var entryCount = 0;
        Visit(root, root, result, 0, ref entryCount);
        if (result.Count > PocketAppPackageRuntime.MaximumFiles)
        {
            throw new PocketAppPackageRuntimeException("$:package_size");
        }
        return result;
    }

    private static void Visit(string root, string current, HashSet<string> result, int depth, ref int entryCount)
    {
        foreach (var entry in Directory.EnumerateFileSystemEntries(current).Order(StringComparer.Ordinal))
        {
            entryCount++;
            if (entryCount > MaximumInventoryEntries)
            {
                throw new PocketAppPackageRuntimeException("$:package_size");
            }
            var entryDepth = depth + 1;
            if (entryDepth > MaximumDirectoryDepth)
            {
                throw new PocketAppPackageRuntimeException("$:package_depth");
            }
            var attributes = File.GetAttributes(entry);
            if (attributes.HasFlag(FileAttributes.ReparsePoint))
            {
                throw new PocketAppPackageRuntimeException("$:package_symlink");
            }
            if (attributes.HasFlag(FileAttributes.Directory))
            {
                Visit(root, entry, result, entryDepth, ref entryCount);
                continue;
            }
            var relative = Path.GetRelativePath(root, entry).Replace(Path.DirectorySeparatorChar, '/');
            if (!SafeRelativePath(relative) || !result.Add(relative))
            {
                throw new PocketAppPackageRuntimeException("$:package_path");
            }
        }
    }

    private static (byte[] Data, PocketAppFileIdentity Identity) ReadStable(
        string root,
        string rootFinalPath,
        string relativePath)
    {
        if (!SafeRelativePath(relativePath))
        {
            throw new PocketAppPackageRuntimeException("$:package_path");
        }
        using var parents = OpenParents(root, relativePath);
        var fullPath = Path.Combine(root, relativePath.Replace('/', Path.DirectorySeparatorChar));
        using var handle = OpenFile(fullPath);
        var identityBefore = Identity(handle);
        if (identityBefore.Size < 0 || identityBefore.Size > PocketAppPackageRuntime.MaximumFileBytes)
        {
            throw new PocketAppPackageRuntimeException("$:package_file_size");
        }
        var finalPath = FinalPath(handle);
        if (!MatchesExpectedPath(rootFinalPath, relativePath, finalPath))
        {
            throw new PocketAppPackageRuntimeException("$:package_reference");
        }
        var attributes = File.GetAttributes(fullPath);
        if (attributes.HasFlag(FileAttributes.ReparsePoint) || attributes.HasFlag(FileAttributes.Directory))
        {
            throw new PocketAppPackageRuntimeException("$:package_symlink");
        }

        var first = ReadExactly(handle, checked((int)identityBefore.Size));
        var second = ReadExactly(handle, checked((int)identityBefore.Size));
        var identityAfter = Identity(handle);
        if (!first.AsSpan().SequenceEqual(second) || identityBefore != identityAfter)
        {
            throw new PocketAppPackageRuntimeException("$:package_changed");
        }
        parents.VerifyUnchanged();
        return (first, identityBefore);
    }

    private static PocketAppFileIdentity ReadIdentityStable(string root, string rootFinalPath, string relativePath)
    {
        using var parents = OpenParents(root, relativePath);
        var fullPath = Path.Combine(root, relativePath.Replace('/', Path.DirectorySeparatorChar));
        using var handle = OpenFile(fullPath);
        if (!MatchesExpectedPath(rootFinalPath, relativePath, FinalPath(handle)))
        {
            throw new PocketAppPackageRuntimeException("$:package_reference");
        }
        var result = Identity(handle);
        parents.VerifyUnchanged();
        return result;
    }

    private static ParentHandleSet OpenParents(string root, string relativePath)
    {
        var handles = new List<(string Path, SafeFileHandle Handle, PocketAppFileIdentity Identity)>();
        try
        {
            var current = root;
            handles.Add((current, OpenDirectory(current), default));
            handles[0] = (current, handles[0].Handle, Identity(handles[0].Handle));
            foreach (var component in relativePath.Split('/').SkipLast(1))
            {
                current = Path.Combine(current, component);
                var handle = OpenDirectory(current);
                handles.Add((current, handle, Identity(handle)));
            }
            return new ParentHandleSet(handles);
        }
        catch
        {
            foreach (var item in handles) { item.Handle.Dispose(); }
            throw;
        }
    }

    private sealed class ParentHandleSet(List<(string Path, SafeFileHandle Handle, PocketAppFileIdentity Identity)> items) : IDisposable
    {
        public void VerifyUnchanged()
        {
            foreach (var item in items)
            {
                var attributes = File.GetAttributes(item.Path);
                using var current = OpenDirectory(item.Path);
                if (attributes.HasFlag(FileAttributes.ReparsePoint)
                    || !attributes.HasFlag(FileAttributes.Directory)
                    || Identity(item.Handle) != item.Identity
                    || Identity(current) != item.Identity)
                {
                    throw new PocketAppPackageRuntimeException("$:package_changed");
                }
            }
        }

        public void Dispose()
        {
            foreach (var item in items) { item.Handle.Dispose(); }
        }
    }

    private static byte[] ReadExactly(SafeFileHandle handle, int size)
    {
        var data = new byte[size];
        var offset = 0;
        while (offset < data.Length)
        {
            var count = RandomAccess.Read(handle, data.AsSpan(offset), offset);
            if (count <= 0) { throw new PocketAppPackageRuntimeException("$:package_read"); }
            offset += count;
        }
        Span<byte> probe = stackalloc byte[1];
        if (RandomAccess.Read(handle, probe, size) != 0)
        {
            throw new PocketAppPackageRuntimeException("$:package_changed");
        }
        return data;
    }

    private static SafeFileHandle OpenDirectory(string path) => OpenHandle(
        path,
        FileAccessMask.GenericRead,
        FileShareMask.Read,
        CreationDisposition.OpenExisting,
        FileFlags.BackupSemantics | FileFlags.OpenReparsePoint);

    private static SafeFileHandle OpenFile(string path) => OpenHandle(
        path,
        FileAccessMask.GenericRead,
        FileShareMask.Read,
        CreationDisposition.OpenExisting,
        FileFlags.SequentialScan | FileFlags.OpenReparsePoint);

    private static SafeFileHandle OpenHandle(
        string path,
        FileAccessMask access,
        FileShareMask share,
        CreationDisposition disposition,
        FileFlags flags)
    {
        var handle = CreateFileW(path, access, share, IntPtr.Zero, disposition, flags, IntPtr.Zero);
        if (handle.IsInvalid)
        {
            handle.Dispose();
            throw new PocketAppPackageRuntimeException("$:package_open");
        }
        if (!GetFileInformationByHandle(handle, out var information))
        {
            handle.Dispose();
            throw new PocketAppPackageRuntimeException("$:package_identity");
        }
        if ((information.FileAttributes & (uint)FileAttributes.ReparsePoint) != 0)
        {
            handle.Dispose();
            throw new PocketAppPackageRuntimeException("$:package_symlink");
        }
        return handle;
    }

    private static PocketAppFileIdentity Identity(SafeFileHandle handle)
    {
        if (!GetFileInformationByHandle(handle, out var info))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        var index = ((ulong)info.FileIndexHigh << 32) | info.FileIndexLow;
        var size = ((long)info.FileSizeHigh << 32) | info.FileSizeLow;
        var ticks = ((long)info.LastWriteTimeHigh << 32) | info.LastWriteTimeLow;
        return new PocketAppFileIdentity(info.VolumeSerialNumber, index, size, ticks);
    }

    private static string FinalPath(SafeFileHandle handle)
    {
        var buffer = new char[32_768];
        var count = GetFinalPathNameByHandleW(handle, buffer, (uint)buffer.Length, 0);
        if (count == 0 || count >= buffer.Length)
        {
            throw new PocketAppPackageRuntimeException("$:package_identity");
        }
        var path = new string(buffer, 0, checked((int)count));
        if (path.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase))
        {
            path = @"\\" + path[8..];
        }
        else if (path.StartsWith(@"\\?\", StringComparison.Ordinal))
        {
            path = path[4..];
        }
        return Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar);
    }

    private static bool MatchesExpectedPath(string root, string relativePath, string candidate)
    {
        var expected = Path.GetFullPath(
            Path.Combine(root, relativePath.Replace('/', Path.DirectorySeparatorChar)))
            .TrimEnd(Path.DirectorySeparatorChar);
        var observed = Path.GetFullPath(candidate).TrimEnd(Path.DirectorySeparatorChar);
        return string.Equals(expected, observed, StringComparison.OrdinalIgnoreCase);
    }

    private static bool SafeRelativePath(string value)
    {
        if (string.IsNullOrEmpty(value) || value.StartsWith('/') || value.Contains('\\') || value.Contains('\0'))
        {
            return false;
        }
        foreach (var component in value.Split('/'))
        {
            if (component.Length == 0 || component is "." or ".."
                || component.Any(character => !(char.IsAsciiLetterOrDigit(character) || character is '.' or '_' or '-')))
            {
                return false;
            }
        }
        return true;
    }

    [Flags]
    private enum FileAccessMask : uint { GenericRead = 0x80000000 }
    [Flags]
    private enum FileShareMask : uint { Read = 0x00000001 }
    private enum CreationDisposition : uint { OpenExisting = 3 }
    [Flags]
    private enum FileFlags : uint
    {
        SequentialScan = 0x08000000,
        BackupSemantics = 0x02000000,
        OpenReparsePoint = 0x00200000
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ByHandleFileInformation
    {
        public uint FileAttributes;
        public uint CreationTimeLow;
        public uint CreationTimeHigh;
        public uint LastAccessTimeLow;
        public uint LastAccessTimeHigh;
        public uint LastWriteTimeLow;
        public uint LastWriteTimeHigh;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(
        string fileName,
        FileAccessMask desiredAccess,
        FileShareMask shareMode,
        IntPtr securityAttributes,
        CreationDisposition creationDisposition,
        FileFlags flagsAndAttributes,
        IntPtr templateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandle(
        SafeFileHandle file,
        out ByHandleFileInformation information);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetFinalPathNameByHandleW(
        SafeFileHandle file,
        [Out] char[] filePath,
        uint filePathLength,
        uint flags);
}
