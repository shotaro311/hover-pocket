using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.Win32.SafeHandles;

namespace HoverPocket.Shell.PocketApps;

internal sealed class PocketAppPinnedDirectory : IDisposable
{
    private readonly SafeFileHandle _handle;
    private readonly FileIdentity _identity;
    private readonly bool _allowReplacement;
    private bool _disposed;

    public PocketAppPinnedDirectory(string path, bool allowReplacement = true)
    {
        FullPath = Path.GetFullPath(path);
        _allowReplacement = allowReplacement;
        if (FullPath.StartsWith("\\\\", StringComparison.Ordinal))
        {
            throw Failure("GENERATION_ROOT_UNSAFE");
        }
        EnsureNoReparsePath(FullPath, createMissing: true);
        _handle = OpenDirectory(FullPath, _allowReplacement);
        _identity = Identity(_handle);
        Validate();
    }

    public string FullPath { get; }

    public void Validate()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        EnsureNoReparsePath(FullPath, createMissing: false);
        using var current = OpenDirectory(FullPath, _allowReplacement);
        if (Identity(current) != _identity || Identity(_handle) != _identity)
        {
            throw Failure("GENERATION_ROOT_UNSAFE");
        }
    }

    public SafeFileHandle? OpenFileForRead(string fileName)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (string.IsNullOrEmpty(fileName)
            || fileName != Path.GetFileName(fileName)
            || fileName.Contains(Path.DirectorySeparatorChar)
            || fileName.Contains(Path.AltDirectorySeparatorChar))
        {
            throw Failure("GENERATION_ROOT_UNSAFE");
        }
        Validate();
        var path = Path.Combine(FullPath, fileName);
        var handle = CreateFile(
            path,
            GenericRead,
            FileShare.Read,
            IntPtr.Zero,
            FileMode.Open,
            FileFlagsAndAttributes.OpenReparsePoint | FileFlagsAndAttributes.SequentialScan,
            IntPtr.Zero);
        if (handle.IsInvalid)
        {
            var error = Marshal.GetLastWin32Error();
            handle.Dispose();
            if (error is ErrorFileNotFound or ErrorPathNotFound) { return null; }
            throw Failure("GENERATION_ROOT_UNSAFE");
        }
        try
        {
            var information = Information(handle);
            if ((information.FileAttributes & (uint)FileAttributes.Directory) != 0
                || (information.FileAttributes & (uint)FileAttributes.ReparsePoint) != 0)
            {
                throw Failure("GENERATION_ROOT_UNSAFE");
            }
            Validate();
            return handle;
        }
        catch
        {
            handle.Dispose();
            throw;
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

    private static SafeFileHandle OpenDirectory(string path, bool allowReplacement)
    {
        var handle = CreateFile(
            path,
            0,
            FileShare.Read | FileShare.Write | (allowReplacement ? FileShare.Delete : FileShare.None),
            IntPtr.Zero,
            FileMode.Open,
            FileFlagsAndAttributes.BackupSemantics | FileFlagsAndAttributes.OpenReparsePoint,
            IntPtr.Zero);
        if (handle.IsInvalid)
        {
            handle.Dispose();
            throw Failure("GENERATION_ROOT_UNSAFE");
        }
        try
        {
            var information = Information(handle);
            if ((information.FileAttributes & (uint)FileAttributes.Directory) == 0
                || (information.FileAttributes & (uint)FileAttributes.ReparsePoint) != 0)
            {
                throw Failure("GENERATION_ROOT_UNSAFE");
            }
            return handle;
        }
        catch
        {
            handle.Dispose();
            throw;
        }
    }

    private static FileIdentity Identity(SafeFileHandle handle)
    {
        var information = Information(handle);
        return new FileIdentity(
            information.VolumeSerialNumber,
            ((ulong)information.FileIndexHigh << 32) | information.FileIndexLow);
    }

    private static ByHandleFileInformation Information(SafeFileHandle handle)
    {
        if (!GetFileInformationByHandle(handle, out var information))
        {
            throw Failure("GENERATION_ROOT_UNSAFE");
        }
        return information;
    }

    private const uint GenericRead = 0x80000000;
    private const int ErrorFileNotFound = 2;
    private const int ErrorPathNotFound = 3;

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
        OpenReparsePoint = 0x00200000,
        SequentialScan = 0x08000000
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
        // The named profile and isolated process environment are prepared below, but
        // production remains disconnected until Host-brokered credentials and a
        // native elevated-sandbox outside-root canary pass on a supported Windows host.
        return null;
    }

    private readonly string _executable;
    private readonly PocketAppPinnedDirectory _workspaceRoot;
    private readonly TimeSpan _timeout;
    private readonly Func<string> _credentialProvider;
    private bool _disposed;

    public CodexPocketAppGenerationAdapter(
        string executable,
        string workspaceRoot,
        Func<string> credentialProvider,
        TimeSpan? timeout = null)
    {
        if (string.IsNullOrWhiteSpace(executable)) { throw Failure("GENERATOR_UNAVAILABLE"); }
        _executable = executable;
        _workspaceRoot = new PocketAppPinnedDirectory(workspaceRoot);
        _credentialProvider = credentialProvider
            ?? throw Failure("GENERATOR_UNAVAILABLE");
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
        var modelCatalog = CodexPocketAppGenerationModelCatalog.Load();
        _workspaceRoot.Validate();
        cancellationToken.ThrowIfCancellationRequested();

        var runRoot = Path.Combine(_workspaceRoot.FullPath, $"codex-{Guid.NewGuid():N}");
        var workspace = Path.Combine(runRoot, "workspace");
        var codexHome = Path.Combine(runRoot, "codex-home");
        var userHome = Path.Combine(runRoot, "user-home");
        var localAppData = Path.Combine(userHome, "AppData", "Local");
        var roamingAppData = Path.Combine(userHome, "AppData", "Roaming");
        var temporaryDirectory = Path.Combine(runRoot, "tmp");
        foreach (var directory in new[] { workspace, codexHome, userHome, localAppData, roamingAppData, temporaryDirectory })
        {
            Directory.CreateDirectory(directory);
        }
        try
        {
            _workspaceRoot.Validate();
            var schemaPath = Path.Combine(workspace, "generation-output.schema.json");
            await File.WriteAllTextAsync(schemaPath, PocketAppGenerationContract.OutputSchemaJson, cancellationToken);
            File.SetAttributes(schemaPath, File.GetAttributes(schemaPath) | FileAttributes.ReadOnly);
            var modelCatalogPath = Path.Combine(workspace, "model-catalog.json");
            await File.WriteAllBytesAsync(modelCatalogPath, modelCatalog, cancellationToken);
            File.SetAttributes(modelCatalogPath, File.GetAttributes(modelCatalogPath) | FileAttributes.ReadOnly);

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
            var helperExecutable = Environment.ProcessPath;
            if (string.IsNullOrWhiteSpace(helperExecutable))
            {
                throw Failure("GENERATOR_UNAVAILABLE");
            }
            foreach (var argument in ConfinementArguments(
                workspace,
                codexHome,
                userHome,
                HostUserProfile(),
                schemaPath,
                modelCatalogPath,
                helperExecutable))
            {
                start.ArgumentList.Add(argument);
            }
            start.Environment.Clear();
            foreach (var (key, value) in ConfinementEnvironment(
                codexHome,
                userHome,
                localAppData,
                roamingAppData,
                temporaryDirectory))
            {
                start.Environment[key] = value;
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

            using var credentialBroker = CreateCredentialBroker(process);

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
            MakeMutable(runRoot);
            try { if (Directory.Exists(runRoot)) { Directory.Delete(runRoot, true); } } catch { }
        }
    }

    internal static IReadOnlyList<string> ConfinementArguments(
        string workspace,
        string codexHome,
        string userHome,
        string hostUserProfile,
        string schemaPath,
        string modelCatalogPath,
        string credentialHelperExecutable)
    {
        var normalizedWorkspace = Path.GetFullPath(workspace);
        var normalizedCodexHome = Path.GetFullPath(codexHome);
        var normalizedUserHome = Path.GetFullPath(userHome);
        var normalizedHostUserProfile = Path.TrimEndingDirectorySeparator(Path.GetFullPath(hostUserProfile));
        var normalizedSchema = Path.GetFullPath(schemaPath);
        var normalizedModelCatalog = Path.GetFullPath(modelCatalogPath);
        var normalizedHelper = Path.GetFullPath(credentialHelperExecutable);
        var directories = new[] { normalizedWorkspace, normalizedCodexHome, normalizedUserHome };
        if (directories
                .Distinct(StringComparer.OrdinalIgnoreCase).Count() != 3
            || directories.Select(Path.GetDirectoryName)
                .Distinct(StringComparer.OrdinalIgnoreCase).Count() != 1
            || normalizedHostUserProfile.StartsWith("\\\\", StringComparison.Ordinal)
            || string.Equals(
                normalizedHostUserProfile,
                Path.TrimEndingDirectorySeparator(Path.GetPathRoot(normalizedHostUserProfile) ?? string.Empty),
                StringComparison.OrdinalIgnoreCase)
            || !IsStrictDescendant(normalizedWorkspace, normalizedHostUserProfile)
            || !string.Equals(
                Path.GetDirectoryName(normalizedSchema),
                normalizedWorkspace,
                StringComparison.OrdinalIgnoreCase)
            || !string.Equals(
                Path.GetDirectoryName(normalizedModelCatalog),
                normalizedWorkspace,
                StringComparison.OrdinalIgnoreCase)
            || string.Equals(normalizedModelCatalog, normalizedSchema, StringComparison.OrdinalIgnoreCase)
            || string.IsNullOrWhiteSpace(normalizedHelper)
            || normalizedHelper.StartsWith("\\\\", StringComparison.Ordinal))
        {
            throw Failure("GENERATOR_UNAVAILABLE");
        }
        // The elevated sandbox identity may otherwise inherit broad Users-group read ACLs.
        // Deny the real Host profile and reopen only the isolated generation workspace.
        var filesystem = "permissions.hoverpocket-generation.filesystem={"
            + $"{JsonSerializer.Serialize(":minimal")}=\"read\","
            + $"{JsonSerializer.Serialize(normalizedHostUserProfile)}=\"deny\","
            + $"{JsonSerializer.Serialize(normalizedWorkspace)}=\"read\","
            + $"{JsonSerializer.Serialize(normalizedUserHome)}=\"deny\","
            + $"{JsonSerializer.Serialize(normalizedHelper)}=\"deny\"}}";
        var windows = WindowsDirectory();
        var systemDrive = SystemDrive(windows);
        var shellEnvironment = "shell_environment_policy.set={"
            + $"PATH={JsonSerializer.Serialize(SystemPath())},"
            + "LANG=\"C\","
            + $"SYSTEMDRIVE={JsonSerializer.Serialize(systemDrive)},"
            + $"SYSTEMROOT={JsonSerializer.Serialize(windows)},"
            + $"WINDIR={JsonSerializer.Serialize(windows)},"
            + $"COMSPEC={JsonSerializer.Serialize(Path.Combine(windows, "System32", "cmd.exe"))}}}";
        return
        [
            "exec",
            "--ephemeral",
            "--ignore-user-config",
            "--ignore-rules",
            "--skip-git-repo-check",
            "-c", "approval_policy=\"never\"",
            "-c", $"model={JsonSerializer.Serialize(CodexPocketAppGenerationModelCatalog.ModelId)}",
            "-c", $"model_reasoning_effort={JsonSerializer.Serialize(CodexPocketAppGenerationModelCatalog.ReasoningEffort)}",
            "-c", $"model_catalog_json={JsonSerializer.Serialize(normalizedModelCatalog)}",
            "-c", "model_provider=\"hoverpocket\"",
            "-c", "model_providers.hoverpocket.name=\"HoverPocket OpenAI\"",
            "-c", "model_providers.hoverpocket.base_url=\"https://api.openai.com/v1\"",
            "-c", "model_providers.hoverpocket.wire_api=\"responses\"",
            "-c", $"model_providers.hoverpocket.auth.command={JsonSerializer.Serialize(normalizedHelper)}",
            "-c", $"model_providers.hoverpocket.auth.args=[{JsonSerializer.Serialize(CodexCredentialBrokerHelper.GenerationArgument)}]",
            "-c", $"model_providers.hoverpocket.auth.cwd={JsonSerializer.Serialize(normalizedWorkspace)}",
            "-c", "model_providers.hoverpocket.auth.refresh_interval_ms=0",
            "-c", "model_providers.hoverpocket.auth.timeout_ms=5000",
            "-c", "model_providers.hoverpocket.request_max_retries=0",
            "-c", "model_providers.hoverpocket.stream_max_retries=0",
            "-c", "windows.sandbox=\"elevated\"",
            "-c", "default_permissions=\"hoverpocket-generation\"",
            "-c", filesystem,
            "-c", "permissions.hoverpocket-generation.network.enabled=false",
            "-c", "shell_environment_policy.inherit=\"none\"",
            "-c", shellEnvironment,
            "--output-schema", normalizedSchema,
            "-"
        ];
    }

    internal static IReadOnlyDictionary<string, string> ConfinementEnvironment(
        string codexHome,
        string userHome,
        string localAppData,
        string roamingAppData,
        string temporaryDirectory)
    {
        var windows = WindowsDirectory();
        var systemDrive = SystemDrive(windows);
        return new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            ["CODEX_HOME"] = Path.GetFullPath(codexHome),
            ["HOME"] = Path.GetFullPath(userHome),
            ["USERPROFILE"] = Path.GetFullPath(userHome),
            ["LOCALAPPDATA"] = Path.GetFullPath(localAppData),
            ["APPDATA"] = Path.GetFullPath(roamingAppData),
            ["TEMP"] = Path.GetFullPath(temporaryDirectory),
            ["TMP"] = Path.GetFullPath(temporaryDirectory),
            ["PATH"] = SystemPath(),
            ["USERNAME"] = WindowsUserName(),
            ["SYSTEMDRIVE"] = systemDrive,
            ["SYSTEMROOT"] = windows,
            ["WINDIR"] = windows,
            ["COMSPEC"] = Path.Combine(windows, "System32", "cmd.exe"),
            ["LANG"] = "C"
        };
    }

    private static string WindowsUserName()
    {
        var userName = Environment.UserName;
        if (string.IsNullOrWhiteSpace(userName) || userName.Any(char.IsControl))
        {
            throw Failure("GENERATOR_UNAVAILABLE");
        }
        return userName;
    }

    internal static string HostUserProfile()
    {
        var profile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        if (string.IsNullOrWhiteSpace(profile)) { throw Failure("GENERATOR_UNAVAILABLE"); }
        var normalized = Path.TrimEndingDirectorySeparator(Path.GetFullPath(profile));
        if (normalized.StartsWith("\\\\", StringComparison.Ordinal)
            || string.Equals(normalized, Path.GetPathRoot(normalized), StringComparison.OrdinalIgnoreCase))
        {
            throw Failure("GENERATOR_UNAVAILABLE");
        }
        return normalized;
    }

    private static bool IsStrictDescendant(string candidate, string ancestor)
    {
        if (string.Equals(candidate, ancestor, StringComparison.OrdinalIgnoreCase)) { return false; }
        var prefix = Path.TrimEndingDirectorySeparator(ancestor) + Path.DirectorySeparatorChar;
        return candidate.StartsWith(prefix, StringComparison.OrdinalIgnoreCase);
    }

    private static string SystemPath()
    {
        var windows = WindowsDirectory();
        return string.Join(Path.PathSeparator, Path.Combine(windows, "System32"), windows);
    }

    private static string SystemDrive(string windowsDirectory)
    {
        var root = Path.GetPathRoot(windowsDirectory);
        if (string.IsNullOrWhiteSpace(root)) { throw Failure("GENERATOR_UNAVAILABLE"); }
        var drive = root.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        if (drive.Length != 2 || drive[1] != ':') { throw Failure("GENERATOR_UNAVAILABLE"); }
        return drive;
    }

    private static string WindowsDirectory()
    {
        var windows = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        if (string.IsNullOrWhiteSpace(windows)) { throw Failure("GENERATOR_UNAVAILABLE"); }
        return Path.GetFullPath(windows);
    }

    public void Dispose()
    {
        if (_disposed) { return; }
        _workspaceRoot.Dispose();
        _disposed = true;
    }

    private CodexCredentialBrokerServer CreateCredentialBroker(Process process)
    {
        try
        {
            return CodexCredentialBrokerServer.CreateForGeneration(
                TimeSpan.FromSeconds(30),
                process.Id,
                _credentialProvider);
        }
        catch
        {
            Kill(process);
            throw Failure("GENERATOR_UNAVAILABLE");
        }
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
