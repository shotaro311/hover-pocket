using System.Text.Json;

namespace HoverPocket.Shell.Providers.CodexVoice;

internal enum CodexVoiceAvailability
{
    Disabled,
    Starting,
    Ready,
    Unavailable,
    Incompatible,
    Faulted
}

internal enum CodexVoiceSessionStatus
{
    Idle,
    Connecting,
    Connected,
    Muted,
    Reconnecting,
    Closed,
    Failed
}

internal sealed record CodexVoiceTranscriptEntry(
    string ThreadId,
    string Role,
    string Text,
    bool IsComplete,
    DateTimeOffset UpdatedAt);

internal sealed record CodexVoiceSnapshot(
    bool FeatureEnabled,
    CodexVoiceAvailability Availability,
    CodexVoiceSessionStatus SessionStatus,
    string? RootThreadId,
    bool TransportAttached,
    bool IsMuted,
    IReadOnlyList<CodexVoiceTranscriptEntry> Transcript,
    string? LastErrorCode,
    int? AppServerProcessId);

internal sealed class CodexVoiceCoordinator : IAsyncDisposable
{
    private const int DefaultTranscriptEntryLimit = 120;
    private const int DefaultTranscriptCharacterLimit = 32_000;

    private readonly bool _featureEnabled;
    private readonly Func<CancellationToken, Task<CodexAppServerClient>> _clientFactory;
    private readonly SemaphoreSlim _lifecycleGate = new(1, 1);
    private readonly object _stateSync = new();
    private readonly CodexVoiceTranscriptBuffer _transcript;
    private CodexAppServerClient? _client;
    private CodexVoiceAvailability _availability;
    private CodexVoiceSessionStatus _sessionStatus = CodexVoiceSessionStatus.Idle;
    private string? _rootThreadId;
    private bool _transportAttached;
    private bool _isMuted = true;
    private string? _lastErrorCode;
    private int _disposeState;

    public CodexVoiceCoordinator(
        bool featureEnabled,
        Func<CancellationToken, Task<CodexAppServerClient>>? clientFactory = null,
        int transcriptEntryLimit = DefaultTranscriptEntryLimit,
        int transcriptCharacterLimit = DefaultTranscriptCharacterLimit)
    {
        _featureEnabled = featureEnabled;
        _availability = featureEnabled
            ? CodexVoiceAvailability.Unavailable
            : CodexVoiceAvailability.Disabled;
        _clientFactory = clientFactory
            ?? (cancellationToken => CodexAppServerClient.StartAsync(cancellationToken: cancellationToken));
        _transcript = new CodexVoiceTranscriptBuffer(
            transcriptEntryLimit,
            transcriptCharacterLimit);
    }

    public event EventHandler<CodexVoiceSnapshot>? SnapshotChanged;

    public CodexVoiceSnapshot Snapshot
    {
        get
        {
            lock (_stateSync)
            {
                return BuildSnapshotLocked();
            }
        }
    }

    public async Task InitializeAsync(CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        if (!_featureEnabled)
        {
            PublishSnapshot();
            return;
        }

        await _lifecycleGate.WaitAsync(cancellationToken);
        try
        {
            ThrowIfDisposed();
            if (_client is not null)
            {
                return;
            }

            UpdateState(
                availability: CodexVoiceAvailability.Starting,
                sessionStatus: CodexVoiceSessionStatus.Idle,
                lastErrorCode: null);
            try
            {
                var client = await _clientFactory(cancellationToken);
                client.NotificationReceived += OnAppServerNotification;
                client.ServerRequestHandler = HandleServerRequestAsync;
                _client = client;
                UpdateState(
                    availability: CodexVoiceAvailability.Ready,
                    sessionStatus: CodexVoiceSessionStatus.Idle,
                    lastErrorCode: null);
            }
            catch (FileNotFoundException)
            {
                UpdateState(
                    availability: CodexVoiceAvailability.Unavailable,
                    sessionStatus: CodexVoiceSessionStatus.Failed,
                    lastErrorCode: "codex_not_found");
            }
            catch (CodexAppServerRpcException exception)
            {
                UpdateState(
                    availability: CodexVoiceAvailability.Incompatible,
                    sessionStatus: CodexVoiceSessionStatus.Failed,
                    lastErrorCode: $"rpc_{exception.Code}");
            }
            catch (Exception exception) when (exception is IOException
                or InvalidOperationException
                or TimeoutException
                or System.ComponentModel.Win32Exception)
            {
                UpdateState(
                    availability: CodexVoiceAvailability.Faulted,
                    sessionStatus: CodexVoiceSessionStatus.Failed,
                    lastErrorCode: exception.GetType().Name);
            }
        }
        finally
        {
            _lifecycleGate.Release();
        }
    }

    public void MarkSessionConnecting(string? rootThreadId = null)
    {
        ThrowIfDisposed();
        lock (_stateSync)
        {
            if (!string.IsNullOrWhiteSpace(rootThreadId))
            {
                _rootThreadId = rootThreadId;
            }

            _sessionStatus = CodexVoiceSessionStatus.Connecting;
            _lastErrorCode = null;
        }

        PublishSnapshot();
    }

    public void AttachTransport()
    {
        ThrowIfDisposed();
        lock (_stateSync)
        {
            _transportAttached = true;
            _sessionStatus = _isMuted
                ? CodexVoiceSessionStatus.Muted
                : CodexVoiceSessionStatus.Connected;
        }

        PublishSnapshot();
    }

    public void DetachTransport(bool reconnectExpected)
    {
        ThrowIfDisposed();
        lock (_stateSync)
        {
            _transportAttached = false;
            _sessionStatus = reconnectExpected
                ? CodexVoiceSessionStatus.Reconnecting
                : CodexVoiceSessionStatus.Closed;
        }

        PublishSnapshot();
    }

    public void SetMuted(bool muted)
    {
        ThrowIfDisposed();
        lock (_stateSync)
        {
            _isMuted = muted;
            if (_transportAttached)
            {
                _sessionStatus = muted
                    ? CodexVoiceSessionStatus.Muted
                    : CodexVoiceSessionStatus.Connected;
            }
        }

        PublishSnapshot();
    }

    public void ClearTransientUiState()
    {
        ThrowIfDisposed();
        lock (_stateSync)
        {
            _transportAttached = false;
            _isMuted = true;
            if (_sessionStatus is CodexVoiceSessionStatus.Connected
                or CodexVoiceSessionStatus.Muted
                or CodexVoiceSessionStatus.Connecting)
            {
                _sessionStatus = CodexVoiceSessionStatus.Reconnecting;
            }
        }

        PublishSnapshot();
    }

    internal void ProcessNotificationForVerify(
        string method,
        object? parameters)
    {
        var element = parameters is null
            ? (JsonElement?)null
            : JsonSerializer.SerializeToElement(parameters);
        ProcessNotification(method, element);
    }

    private void OnAppServerNotification(
        object? sender,
        CodexAppServerNotificationEventArgs eventArgs)
    {
        _ = sender;
        ProcessNotification(eventArgs.Method, eventArgs.Params);
    }

    private void ProcessNotification(string method, JsonElement? parameters)
    {
        if (Volatile.Read(ref _disposeState) != 0)
        {
            return;
        }

        var changed = false;
        lock (_stateSync)
        {
            switch (method)
            {
                case "thread/realtime/started":
                    _rootThreadId = ReadString(parameters, "threadId") ?? _rootThreadId;
                    _sessionStatus = _isMuted
                        ? CodexVoiceSessionStatus.Muted
                        : CodexVoiceSessionStatus.Connected;
                    _lastErrorCode = null;
                    changed = true;
                    break;
                case "thread/realtime/transcript/delta":
                    changed = _transcript.AppendDelta(
                        ReadString(parameters, "threadId") ?? _rootThreadId ?? string.Empty,
                        ReadString(parameters, "role") ?? "unknown",
                        ReadString(parameters, "delta") ?? string.Empty,
                        DateTimeOffset.UtcNow);
                    break;
                case "thread/realtime/transcript/done":
                    changed = _transcript.MarkComplete(
                        ReadString(parameters, "threadId") ?? _rootThreadId ?? string.Empty,
                        ReadString(parameters, "role") ?? "unknown",
                        DateTimeOffset.UtcNow);
                    break;
                case "thread/realtime/closed":
                    _transportAttached = false;
                    _sessionStatus = CodexVoiceSessionStatus.Closed;
                    _lastErrorCode = ReadString(parameters, "reason") is { Length: > 0 }
                        ? "realtime_closed"
                        : null;
                    changed = true;
                    break;
                case "thread/realtime/error":
                    _sessionStatus = CodexVoiceSessionStatus.Failed;
                    _lastErrorCode = "realtime_error";
                    changed = true;
                    break;
            }
        }

        if (changed)
        {
            PublishSnapshot();
        }
    }

    private static Task<CodexAppServerReply> HandleServerRequestAsync(
        CodexAppServerRequest request,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();

        // Approval and user-input requests must be surfaced through a dedicated,
        // structured UI path. Until that path is implemented, fail closed instead
        // of accepting or synthesizing a response.
        return Task.FromResult(
            CodexAppServerReply.Failure(
                -32601,
                $"HoverPocket has no handler for app-server request: {request.Method}"));
    }

    private void UpdateState(
        CodexVoiceAvailability availability,
        CodexVoiceSessionStatus sessionStatus,
        string? lastErrorCode)
    {
        lock (_stateSync)
        {
            _availability = availability;
            _sessionStatus = sessionStatus;
            _lastErrorCode = lastErrorCode;
        }

        PublishSnapshot();
    }

    private void PublishSnapshot()
    {
        var handlers = SnapshotChanged;
        if (handlers is null)
        {
            return;
        }

        var snapshot = Snapshot;
        foreach (EventHandler<CodexVoiceSnapshot> handler in handlers.GetInvocationList())
        {
            try
            {
                handler(this, snapshot);
            }
            catch (Exception)
            {
                // A UI subscriber must never take down the coordinator or app-server.
            }
        }
    }

    private CodexVoiceSnapshot BuildSnapshotLocked()
    {
        return new CodexVoiceSnapshot(
            _featureEnabled,
            _availability,
            _sessionStatus,
            _rootThreadId,
            _transportAttached,
            _isMuted,
            _transcript.Snapshot(),
            _lastErrorCode,
            _client?.ProcessId);
    }

    private static string? ReadString(JsonElement? parameters, string propertyName)
    {
        if (parameters is not { } element
            || element.ValueKind != JsonValueKind.Object
            || !element.TryGetProperty(propertyName, out var property)
            || property.ValueKind != JsonValueKind.String)
        {
            return null;
        }

        return property.GetString();
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

        await _lifecycleGate.WaitAsync();
        try
        {
            var client = _client;
            _client = null;
            if (client is not null)
            {
                client.NotificationReceived -= OnAppServerNotification;
                client.ServerRequestHandler = null;
                await client.DisposeAsync();
            }

            lock (_stateSync)
            {
                _transportAttached = false;
                _isMuted = true;
                _sessionStatus = CodexVoiceSessionStatus.Closed;
            }
        }
        finally
        {
            _lifecycleGate.Release();
            _lifecycleGate.Dispose();
        }
    }
}

internal sealed class CodexVoiceTranscriptBuffer
{
    private readonly int _entryLimit;
    private readonly int _characterLimit;
    private readonly List<CodexVoiceTranscriptEntry> _entries = [];
    private int _characterCount;

    public CodexVoiceTranscriptBuffer(int entryLimit, int characterLimit)
    {
        if (entryLimit < 1)
        {
            throw new ArgumentOutOfRangeException(nameof(entryLimit));
        }

        if (characterLimit < 1)
        {
            throw new ArgumentOutOfRangeException(nameof(characterLimit));
        }

        _entryLimit = entryLimit;
        _characterLimit = characterLimit;
    }

    public bool AppendDelta(
        string threadId,
        string role,
        string delta,
        DateTimeOffset updatedAt)
    {
        if (string.IsNullOrEmpty(delta))
        {
            return false;
        }

        var lastIndex = _entries.Count - 1;
        if (lastIndex >= 0)
        {
            var last = _entries[lastIndex];
            if (!last.IsComplete
                && last.ThreadId == threadId
                && last.Role == role)
            {
                _entries[lastIndex] = last with
                {
                    Text = last.Text + delta,
                    UpdatedAt = updatedAt
                };
                _characterCount += delta.Length;
                Trim();
                return true;
            }
        }

        _entries.Add(new CodexVoiceTranscriptEntry(
            threadId,
            role,
            delta,
            false,
            updatedAt));
        _characterCount += delta.Length;
        Trim();
        return true;
    }

    public bool MarkComplete(
        string threadId,
        string role,
        DateTimeOffset updatedAt)
    {
        for (var index = _entries.Count - 1; index >= 0; index--)
        {
            var entry = _entries[index];
            if (!entry.IsComplete
                && entry.ThreadId == threadId
                && entry.Role == role)
            {
                _entries[index] = entry with
                {
                    IsComplete = true,
                    UpdatedAt = updatedAt
                };
                return true;
            }
        }

        return false;
    }

    public IReadOnlyList<CodexVoiceTranscriptEntry> Snapshot()
    {
        return _entries.ToArray();
    }

    private void Trim()
    {
        while (_entries.Count > _entryLimit
            || (_characterCount > _characterLimit && _entries.Count > 1))
        {
            _characterCount -= _entries[0].Text.Length;
            _entries.RemoveAt(0);
        }

        if (_entries.Count == 1 && _characterCount > _characterLimit)
        {
            var entry = _entries[0];
            var keep = Math.Min(_characterLimit, entry.Text.Length);
            var trimmedText = entry.Text[^keep..];
            _entries[0] = entry with { Text = trimmedText };
            _characterCount = trimmedText.Length;
        }
    }
}
