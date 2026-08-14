using System.Text.Json;

namespace HoverPocket.Shell.Providers.CodexVoice;

internal enum CodexVoiceAvailability
{
    Disabled,
    Starting,
    Ready,
    SignedOut,
    Unavailable,
    Incompatible,
    Faulted,
    Blocked
}

internal enum CodexVoiceSessionStatus
{
    Idle,
    RequestingPermission,
    Negotiating,
    Connecting,
    Connected,
    Muted,
    Reconnecting,
    Stopping,
    Closed,
    RecoverableFailure,
    BlockedFailure
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
    int? AppServerProcessId,
    int RestartAttempt,
    int VoiceCount);

internal sealed record CodexVoiceWebRtcAnswer(
    string RootThreadId,
    string Sdp);

internal sealed class CodexVoiceCoordinator : IAsyncDisposable
{
    private const int DefaultTranscriptEntryLimit = 120;
    private const int DefaultTranscriptCharacterLimit = 32_000;
    private static readonly IReadOnlyList<TimeSpan> DefaultRestartDelays =
    [
        TimeSpan.Zero,
        TimeSpan.FromMilliseconds(450),
        TimeSpan.FromMilliseconds(1400)
    ];

    private readonly bool _featureEnabled;
    private readonly Func<CancellationToken, Task<CodexAppServerClient>> _clientFactory;
    private readonly SemaphoreSlim _lifecycleGate = new(1, 1);
    private readonly SemaphoreSlim _sessionGate = new(1, 1);
    private readonly object _stateSync = new();
    private readonly CodexVoiceTranscriptBuffer _transcript;
    private readonly IReadOnlyList<TimeSpan> _restartDelays;
    private readonly CancellationTokenSource _lifetimeCancellation = new();
    private readonly string _workspaceDirectory;
    private CodexAppServerClient? _client;
    private Task? _restartTask;
    private CodexVoiceAvailability _availability;
    private CodexVoiceSessionStatus _sessionStatus = CodexVoiceSessionStatus.Idle;
    private string? _rootThreadId;
    private bool _transportAttached;
    private bool _isMuted = true;
    private string? _lastErrorCode;
    private int? _appServerProcessId;
    private int _restartAttempt;
    private int _voiceCount;
    private string? _defaultVoice;
    private string? _pendingSdpThreadId;
    private TaskCompletionSource<string>? _pendingSdp;
    private int _disposeState;

    public CodexVoiceCoordinator(
        bool featureEnabled,
        Func<CancellationToken, Task<CodexAppServerClient>>? clientFactory = null,
        int transcriptEntryLimit = DefaultTranscriptEntryLimit,
        int transcriptCharacterLimit = DefaultTranscriptCharacterLimit,
        IReadOnlyList<TimeSpan>? restartDelays = null,
        string? workspaceDirectory = null)
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
        _restartDelays = restartDelays ?? DefaultRestartDelays;
        _workspaceDirectory = Path.GetFullPath(
            workspaceDirectory
                ?? Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    "HoverPocket",
                    "VoiceWorkspace"));
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
                await StartClientAndValidateAsync(cancellationToken);
                UpdateState(
                    availability: CodexVoiceAvailability.Ready,
                    sessionStatus: CodexVoiceSessionStatus.Idle,
                    lastErrorCode: null);
            }
            catch (CodexVoiceSignedOutException)
            {
                UpdateState(
                    availability: CodexVoiceAvailability.SignedOut,
                    sessionStatus: CodexVoiceSessionStatus.BlockedFailure,
                    lastErrorCode: "signed_out");
            }
            catch (CodexVoiceCompatibilityException exception)
            {
                UpdateState(
                    availability: CodexVoiceAvailability.Incompatible,
                    sessionStatus: CodexVoiceSessionStatus.BlockedFailure,
                    lastErrorCode: exception.ErrorCode);
            }
            catch (FileNotFoundException)
            {
                UpdateState(
                    availability: CodexVoiceAvailability.Unavailable,
                    sessionStatus: CodexVoiceSessionStatus.BlockedFailure,
                    lastErrorCode: "codex_not_found");
            }
            catch (CodexAppServerRpcException exception)
            {
                UpdateState(
                    availability: CodexVoiceAvailability.Incompatible,
                    sessionStatus: CodexVoiceSessionStatus.BlockedFailure,
                    lastErrorCode: $"rpc_{exception.Code}");
            }
            catch (Exception exception) when (exception is IOException
                or InvalidOperationException
                or TimeoutException
                or System.ComponentModel.Win32Exception)
            {
                UpdateState(
                    availability: CodexVoiceAvailability.Faulted,
                    sessionStatus: CodexVoiceSessionStatus.RecoverableFailure,
                    lastErrorCode: exception.GetType().Name);
            }
        }
        finally
        {
            _lifecycleGate.Release();
        }
    }

    private async Task StartClientAndValidateAsync(CancellationToken cancellationToken)
    {
        var client = await _clientFactory(cancellationToken);
        try
        {
            client.NotificationReceived += OnAppServerNotification;
            client.TransportEnded += OnAppServerTransportEnded;
            client.ServerRequestHandler = HandleServerRequestAsync;

            var account = await client.SendRequestAsync(
                "account/read",
                cancellationToken: cancellationToken);
            if (RequiresOpenAiLogin(account) && !HasAccount(account))
            {
                throw new CodexVoiceSignedOutException();
            }

            var voices = await client.SendRequestAsync(
                "thread/realtime/listVoices",
                cancellationToken: cancellationToken);
            var voiceCount = CountVoices(voices);
            var defaultVoice = ReadDefaultVoice(voices);
            if (voiceCount < 1 || string.IsNullOrWhiteSpace(defaultVoice))
            {
                throw new CodexVoiceCompatibilityException("realtime_voices_unavailable");
            }

            _client = client;
            lock (_stateSync)
            {
                _appServerProcessId = client.ProcessId;
                _voiceCount = voiceCount;
                _defaultVoice = defaultVoice;
            }
        }
        catch
        {
            client.NotificationReceived -= OnAppServerNotification;
            client.TransportEnded -= OnAppServerTransportEnded;
            client.ServerRequestHandler = null;
            await client.DisposeAsync();
            throw;
        }
    }

    public void MarkSessionRequestingPermission()
    {
        SetSessionStatus(CodexVoiceSessionStatus.RequestingPermission);
    }

    public void MarkSessionNegotiating(string? rootThreadId = null)
    {
        ThrowIfDisposed();
        lock (_stateSync)
        {
            if (!string.IsNullOrWhiteSpace(rootThreadId))
            {
                _rootThreadId = rootThreadId;
            }

            _sessionStatus = CodexVoiceSessionStatus.Negotiating;
            _lastErrorCode = null;
        }

        PublishSnapshot();
    }

    public void MarkSessionStopping()
    {
        SetSessionStatus(CodexVoiceSessionStatus.Stopping);
    }

    public void MarkSessionFailure(string errorCode)
    {
        ThrowIfDisposed();
        if (errorCode is not ("microphone_denied" or "webrtc_failed"))
        {
            errorCode = "voice_start_failed";
        }

        lock (_stateSync)
        {
            _transportAttached = false;
            _isMuted = true;
            _sessionStatus = CodexVoiceSessionStatus.RecoverableFailure;
            _lastErrorCode = errorCode;
        }

        PublishSnapshot();
    }

    private void SetSessionStatus(CodexVoiceSessionStatus status)
    {
        ThrowIfDisposed();
        lock (_stateSync)
        {
            _sessionStatus = status;
            _lastErrorCode = null;
        }

        PublishSnapshot();
    }

    public async Task<CodexVoiceWebRtcAnswer> StartWebRtcAsync(
        string sdpOffer,
        CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        if (string.IsNullOrWhiteSpace(sdpOffer)
            || sdpOffer.Length > 131_072
            || !sdpOffer.StartsWith("v=0", StringComparison.Ordinal))
        {
            throw new CodexVoiceCompatibilityException("webrtc_offer_invalid");
        }

        await _sessionGate.WaitAsync(cancellationToken);
        try
        {
            var client = _client;
            string? voice;
            lock (_stateSync)
            {
                if (_availability != CodexVoiceAvailability.Ready || client is null)
                {
                    throw new InvalidOperationException("Codex Voice is not ready.");
                }

                voice = _defaultVoice;
            }

            if (string.IsNullOrWhiteSpace(voice))
            {
                throw new CodexVoiceCompatibilityException("realtime_voice_missing");
            }

            var rootThreadId = await EnsureRootThreadAsync(client, cancellationToken);
            MarkSessionNegotiating(rootThreadId);
            var sdpCompletion = new TaskCompletionSource<string>(
                TaskCreationOptions.RunContinuationsAsynchronously);
            lock (_stateSync)
            {
                _pendingSdpThreadId = rootThreadId;
                _pendingSdp = sdpCompletion;
            }

            try
            {
                _ = await client.SendRequestAsync(
                    "thread/realtime/start",
                    new
                    {
                        threadId = rootThreadId,
                        outputModality = "audio",
                        version = "v1",
                        voice,
                        prompt = "Respond concisely for a compact desktop voice interface. Use only HoverPocket capabilities when they are available.",
                        transport = new
                        {
                            type = "webrtc",
                            sdp = sdpOffer
                        }
                    },
                    cancellationToken);

                var answer = await sdpCompletion.Task.WaitAsync(
                    TimeSpan.FromSeconds(20),
                    cancellationToken);
                return new CodexVoiceWebRtcAnswer(rootThreadId, answer);
            }
            catch
            {
                UpdateState(
                    CodexVoiceAvailability.Ready,
                    CodexVoiceSessionStatus.RecoverableFailure,
                    "webrtc_negotiation_failed");
                throw;
            }
            finally
            {
                lock (_stateSync)
                {
                    if (ReferenceEquals(_pendingSdp, sdpCompletion))
                    {
                        _pendingSdp = null;
                        _pendingSdpThreadId = null;
                    }
                }
            }
        }
        finally
        {
            _sessionGate.Release();
        }
    }

    public void MarkTransportAttached()
    {
        AttachTransport();
        SetMuted(false);
    }

    public async Task StopRealtimeAsync(CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        await _sessionGate.WaitAsync(cancellationToken);
        try
        {
            var client = _client;
            string? rootThreadId;
            lock (_stateSync)
            {
                rootThreadId = _rootThreadId;
            }

            if (client is null || string.IsNullOrWhiteSpace(rootThreadId))
            {
                DetachTransport(reconnectExpected: false);
                return;
            }

            MarkSessionStopping();
            _ = await client.SendRequestAsync(
                "thread/realtime/stop",
                new { threadId = rootThreadId },
                cancellationToken);
            DetachTransport(reconnectExpected: false);
        }
        finally
        {
            _sessionGate.Release();
        }
    }

    private async Task<string> EnsureRootThreadAsync(
        CodexAppServerClient client,
        CancellationToken cancellationToken)
    {
        lock (_stateSync)
        {
            var existingThreadId = _rootThreadId;
            if (!string.IsNullOrWhiteSpace(existingThreadId))
            {
                return existingThreadId;
            }
        }

        Directory.CreateDirectory(_workspaceDirectory);
        var response = await client.SendRequestAsync(
            "thread/start",
            new
            {
                cwd = _workspaceDirectory,
                sandbox = "read-only",
                approvalPolicy = "never",
                approvalsReviewer = "user",
                ephemeral = false,
                runtimeWorkspaceRoots = Array.Empty<string>(),
                selectedCapabilityRoots = Array.Empty<object>(),
                dynamicTools = Array.Empty<object>(),
                threadSource = "hoverpocket_voice",
                sessionStartSource = "startup",
                baseInstructions = "You are the HoverPocket Voice Lane. Do not use shell, filesystem, network, or arbitrary code tools. Only invoke explicitly provided HoverPocket capabilities. Keep spoken replies concise."
            },
            cancellationToken);
        var threadId = ReadNestedString(response, "thread", "id")
            ?? throw new CodexVoiceCompatibilityException("thread_start_response_invalid");
        lock (_stateSync)
        {
            _rootThreadId = threadId;
        }

        PublishSnapshot();
        return threadId;
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
                or CodexVoiceSessionStatus.Connecting
                or CodexVoiceSessionStatus.Negotiating
                or CodexVoiceSessionStatus.RequestingPermission)
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

    internal async Task TriggerTransportExitForVerifyAsync(
        CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        var client = _client
            ?? throw new InvalidOperationException("Codex app-server is not connected.");
        _ = await client.SendRequestAsync(
            "fake/exit",
            cancellationToken: cancellationToken);
    }

    private void OnAppServerNotification(
        object? sender,
        CodexAppServerNotificationEventArgs eventArgs)
    {
        _ = sender;
        ProcessNotification(eventArgs.Method, eventArgs.Params);
    }

    private void OnAppServerTransportEnded(
        object? sender,
        CodexAppServerTransportEndedEventArgs eventArgs)
    {
        if (Volatile.Read(ref _disposeState) != 0
            || sender is not CodexAppServerClient failedClient
            || !ReferenceEquals(failedClient, _client))
        {
            return;
        }

        lock (_stateSync)
        {
            _availability = CodexVoiceAvailability.Faulted;
            _sessionStatus = CodexVoiceSessionStatus.RecoverableFailure;
            _transportAttached = false;
            _isMuted = true;
            _appServerProcessId = null;
            _lastErrorCode = $"transport_{eventArgs.ErrorCode}";
            if (_restartTask is { IsCompleted: false })
            {
                return;
            }

            _restartTask = Task.Run(
                () => RestartAfterTransportEndedAsync(
                    failedClient,
                    _lifetimeCancellation.Token));
        }

        PublishSnapshot();
    }

    private async Task RestartAfterTransportEndedAsync(
        CodexAppServerClient failedClient,
        CancellationToken cancellationToken)
    {
        try
        {
            await _lifecycleGate.WaitAsync(cancellationToken);
            try
            {
                if (!ReferenceEquals(_client, failedClient))
                {
                    return;
                }

                _client = null;
                failedClient.NotificationReceived -= OnAppServerNotification;
                failedClient.TransportEnded -= OnAppServerTransportEnded;
                failedClient.ServerRequestHandler = null;
                await failedClient.DisposeAsync();

                for (var index = 0; index < _restartDelays.Count; index++)
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    var attempt = index + 1;
                    lock (_stateSync)
                    {
                        _restartAttempt = attempt;
                        _availability = CodexVoiceAvailability.Starting;
                        _sessionStatus = CodexVoiceSessionStatus.Reconnecting;
                        _lastErrorCode = null;
                    }
                    PublishSnapshot();

                    var delay = _restartDelays[index];
                    if (delay > TimeSpan.Zero)
                    {
                        await Task.Delay(delay, cancellationToken);
                    }

                    try
                    {
                        await StartClientAndValidateAsync(cancellationToken);
                        lock (_stateSync)
                        {
                            _availability = CodexVoiceAvailability.Ready;
                            _sessionStatus = string.IsNullOrWhiteSpace(_rootThreadId)
                                ? CodexVoiceSessionStatus.Idle
                                : CodexVoiceSessionStatus.Reconnecting;
                            _lastErrorCode = null;
                        }
                        PublishSnapshot();
                        return;
                    }
                    catch (CodexVoiceSignedOutException)
                    {
                        UpdateState(
                            CodexVoiceAvailability.SignedOut,
                            CodexVoiceSessionStatus.BlockedFailure,
                            "signed_out");
                        return;
                    }
                    catch (CodexVoiceCompatibilityException exception)
                    {
                        UpdateState(
                            CodexVoiceAvailability.Incompatible,
                            CodexVoiceSessionStatus.BlockedFailure,
                            exception.ErrorCode);
                        return;
                    }
                    catch (CodexAppServerRpcException exception)
                    {
                        UpdateState(
                            CodexVoiceAvailability.Incompatible,
                            CodexVoiceSessionStatus.BlockedFailure,
                            $"rpc_{exception.Code}");
                        return;
                    }
                    catch (FileNotFoundException)
                    {
                        UpdateState(
                            CodexVoiceAvailability.Unavailable,
                            CodexVoiceSessionStatus.BlockedFailure,
                            "codex_not_found");
                        return;
                    }
                    catch (Exception exception) when (exception is IOException
                        or InvalidOperationException
                        or TimeoutException
                        or System.ComponentModel.Win32Exception)
                    {
                        lock (_stateSync)
                        {
                            _availability = CodexVoiceAvailability.Faulted;
                            _sessionStatus = CodexVoiceSessionStatus.RecoverableFailure;
                            _lastErrorCode = exception.GetType().Name;
                        }
                        PublishSnapshot();
                    }
                }

                UpdateState(
                    CodexVoiceAvailability.Blocked,
                    CodexVoiceSessionStatus.BlockedFailure,
                    "restart_exhausted");
            }
            finally
            {
                _lifecycleGate.Release();
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
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
                    _sessionStatus = _transportAttached
                        ? (_isMuted
                            ? CodexVoiceSessionStatus.Muted
                            : CodexVoiceSessionStatus.Connected)
                        : CodexVoiceSessionStatus.Connecting;
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
                    changed = _transcript.CompleteWithText(
                        ReadString(parameters, "threadId") ?? _rootThreadId ?? string.Empty,
                        ReadString(parameters, "role") ?? "unknown",
                        ReadString(parameters, "text"),
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
                case "thread/realtime/sdp":
                {
                    var sdpThreadId = ReadString(parameters, "threadId");
                    var sdp = ReadString(parameters, "sdp");
                    if (_pendingSdp is { } pendingSdp
                        && string.Equals(
                            sdpThreadId,
                            _pendingSdpThreadId,
                            StringComparison.Ordinal)
                        && !string.IsNullOrWhiteSpace(sdp)
                        && sdp.Length <= 131_072
                        && sdp.StartsWith("v=0", StringComparison.Ordinal))
                    {
                        pendingSdp.TrySetResult(sdp);
                        _sessionStatus = CodexVoiceSessionStatus.Connecting;
                        _lastErrorCode = null;
                        changed = true;
                    }
                    break;
                }
                case "thread/realtime/error":
                    _sessionStatus = CodexVoiceSessionStatus.RecoverableFailure;
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
            _appServerProcessId,
            _restartAttempt,
            _voiceCount);
    }

    private static bool RequiresOpenAiLogin(JsonElement account)
    {
        if (account.ValueKind != JsonValueKind.Object
            || !account.TryGetProperty("requiresOpenaiAuth", out var requires)
            || requires.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
        {
            throw new CodexVoiceCompatibilityException("account_response_invalid");
        }

        return requires.GetBoolean();
    }

    private static bool HasAccount(JsonElement account)
    {
        return account.ValueKind == JsonValueKind.Object
            && account.TryGetProperty("account", out var accountValue)
            && accountValue.ValueKind == JsonValueKind.Object;
    }

    private static int CountVoices(JsonElement response)
    {
        if (response.ValueKind != JsonValueKind.Object
            || !response.TryGetProperty("voices", out var voices)
            || voices.ValueKind != JsonValueKind.Object)
        {
            return 0;
        }

        var unique = new HashSet<string>(StringComparer.Ordinal);
        foreach (var property in voices.EnumerateObject())
        {
            if (property.Value.ValueKind != JsonValueKind.Array)
            {
                continue;
            }

            foreach (var item in property.Value.EnumerateArray())
            {
                if (item.ValueKind == JsonValueKind.String
                    && item.GetString() is { Length: > 0 } value)
                {
                    unique.Add(value);
                }
            }
        }

        return unique.Count;
    }

    private static string? ReadDefaultVoice(JsonElement response)
    {
        if (response.ValueKind != JsonValueKind.Object
            || !response.TryGetProperty("voices", out var voices)
            || voices.ValueKind != JsonValueKind.Object)
        {
            return null;
        }

        foreach (var propertyName in new[] { "defaultV1", "defaultV2" })
        {
            if (voices.TryGetProperty(propertyName, out var value)
                && value.ValueKind == JsonValueKind.String
                && value.GetString() is { Length: > 0 } voice)
            {
                return voice;
            }
        }

        return null;
    }

    private static string? ReadNestedString(
        JsonElement root,
        string objectPropertyName,
        string stringPropertyName)
    {
        if (root.ValueKind != JsonValueKind.Object
            || !root.TryGetProperty(objectPropertyName, out var nested)
            || nested.ValueKind != JsonValueKind.Object
            || !nested.TryGetProperty(stringPropertyName, out var value)
            || value.ValueKind != JsonValueKind.String)
        {
            return null;
        }

        return value.GetString();
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

        _lifetimeCancellation.Cancel();
        lock (_stateSync)
        {
            _pendingSdp?.TrySetCanceled();
            _pendingSdp = null;
            _pendingSdpThreadId = null;
        }
        if (_restartTask is { } restartTask)
        {
            try
            {
                await restartTask;
            }
            catch (OperationCanceledException)
            {
            }
        }

        await _sessionGate.WaitAsync();
        await _lifecycleGate.WaitAsync();
        try
        {
            var client = _client;
            _client = null;
            if (client is not null)
            {
                client.NotificationReceived -= OnAppServerNotification;
                client.TransportEnded -= OnAppServerTransportEnded;
                client.ServerRequestHandler = null;
                await client.DisposeAsync();
            }

            lock (_stateSync)
            {
                _appServerProcessId = null;
                _transportAttached = false;
                _isMuted = true;
                _sessionStatus = CodexVoiceSessionStatus.Closed;
                _voiceCount = 0;
                _defaultVoice = null;
            }
        }
        finally
        {
            _lifecycleGate.Release();
            _lifecycleGate.Dispose();
            _sessionGate.Release();
            _sessionGate.Dispose();
            _lifetimeCancellation.Dispose();
        }
    }
}

internal sealed class CodexVoiceSignedOutException : Exception
{
}

internal sealed class CodexVoiceCompatibilityException(string errorCode) : Exception(errorCode)
{
    public string ErrorCode { get; } = errorCode;
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

    public bool CompleteWithText(
        string threadId,
        string role,
        string? finalText,
        DateTimeOffset updatedAt)
    {
        for (var index = _entries.Count - 1; index >= 0; index--)
        {
            var entry = _entries[index];
            if (!entry.IsComplete
                && entry.ThreadId == threadId
                && entry.Role == role)
            {
                var text = string.IsNullOrEmpty(finalText) ? entry.Text : finalText;
                _characterCount += text.Length - entry.Text.Length;
                _entries[index] = entry with
                {
                    Text = text,
                    IsComplete = true,
                    UpdatedAt = updatedAt
                };
                Trim();
                return true;
            }
        }

        if (string.IsNullOrEmpty(finalText))
        {
            return false;
        }

        _entries.Add(new CodexVoiceTranscriptEntry(
            threadId,
            role,
            finalText,
            true,
            updatedAt));
        _characterCount += finalText.Length;
        Trim();
        return true;
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
