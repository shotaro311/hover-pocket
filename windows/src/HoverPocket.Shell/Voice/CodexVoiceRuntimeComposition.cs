using System.Diagnostics;
using System.Security.Cryptography;
using System.Text.Json;

namespace HoverPocket.Shell.Voice;

internal sealed record CodexExecutableIdentity(
    string Path,
    long Length,
    DateTime LastWriteTimeUtc,
    string Sha256)
{
    public FileStream OpenValidated()
    {
        CodexExecutableResolver.ValidatePath(Path);
        var stream = new FileStream(
            Path,
            FileMode.Open,
            FileAccess.Read,
            FileShare.Read,
            bufferSize: 64 * 1024,
            FileOptions.SequentialScan);
        try
        {
            var info = new FileInfo(Path);
            var digest = Convert.ToHexString(SHA256.HashData(stream));
            if (info.Length != Length
                || info.LastWriteTimeUtc != LastWriteTimeUtc
                || !string.Equals(digest, Sha256, StringComparison.Ordinal))
            {
                throw new CodexAppServerProtocolException("codex_executable_changed");
            }
            return stream;
        }
        catch
        {
            stream.Dispose();
            throw;
        }
    }
}

internal static class CodexExecutableResolver
{
    private const string ExpectedFileName = "codex.exe";

    public static CodexExecutableIdentity? Resolve()
    {
        if (!OperatingSystem.IsWindows())
        {
            return null;
        }

        foreach (var candidate in CandidatePaths())
        {
            try
            {
                ValidatePath(candidate);
                using var stream = new FileStream(
                    candidate,
                    FileMode.Open,
                    FileAccess.Read,
                    FileShare.Read,
                    bufferSize: 64 * 1024,
                    FileOptions.SequentialScan);
                var info = new FileInfo(candidate);
                return new CodexExecutableIdentity(
                    info.FullName,
                    info.Length,
                    info.LastWriteTimeUtc,
                    Convert.ToHexString(SHA256.HashData(stream)));
            }
            catch (Exception exception) when (exception is IOException
                or UnauthorizedAccessException
                or CodexAppServerProtocolException)
            {
            }
        }
        return null;
    }

    internal static void ValidatePath(string candidate)
    {
        if (string.IsNullOrWhiteSpace(candidate)
            || !Path.IsPathFullyQualified(candidate)
            || !string.Equals(Path.GetFileName(candidate), ExpectedFileName, StringComparison.OrdinalIgnoreCase)
            || !File.Exists(candidate))
        {
            throw new CodexAppServerProtocolException("codex_executable_invalid");
        }

        var fullPath = Path.GetFullPath(candidate);
        if (!string.Equals(fullPath, candidate, StringComparison.OrdinalIgnoreCase))
        {
            throw new CodexAppServerProtocolException("codex_executable_invalid");
        }

        var root = Path.GetPathRoot(fullPath);
        var current = Path.GetDirectoryName(fullPath);
        while (!string.IsNullOrEmpty(current)
            && !string.Equals(current, root, StringComparison.OrdinalIgnoreCase))
        {
            if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
            {
                throw new CodexAppServerProtocolException("codex_executable_reparse_path");
            }
            current = Path.GetDirectoryName(current);
        }
        if ((File.GetAttributes(fullPath) & FileAttributes.ReparsePoint) != 0)
        {
            throw new CodexAppServerProtocolException("codex_executable_reparse_path");
        }
    }

    private static IEnumerable<string> CandidatePaths()
    {
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var path = Environment.GetEnvironmentVariable("PATH") ?? string.Empty;
        foreach (var entry in path.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            string? normalized = null;
            try
            {
                normalized = Path.GetFullPath(entry.Trim().Trim('"'));
            }
            catch (Exception exception) when (exception is ArgumentException
                or NotSupportedException
                or PathTooLongException)
            {
            }
            if (!string.IsNullOrEmpty(normalized))
            {
                var candidate = Path.Combine(normalized, ExpectedFileName);
                if (seen.Add(candidate))
                {
                    yield return candidate;
                }
            }
        }

        var profile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var roaming = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var conventional = new[]
        {
            Path.Combine(profile, ".codex", "bin", ExpectedFileName),
            Path.Combine(local, "Programs", "Codex", ExpectedFileName),
            Path.Combine(
                roaming,
                "npm",
                "node_modules",
                "@openai",
                "codex",
                "node_modules",
                "@openai",
                "codex-win32-x64",
                "vendor",
                "x86_64-pc-windows-msvc",
                "codex",
                ExpectedFileName)
        };
        foreach (var candidate in conventional)
        {
            if (seen.Add(candidate))
            {
                yield return candidate;
            }
        }
    }
}

internal sealed class InstalledCodexVoiceRuntime : ICodexVoiceCompatibilityProbe
{
    private static readonly TimeSpan SchemaTimeout = TimeSpan.FromSeconds(20);
    private static readonly TimeSpan RequestTimeout = TimeSpan.FromSeconds(20);
    private readonly object _sync = new();
    private CodexExecutableIdentity? _identity;

    public async Task<CodexVoiceGate> ProbeAsync(CancellationToken cancellationToken)
    {
        var identity = CodexExecutableResolver.Resolve();
        if (identity is null)
        {
            return new CodexVoiceGate(false, false, false, "codex_executable_missing");
        }
        lock (_sync)
        {
            if (Equals(_identity, identity))
            {
                return CodexVoiceGate.Ready;
            }
        }

        try
        {
            if (!await ProbeSchemaAsync(identity, cancellationToken).ConfigureAwait(false))
            {
                return new CodexVoiceGate(false, true, false, "installed_schema_mismatch");
            }
            lock (_sync)
            {
                _identity = identity;
            }
            return CodexVoiceGate.Ready;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception exception) when (exception is IOException
            or UnauthorizedAccessException
            or JsonException
            or CodexAppServerProtocolException
            or System.ComponentModel.Win32Exception)
        {
            return new CodexVoiceGate(false, true, false, "installed_schema_probe_failed");
        }
    }

    public Task<CodexAppServerClient> StartClientAsync(CancellationToken cancellationToken)
    {
        CodexExecutableIdentity? identity;
        lock (_sync)
        {
            identity = _identity;
        }
        identity ??= CodexExecutableResolver.Resolve();
        if (identity is null)
        {
            throw new CodexAppServerProtocolException("codex_executable_missing");
        }

        using var executableLease = identity.OpenValidated();
        return CodexAppServerClient.StartProcessAsync(
            identity.Path,
            ["app-server", "--stdio"],
            RequestTimeout,
            cancellationToken);
    }

    private static async Task<bool> ProbeSchemaAsync(
        CodexExecutableIdentity identity,
        CancellationToken cancellationToken)
    {
        var schemaRoot = Directory.CreateTempSubdirectory("HoverPocket-VoiceSchema-").FullName;
        try
        {
            using var executableLease = identity.OpenValidated();
            using var processJob = WindowsProcessJob.CreateKillOnClose();
            using var process = new Process
            {
                StartInfo = new ProcessStartInfo
                {
                    FileName = identity.Path,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true
                },
                EnableRaisingEvents = true
            };
            process.StartInfo.ArgumentList.Add("app-server");
            process.StartInfo.ArgumentList.Add("generate-json-schema");
            process.StartInfo.ArgumentList.Add("--experimental");
            process.StartInfo.ArgumentList.Add("--out");
            process.StartInfo.ArgumentList.Add(schemaRoot);
            if (!process.Start())
            {
                throw new CodexAppServerProtocolException("schema_probe_start_failed");
            }
            processJob.Assign(process);
            var stdoutDrain = DrainBoundedAsync(process.StandardOutput, cancellationToken);
            var stderrDrain = DrainBoundedAsync(process.StandardError, cancellationToken);
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(SchemaTimeout);
            try
            {
                await process.WaitForExitAsync(timeout.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                try
                {
                    if (!process.HasExited)
                    {
                        process.Kill(entireProcessTree: true);
                        await process.WaitForExitAsync(CancellationToken.None).ConfigureAwait(false);
                    }
                }
                catch (Exception exception) when (exception is InvalidOperationException
                    or System.ComponentModel.Win32Exception)
                {
                }
                if (cancellationToken.IsCancellationRequested)
                {
                    throw;
                }
                throw new CodexAppServerProtocolException("schema_probe_timeout");
            }
            await Task.WhenAll(stdoutDrain, stderrDrain).ConfigureAwait(false);
            return process.ExitCode == 0 && CodexVoiceSchemaContract.IsCompatible(schemaRoot);
        }
        finally
        {
            try
            {
                Directory.Delete(schemaRoot, recursive: true);
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
            }
        }
    }

    private static async Task DrainBoundedAsync(TextReader reader, CancellationToken cancellationToken)
    {
        var buffer = new char[4_096];
        var total = 0;
        while (total <= 1_048_576)
        {
            var read = await reader.ReadAsync(buffer.AsMemory(), cancellationToken).ConfigureAwait(false);
            if (read == 0)
            {
                return;
            }
            total += read;
        }
        throw new CodexAppServerProtocolException("schema_probe_output_too_large");
    }
}

internal static class CodexVoiceSchemaContract
{
    public static bool IsCompatible(string schemaRoot)
    {
        try
        {
            using var initialize = Load(schemaRoot, "v1", "InitializeParams.json");
            using var start = Load(schemaRoot, "v2", "ThreadRealtimeStartParams.json");
            using var sdp = Load(schemaRoot, "v2", "ThreadRealtimeSdpNotification.json");
            using var transcriptDelta = Load(schemaRoot, "v2", "ThreadRealtimeTranscriptDeltaNotification.json");
            using var transcriptDone = Load(schemaRoot, "v2", "ThreadRealtimeTranscriptDoneNotification.json");
            using var outputAudio = Load(schemaRoot, "v2", "ThreadRealtimeOutputAudioDeltaNotification.json");
            using var stop = Load(schemaRoot, "v2", "ThreadRealtimeStopParams.json");
            using var voices = Load(schemaRoot, "v2", "ThreadRealtimeListVoicesResponse.json");
            using var account = Load(schemaRoot, "v2", "GetAccountResponse.json");

            return HasBooleanProperty(initialize.RootElement, "definitions", "InitializeCapabilities", "properties", "experimentalApi")
                && RequiredContains(start.RootElement, "threadId", "outputModality")
                && HasWebRtcTransport(start.RootElement)
                && RequiredContains(sdp.RootElement, "threadId", "sdp")
                && RequiredContains(transcriptDelta.RootElement, "threadId", "role", "delta")
                && RequiredContains(transcriptDone.RootElement, "threadId", "role", "text")
                && RequiredContains(outputAudio.RootElement, "threadId", "audio")
                && RequiredContains(stop.RootElement, "threadId")
                && RequiredContains(voices.RootElement, "voices")
                && RequiredContains(account.RootElement, "requiresOpenaiAuth")
                && HasProperty(account.RootElement, "account");
        }
        catch (Exception exception) when (exception is IOException
            or UnauthorizedAccessException
            or JsonException
            or KeyNotFoundException)
        {
            return false;
        }
    }

    private static JsonDocument Load(string root, params string[] segments) =>
        JsonDocument.Parse(File.ReadAllText(Path.Combine([root, .. segments])));

    private static bool RequiredContains(JsonElement root, params string[] names)
    {
        if (!root.TryGetProperty("required", out var required)
            || required.ValueKind != JsonValueKind.Array)
        {
            return false;
        }
        var actual = required.EnumerateArray()
            .Where(item => item.ValueKind == JsonValueKind.String)
            .Select(item => item.GetString())
            .ToHashSet(StringComparer.Ordinal);
        return names.All(actual.Contains);
    }

    private static bool HasProperty(JsonElement root, string name) =>
        root.TryGetProperty("properties", out var properties)
        && properties.ValueKind == JsonValueKind.Object
        && properties.TryGetProperty(name, out _);

    private static bool HasBooleanProperty(JsonElement root, params string[] path)
    {
        var current = root;
        foreach (var segment in path)
        {
            if (current.ValueKind != JsonValueKind.Object
                || !current.TryGetProperty(segment, out current))
            {
                return false;
            }
        }
        return current.ValueKind == JsonValueKind.Object
            && current.TryGetProperty("type", out var type)
            && type.ValueKind == JsonValueKind.String
            && type.GetString() == "boolean";
    }

    private static bool HasWebRtcTransport(JsonElement root)
    {
        if (!root.TryGetProperty("definitions", out var definitions)
            || !definitions.TryGetProperty("ThreadRealtimeStartTransport", out var transport)
            || !transport.TryGetProperty("oneOf", out var options)
            || options.ValueKind != JsonValueKind.Array)
        {
            return false;
        }
        foreach (var option in options.EnumerateArray())
        {
            if (!RequiredContains(option, "type", "sdp")
                || !option.TryGetProperty("properties", out var properties)
                || !properties.TryGetProperty("type", out var type)
                || !type.TryGetProperty("enum", out var values))
            {
                continue;
            }
            if (values.EnumerateArray().Any(item => item.GetString() == "webrtc"))
            {
                return true;
            }
        }
        return false;
    }
}

internal static class CodexVoiceRuntimeComposition
{
    public static CodexVoiceCoordinator Create(bool featureEnabled)
    {
        var runtime = new InstalledCodexVoiceRuntime();
        return new CodexVoiceCoordinator(
            featureEnabled,
            runtime.StartClientAsync,
            runtime);
    }
}
