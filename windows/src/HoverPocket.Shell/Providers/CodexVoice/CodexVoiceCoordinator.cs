using System.Text;
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

internal enum CodexVoiceThreadState
{
    Running,
    Completed,
    Failed
}

internal sealed record CodexVoiceThreadSummary(
    string ThreadId,
    bool IsCurrentRoot,
    string Title,
    string Detail,
    CodexVoiceThreadState State,
    DateTimeOffset CreatedAt,
    DateTimeOffset UpdatedAt);

internal sealed record CodexVoiceSnapshot(
    bool FeatureEnabled,
    CodexVoiceAvailability Availability,
    CodexVoiceSessionStatus SessionStatus,
    string? RootThreadId,
    bool TransportAttached,
    bool IsMuted,
    IReadOnlyList<CodexVoiceTranscriptEntry> Transcript,
    IReadOnlyList<CodexVoiceThreadSummary> Sessions,
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
    private const int ThreadListPageLimit = 64;
    private const int MaximumThreadListPages = 8;
    private const int MaximumThreadListRecords = ThreadListPageLimit * MaximumThreadListPages;
    private static readonly IReadOnlyList<TimeSpan> DefaultRestartDelays =
    [
        TimeSpan.Zero,
        TimeSpan.FromMilliseconds(450),
        TimeSpan.FromMilliseconds(1400)
    ];

    private sealed record ListedThread(
        string ThreadId,
        string SessionId,
        string ParentThreadId,
        string Title,
        string Preview,
        string Status,
        DateTimeOffset CreatedAt,
        DateTimeOffset UpdatedAt);

    private sealed record ThreadReadCacheKey(
        string ThreadId,
        string SessionId,
        string ParentThreadId,
        DateTimeOffset UpdatedAt);

    private sealed record ThreadReadCacheValue(string? Message);

    private sealed record ThreadReadResult(
        ThreadReadCacheKey Key,
        bool IdentityValidated,
        string? Message);

    private readonly bool _featureEnabled;
    private readonly Func<CancellationToken, Task<CodexAppServerClient>> _clientFactory;
    private readonly SemaphoreSlim _lifecycleGate = new(1, 1);
    private readonly SemaphoreSlim _sessionGate = new(1, 1);
    private readonly object _stateSync = new();
    private readonly CodexVoiceTranscriptBuffer _transcript;
    private readonly IReadOnlyList<TimeSpan> _restartDelays;
    private readonly CancellationTokenSource _lifetimeCancellation = new();
    private readonly string _workspaceDirectory;
    private readonly ICodexVoiceCapabilityToolAdapter? _toolAdapter;
    private CodexAppServerClient? _client;
    private Task? _restartTask;
    private CodexVoiceAvailability _availability;
    private CodexVoiceSessionStatus _sessionStatus = CodexVoiceSessionStatus.Idle;
    private string? _rootThreadId;
    private string? _rootSessionId;
    private DateTimeOffset? _rootCreatedAt;
    private IReadOnlyList<CodexVoiceThreadSummary> _childSessions =
        Array.Empty<CodexVoiceThreadSummary>();
    private readonly Dictionary<ThreadReadCacheKey, ThreadReadCacheValue> _threadReadCache = [];
    private CancellationTokenSource? _sessionRefreshCancellation;
    private Task? _sessionRefreshTask;
    private bool _transportAttached;
    private bool _isMuted = true;
    private string? _lastErrorCode;
    private int? _appServerProcessId;
    private int _restartAttempt;
    private int _voiceCount;
    private string? _defaultVoice;
    private string? _pendingSdpThreadId;
    private TaskCompletionSource<string>? _pendingSdp;
    private long _nextClientGeneration;
    private long _clientGeneration;
    private long _rootThreadGeneration;
    private int _disposeState;

    public CodexVoiceCoordinator(
        bool featureEnabled,
        Func<CancellationToken, Task<CodexAppServerClient>>? clientFactory = null,
        int transcriptEntryLimit = DefaultTranscriptEntryLimit,
        int transcriptCharacterLimit = DefaultTranscriptCharacterLimit,
        IReadOnlyList<TimeSpan>? restartDelays = null,
        string? workspaceDirectory = null,
        ICodexVoiceCapabilityToolAdapter? toolAdapter = null)
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
        _toolAdapter = toolAdapter;
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
        var generation = Interlocked.Increment(ref _nextClientGeneration);
        try
        {
            client.NotificationReceived += OnAppServerNotification;
            client.TransportEnded += OnAppServerTransportEnded;
            client.ServerRequestHandler = (request, token) =>
                HandleServerRequestAsync(client, generation, request, token);

            var account = await client.SendRequestAsync(
                "account/read",
                new { refreshToken = false },
                cancellationToken: cancellationToken);
            if (RequiresOpenAiLogin(account) && !HasAccount(account))
            {
                throw new CodexVoiceSignedOutException();
            }

            var voices = await client.SendRequestAsync(
                "thread/realtime/listVoices",
                new { },
                cancellationToken: cancellationToken);
            var voiceCount = CountVoices(voices);
            var defaultVoice = ReadDefaultVoice(voices);
            if (voiceCount < 1 || string.IsNullOrWhiteSpace(defaultVoice))
            {
                throw new CodexVoiceCompatibilityException("realtime_voices_unavailable");
            }

            lock (_stateSync)
            {
                _client = client;
                _clientGeneration = generation;
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
            if (!string.IsNullOrWhiteSpace(rootThreadId)
                && !string.Equals(rootThreadId, _rootThreadId, StringComparison.Ordinal))
            {
                throw new InvalidOperationException("Realtime negotiation cannot replace the root thread.");
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
            long clientGeneration;
            string? voice;
            lock (_stateSync)
            {
                if (_availability != CodexVoiceAvailability.Ready || client is null)
                {
                    throw new InvalidOperationException("Codex Voice is not ready.");
                }

                voice = _defaultVoice;
                clientGeneration = _clientGeneration;
            }

            if (string.IsNullOrWhiteSpace(voice))
            {
                throw new CodexVoiceCompatibilityException("realtime_voice_missing");
            }

            var rootThreadId = await EnsureRootThreadAsync(
                client,
                clientGeneration,
                cancellationToken);
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
                var invalidatedAttempt = false;
                lock (_stateSync)
                {
                    if (Volatile.Read(ref _disposeState) == 0
                        && ReferenceEquals(_client, client)
                        && _clientGeneration == clientGeneration
                        && _rootThreadGeneration == clientGeneration
                        && string.Equals(_rootThreadId, rootThreadId, StringComparison.Ordinal))
                    {
                        ClearRootThreadStateLocked();
                        _availability = CodexVoiceAvailability.Ready;
                        _sessionStatus = CodexVoiceSessionStatus.RecoverableFailure;
                        _lastErrorCode = "webrtc_negotiation_failed";
                        invalidatedAttempt = true;
                    }
                }
                if (invalidatedAttempt)
                {
                    PublishSnapshot();
                }
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
        long clientGeneration,
        CancellationToken cancellationToken)
    {
        lock (_stateSync)
        {
            if (!ReferenceEquals(_client, client)
                || _clientGeneration != clientGeneration
                || _availability != CodexVoiceAvailability.Ready)
            {
                throw new InvalidOperationException("Codex Voice client generation is no longer current.");
            }

            var existingThreadId = _rootThreadId;
            if (!string.IsNullOrWhiteSpace(existingThreadId)
                && _rootThreadGeneration == clientGeneration)
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
                dynamicTools = _toolAdapter?.DynamicTools ?? Array.Empty<object>(),
                threadSource = "hoverpocket_voice",
                sessionStartSource = "startup",
                baseInstructions = "You are the HoverPocket Voice Lane. Do not use shell, filesystem, network, or arbitrary code tools. Only invoke explicitly provided HoverPocket capabilities. Keep spoken replies concise."
            },
            cancellationToken);
        if (!TryReadStartedThread(
                response,
                out var threadId,
                out var sessionId,
                out var createdAt))
        {
            throw new CodexVoiceCompatibilityException("thread_start_response_invalid");
        }
        lock (_stateSync)
        {
            if (!ReferenceEquals(_client, client)
                || _clientGeneration != clientGeneration
                || _availability != CodexVoiceAvailability.Ready)
            {
                throw new InvalidOperationException("Codex Voice client generation changed during thread start.");
            }

            _rootThreadId = threadId;
            _rootSessionId = sessionId;
            _rootCreatedAt = createdAt;
            _rootThreadGeneration = clientGeneration;
            _childSessions = Array.Empty<CodexVoiceThreadSummary>();
            _threadReadCache.Clear();
        }

        StartSessionRefreshLoop(client, clientGeneration, threadId, sessionId);

        PublishSnapshot();
        return threadId;
    }

    private void StartSessionRefreshLoop(
        CodexAppServerClient client,
        long generation,
        string rootThreadId,
        string rootSessionId)
    {
        CancellationTokenSource cancellation;
        lock (_stateSync)
        {
            _sessionRefreshCancellation?.Cancel();
            cancellation = CancellationTokenSource.CreateLinkedTokenSource(
                _lifetimeCancellation.Token);
            _sessionRefreshCancellation = cancellation;
            _sessionRefreshTask = Task.Run(
                () => RunSessionRefreshLoopAsync(
                    client,
                    generation,
                    rootThreadId,
                    rootSessionId,
                    cancellation.Token),
                cancellation.Token);
        }
    }

    private async Task RunSessionRefreshLoopAsync(
        CodexAppServerClient client,
        long generation,
        string rootThreadId,
        string rootSessionId,
        CancellationToken cancellationToken)
    {
        try
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                await RefreshChildSessionsAsync(
                    client,
                    generation,
                    rootThreadId,
                    rootSessionId,
                    cancellationToken);
                await Task.Delay(TimeSpan.FromSeconds(1), cancellationToken);
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
    }

    private async Task RefreshChildSessionsAsync(
        CodexAppServerClient client,
        long generation,
        string rootThreadId,
        string rootSessionId,
        CancellationToken cancellationToken)
    {
        Dictionary<ThreadReadCacheKey, ThreadReadCacheValue> previousReadCache;
        lock (_stateSync)
        {
            if (!IsSessionScopeCurrentLocked(
                    client,
                    generation,
                    rootThreadId,
                    rootSessionId))
            {
                return;
            }

            previousReadCache = new Dictionary<ThreadReadCacheKey, ThreadReadCacheValue>(
                _threadReadCache);
        }

        var listed = await FetchListedThreadsAsync(
            client,
            generation,
            rootThreadId,
            rootSessionId,
            cancellationToken);
        if (listed is null)
        {
            return;
        }
        var duplicateIds = listed
            .GroupBy(thread => thread.ThreadId, StringComparer.Ordinal)
            .Where(group => group.Count() > 1)
            .Select(group => group.Key)
            .ToHashSet(StringComparer.Ordinal);
        var acceptedIds = new HashSet<string>(StringComparer.Ordinal)
        {
            rootThreadId
        };
        var accepted = new List<ListedThread>();
        var remaining = listed
            .Where(thread => !string.Equals(
                    thread.ThreadId,
                    rootThreadId,
                    StringComparison.Ordinal)
                && string.Equals(
                    thread.SessionId,
                    rootSessionId,
                    StringComparison.Ordinal)
                && !duplicateIds.Contains(thread.ThreadId))
            .ToList();
        while (remaining.Count > 0)
        {
            var madeProgress = false;
            for (var index = remaining.Count - 1; index >= 0; index--)
            {
                var thread = remaining[index];
                if (!acceptedIds.Contains(thread.ParentThreadId))
                {
                    continue;
                }

                if (acceptedIds.Contains(thread.ThreadId))
                {
                    remaining.RemoveAt(index);
                    madeProgress = true;
                    continue;
                }

                acceptedIds.Add(thread.ThreadId);
                accepted.Add(thread);
                remaining.RemoveAt(index);
                madeProgress = true;
            }

            if (!madeProgress)
            {
                break;
            }
        }

        var visible = accepted
            .OrderByDescending(thread => thread.UpdatedAt)
            .ThenBy(thread => thread.ThreadId, StringComparer.Ordinal)
            .Take(16)
            .ToArray();
        var recentMessages = new Dictionary<string, string>(StringComparer.Ordinal);
        var nextReadCache = new Dictionary<ThreadReadCacheKey, ThreadReadCacheValue>();
        foreach (var thread in visible)
        {
            var key = ThreadReadCacheKeyFor(thread);
            if (previousReadCache.GetValueOrDefault(key) is { } cached)
            {
                nextReadCache[key] = cached;
                if (!string.IsNullOrWhiteSpace(cached.Message))
                {
                    recentMessages[thread.ThreadId] = cached.Message;
                }
            }
        }
        var readTasks = visible
            .Where(thread => !nextReadCache.ContainsKey(ThreadReadCacheKeyFor(thread)))
            .Select(async thread =>
        {
            var key = ThreadReadCacheKeyFor(thread);
            try
            {
                var read = await client.SendRequestAsync(
                    "thread/read",
                    new
                    {
                        threadId = thread.ThreadId,
                        includeTurns = true
                    },
                    cancellationToken);
                var identityValidated = TryLatestMessage(
                    read,
                    thread.ThreadId,
                    thread.SessionId,
                    thread.ParentThreadId,
                    out var message);
                return new ThreadReadResult(key, identityValidated, message);
            }
            catch (Exception exception) when (exception is CodexAppServerRpcException
                or IOException
                or InvalidOperationException
                or TimeoutException)
            {
                return new ThreadReadResult(key, IdentityValidated: false, Message: null);
            }
        });
        var readResults = await Task.WhenAll(readTasks);
        foreach (var result in readResults)
        {
            if (!result.IdentityValidated)
            {
                continue;
            }

            nextReadCache[result.Key] = new ThreadReadCacheValue(result.Message);
            if (!string.IsNullOrWhiteSpace(result.Message))
            {
                recentMessages[result.Key.ThreadId] = result.Message;
            }
        }
        var summaries = visible.Select(thread => new CodexVoiceThreadSummary(
                thread.ThreadId,
                IsCurrentRoot: false,
                thread.Title,
                recentMessages.GetValueOrDefault(thread.ThreadId) ?? thread.Preview,
                thread.Status switch
                {
                    "active" => CodexVoiceThreadState.Running,
                    "systemError" => CodexVoiceThreadState.Failed,
                    _ => CodexVoiceThreadState.Completed
                },
                thread.CreatedAt,
                thread.UpdatedAt))
            .ToArray();
        lock (_stateSync)
        {
            if (!IsSessionScopeCurrentLocked(
                    client,
                    generation,
                    rootThreadId,
                    rootSessionId))
            {
                return;
            }

            _childSessions = summaries;
            _threadReadCache.Clear();
            foreach (var entry in nextReadCache)
            {
                _threadReadCache[entry.Key] = entry.Value;
            }
        }

        PublishSnapshot();
    }

    private async Task<IReadOnlyList<ListedThread>?> FetchListedThreadsAsync(
        CodexAppServerClient client,
        long generation,
        string rootThreadId,
        string rootSessionId,
        CancellationToken cancellationToken)
    {
        string? cursor = null;
        var seenCursors = new HashSet<string>(StringComparer.Ordinal);
        var listed = new List<ListedThread>();
        for (var pageIndex = 0; pageIndex < MaximumThreadListPages; pageIndex++)
        {
            lock (_stateSync)
            {
                if (!IsSessionScopeCurrentLocked(
                        client,
                        generation,
                        rootThreadId,
                        rootSessionId))
                {
                    return null;
                }
            }

            var request = new Dictionary<string, object?>
            {
                ["ancestorThreadId"] = rootThreadId,
                ["archived"] = false,
                ["limit"] = ThreadListPageLimit,
                ["sourceKinds"] = new[]
                {
                    "appServer",
                    "subAgent",
                    "subAgentReview",
                    "subAgentCompact",
                    "subAgentThreadSpawn",
                    "subAgentOther"
                },
                ["sortDirection"] = "asc",
                ["sortKey"] = "created_at",
                ["useStateDbOnly"] = true
            };
            if (cursor is not null)
            {
                request["cursor"] = cursor;
            }

            JsonElement response;
            try
            {
                response = await client.SendRequestAsync(
                    "thread/list",
                    request,
                    cancellationToken);
            }
            catch (Exception exception) when (exception is CodexAppServerRpcException
                or IOException
                or InvalidOperationException
                or TimeoutException)
            {
                return null;
            }

            if (!TryParseThreadListPage(response, out var page, out var nextCursor))
            {
                return null;
            }
            listed.AddRange(page);
            if (listed.Count > MaximumThreadListRecords)
            {
                return null;
            }
            if (nextCursor is null)
            {
                return listed;
            }
            if (pageIndex >= MaximumThreadListPages - 1
                || !seenCursors.Add(nextCursor))
            {
                return null;
            }
            cursor = nextCursor;
        }

        return null;
    }

    private bool IsSessionScopeCurrentLocked(
        CodexAppServerClient client,
        long generation,
        string rootThreadId,
        string rootSessionId)
    {
        return Volatile.Read(ref _disposeState) == 0
            && ReferenceEquals(_client, client)
            && _clientGeneration == generation
            && _rootThreadGeneration == generation
            && string.Equals(_rootThreadId, rootThreadId, StringComparison.Ordinal)
            && string.Equals(_rootSessionId, rootSessionId, StringComparison.Ordinal);
    }

    private void ClearRootThreadStateLocked()
    {
        _sessionRefreshCancellation?.Cancel();
        _sessionRefreshCancellation = null;
        _sessionRefreshTask = null;
        _rootThreadId = null;
        _rootSessionId = null;
        _rootCreatedAt = null;
        _rootThreadGeneration = 0;
        _childSessions = Array.Empty<CodexVoiceThreadSummary>();
        _threadReadCache.Clear();
    }

    private static bool TryParseThreadListPage(
        JsonElement response,
        out IReadOnlyList<ListedThread> threads,
        out string? nextCursor)
    {
        threads = Array.Empty<ListedThread>();
        nextCursor = null;
        if (response.ValueKind != JsonValueKind.Object
            || !response.TryGetProperty("data", out var data)
            || data.ValueKind != JsonValueKind.Array
            || data.GetArrayLength() > ThreadListPageLimit)
        {
            return false;
        }

        var parsed = new List<ListedThread>();
        foreach (var value in data.EnumerateArray())
        {
            if (TryParseListedThread(value, out var thread))
            {
                parsed.Add(thread);
            }
        }

        if (response.TryGetProperty("nextCursor", out var cursorValue)
            && cursorValue.ValueKind != JsonValueKind.Null)
        {
            if (cursorValue.ValueKind != JsonValueKind.String
                || cursorValue.GetString() is not { } candidate
                || !ValidCursor(candidate))
            {
                return false;
            }
            nextCursor = candidate;
        }

        threads = parsed;
        return true;
    }

    private static bool TryParseListedThread(
        JsonElement value,
        out ListedThread thread)
    {
        thread = null!;
        if (value.ValueKind != JsonValueKind.Object
            || !TryReadBoundedIdentifier(value, "id", out var threadId)
            || !TryReadBoundedIdentifier(value, "sessionId", out var sessionId)
            || !TryReadBoundedIdentifier(value, "parentThreadId", out var parentThreadId)
            || !value.TryGetProperty("status", out var statusObject)
            || statusObject.ValueKind != JsonValueKind.Object
            || !statusObject.TryGetProperty("type", out var statusValue)
            || statusValue.ValueKind != JsonValueKind.String
            || statusValue.GetString() is not { } status
            || status is not ("active" or "idle" or "notLoaded" or "systemError")
            || !TryReadUnixTimestamp(value, "createdAt", out var createdAt)
            || !TryReadUnixTimestamp(value, "updatedAt", out var updatedAt)
            || updatedAt < createdAt)
        {
            return false;
        }

        var title = ReadOptionalString(value, "name")
            ?? ReadOptionalString(value, "agentNickname")
            ?? "Codex";
        title = SafeCardText(title, 72);
        thread = new ListedThread(
            threadId,
            sessionId,
            parentThreadId,
            string.IsNullOrEmpty(title) ? "Codex" : title,
            SafeCardText(ReadOptionalString(value, "preview") ?? string.Empty, 160),
            status,
            createdAt,
            updatedAt);
        return true;
    }

    private static bool TryLatestMessage(
        JsonElement response,
        string expectedThreadId,
        string expectedSessionId,
        string expectedParentThreadId,
        out string? message)
    {
        message = null;
        if (response.ValueKind != JsonValueKind.Object
            || !response.TryGetProperty("thread", out var thread)
            || thread.ValueKind != JsonValueKind.Object
            || !string.Equals(
                ReadOptionalString(thread, "id"),
                expectedThreadId,
                StringComparison.Ordinal)
            || !string.Equals(
                ReadOptionalString(thread, "sessionId"),
                expectedSessionId,
                StringComparison.Ordinal)
            || !string.Equals(
                ReadOptionalString(thread, "parentThreadId"),
                expectedParentThreadId,
                StringComparison.Ordinal)
            || !thread.TryGetProperty("turns", out var turns)
            || turns.ValueKind != JsonValueKind.Array)
        {
            return false;
        }

        for (var turnIndex = turns.GetArrayLength() - 1; turnIndex >= 0; turnIndex--)
        {
            var turn = turns[turnIndex];
            if (turn.ValueKind != JsonValueKind.Object
                || !turn.TryGetProperty("items", out var items)
                || items.ValueKind != JsonValueKind.Array)
            {
                continue;
            }

            for (var itemIndex = items.GetArrayLength() - 1; itemIndex >= 0; itemIndex--)
            {
                var item = items[itemIndex];
                var type = ReadOptionalString(item, "type");
                if (string.Equals(type, "agentMessage", StringComparison.Ordinal))
                {
                    var candidate = SafeCardText(
                        ReadOptionalString(item, "text") ?? string.Empty,
                        160);
                    if (!string.IsNullOrEmpty(candidate))
                    {
                        message = candidate;
                        return true;
                    }
                }

                if (!string.Equals(type, "userMessage", StringComparison.Ordinal)
                    || !item.TryGetProperty("content", out var content)
                    || content.ValueKind != JsonValueKind.Array)
                {
                    continue;
                }

                for (var inputIndex = content.GetArrayLength() - 1; inputIndex >= 0; inputIndex--)
                {
                    var input = content[inputIndex];
                    if (!string.Equals(
                            ReadOptionalString(input, "type"),
                            "text",
                            StringComparison.Ordinal))
                    {
                        continue;
                    }

                    var candidate = SafeCardText(
                        ReadOptionalString(input, "text") ?? string.Empty,
                        160);
                    if (!string.IsNullOrEmpty(candidate))
                    {
                        message = candidate;
                        return true;
                    }
                }
            }
        }

        return true;
    }

    private static ThreadReadCacheKey ThreadReadCacheKeyFor(ListedThread thread)
    {
        return new ThreadReadCacheKey(
            thread.ThreadId,
            thread.SessionId,
            thread.ParentThreadId,
            thread.UpdatedAt);
    }

    private static bool ValidCursor(string value)
    {
        if (string.IsNullOrEmpty(value) || Encoding.UTF8.GetByteCount(value) > 512)
        {
            return false;
        }

        foreach (var rune in value.EnumerateRunes())
        {
            var codePoint = rune.Value;
            if (codePoint < 0x20
                || codePoint == 0x7F
                || codePoint is >= 0x202A and <= 0x202E
                || codePoint is >= 0x2066 and <= 0x2069)
            {
                return false;
            }
        }

        return true;
    }

    private static string SafeCardText(string value, int maximumScalars)
    {
        var output = new StringBuilder();
        var scalarCount = 0;
        var previousWasSpace = false;
        foreach (var rune in value.EnumerateRunes())
        {
            if (Rune.IsWhiteSpace(rune))
            {
                if (!previousWasSpace && output.Length > 0)
                {
                    output.Append(' ');
                    previousWasSpace = true;
                }
                continue;
            }

            var codePoint = rune.Value;
            if (codePoint < 0x20
                || codePoint is >= 0x7F and <= 0x9F
                || codePoint is >= 0x202A and <= 0x202E
                || codePoint is >= 0x2066 and <= 0x2069)
            {
                continue;
            }

            output.Append(rune.ToString());
            scalarCount++;
            previousWasSpace = false;
            if (scalarCount >= maximumScalars)
            {
                break;
            }
        }

        return output.ToString().Trim();
    }

    private static bool TryReadStartedThread(
        JsonElement response,
        out string threadId,
        out string sessionId,
        out DateTimeOffset createdAt)
    {
        threadId = string.Empty;
        sessionId = string.Empty;
        createdAt = default;
        return response.ValueKind == JsonValueKind.Object
            && response.TryGetProperty("thread", out var thread)
            && thread.ValueKind == JsonValueKind.Object
            && TryReadBoundedIdentifier(thread, "id", out threadId)
            && TryReadBoundedIdentifier(thread, "sessionId", out sessionId)
            && TryReadUnixTimestamp(thread, "createdAt", out createdAt);
    }

    private static bool TryReadBoundedIdentifier(
        JsonElement value,
        string propertyName,
        out string identifier)
    {
        identifier = string.Empty;
        if (value.ValueKind != JsonValueKind.Object
            || !value.TryGetProperty(propertyName, out var property)
            || property.ValueKind != JsonValueKind.String
            || property.GetString() is not { Length: > 0 } candidate
            || Encoding.UTF8.GetByteCount(candidate) > 128
            || candidate.Any(character => !(char.IsAsciiLetterOrDigit(character)
                || character is '-' or '.' or '_' or ':')))
        {
            return false;
        }

        identifier = candidate;
        return true;
    }

    private static bool TryReadUnixTimestamp(
        JsonElement value,
        string propertyName,
        out DateTimeOffset timestamp)
    {
        timestamp = default;
        if (value.ValueKind != JsonValueKind.Object
            || !value.TryGetProperty(propertyName, out var property)
            || property.ValueKind != JsonValueKind.Number
            || !property.TryGetInt64(out var seconds)
            || seconds <= 0)
        {
            return false;
        }

        try
        {
            timestamp = DateTimeOffset.FromUnixTimeSeconds(seconds);
            return true;
        }
        catch (ArgumentOutOfRangeException)
        {
            return false;
        }
    }

    private static string? ReadOptionalString(JsonElement value, string propertyName)
    {
        return value.ValueKind == JsonValueKind.Object
            && value.TryGetProperty(propertyName, out var property)
            && property.ValueKind == JsonValueKind.String
                ? property.GetString()
                : null;
    }

    public void MarkSessionConnecting(string? rootThreadId = null)
    {
        ThrowIfDisposed();
        lock (_stateSync)
        {
            if (!string.IsNullOrWhiteSpace(rootThreadId)
                && !string.Equals(rootThreadId, _rootThreadId, StringComparison.Ordinal))
            {
                throw new InvalidOperationException("Realtime connection cannot replace the root thread.");
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
        lock (_stateSync)
        {
            if (sender is not CodexAppServerClient source
                || !ReferenceEquals(source, _client)
                || _clientGeneration <= 0)
            {
                return;
            }
        }

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
            ClearRootThreadStateLocked();
            _pendingSdp?.TrySetException(
                new IOException("Codex app-server transport ended during WebRTC negotiation."));
            _pendingSdp = null;
            _pendingSdpThreadId = null;
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

                lock (_stateSync)
                {
                    _client = null;
                    _clientGeneration = 0;
                }
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
                            _sessionStatus = CodexVoiceSessionStatus.Idle;
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
                    if (_rootThreadGeneration != _clientGeneration
                        || !string.Equals(
                            ReadString(parameters, "threadId"),
                            _rootThreadId,
                            StringComparison.Ordinal))
                    {
                        break;
                    }
                    _sessionStatus = _transportAttached
                        ? (_isMuted
                            ? CodexVoiceSessionStatus.Muted
                            : CodexVoiceSessionStatus.Connected)
                        : CodexVoiceSessionStatus.Connecting;
                    _lastErrorCode = null;
                    changed = true;
                    break;
                case "thread/realtime/transcript/delta":
                    if (!IsCurrentRootNotificationLocked(parameters))
                    {
                        break;
                    }
                    changed = _transcript.AppendDelta(
                        _rootThreadId!,
                        ReadString(parameters, "role") ?? "unknown",
                        ReadString(parameters, "delta") ?? string.Empty,
                        DateTimeOffset.UtcNow);
                    break;
                case "thread/realtime/transcript/done":
                    if (!IsCurrentRootNotificationLocked(parameters))
                    {
                        break;
                    }
                    changed = _transcript.CompleteWithText(
                        _rootThreadId!,
                        ReadString(parameters, "role") ?? "unknown",
                        ReadString(parameters, "text"),
                        DateTimeOffset.UtcNow);
                    break;
                case "thread/realtime/closed":
                    if (!IsCurrentRootNotificationLocked(parameters))
                    {
                        break;
                    }
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

    private bool IsCurrentRootNotificationLocked(JsonElement? parameters)
    {
        return _rootThreadGeneration == _clientGeneration
            && _rootThreadGeneration > 0
            && !string.IsNullOrWhiteSpace(_rootThreadId)
            && string.Equals(
                ReadString(parameters, "threadId"),
                _rootThreadId,
                StringComparison.Ordinal);
    }

    private Task<CodexAppServerReply> HandleServerRequestAsync(
        CodexAppServerClient sourceClient,
        long sourceGeneration,
        CodexAppServerRequest request,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (_toolAdapter is not null)
        {
            CodexVoiceToolRequestContext? context = null;
            lock (_stateSync)
            {
                if (ReferenceEquals(sourceClient, _client)
                    && sourceGeneration == _clientGeneration
                    && _availability == CodexVoiceAvailability.Ready
                    && _rootThreadGeneration == sourceGeneration
                    && !string.IsNullOrWhiteSpace(_rootThreadId))
                {
                    context = new CodexVoiceToolRequestContext(
                        _rootThreadId,
                        sourceGeneration);
                }
            }
            if (context is { } currentContext)
            {
                return _toolAdapter.HandleAsync(request, currentContext, cancellationToken);
            }

            return Task.FromResult(
                CodexAppServerReply.Failure(
                    -32600,
                    "HoverPocket rejected a tool call from a stale or non-ready Codex session."));
        }

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
        var sessions = new List<CodexVoiceThreadSummary>();
        if (!string.IsNullOrWhiteSpace(_rootThreadId)
            && _rootCreatedAt is { } rootCreatedAt)
        {
            sessions.Add(new CodexVoiceThreadSummary(
                _rootThreadId,
                IsCurrentRoot: true,
                Title: "current",
                Detail: _sessionStatus.ToString(),
                State: _sessionStatus is CodexVoiceSessionStatus.RecoverableFailure
                    or CodexVoiceSessionStatus.BlockedFailure
                        ? CodexVoiceThreadState.Failed
                        : CodexVoiceThreadState.Running,
                CreatedAt: rootCreatedAt,
                UpdatedAt: DateTimeOffset.UtcNow));
        }
        sessions.AddRange(_childSessions);
        return new CodexVoiceSnapshot(
            _featureEnabled,
            _availability,
            _sessionStatus,
            _rootThreadId,
            _transportAttached,
            _isMuted,
            _transcript.Snapshot(),
            sessions,
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
        Task? sessionRefreshTask;
        lock (_stateSync)
        {
            sessionRefreshTask = _sessionRefreshTask;
            ClearRootThreadStateLocked();
            _pendingSdp?.TrySetCanceled();
            _pendingSdp = null;
            _pendingSdpThreadId = null;
        }
        if (sessionRefreshTask is not null)
        {
            try
            {
                await sessionRefreshTask;
            }
            catch (OperationCanceledException)
            {
            }
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
            lock (_stateSync)
            {
                _client = null;
                _clientGeneration = 0;
                ClearRootThreadStateLocked();
            }
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
