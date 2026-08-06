using System.Collections.Concurrent;
using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace HoverPocket.Shell.Providers.CodexVoice;

internal sealed record CodexAppServerClientOptions
{
    public string? ExecutablePath { get; init; }

    public TimeSpan RequestTimeout { get; init; } = TimeSpan.FromSeconds(15);

    public string ClientName { get; init; } = "hover_pocket";

    public string ClientTitle { get; init; } = "HoverPocket";

    public string ClientVersion { get; init; } = "0.0.0";

    public bool ExperimentalApi { get; init; } = true;
}

internal sealed class CodexAppServerClient : IAsyncDisposable
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };

    private static readonly JsonElement EmptyObject = JsonSerializer.SerializeToElement(new { });

    private readonly CodexAppServerClientOptions _options;
    private readonly Process _process;
    private readonly CancellationTokenSource _lifetimeCancellation = new();
    private readonly ConcurrentDictionary<string, TaskCompletionSource<JsonElement>> _pendingRequests =
        new(StringComparer.Ordinal);
    private readonly SemaphoreSlim _writeGate = new(1, 1);
    private readonly object _stderrSync = new();
    private readonly Queue<string> _stderrTail = new();
    private readonly Task _stdoutReaderTask;
    private readonly Task _stderrReaderTask;
    private long _nextRequestId;
    private int _disposeState;
    private int _malformedStdoutLineCount;
    private int _unknownResponseCount;
    private bool _initialized;

    private CodexAppServerClient(
        CodexAppServerClientOptions options,
        Process process,
        string executablePath)
    {
        _options = options;
        _process = process;
        ExecutablePath = executablePath;
        _stdoutReaderTask = ReadStdoutAsync(_lifetimeCancellation.Token);
        _stderrReaderTask = ReadStderrAsync(_lifetimeCancellation.Token);
    }

    public event EventHandler<CodexAppServerNotificationEventArgs>? NotificationReceived;

    public string ExecutablePath { get; }

    public int ProcessId => _process.Id;

    public bool IsInitialized => _initialized;

    public int MalformedStdoutLineCount => Volatile.Read(ref _malformedStdoutLineCount);

    public int UnknownResponseCount => Volatile.Read(ref _unknownResponseCount);

    public IReadOnlyList<string> StderrTail
    {
        get
        {
            lock (_stderrSync)
            {
                return _stderrTail.ToArray();
            }
        }
    }

    public static async Task<CodexAppServerClient> StartAsync(
        CodexAppServerClientOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        options ??= new CodexAppServerClientOptions();
        var executablePath = CodexExecutableResolver.Resolve(options.ExecutablePath);
        var process = new Process
        {
            StartInfo = CodexExecutableResolver.CreateAppServerStartInfo(executablePath),
            EnableRaisingEvents = true
        };

        if (!process.Start())
        {
            process.Dispose();
            throw new InvalidOperationException("Failed to start codex app-server.");
        }

        process.StandardInput.AutoFlush = true;
        var client = new CodexAppServerClient(options, process, executablePath);
        try
        {
            await client.InitializeAsync(cancellationToken);
            return client;
        }
        catch
        {
            await client.DisposeAsync();
            throw;
        }
    }

    public Task<JsonElement> SendRequestAsync(
        string method,
        object? parameters = null,
        CancellationToken cancellationToken = default)
    {
        if (!_initialized)
        {
            throw new InvalidOperationException("codex app-server is not initialized.");
        }

        return SendRequestCoreAsync(method, parameters, cancellationToken);
    }

    public Task SendNotificationAsync(
        string method,
        object? parameters = null,
        CancellationToken cancellationToken = default)
    {
        if (!_initialized)
        {
            throw new InvalidOperationException("codex app-server is not initialized.");
        }

        return SendNotificationCoreAsync(method, parameters, cancellationToken);
    }

    private async Task InitializeAsync(CancellationToken cancellationToken)
    {
        _ = await SendRequestCoreAsync(
            "initialize",
            new
            {
                clientInfo = new
                {
                    name = _options.ClientName,
                    title = _options.ClientTitle,
                    version = _options.ClientVersion
                },
                capabilities = new
                {
                    experimentalApi = _options.ExperimentalApi
                }
            },
            cancellationToken);

        await SendNotificationCoreAsync("initialized", new { }, cancellationToken);
        _initialized = true;
    }

    private async Task<JsonElement> SendRequestCoreAsync(
        string method,
        object? parameters,
        CancellationToken cancellationToken)
    {
        ThrowIfDisposed();
        ArgumentException.ThrowIfNullOrWhiteSpace(method);

        var id = Interlocked.Increment(ref _nextRequestId);
        var requestKey = id.ToString(CultureInfo.InvariantCulture);
        var completion = new TaskCompletionSource<JsonElement>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        if (!_pendingRequests.TryAdd(requestKey, completion))
        {
            throw new InvalidOperationException($"Duplicate app-server request id: {requestKey}");
        }

        try
        {
            await WriteMessageAsync(
                new
                {
                    method,
                    id,
                    @params = parameters
                },
                cancellationToken);

            try
            {
                return await completion.Task.WaitAsync(_options.RequestTimeout, cancellationToken);
            }
            catch (TimeoutException)
            {
                _pendingRequests.TryRemove(requestKey, out _);
                throw new TimeoutException(
                    $"codex app-server request timed out after {_options.RequestTimeout}: {method}");
            }
            catch (OperationCanceledException)
            {
                _pendingRequests.TryRemove(requestKey, out _);
                throw;
            }
        }
        catch
        {
            _pendingRequests.TryRemove(requestKey, out _);
            throw;
        }
    }

    private Task SendNotificationCoreAsync(
        string method,
        object? parameters,
        CancellationToken cancellationToken)
    {
        ThrowIfDisposed();
        ArgumentException.ThrowIfNullOrWhiteSpace(method);
        return WriteMessageAsync(
            new
            {
                method,
                @params = parameters
            },
            cancellationToken);
    }

    private async Task WriteMessageAsync(object message, CancellationToken cancellationToken)
    {
        var json = JsonSerializer.Serialize(message, JsonOptions);
        await _writeGate.WaitAsync(cancellationToken);
        try
        {
            ThrowIfDisposed();
            await _process.StandardInput.WriteLineAsync(json.AsMemory(), cancellationToken);
            await _process.StandardInput.FlushAsync(cancellationToken);
        }
        catch (InvalidOperationException exception)
        {
            throw new IOException("codex app-server stdin is unavailable.", exception);
        }
        finally
        {
            _writeGate.Release();
        }
    }

    private async Task ReadStdoutAsync(CancellationToken cancellationToken)
    {
        Exception? terminalError = null;
        try
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                var line = await _process.StandardOutput.ReadLineAsync(cancellationToken);
                if (line is null)
                {
                    break;
                }

                HandleProtocolLine(line);
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
        catch (Exception exception) when (exception is IOException or ObjectDisposedException)
        {
            terminalError = exception;
        }
        finally
        {
            var exitDescription = _process.HasExited
                ? $"exit code {_process.ExitCode}"
                : "stdout closed";
            FailPendingRequests(
                terminalError
                ?? new IOException($"codex app-server transport ended: {exitDescription}."));
        }
    }

    private async Task ReadStderrAsync(CancellationToken cancellationToken)
    {
        try
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                var line = await _process.StandardError.ReadLineAsync(cancellationToken);
                if (line is null)
                {
                    break;
                }

                lock (_stderrSync)
                {
                    _stderrTail.Enqueue(line);
                    while (_stderrTail.Count > 50)
                    {
                        _ = _stderrTail.Dequeue();
                    }
                }
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
        catch (Exception exception) when (exception is IOException or ObjectDisposedException)
        {
            lock (_stderrSync)
            {
                _stderrTail.Enqueue($"stderr-reader:{exception.GetType().Name}");
            }
        }
    }

    private void HandleProtocolLine(string line)
    {
        JsonElement root;
        try
        {
            using var document = JsonDocument.Parse(line);
            root = document.RootElement.Clone();
        }
        catch (JsonException)
        {
            Interlocked.Increment(ref _malformedStdoutLineCount);
            return;
        }

        if (TryReadResponseId(root, out var responseId))
        {
            if (!_pendingRequests.TryRemove(responseId, out var completion))
            {
                Interlocked.Increment(ref _unknownResponseCount);
                return;
            }

            if (root.TryGetProperty("error", out var error)
                && error.ValueKind is not JsonValueKind.Null and not JsonValueKind.Undefined)
            {
                completion.TrySetException(CodexAppServerRpcException.From(error));
                return;
            }

            completion.TrySetResult(
                root.TryGetProperty("result", out var result)
                    ? result.Clone()
                    : EmptyObject.Clone());
            return;
        }

        if (!root.TryGetProperty("method", out var methodElement)
            || methodElement.ValueKind != JsonValueKind.String)
        {
            Interlocked.Increment(ref _malformedStdoutLineCount);
            return;
        }

        var method = methodElement.GetString();
        if (string.IsNullOrWhiteSpace(method))
        {
            Interlocked.Increment(ref _malformedStdoutLineCount);
            return;
        }

        JsonElement? parameters = null;
        if (root.TryGetProperty("params", out var paramsElement))
        {
            parameters = paramsElement.Clone();
        }

        NotificationReceived?.Invoke(
            this,
            new CodexAppServerNotificationEventArgs(method, parameters));
    }

    private static bool TryReadResponseId(JsonElement root, out string id)
    {
        id = string.Empty;
        if (!root.TryGetProperty("id", out var idElement))
        {
            return false;
        }

        switch (idElement.ValueKind)
        {
            case JsonValueKind.Number:
                id = idElement.GetRawText();
                return true;
            case JsonValueKind.String:
                id = idElement.GetString() ?? string.Empty;
                return !string.IsNullOrWhiteSpace(id);
            default:
                return false;
        }
    }

    private void FailPendingRequests(Exception exception)
    {
        foreach (var entry in _pendingRequests.ToArray())
        {
            if (_pendingRequests.TryRemove(entry.Key, out var completion))
            {
                completion.TrySetException(exception);
            }
        }
    }

    private void ThrowIfDisposed()
    {
        ObjectDisposedException.ThrowIf(Volatile.Read(ref _disposeState) != 0, this);
    }

    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref _disposeState, 1) != 0)
        {
            return;
        }

        _initialized = false;
        try
        {
            _process.StandardInput.Close();
        }
        catch (Exception exception) when (exception is IOException or InvalidOperationException)
        {
        }

        try
        {
            await _process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(2));
        }
        catch (TimeoutException)
        {
            try
            {
                _process.Kill(entireProcessTree: true);
            }
            catch (Exception exception) when (exception is InvalidOperationException or System.ComponentModel.Win32Exception)
            {
            }
        }

        _lifetimeCancellation.Cancel();
        FailPendingRequests(new ObjectDisposedException(nameof(CodexAppServerClient)));

        await SuppressShutdownExceptionAsync(_stdoutReaderTask);
        await SuppressShutdownExceptionAsync(_stderrReaderTask);

        _writeGate.Dispose();
        _lifetimeCancellation.Dispose();
        _process.Dispose();
    }

    private static async Task SuppressShutdownExceptionAsync(Task task)
    {
        try
        {
            await task;
        }
        catch (Exception exception) when (exception is OperationCanceledException or IOException or ObjectDisposedException)
        {
        }
    }
}

internal sealed class CodexAppServerNotificationEventArgs(
    string method,
    JsonElement? parameters) : EventArgs
{
    public string Method { get; } = method;

    public JsonElement? Params { get; } = parameters;
}

internal sealed class CodexAppServerRpcException(
    int code,
    string rpcMessage,
    JsonElement? data) : Exception($"codex app-server RPC error {code}: {rpcMessage}")
{
    public int Code { get; } = code;

    public string RpcMessage { get; } = rpcMessage;

    public JsonElement? Data { get; } = data;

    public bool IsRetryableOverload => Code == -32001;

    public static CodexAppServerRpcException From(JsonElement error)
    {
        var code = error.TryGetProperty("code", out var codeElement)
            && codeElement.TryGetInt32(out var parsedCode)
                ? parsedCode
                : 0;
        var message = error.TryGetProperty("message", out var messageElement)
            && messageElement.ValueKind == JsonValueKind.String
                ? messageElement.GetString() ?? "Unknown app-server error."
                : "Unknown app-server error.";
        JsonElement? data = error.TryGetProperty("data", out var dataElement)
            ? dataElement.Clone()
            : null;
        return new CodexAppServerRpcException(code, message, data);
    }
}

internal static class CodexExecutableResolver
{
    private static readonly string[] SupportedExtensions = [".exe", ".cmd", ".bat", ".ps1"];

    public static string Resolve(string? explicitPath = null)
    {
        var configured = explicitPath;
        if (string.IsNullOrWhiteSpace(configured))
        {
            configured = Environment.GetEnvironmentVariable("HOVERPOCKET_CODEX_EXECUTABLE");
        }

        if (!string.IsNullOrWhiteSpace(configured))
        {
            var fullPath = Path.GetFullPath(configured);
            if (!File.Exists(fullPath))
            {
                throw new FileNotFoundException("Configured Codex executable was not found.", fullPath);
            }

            return fullPath;
        }

        var candidates = LocateWithWhere("codex");
        var resolved = candidates.FirstOrDefault(path =>
            SupportedExtensions.Contains(Path.GetExtension(path), StringComparer.OrdinalIgnoreCase));
        return resolved
            ?? throw new FileNotFoundException(
                "Codex CLI was not found on PATH. Set HOVERPOCKET_CODEX_EXECUTABLE to codex.exe, codex.cmd, or codex.ps1.");
    }

    public static ProcessStartInfo CreateAppServerStartInfo(string executablePath)
    {
        var extension = Path.GetExtension(executablePath);
        ProcessStartInfo startInfo;
        if (extension.Equals(".cmd", StringComparison.OrdinalIgnoreCase)
            || extension.Equals(".bat", StringComparison.OrdinalIgnoreCase))
        {
            startInfo = CreateBaseStartInfo(
                Environment.GetEnvironmentVariable("COMSPEC") ?? "cmd.exe");
            startInfo.ArgumentList.Add("/d");
            startInfo.ArgumentList.Add("/s");
            startInfo.ArgumentList.Add("/c");
            startInfo.ArgumentList.Add($"\"{executablePath}\" app-server --stdio");
        }
        else if (extension.Equals(".ps1", StringComparison.OrdinalIgnoreCase))
        {
            var powershell = LocateWithWhere("pwsh.exe").FirstOrDefault()
                ?? LocateWithWhere("powershell.exe").FirstOrDefault()
                ?? "powershell.exe";
            startInfo = CreateBaseStartInfo(powershell);
            startInfo.ArgumentList.Add("-NoLogo");
            startInfo.ArgumentList.Add("-NoProfile");
            startInfo.ArgumentList.Add("-NonInteractive");
            startInfo.ArgumentList.Add("-ExecutionPolicy");
            startInfo.ArgumentList.Add("Bypass");
            startInfo.ArgumentList.Add("-File");
            startInfo.ArgumentList.Add(executablePath);
            startInfo.ArgumentList.Add("app-server");
            startInfo.ArgumentList.Add("--stdio");
        }
        else
        {
            startInfo = CreateBaseStartInfo(executablePath);
            startInfo.ArgumentList.Add("app-server");
            startInfo.ArgumentList.Add("--stdio");
        }

        startInfo.Environment["LOG_FORMAT"] = "json";
        return startInfo;
    }

    private static ProcessStartInfo CreateBaseStartInfo(string fileName)
    {
        return new ProcessStartInfo
        {
            FileName = fileName,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardInputEncoding = new UTF8Encoding(false),
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8
        };
    }

    private static IReadOnlyList<string> LocateWithWhere(string command)
    {
        try
        {
            using var process = new Process
            {
                StartInfo = new ProcessStartInfo
                {
                    FileName = "where.exe",
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true
                }
            };
            process.StartInfo.ArgumentList.Add(command);
            if (!process.Start())
            {
                return [];
            }

            var output = process.StandardOutput.ReadToEnd();
            if (!process.WaitForExit(3000) || process.ExitCode != 0)
            {
                return [];
            }

            return output
                .Split(["\r\n", "\n"], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                .Where(File.Exists)
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .ToArray();
        }
        catch (Exception exception) when (exception is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            return [];
        }
    }
}
