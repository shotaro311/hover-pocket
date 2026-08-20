using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text;
using System.Text.Json;

namespace HoverPocket.Shell.Voice;

internal sealed record CodexAppServerRequest(long Id, string Method, JsonElement? Parameters);

internal sealed record CodexAppServerNotification(string Method, JsonElement? Parameters);

internal sealed class CodexAppServerProtocolException : Exception
{
    public CodexAppServerProtocolException(string code)
        : base(code)
    {
        Code = code;
    }

    public string Code { get; }
}

internal sealed class CodexAppServerClient : IAsyncDisposable
{
    private const int MaxPendingRequests = 64;
    internal const int MaxLineCharacters = 1_048_576;

    private readonly TextReader _reader;
    private readonly TextWriter _writer;
    private readonly Func<ValueTask>? _disposeOwner;
    private readonly TimeSpan _requestTimeout;
    private readonly SemaphoreSlim _writeGate = new(1, 1);
    private readonly CancellationTokenSource _lifetime = new();
    private readonly ConcurrentDictionary<long, TaskCompletionSource<JsonElement>> _pending = new();
    private readonly Task _readLoop;
    private readonly char[] _readBuffer = new char[4_096];
    private int _readBufferOffset;
    private int _readBufferCount;
    private long _nextRequestId;
    private int _disposed;
    private int _disconnected;

    private CodexAppServerClient(
        TextReader reader,
        TextWriter writer,
        TimeSpan requestTimeout,
        Func<ValueTask>? disposeOwner,
        int? processId)
    {
        _reader = reader;
        _writer = writer;
        _requestTimeout = requestTimeout;
        _disposeOwner = disposeOwner;
        ProcessId = processId;
        _readLoop = ReadLoopAsync(_lifetime.Token);
    }

    public event EventHandler<CodexAppServerRequest>? ServerRequestReceived;

    public event EventHandler<CodexAppServerNotification>? NotificationReceived;

    public event EventHandler? Disconnected;

    public int? ProcessId { get; }

    public static CodexAppServerClient AttachForTesting(
        TextReader reader,
        TextWriter writer,
        TimeSpan? requestTimeout = null,
        Func<ValueTask>? disposeOwner = null)
    {
        return new CodexAppServerClient(
            reader,
            writer,
            requestTimeout ?? TimeSpan.FromSeconds(2),
            disposeOwner,
            processId: null);
    }

    public static Task<CodexAppServerClient> StartProcessAsync(
        string executablePath,
        IReadOnlyList<string> arguments,
        TimeSpan requestTimeout,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (string.IsNullOrWhiteSpace(executablePath))
        {
            throw new CodexAppServerProtocolException("codex_executable_missing");
        }

        var startInfo = new ProcessStartInfo
        {
            FileName = executablePath,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        foreach (var argument in arguments)
        {
            startInfo.ArgumentList.Add(argument);
        }

        var process = new Process
        {
            StartInfo = startInfo,
            EnableRaisingEvents = true
        };
        if (!process.Start())
        {
            process.Dispose();
            throw new CodexAppServerProtocolException("codex_process_start_failed");
        }

        var client = new CodexAppServerClient(
            process.StandardOutput,
            process.StandardInput,
            requestTimeout,
            async () =>
            {
                try
                {
                    if (!process.HasExited)
                    {
                        process.Kill(entireProcessTree: true);
                        await process.WaitForExitAsync();
                    }
                }
                catch (Exception exception) when (exception is InvalidOperationException
                    or NotSupportedException
                    or System.ComponentModel.Win32Exception)
                {
                }
                finally
                {
                    process.Dispose();
                }
            },
            process.Id);
        process.Exited += (_, _) => client.SignalDisconnected();
        return Task.FromResult(client);
    }

    public Task<JsonElement> InitializeAsync(JsonElement parameters, CancellationToken cancellationToken) =>
        SendRequestAsync("initialize", parameters, cancellationToken);

    public async Task<JsonElement> SendRequestAsync(
        string method,
        JsonElement? parameters,
        CancellationToken cancellationToken)
    {
        ThrowIfDisposed();
        if (string.IsNullOrWhiteSpace(method) || method.Length > 160)
        {
            throw new CodexAppServerProtocolException("request_method_invalid");
        }
        if (_pending.Count >= MaxPendingRequests)
        {
            throw new CodexAppServerProtocolException("request_overloaded");
        }

        var id = Interlocked.Increment(ref _nextRequestId);
        var completion = new TaskCompletionSource<JsonElement>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        if (!_pending.TryAdd(id, completion))
        {
            throw new CodexAppServerProtocolException("request_correlation_failed");
        }

        try
        {
            var envelope = JsonSerializer.Serialize(new
            {
                id,
                method,
                @params = parameters
            });
            await WriteLineAsync(envelope, cancellationToken);

            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(
                cancellationToken,
                _lifetime.Token);
            timeout.CancelAfter(_requestTimeout);
            try
            {
                return await completion.Task.WaitAsync(timeout.Token);
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested
                && !_lifetime.IsCancellationRequested)
            {
                throw new CodexAppServerProtocolException("request_timeout");
            }
        }
        finally
        {
            _pending.TryRemove(id, out _);
        }
    }

    public async Task ReplyFailClosedAsync(
        long requestId,
        string safeErrorCode,
        CancellationToken cancellationToken)
    {
        ThrowIfDisposed();
        var envelope = JsonSerializer.Serialize(new
        {
            id = requestId,
            error = new
            {
                code = -32601,
                message = VoiceTextSafety.SanitizeErrorCode(safeErrorCode)
            }
        });
        await WriteLineAsync(envelope, cancellationToken);
    }

    private async Task WriteLineAsync(string value, CancellationToken cancellationToken)
    {
        if (value.Length > MaxLineCharacters)
        {
            throw new CodexAppServerProtocolException("request_too_large");
        }

        await _writeGate.WaitAsync(cancellationToken);
        try
        {
            await _writer.WriteLineAsync(value.AsMemory(), cancellationToken);
            await _writer.FlushAsync(cancellationToken);
        }
        finally
        {
            _writeGate.Release();
        }
    }

    private async Task ReadLoopAsync(CancellationToken cancellationToken)
    {
        try
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                var line = await ReadBoundedLineAsync(cancellationToken);
                if (line is null)
                {
                    break;
                }
                if (line.Length == 0)
                {
                    continue;
                }
                using var document = JsonDocument.Parse(line);
                var root = document.RootElement;
                var hasId = root.TryGetProperty("id", out var idElement)
                    && idElement.ValueKind == JsonValueKind.Number
                    && idElement.TryGetInt64(out var id);
                var hasMethod = root.TryGetProperty("method", out var methodElement)
                    && methodElement.ValueKind == JsonValueKind.String;
                var method = hasMethod ? methodElement.GetString() ?? string.Empty : string.Empty;
                JsonElement? parameters = root.TryGetProperty("params", out var parametersElement)
                    ? parametersElement.Clone()
                    : null;

                if (hasId && hasMethod)
                {
                    ServerRequestReceived?.Invoke(
                        this,
                        new CodexAppServerRequest(id, method, parameters));
                    continue;
                }

                if (hasMethod)
                {
                    NotificationReceived?.Invoke(
                        this,
                        new CodexAppServerNotification(method, parameters));
                    continue;
                }

                if (!hasId || !_pending.TryGetValue(id, out var completion))
                {
                    continue;
                }

                if (root.TryGetProperty("result", out var result))
                {
                    completion.TrySetResult(result.Clone());
                }
                else
                {
                    completion.TrySetException(
                        new CodexAppServerProtocolException("server_error"));
                }
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
        catch (JsonException)
        {
        }
        catch (IOException)
        {
        }
        catch (InvalidOperationException)
        {
        }
        catch (CodexAppServerProtocolException)
        {
        }
        finally
        {
            SignalDisconnected();
        }
    }

    private async Task<string?> ReadBoundedLineAsync(CancellationToken cancellationToken)
    {
        var line = new StringBuilder(capacity: 4_096);
        while (true)
        {
            if (_readBufferOffset >= _readBufferCount)
            {
                _readBufferCount = await _reader.ReadAsync(_readBuffer.AsMemory(), cancellationToken);
                _readBufferOffset = 0;
                if (_readBufferCount == 0)
                {
                    return line.Length == 0 ? null : line.ToString();
                }
            }

            var character = _readBuffer[_readBufferOffset++];
            if (character == '\n')
            {
                if (line.Length > 0 && line[^1] == '\r')
                {
                    line.Length -= 1;
                }
                return line.ToString();
            }

            line.Append(character);
            if (line.Length > MaxLineCharacters)
            {
                throw new CodexAppServerProtocolException("response_too_large");
            }
        }
    }

    private void SignalDisconnected()
    {
        if (_lifetime.IsCancellationRequested
            || Interlocked.Exchange(ref _disconnected, 1) != 0)
        {
            return;
        }
        foreach (var completion in _pending.Values)
        {
            completion.TrySetException(
                new CodexAppServerProtocolException("transport_disconnected"));
        }
        Disconnected?.Invoke(this, EventArgs.Empty);
    }

    private void ThrowIfDisposed()
    {
        ObjectDisposedException.ThrowIf(Volatile.Read(ref _disposed) != 0, this);
    }

    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0)
        {
            return;
        }

        _lifetime.Cancel();
        try
        {
            try
            {
                await _readLoop;
            }
            catch (Exception) when (_lifetime.IsCancellationRequested)
            {
            }

            foreach (var completion in _pending.Values)
            {
                completion.TrySetCanceled();
            }
            _pending.Clear();
            if (_disposeOwner is not null)
            {
                await _disposeOwner();
            }
        }
        finally
        {
            _writeGate.Dispose();
            _lifetime.Dispose();
        }
    }
}
