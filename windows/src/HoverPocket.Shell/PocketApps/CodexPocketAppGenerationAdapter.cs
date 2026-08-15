using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace HoverPocket.Shell.PocketApps;

internal sealed class PocketAppPinnedDirectory : IDisposable
{
    private readonly SafeFileHandle _handle;
    private readonly FileIdentity _identity;
    private bool _disposed;

    public PocketAppPinnedDirectory(string path)
    {
        FullPath = Path.GetFullPath(path);
        if (FullPath.StartsWith("\\\\", StringComparison.Ordinal))
        {
            throw Failure("GENERATION_ROOT_UNSAFE");
        }
        EnsureNoReparsePath(FullPath, createMissing: true);
        _handle = OpenDirectory(FullPath);
        _identity = Identity(_handle);
        Validate();
    }

    public string FullPath { get; }

    public void Validate()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        EnsureNoReparsePath(FullPath, createMissing: false);
        using var current = OpenDirectory(FullPath);
        if (Identity(current) != _identity || Identity(_handle) != _identity)
        {
            throw Failure("GENERATION_ROOT_UNSAFE");
        }
    }

    public void Dispose()
    {
        if (_disposed) { return; }
        _handle.Dispose();
        _disposed = true;
    }

    private static void EnsureNoReparsePath(string path, bool createMissing)
    {
        var root = Path.GetPathRoot(path);
        if (string.IsNullOrEmpty(root) || root.StartsWith("\\\\", StringComparison.Ordinal))
        {
            throw Failure("GENERATION_ROOT_UNSAFE");
        }
        var relative = path[root.Length..];
        var current = root.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        if (current.Length == 2 && current[1] == ':') { current += Path.DirectorySeparatorChar; }
        foreach (var component in relative.Split(
            [Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar],
            StringSplitOptions.RemoveEmptyEntries))
        {
            if (Directory.Exists(current)
                && File.GetAttributes(current).HasFlag(FileAttributes.ReparsePoint))
            {
                throw Failure("GENERATION_ROOT_UNSAFE");
            }
            current = Path.Combine(current, component);
            if (!Directory.Exists(current))
            {
                if (!createMissing) { throw Failure("GENERATION_ROOT_UNSAFE"); }
                Directory.CreateDirectory(current);
            }
            var attributes = File.GetAttributes(current);
            if (!attributes.HasFlag(FileAttributes.Directory) || attributes.HasFlag(FileAttributes.ReparsePoint))
            {
                throw Failure("GENERATION_ROOT_UNSAFE");
            }
        }
    }

    private static SafeFileHandle OpenDirectory(string path)
    {
        var handle = CreateFile(
            path,
            0,
            FileShare.Read | FileShare.Write | FileShare.Delete,
            IntPtr.Zero,
            FileMode.Open,
            FileFlagsAndAttributes.BackupSemantics | FileFlagsAndAttributes.OpenReparsePoint,
            IntPtr.Zero);
        if (handle.IsInvalid)
        {
            handle.Dispose();
            throw Failure("GENERATION_ROOT_UNSAFE");
        }
        if (File.GetAttributes(path).HasFlag(FileAttributes.ReparsePoint))
        {
            handle.Dispose();
            throw Failure("GENERATION_ROOT_UNSAFE");
        }
        return handle;
    }

    private static FileIdentity Identity(SafeFileHandle handle)
    {
        if (!GetFileInformationByHandle(handle, out var information))
        {
            throw Failure("GENERATION_ROOT_UNSAFE");
        }
        return new FileIdentity(
            information.VolumeSerialNumber,
            ((ulong)information.FileIndexHigh << 32) | information.FileIndexLow);
    }

    private readonly record struct FileIdentity(uint VolumeSerialNumber, ulong FileIndex);

    [StructLayout(LayoutKind.Sequential)]
    private struct ByHandleFileInformation
    {
        public uint FileAttributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

    [Flags]
    private enum FileFlagsAndAttributes : uint
    {
        BackupSemantics = 0x02000000,
        OpenReparsePoint = 0x00200000
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFile(
        string fileName,
        uint desiredAccess,
        FileShare shareMode,
        IntPtr securityAttributes,
        FileMode creationDisposition,
        FileFlagsAndAttributes flagsAndAttributes,
        IntPtr templateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandle(
        SafeFileHandle file,
        out ByHandleFileInformation fileInformation);

    private static PocketAppGenerationException Failure(string code) => new(code);
}

internal sealed class CodexPocketAppGenerationAdapter : IPocketAppGenerationAdapter, IDisposable
{
    public bool AllowsActivation => false;

    public static string? ResolveExecutable()
    {
        // AN5-B intentionally keeps the Windows production generator disconnected.
        // Enablement requires a restricted-token/AppContainer canary that proves
        // repository, profile, and system-file reads fail from the Codex process.
        return null;
    }

    private static readonly string[] AllowedEnvironmentKeys =
    [
        "USERPROFILE", "HOMEDRIVE", "HOMEPATH", "LOCALAPPDATA", "APPDATA",
        "PATH", "TEMP", "TMP", "LANG"
    ];

    private readonly string _executable;
    private readonly PocketAppPinnedDirectory _workspaceRoot;
    private readonly TimeSpan _timeout;
    private bool _disposed;

    public CodexPocketAppGenerationAdapter(
        string executable,
        string workspaceRoot,
        TimeSpan? timeout = null)
    {
        if (string.IsNullOrWhiteSpace(executable)) { throw Failure("GENERATOR_UNAVAILABLE"); }
        _executable = executable;
        _workspaceRoot = new PocketAppPinnedDirectory(workspaceRoot);
        _timeout = timeout ?? TimeSpan.FromSeconds(60);
        if (_timeout < TimeSpan.FromSeconds(1) || _timeout > TimeSpan.FromMinutes(5))
        {
            throw Failure("GENERATION_REQUEST_INVALID");
        }
    }

    public async Task<PocketAppGenerationEnvelope> GenerateAsync(
        PocketAppGenerationRequest request,
        CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        request.Validate();
        _workspaceRoot.Validate();
        cancellationToken.ThrowIfCancellationRequested();

        var workspace = Path.Combine(_workspaceRoot.FullPath, $"codex-{Guid.NewGuid():N}");
        Directory.CreateDirectory(workspace);
        try
        {
            _workspaceRoot.Validate();
            var schemaPath = Path.Combine(workspace, "generation-output.schema.json");
            await File.WriteAllTextAsync(schemaPath, PocketAppGenerationContract.OutputSchemaJson, cancellationToken);
            File.SetAttributes(schemaPath, File.GetAttributes(schemaPath) | FileAttributes.ReadOnly);

            var start = new ProcessStartInfo
            {
                FileName = _executable,
                WorkingDirectory = workspace,
                UseShellExecute = false,
                RedirectStandardInput = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true
            };
            start.ArgumentList.Add("exec");
            start.ArgumentList.Add("--sandbox");
            start.ArgumentList.Add("read-only");
            start.ArgumentList.Add("--ephemeral");
            start.ArgumentList.Add("--ignore-user-config");
            start.ArgumentList.Add("--skip-git-repo-check");
            start.ArgumentList.Add("--output-schema");
            start.ArgumentList.Add(schemaPath);
            start.ArgumentList.Add("-");
            start.Environment.Clear();
            foreach (var key in AllowedEnvironmentKeys)
            {
                var value = Environment.GetEnvironmentVariable(key);
                if (!string.IsNullOrEmpty(value)) { start.Environment[key] = value; }
            }

            using var process = new Process { StartInfo = start };
            try
            {
                if (!process.Start()) { throw Failure("GENERATOR_UNAVAILABLE"); }
            }
            catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or InvalidOperationException)
            {
                throw Failure("GENERATOR_UNAVAILABLE");
            }

            var stdoutTask = ReadBoundedAsync(
                process.StandardOutput.BaseStream,
                PocketAppGenerationContract.MaximumOutputBytes,
                CancellationToken.None);
            var stderrTask = ReadBoundedAsync(
                process.StandardError.BaseStream,
                PocketAppGenerationContract.MaximumErrorBytes,
                CancellationToken.None);
            try
            {
                await process.StandardInput.WriteAsync(PocketAppGenerationContract.Prompt(request));
                process.StandardInput.Close();
            }
            catch
            {
                Kill(process);
                throw Failure("GENERATOR_PROCESS_FAILED");
            }

            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(_timeout);
            try
            {
                await process.WaitForExitAsync(timeout.Token);
            }
            catch (OperationCanceledException)
            {
                Kill(process);
                await DrainAsync(stdoutTask, stderrTask);
                throw Failure(cancellationToken.IsCancellationRequested
                    ? "GENERATOR_CANCELLED"
                    : "GENERATOR_TIMEOUT");
            }

            var stdout = await stdoutTask;
            var stderr = await stderrTask;
            if (stdout.Exceeded || stderr.Exceeded)
            {
                throw Failure("GENERATOR_OUTPUT_LIMIT");
            }
            if (process.ExitCode != 0)
            {
                throw Failure("GENERATOR_PROCESS_FAILED");
            }
            _workspaceRoot.Validate();
            return PocketAppGenerationContract.DecodeEnvelope(stdout.Data);
        }
        finally
        {
            MakeMutable(workspace);
            try { if (Directory.Exists(workspace)) { Directory.Delete(workspace, true); } } catch { }
        }
    }

    public void Dispose()
    {
        if (_disposed) { return; }
        _workspaceRoot.Dispose();
        _disposed = true;
    }

    private static async Task<(byte[] Data, bool Exceeded)> ReadBoundedAsync(
        Stream stream,
        int limit,
        CancellationToken cancellationToken)
    {
        using var output = new MemoryStream(capacity: Math.Min(limit, 64 * 1024));
        var buffer = new byte[8192];
        var exceeded = false;
        while (true)
        {
            var read = await stream.ReadAsync(buffer, cancellationToken);
            if (read == 0) { break; }
            var remaining = Math.Max(0, limit - checked((int)output.Length));
            if (remaining > 0)
            {
                output.Write(buffer, 0, Math.Min(remaining, read));
            }
            if (read > remaining) { exceeded = true; }
        }
        return (output.ToArray(), exceeded);
    }

    private static async Task DrainAsync(
        Task<(byte[] Data, bool Exceeded)> stdout,
        Task<(byte[] Data, bool Exceeded)> stderr)
    {
        try { await Task.WhenAll(stdout, stderr); } catch { }
    }

    private static void Kill(Process process)
    {
        try
        {
            if (!process.HasExited) { process.Kill(entireProcessTree: true); }
        }
        catch (InvalidOperationException) { }
        catch (System.ComponentModel.Win32Exception) { }
    }

    private static void MakeMutable(string directory)
    {
        if (!Directory.Exists(directory)) { return; }
        try
        {
            foreach (var file in Directory.EnumerateFiles(directory, "*", SearchOption.AllDirectories))
            {
                File.SetAttributes(file, File.GetAttributes(file) & ~FileAttributes.ReadOnly);
            }
        }
        catch { }
    }

    private static PocketAppGenerationException Failure(string code) => new(code);
}
