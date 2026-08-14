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

    public bool ExperimentalApi { get; init; }
}

internal sealed record CodexAppServerRequest(
    JsonElement Id,
    string Method,
    JsonElement? Params);

internal sealed record CodexAppServerReply(
    object? Result,
    CodexAppServerReplyError? Error)
{
    public static CodexAppServerReply Success(object? result = null)
    {
        return new CodexAppServerReply(result, null);
    }

    public static CodexAppServerReply Failure(
        int code,
        string message,
        object? data = null)
    {
        return new CodexAppServerReply(null, new CodexAppServerReplyError(code, message, data));
    }
}

internal sealed record CodexAppServerReplyError(
    [property: JsonPropertyName("code")] int Code,
    [property: JsonPropertyName("message")] string Message,
    [property: JsonPropertyName("data")] object? Data = null);

internal sealed class CodexAppServerClient : IAsyncDisposable
{
    private const int MaximumProtocolLineCharacters = 1_048_576;
    private const int MaximumConcurrentServerRequests = 8;
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
    private readonly SemaphoreSlim _serverRequestGate = new(
        MaximumConcurrentServerRequests,
        MaximumConcurrentServerRequests);
    private readonly object _stderrSync = new();
    private readonly Queue<string> _stderrTail = new();
    private readonly Task _stdoutReaderTask;
    private readonly Task _stderrReaderTask;
    private long _nextRequestId;
    private int _disposeState;
    private int _malformedStdoutLineCount;
    private int _unknownResponseCount;
    private int _unhandledServerRequestCount;
    private int _notificationHandlerFailureCount;
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

    public event EventHandler<CodexAppServerTransportEndedEventArgs>? TransportEnded;

    public Func<CodexAppServerRequest, CancellationToken, Task<CodexAppServerReply>>? ServerRequestHandler { get; set; }

    public string ExecutablePath { get; }

    public int ProcessId => _process.Id;

    public bool IsInitialized => _initialized;

    public int MalformedStdoutLineCount => Volatile.Read(ref _malformedStdoutLineCount);

    public int UnknownResponseCount => Volatile.Read(ref _unknownResponseCount);

    public int UnhandledServerRequestCount => Volatile.Read(ref _unhandledServerRequestCount);

    public int NotificationHandlerFailureCount => Volatile.Read(ref _notificationHandlerFailureCount);

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

    public async Task<JsonElement> SendIdempotentRequestWithRetryAsync(
        string method,
        object? parameters = null,
        int maxAttempts = 3,
        CancellationToken cancellationToken = default)
    {
        if (maxAttempts < 1)
        {
            throw new ArgumentOutOfRangeException(nameof(maxAttempts), maxAttempts, "At least one attempt is required.");
        }

        for (var attempt = 1; ; attempt++)
        {
            try
            {
                return await SendRequestAsync(method, parameters, cancellationToken);
            }
            catch (CodexAppServerRpcException exception)
                when (exception.IsRetryableOverload && attempt < maxAttempts)
            {
                var exponentialMilliseconds = Math.Min(2_000, 100 * Math.Pow(2, attempt - 1));
                var jitterMilliseconds = Random.Shared.Next(25, 126);
                await Task.Delay(
                    TimeSpan.FromMilliseconds(exponentialMilliseconds + jitterMilliseconds),
                    cancellationToken);
            }
        }
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
        catch (Exception exception) when (exception is InvalidOperationException or IOException or ObjectDisposedException)
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
            var buffer = new char[4096];
            var line = new StringBuilder();
            var discardingOversizedLine = false;
            while (!cancellationToken.IsCancellationRequested)
            {
                var count = await _process.StandardOutput.ReadAsync(
                    buffer.AsMemory(),
                    cancellationToken);
                if (count == 0)
                {
                    break;
                }

                for (var index = 0; index < count; index++)
                {
                    var character = buffer[index];
                    if (character == '\n')
                    {
                        if (discardingOversizedLine)
                        {
                            Interlocked.Increment(ref _malformedStdoutLineCount);
                        }
                        else
                        {
                            if (line.Length > 0 && line[^1] == '\r')
                            {
                                line.Length--;
                            }
                            if (line.Length > 0)
                            {
                                HandleProtocolLine(line.ToString());
                            }
                        }

                        line.Clear();
                        discardingOversizedLine = false;
                        continue;
                    }

                    if (discardingOversizedLine)
                    {
                        continue;
                    }
                    if (line.Length >= MaximumProtocolLineCharacters)
                    {
                        line.Clear();
                        discardingOversizedLine = true;
                        continue;
                    }
                    line.Append(character);
                }
            }

            if (discardingOversizedLine)
            {
                Interlocked.Increment(ref _malformedStdoutLineCount);
            }
            else if (line.Length > 0)
            {
                HandleProtocolLine(line.ToString());
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
            var exitDescription = "stdout closed";
            try
            {
                if (_process.HasExited)
                {
                    exitDescription = $"exit code {_process.ExitCode}";
                }
            }
            catch (InvalidOperationException)
            {
            }

            var transportError = terminalError
                ?? new IOException($"codex app-server transport ended: {exitDescription}.");
            FailPendingRequests(transportError);
            if (!cancellationToken.IsCancellationRequested
                && Volatile.Read(ref _disposeState) == 0)
            {
                RaiseTransportEndedSafely(transportError.GetType().Name);
            }
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

        if (TryReadMethod(root, out var method))
        {
            JsonElement? parameters = null;
            if (root.TryGetProperty("params", out var paramsElement))
            {
                parameters = paramsElement.Clone();
            }

            if (TryReadIdElement(root, out var requestId))
            {
                var request = new CodexAppServerRequest(requestId, method, parameters);
                if (_serverRequestGate.Wait(0))
                {
                    _ = HandleBoundedServerRequestAsync(
                        request,
                        _lifetimeCancellation.Token);
                }
                else
                {
                    _ = WriteServerReplyAsync(
                        request,
                        CodexAppServerReply.Failure(
                            -32001,
                            "HoverPocket server request queue is full."),
                        _lifetimeCancellation.Token);
                }
                return;
            }

            RaiseNotificationSafely(method, parameters);
            return;
        }

        if (!TryReadResponseId(root, out var responseId))
        {
            Interlocked.Increment(ref _malformedStdoutLineCount);
            return;
        }

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
    }

    private async Task HandleServerRequestAsync(
        CodexAppServerRequest request,
        CancellationToken cancellationToken)
    {
        CodexAppServerReply reply;
        try
        {
            var handler = ServerRequestHandler;
            if (handler is null)
            {
                Interlocked.Increment(ref _unhandledServerRequestCount);
                reply = CodexAppServerReply.Failure(
                    -32601,
                    $"Unsupported app-server request: {request.Method}");
            }
            else
            {
                reply = await handler(request, cancellationToken);
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            return;
        }
        catch (Exception)
        {
            reply = CodexAppServerReply.Failure(-32603, "Client request handler failed.");
        }

        await WriteServerReplyAsync(request, reply, cancellationToken);
    }

    private async Task HandleBoundedServerRequestAsync(
        CodexAppServerRequest request,
        CancellationToken cancellationToken)
    {
        try
        {
            await HandleServerRequestAsync(request, cancellationToken);
        }
        finally
        {
            _serverRequestGate.Release();
        }
    }

    private async Task WriteServerReplyAsync(
        CodexAppServerRequest request,
        CodexAppServerReply reply,
        CancellationToken cancellationToken)
    {
        try
        {
            if (reply.Error is null)
            {
                await WriteMessageAsync(
                    new
                    {
                        id = request.Id,
                        result = reply.Result ?? new { }
                    },
                    cancellationToken);
            }
            else
            {
                await WriteMessageAsync(
                    new
                    {
                        id = request.Id,
                        error = reply.Error
                    },
                    cancellationToken);
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
        catch (Exception exception) when (exception is IOException or ObjectDisposedException)
        {
        }
    }

    private void RaiseNotificationSafely(string method, JsonElement? parameters)
    {
        var handlers = NotificationReceived;
        if (handlers is null)
        {
            return;
        }

        var eventArgs = new CodexAppServerNotificationEventArgs(method, parameters);
        foreach (EventHandler<CodexAppServerNotificationEventArgs> handler in handlers.GetInvocationList())
        {
            try
            {
                handler(this, eventArgs);
            }
            catch (Exception)
            {
                Interlocked.Increment(ref _notificationHandlerFailureCount);
            }
        }
    }

    private void RaiseTransportEndedSafely(string errorCode)
    {
        var handlers = TransportEnded;
        if (handlers is null)
        {
            return;
        }

        var eventArgs = new CodexAppServerTransportEndedEventArgs(errorCode);
        foreach (EventHandler<CodexAppServerTransportEndedEventArgs> handler in handlers.GetInvocationList())
        {
            try
            {
                handler(this, eventArgs);
            }
            catch (Exception)
            {
                // Transport observers must never take down the protocol reader.
            }
        }
    }

    private static bool TryReadMethod(JsonElement root, out string method)
    {
        method = string.Empty;
        if (!root.TryGetProperty("method", out var methodElement)
            || methodElement.ValueKind != JsonValueKind.String)
        {
            return false;
        }

        method = methodElement.GetString() ?? string.Empty;
        return !string.IsNullOrWhiteSpace(method);
    }

    private static bool TryReadIdElement(JsonElement root, out JsonElement id)
    {
        id = default;
        if (!root.TryGetProperty("id", out var idElement)
            || idElement.ValueKind is not (JsonValueKind.Number or JsonValueKind.String))
        {
            return false;
        }

        id = idElement.Clone();
        return true;
    }

    private static bool TryReadResponseId(JsonElement root, out string id)
    {
        id = string.Empty;
        if (!TryReadIdElement(root, out var idElement))
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
        catch (Exception exception) when (exception is IOException or InvalidOperationException or ObjectDisposedException)
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
            catch (Exception exception) when (exception is InvalidOperationException
                or System.ComponentModel.Win32Exception
                or ObjectDisposedException)
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

internal sealed class CodexAppServerTransportEndedEventArgs(string errorCode) : EventArgs
{
    public string ErrorCode { get; } = errorCode;
}

internal sealed class CodexAppServerRpcException(
    int code,
    string rpcMessage,
    JsonElement? rpcData) : Exception($"codex app-server RPC error {code}: {rpcMessage}")
{
    public int Code { get; } = code;

    public string RpcMessage { get; } = rpcMessage;

    public JsonElement? RpcData { get; } = rpcData;

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
            startInfo.ArgumentList.Add($"\"\"{executablePath}\" app-server --stdio\"");
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
