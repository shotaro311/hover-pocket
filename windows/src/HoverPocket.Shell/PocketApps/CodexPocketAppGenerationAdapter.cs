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

    public PocketAppPinnedDirectory(
        string path,
        bool allowReplacement = true,
        bool createMissing = true)
    {
        FullPath = Path.GetFullPath(path);
        _allowReplacement = allowReplacement;
        if (FullPath.StartsWith("\\\\", StringComparison.Ordinal))
        {
            throw Failure("GENERATION_ROOT_UNSAFE");
        }
        EnsureNoReparsePath(FullPath, createMissing);
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

internal sealed class CodexGenerationSandboxLease : IDisposable
{
    internal const int SetupVersion = 5;
    internal const string OfflineUserName = "CodexSandboxOffline";
    internal const string OnlineUserName = "CodexSandboxOnline";

    private const long MaximumControlFileBytes = 64 * 1024;
    private readonly PocketAppPinnedDirectory _home;
    private readonly PocketAppPinnedDirectory _sandboxDirectory;
    private readonly PocketAppPinnedDirectory _secretsDirectory;
    private readonly FileStream _marker;
    private readonly FileStream _users;
    private bool _disposed;

    private CodexGenerationSandboxLease(
        string homePath,
        PocketAppPinnedDirectory home,
        PocketAppPinnedDirectory sandboxDirectory,
        PocketAppPinnedDirectory secretsDirectory,
        FileStream marker,
        FileStream users)
    {
        HomePath = homePath;
        _home = home;
        _sandboxDirectory = sandboxDirectory;
        _secretsDirectory = secretsDirectory;
        _marker = marker;
        _users = users;
    }

    public string HomePath { get; }

    public static string DefaultHomePath()
    {
        var localApplicationData = Environment.GetFolderPath(
            Environment.SpecialFolder.LocalApplicationData);
        if (string.IsNullOrWhiteSpace(localApplicationData))
        {
            throw Failure();
        }
        return Path.Combine(
            Path.GetFullPath(localApplicationData),
            "HoverPocket",
            "CodexGenerationSandbox",
            "codex-home");
    }

    public static CodexGenerationSandboxLease Open(string homePath)
    {
        if (string.IsNullOrWhiteSpace(homePath)) { throw Failure(); }
        var normalizedHome = Path.TrimEndingDirectorySeparator(Path.GetFullPath(homePath));
        var root = Path.TrimEndingDirectorySeparator(
            Path.GetPathRoot(normalizedHome) ?? string.Empty);
        if (normalizedHome.StartsWith("\\\\", StringComparison.Ordinal)
            || string.Equals(normalizedHome, root, StringComparison.OrdinalIgnoreCase))
        {
            throw Failure();
        }

        PocketAppPinnedDirectory? home = null;
        PocketAppPinnedDirectory? sandboxDirectory = null;
        PocketAppPinnedDirectory? secretsDirectory = null;
        FileStream? marker = null;
        FileStream? users = null;
        try
        {
            home = new PocketAppPinnedDirectory(
                normalizedHome,
                allowReplacement: false,
                createMissing: false);
            sandboxDirectory = new PocketAppPinnedDirectory(
                Path.Combine(normalizedHome, ".sandbox"),
                allowReplacement: false,
                createMissing: false);
            secretsDirectory = new PocketAppPinnedDirectory(
                Path.Combine(normalizedHome, ".sandbox-secrets"),
                allowReplacement: false,
                createMissing: false);
            marker = OpenControlFile(sandboxDirectory, "setup_marker.json");
            users = OpenControlFile(secretsDirectory, "sandbox_users.json");
            ValidateMarker(marker);
            ValidateUsers(users);
            home.Validate();
            sandboxDirectory.Validate();
            secretsDirectory.Validate();
            return new CodexGenerationSandboxLease(
                normalizedHome,
                home,
                sandboxDirectory,
                secretsDirectory,
                marker,
                users);
        }
        catch
        {
            users?.Dispose();
            marker?.Dispose();
            secretsDirectory?.Dispose();
            sandboxDirectory?.Dispose();
            home?.Dispose();
            throw Failure();
        }
    }

    public void Validate()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        _home.Validate();
        _sandboxDirectory.Validate();
        _secretsDirectory.Validate();
        ValidateMarker(_marker);
        ValidateUsers(_users);
    }

    public void Dispose()
    {
        if (_disposed) { return; }
        _users.Dispose();
        _marker.Dispose();
        _secretsDirectory.Dispose();
        _sandboxDirectory.Dispose();
        _home.Dispose();
        _disposed = true;
    }

    private static FileStream OpenControlFile(PocketAppPinnedDirectory directory, string fileName)
    {
        var handle = directory.OpenFileForRead(fileName) ?? throw Failure();
        try
        {
            var stream = new FileStream(handle, FileAccess.Read, bufferSize: 4096, isAsync: false);
            if (stream.Length is <= 0 or > MaximumControlFileBytes)
            {
                stream.Dispose();
                throw Failure();
            }
            return stream;
        }
        catch
        {
            handle.Dispose();
            throw;
        }
    }

    private static void ValidateMarker(FileStream stream)
    {
        using var document = Parse(stream);
        var root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object
            || !TryReadInt(root, "version", out var version)
            || version != SetupVersion
            || !TryReadString(root, "offline_username", OfflineUserName)
            || !TryReadString(root, "online_username", OnlineUserName)
            || !root.TryGetProperty("proxy_ports", out var proxyPorts)
            || proxyPorts.ValueKind != JsonValueKind.Array
            || proxyPorts.GetArrayLength() != 0
            || (root.TryGetProperty("allow_local_binding", out var localBinding)
                && (localBinding.ValueKind is not JsonValueKind.False)))
        {
            throw Failure();
        }
    }

    private static void ValidateUsers(FileStream stream)
    {
        using var document = Parse(stream);
        var root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object
            || !TryReadInt(root, "version", out var version)
            || version != SetupVersion
            || !TryReadUser(root, "offline", OfflineUserName)
            || !TryReadUser(root, "online", OnlineUserName))
        {
            throw Failure();
        }
    }

    private static JsonDocument Parse(FileStream stream)
    {
        stream.Position = 0;
        try
        {
            return JsonDocument.Parse(stream, new JsonDocumentOptions
            {
                AllowTrailingCommas = false,
                CommentHandling = JsonCommentHandling.Disallow,
                MaxDepth = 8
            });
        }
        finally
        {
            stream.Position = 0;
        }
    }

    private static bool TryReadInt(JsonElement root, string name, out int value)
    {
        value = 0;
        return root.TryGetProperty(name, out var element)
            && element.ValueKind == JsonValueKind.Number
            && element.TryGetInt32(out value);
    }

    private static bool TryReadString(JsonElement root, string name, string expected)
    {
        return root.TryGetProperty(name, out var element)
            && element.ValueKind == JsonValueKind.String
            && element.ValueEquals(expected);
    }

    private static bool TryReadUser(JsonElement root, string name, string expectedUserName)
    {
        return root.TryGetProperty(name, out var user)
            && user.ValueKind == JsonValueKind.Object
            && TryReadString(user, "username", expectedUserName)
            && user.TryGetProperty("password", out var password)
            && password.ValueKind == JsonValueKind.String
            && !password.ValueEquals(string.Empty);
    }

    private static PocketAppGenerationException Failure() =>
        new("GENERATOR_SANDBOX_NOT_READY");
}

internal sealed class CodexPocketAppGenerationAdapter : IPocketAppGenerationAdapter, IDisposable
{
    private const int MaximumConfinementDenyEntries = 256;
    private const int MaximumConfinementDenyCharacters = 16384;

    public bool AllowsActivation => false;

    public static string? ResolveExecutable()
    {
        // The named profile and isolated process environment are prepared below, but
        // production remains disconnected until the explicit one-time sandbox setup,
        // Host-brokered credentials, and the no-UAC outside-root canary pass on a
        // supported Windows host.
        return null;
    }

    private readonly string _executable;
    private readonly PocketAppPinnedDirectory _workspaceRoot;
    private readonly string _sandboxHome;
    private readonly TimeSpan _timeout;
    private readonly Func<string> _credentialProvider;
    private bool _disposed;

    public CodexPocketAppGenerationAdapter(
        string executable,
        string workspaceRoot,
        string sandboxHome,
        Func<string> credentialProvider,
        TimeSpan? timeout = null)
    {
        if (string.IsNullOrWhiteSpace(executable)
            || string.IsNullOrWhiteSpace(sandboxHome))
        {
            throw Failure("GENERATOR_UNAVAILABLE");
        }
        _executable = executable;
        _workspaceRoot = new PocketAppPinnedDirectory(workspaceRoot);
        _sandboxHome = Path.GetFullPath(sandboxHome);
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
        var userHome = Path.Combine(runRoot, "user-home");
        var localAppData = Path.Combine(userHome, "AppData", "Local");
        var roamingAppData = Path.Combine(userHome, "AppData", "Roaming");
        var temporaryDirectory = Path.Combine(runRoot, "tmp");
        using var runRootPin = new PocketAppPinnedDirectory(runRoot);
        foreach (var directory in new[] { workspace, userHome, localAppData, roamingAppData, temporaryDirectory })
        {
            Directory.CreateDirectory(directory);
        }
        try
        {
            using var sandboxLease = CodexGenerationSandboxLease.Open(_sandboxHome);
            _workspaceRoot.Validate();
            runRootPin.Validate();
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
                sandboxLease.HomePath,
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
                sandboxLease.HomePath,
                userHome,
                localAppData,
                roamingAppData,
                temporaryDirectory))
            {
                start.Environment[key] = value;
            }

            using var process = new Process { StartInfo = start };
            sandboxLease.Validate();
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
            runRootPin.Validate();
            return PocketAppGenerationContract.DecodeEnvelope(stdout.Data);
        }
        finally
        {
            runRootPin.Dispose();
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
        var runDirectories = new[] { normalizedWorkspace, normalizedUserHome };
        var runRoot = Path.GetDirectoryName(normalizedWorkspace)
            ?? throw Failure("GENERATOR_UNAVAILABLE");
        if (runDirectories
                .Distinct(StringComparer.OrdinalIgnoreCase).Count() != 2
            || runDirectories.Select(Path.GetDirectoryName)
                .Distinct(StringComparer.OrdinalIgnoreCase).Count() != 1
            || normalizedHostUserProfile.StartsWith("\\\\", StringComparison.Ordinal)
            || string.Equals(
                normalizedHostUserProfile,
                Path.TrimEndingDirectorySeparator(Path.GetPathRoot(normalizedHostUserProfile) ?? string.Empty),
                StringComparison.OrdinalIgnoreCase)
            || !IsStrictDescendant(normalizedWorkspace, normalizedHostUserProfile)
            || !IsStrictDescendant(normalizedCodexHome, normalizedHostUserProfile)
            || string.Equals(normalizedCodexHome, runRoot, StringComparison.OrdinalIgnoreCase)
            || IsStrictDescendant(normalizedCodexHome, runRoot)
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
        var filesystemEntries = new List<string>
        {
            $"{JsonSerializer.Serialize(":minimal")}=\"read\""
        };
        filesystemEntries.AddRange(ConfinementDenyFrontier(
            normalizedHostUserProfile,
            runRoot).Select(path => $"{JsonSerializer.Serialize(path)}=\"deny\""));
        filesystemEntries.Add($"{JsonSerializer.Serialize(normalizedWorkspace)}=\"read\"");
        filesystemEntries.Add($"{JsonSerializer.Serialize(normalizedUserHome)}=\"deny\"");
        filesystemEntries.Add($"{JsonSerializer.Serialize(normalizedHelper)}=\"deny\"");
        var filesystem = "permissions.hoverpocket-generation.filesystem={"
            + string.Join(',', filesystemEntries)
            + "}";
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

    internal static IReadOnlyList<string> ConfinementDenyFrontier(
        string hostUserProfile,
        string runRoot)
    {
        var normalizedHostUserProfile = Path.TrimEndingDirectorySeparator(
            Path.GetFullPath(hostUserProfile));
        var normalizedRunRoot = Path.TrimEndingDirectorySeparator(Path.GetFullPath(runRoot));
        if (normalizedHostUserProfile.StartsWith("\\\\", StringComparison.Ordinal)
            || string.Equals(
                normalizedHostUserProfile,
                Path.TrimEndingDirectorySeparator(
                    Path.GetPathRoot(normalizedHostUserProfile) ?? string.Empty),
                StringComparison.OrdinalIgnoreCase)
            || !IsStrictDescendant(normalizedRunRoot, normalizedHostUserProfile)
            || !Directory.Exists(normalizedHostUserProfile)
            || !Directory.Exists(normalizedRunRoot))
        {
            throw Failure("GENERATOR_UNAVAILABLE");
        }

        var frontier = new List<string> { normalizedHostUserProfile };
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            normalizedHostUserProfile
        };
        var characterCount = normalizedHostUserProfile.Length;
        var current = normalizedHostUserProfile;
        try
        {
            while (!string.Equals(current, normalizedRunRoot, StringComparison.OrdinalIgnoreCase))
            {
                var relative = Path.GetRelativePath(current, normalizedRunRoot);
                var nextComponent = relative.Split(
                    [Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar],
                    StringSplitOptions.RemoveEmptyEntries).FirstOrDefault();
                if (string.IsNullOrWhiteSpace(nextComponent))
                {
                    throw Failure("GENERATOR_UNAVAILABLE");
                }
                var next = Path.GetFullPath(Path.Combine(current, nextComponent));
                if (!Directory.Exists(next)
                    || !IsStrictDescendant(next, current)
                    || (!string.Equals(next, normalizedRunRoot, StringComparison.OrdinalIgnoreCase)
                        && !IsStrictDescendant(normalizedRunRoot, next)))
                {
                    throw Failure("GENERATOR_UNAVAILABLE");
                }

                if (!string.Equals(next, normalizedRunRoot, StringComparison.OrdinalIgnoreCase)
                    && seen.Add(next))
                {
                    frontier.Add(next);
                    characterCount += next.Length;
                }

                foreach (var sibling in Directory
                    .EnumerateFileSystemEntries(current)
                    .Select(Path.GetFullPath)
                    .OrderBy(path => path, StringComparer.OrdinalIgnoreCase))
                {
                    if (string.Equals(sibling, next, StringComparison.OrdinalIgnoreCase)
                        || !seen.Add(sibling))
                    {
                        continue;
                    }
                    frontier.Add(sibling);
                    characterCount += sibling.Length;
                }
                if (frontier.Count > MaximumConfinementDenyEntries
                    || characterCount > MaximumConfinementDenyCharacters)
                {
                    throw Failure("GENERATOR_UNAVAILABLE");
                }
                current = next;
            }
        }
        catch (Exception ex) when (ex is IOException
            or UnauthorizedAccessException
            or System.Security.SecurityException)
        {
            throw Failure("GENERATOR_UNAVAILABLE");
        }
        return frontier;
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
