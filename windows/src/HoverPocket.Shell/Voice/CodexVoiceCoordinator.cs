using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace HoverPocket.Shell.Voice;

internal enum VoiceLaneMode
{
    Disabled,
    Compact,
    Expanded
}

internal enum VoiceLaneLayoutPreference
{
    Compact,
    Expanded
}

internal enum CodexVoiceAvailability
{
    Disabled,
    Ready,
    Unavailable,
    SignedOut,
    SchemaMismatch,
    CapabilityBlocked
}

internal enum CodexVoiceSessionStatus
{
    Idle,
    Connecting,
    RequestingPermission,
    Negotiating,
    Stopping,
    Recovering,
    RecoverableFailure,
    BlockedFailure
}

internal enum VoiceActivity
{
    Idle,
    Listening,
    Thinking,
    Speaking,
    WaitingForApproval,
    Reconnecting,
    Failed
}

internal enum AgentSessionStatus
{
    Queued,
    Running,
    WaitingForUser,
    Succeeded,
    Failed,
    Cancelled
}

internal sealed record CodexVoiceGate(
    bool InstalledSchemaCompatible,
    bool AccountReady,
    bool CapabilityReady,
    string? SafeErrorCode)
{
    public static CodexVoiceGate Ready { get; } = new(true, true, true, null);

    public bool IsReady => InstalledSchemaCompatible && AccountReady && CapabilityReady;
}

internal interface ICodexVoiceCompatibilityProbe
{
    Task<CodexVoiceGate> ProbeAsync(CancellationToken cancellationToken);
}

internal sealed class BlockedCodexVoiceCompatibilityProbe : ICodexVoiceCompatibilityProbe
{
    public Task<CodexVoiceGate> ProbeAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return Task.FromResult(new CodexVoiceGate(
            InstalledSchemaCompatible: false,
            AccountReady: false,
            CapabilityReady: false,
            SafeErrorCode: "production_voice_probe_unconfigured"));
    }
}

internal sealed record VoiceTranscriptEvent(
    string Id,
    string Role,
    string Text,
    bool IsFinal,
    DateTimeOffset Timestamp);

internal sealed record AgentSessionProgress(int Completed, int Total);

internal sealed record AgentSessionSummary(
    string SessionId,
    string RootSessionId,
    string? ParentSessionId,
    string Title,
    AgentSessionStatus Status,
    string? SafeSummary,
    AgentSessionProgress? Progress,
    DateTimeOffset UpdatedAt);

internal sealed record CodexVoiceSnapshot(
    CodexVoiceAvailability Availability,
    CodexVoiceSessionStatus SessionStatus,
    VoiceActivity Activity,
    bool Muted,
    bool UiAttached,
    bool TransportAttached,
    int? AppServerProcessId,
    string? RootSessionId,
    IReadOnlyList<VoiceTranscriptEvent> Transcript,
    string? TranscriptPreview,
    IReadOnlyList<AgentSessionSummary> Sessions,
    int VisibleSessionCount,
    string? LastErrorCode,
    int RestartAttempt)
{
    public static CodexVoiceSnapshot Disabled { get; } = new(
        CodexVoiceAvailability.Disabled,
        CodexVoiceSessionStatus.Idle,
        VoiceActivity.Idle,
        Muted: true,
        UiAttached: false,
        TransportAttached: false,
        AppServerProcessId: null,
        RootSessionId: null,
        Transcript: Array.Empty<VoiceTranscriptEvent>(),
        TranscriptPreview: null,
        Sessions: Array.Empty<AgentSessionSummary>(),
        VisibleSessionCount: 0,
        LastErrorCode: null,
        RestartAttempt: 0);
}

internal static class VoiceTextSafety
{
    private static readonly string[] SensitiveMarkers =
    [
        "authorization:",
        "token=",
        "api_key=",
        "apikey="
    ];

    private static readonly Regex AbsolutePathPattern = new(
        "(?:^|[\\s\\\"'(=])(?:file://|/(?:[^/\\s]+/)*[^/\\s]+|[a-zA-Z]:\\\\[^\\s]+|\\\\\\\\[^\\s]+)",
        RegexOptions.CultureInvariant | RegexOptions.IgnoreCase);

    public static string SanitizeVisibleText(string? value, int maxRunes)
    {
        if (string.IsNullOrEmpty(value) || maxRunes <= 0)
        {
            return string.Empty;
        }

        var normalized = new string(value.Select(character =>
            char.IsControl(character) && character is not '\n' and not '\t' ? ' ' : character).ToArray());
        var lowered = normalized.ToLowerInvariant();
        if (SensitiveMarkers.Any(lowered.Contains)
            || AbsolutePathPattern.IsMatch(normalized))
        {
            return "[redacted]";
        }

        return string.Concat(normalized.EnumerateRunes().Take(maxRunes).Select(rune => rune.ToString()));
    }

    public static string SanitizeIdentifier(string? value)
    {
        if (string.IsNullOrEmpty(value))
        {
            return string.Empty;
        }

        var builder = new StringBuilder();
        foreach (var rune in value.EnumerateRunes())
        {
            if (Rune.IsLetterOrDigit(rune)
                || rune.Value is '-' or '_' or '.' or ':')
            {
                builder.Append(rune);
            }
            if (builder.Length >= 160)
            {
                break;
            }
        }
        return builder.ToString();
    }

    public static string SanitizeErrorCode(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return "voice_unavailable";
        }
        var normalized = new string(value.ToLowerInvariant().Select(character =>
            char.IsLetterOrDigit(character) || character == '_' ? character : '_').ToArray());
        return normalized.Length <= 80 ? normalized : normalized[..80];
    }
}

internal sealed class VoiceTranscriptBuffer
{
    public const int MaxEvents = 64;
    public const int MaxRunes = 8_192;

    private readonly List<VoiceTranscriptEvent> _events = [];

    public IReadOnlyList<VoiceTranscriptEvent> Events => _events;

    public void Append(VoiceTranscriptEvent value)
    {
        var sanitized = value with
        {
            Id = VoiceTextSafety.SanitizeIdentifier(value.Id),
            Role = VoiceTextSafety.SanitizeVisibleText(value.Role, 24),
            Text = VoiceTextSafety.SanitizeVisibleText(value.Text, 1_024)
        };
        _events.Add(sanitized);
        if (_events.Count > MaxEvents)
        {
            _events.RemoveRange(0, _events.Count - MaxEvents);
        }
        TrimRuneBudget();
    }

    public void Clear() => _events.Clear();

    private void TrimRuneBudget()
    {
        var runes = _events.Sum(item => item.Text.EnumerateRunes().Count());
        while (runes > MaxRunes && _events.Count > 1)
        {
            runes -= _events[0].Text.EnumerateRunes().Count();
            _events.RemoveAt(0);
        }
    }
}

internal sealed class CodexVoiceCoordinator : IDisposable
{
    public const int MaxRetainedSessions = 64;

    private readonly object _sync = new();
    private readonly Func<CancellationToken, Task<CodexAppServerClient>>? _clientFactory;
    private readonly ICodexVoiceCompatibilityProbe _compatibilityProbe;
    private readonly IReadOnlyList<TimeSpan> _restartDelays;
    private readonly VoiceTranscriptBuffer _transcript = new();
    private readonly Dictionary<string, AgentSessionSummary> _sessions = new(StringComparer.Ordinal);
    private CancellationTokenSource _lifetime = new();
    private CancellationTokenSource? _restartCancellation;
    private CodexAppServerClient? _client;
    private CodexVoiceSnapshot _snapshot = CodexVoiceSnapshot.Disabled;
    private bool _featureEnabled;
    private string? _rootSessionId;
    private int _restartAttempt;
    private int _generation;
    private bool _disposed;

    public CodexVoiceCoordinator(
        bool featureEnabled,
        Func<CancellationToken, Task<CodexAppServerClient>>? clientFactory = null,
        ICodexVoiceCompatibilityProbe? compatibilityProbe = null,
        IReadOnlyList<TimeSpan>? restartDelays = null)
    {
        _featureEnabled = featureEnabled;
        _clientFactory = clientFactory;
        _compatibilityProbe = compatibilityProbe ?? new BlockedCodexVoiceCompatibilityProbe();
        _restartDelays = restartDelays ??
        [
            TimeSpan.Zero,
            TimeSpan.FromMilliseconds(250),
            TimeSpan.FromSeconds(1)
        ];
        if (featureEnabled)
        {
            _snapshot = _snapshot with
            {
                Availability = CodexVoiceAvailability.Unavailable,
                SessionStatus = CodexVoiceSessionStatus.BlockedFailure,
                Activity = VoiceActivity.Failed,
                LastErrorCode = clientFactory is null
                    ? "production_voice_transport_unconfigured"
                    : "voice_not_initialized"
            };
        }
    }

    public event EventHandler<CodexVoiceSnapshot>? SnapshotChanged;

    public CodexVoiceSnapshot Snapshot
    {
        get
        {
            lock (_sync)
            {
                return _snapshot;
            }
        }
    }

    public async Task InitializeAsync(CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        if (!_featureEnabled)
        {
            Publish(CodexVoiceSnapshot.Disabled);
            return;
        }
        if (_clientFactory is null)
        {
            FailClosed(
                CodexVoiceAvailability.Unavailable,
                "production_voice_transport_unconfigured");
            return;
        }

        await StartClientAsync(cancellationToken);
    }

    public async Task SetFeatureEnabledAsync(bool enabled, CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        if (_featureEnabled == enabled)
        {
            if (enabled && Snapshot.Availability != CodexVoiceAvailability.Ready)
            {
                await InitializeAsync(cancellationToken);
            }
            return;
        }

        _featureEnabled = enabled;
        Interlocked.Increment(ref _generation);
        CancelRestart();
        if (!enabled)
        {
            var client = DetachClient();
            if (client is not null)
            {
                await DisposeDetachedClientAsync(client);
            }
            lock (_sync)
            {
                _transcript.Clear();
                _sessions.Clear();
                _rootSessionId = null;
                _restartAttempt = 0;
            }
            Publish(CodexVoiceSnapshot.Disabled);
            return;
        }

        await InitializeAsync(cancellationToken);
    }

    public void SetUiAttached(bool attached)
    {
        if (!_featureEnabled)
        {
            return;
        }

        UpdateSnapshot(snapshot => snapshot with
        {
            UiAttached = attached,
            Muted = attached ? snapshot.Muted : true
        });
    }

    public void SetMuted(bool muted)
    {
        if (!_featureEnabled)
        {
            return;
        }
        UpdateSnapshot(snapshot => snapshot with { Muted = muted });
    }

    public void CloseAudioSession()
    {
        if (!_featureEnabled)
        {
            return;
        }
        UpdateSnapshot(snapshot => snapshot with
        {
            Muted = true,
            SessionStatus = CodexVoiceSessionStatus.Idle,
            Activity = VoiceActivity.Idle
        });
    }

    public void SetRootSessionId(string? sessionId)
    {
        lock (_sync)
        {
            string? next = VoiceTextSafety.SanitizeIdentifier(sessionId);
            if (string.IsNullOrEmpty(next))
            {
                next = null;
            }
            if (!string.Equals(_rootSessionId, next, StringComparison.Ordinal))
            {
                _transcript.Clear();
                _sessions.Clear();
            }
            _rootSessionId = next;
            PublishLocked();
        }
    }

    public void AppendTranscript(VoiceTranscriptEvent value)
    {
        if (!_featureEnabled)
        {
            return;
        }
        lock (_sync)
        {
            _transcript.Append(value);
            PublishLocked();
        }
    }

    public void UpsertSession(AgentSessionSummary value)
    {
        if (!_featureEnabled)
        {
            return;
        }

        var sanitized = value with
        {
            SessionId = VoiceTextSafety.SanitizeIdentifier(value.SessionId),
            RootSessionId = VoiceTextSafety.SanitizeIdentifier(value.RootSessionId),
            ParentSessionId = string.IsNullOrWhiteSpace(value.ParentSessionId)
                ? null
                : VoiceTextSafety.SanitizeIdentifier(value.ParentSessionId),
            Title = VoiceTextSafety.SanitizeVisibleText(value.Title, 120),
            SafeSummary = value.SafeSummary is null
                ? null
                : VoiceTextSafety.SanitizeVisibleText(value.SafeSummary, 320),
            Progress = value.Progress is { Total: > 0 } progress
                && progress.Completed >= 0
                && progress.Completed <= progress.Total
                    ? progress
                    : null
        };
        if (string.IsNullOrEmpty(sanitized.SessionId)
            || string.IsNullOrEmpty(sanitized.RootSessionId))
        {
            return;
        }

        lock (_sync)
        {
            if (_rootSessionId is not null
                && !string.Equals(sanitized.RootSessionId, _rootSessionId, StringComparison.Ordinal))
            {
                return;
            }
            _sessions[sanitized.SessionId] = sanitized;
            if (_sessions.Count > MaxRetainedSessions)
            {
                foreach (var expired in _sessions.Values
                    .OrderBy(item => item.UpdatedAt)
                    .ThenBy(item => item.SessionId, StringComparer.Ordinal)
                    .Take(_sessions.Count - MaxRetainedSessions)
                    .ToArray())
                {
                    _sessions.Remove(expired.SessionId);
                }
            }
            PublishLocked();
        }
    }

    public void NotifySystemTransition()
    {
        if (!_featureEnabled)
        {
            return;
        }
        UpdateSnapshot(snapshot => snapshot with
        {
            Muted = true,
            SessionStatus = CodexVoiceSessionStatus.Recovering,
            Activity = VoiceActivity.Reconnecting
        });
        ScheduleRestart();
    }

    public void NotifyTransportCrashed()
    {
        if (!_featureEnabled)
        {
            return;
        }
        var client = DetachClient();
        if (client is not null)
        {
            _ = DisposeDetachedClientAsync(client);
        }
        UpdateSnapshot(snapshot => snapshot with
        {
            Availability = CodexVoiceAvailability.Unavailable,
            SessionStatus = CodexVoiceSessionStatus.RecoverableFailure,
            Activity = VoiceActivity.Reconnecting,
            Muted = true,
            TransportAttached = false,
            AppServerProcessId = null,
            LastErrorCode = "voice_transport_crashed"
        });
        ScheduleRestart();
    }

    private async Task StartClientAsync(CancellationToken cancellationToken)
    {
        var generation = Interlocked.Increment(ref _generation);
        UpdateSnapshot(snapshot => snapshot with
        {
            Availability = CodexVoiceAvailability.Unavailable,
            SessionStatus = CodexVoiceSessionStatus.Connecting,
            Activity = VoiceActivity.Reconnecting,
            Muted = true,
            LastErrorCode = null
        });

        var gate = await _compatibilityProbe.ProbeAsync(cancellationToken);
        cancellationToken.ThrowIfCancellationRequested();
        if (!_featureEnabled || generation != Volatile.Read(ref _generation))
        {
            return;
        }
        if (!gate.InstalledSchemaCompatible)
        {
            FailClosed(CodexVoiceAvailability.SchemaMismatch, gate.SafeErrorCode ?? "installed_schema_mismatch");
            return;
        }
        if (!gate.AccountReady)
        {
            FailClosed(CodexVoiceAvailability.SignedOut, gate.SafeErrorCode ?? "signed_out");
            return;
        }
        if (!gate.CapabilityReady)
        {
            FailClosed(CodexVoiceAvailability.CapabilityBlocked, gate.SafeErrorCode ?? "voice_capability_unavailable");
            return;
        }

        CodexAppServerClient? candidate = null;
        try
        {
            candidate = await _clientFactory!(cancellationToken);
            candidate.ServerRequestReceived += OnServerRequestReceived;
            candidate.Disconnected += OnClientDisconnected;
            using var initializeDocument = JsonDocument.Parse(
                """{"clientInfo":{"name":"HoverPocket","version":"an3-a"},"capabilities":{}}""");
            _ = await candidate.InitializeAsync(
                initializeDocument.RootElement.Clone(),
                cancellationToken);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            if (candidate is not null)
            {
                await DisposeDetachedClientAsync(candidate);
            }
            return;
        }
        catch (Exception exception) when (exception is CodexAppServerProtocolException
            or IOException
            or InvalidOperationException)
        {
            if (candidate is not null)
            {
                await DisposeDetachedClientAsync(candidate);
            }
            UpdateSnapshot(snapshot => snapshot with
            {
                Availability = CodexVoiceAvailability.Unavailable,
                SessionStatus = CodexVoiceSessionStatus.RecoverableFailure,
                Activity = VoiceActivity.Reconnecting,
                Muted = true,
                TransportAttached = false,
                AppServerProcessId = null,
                LastErrorCode = "voice_transport_start_failed"
            });
            ScheduleRestart();
            return;
        }

        if (!_featureEnabled || generation != Volatile.Read(ref _generation))
        {
            await DisposeDetachedClientAsync(candidate);
            return;
        }

        var previous = SwapClient(candidate);
        if (previous is not null)
        {
            await previous.DisposeAsync();
        }
        lock (_sync)
        {
            _restartAttempt = 0;
        }
        UpdateSnapshot(snapshot => snapshot with
        {
            Availability = CodexVoiceAvailability.Ready,
            SessionStatus = CodexVoiceSessionStatus.Idle,
            Activity = VoiceActivity.Idle,
            Muted = true,
            TransportAttached = true,
            AppServerProcessId = candidate.ProcessId,
            LastErrorCode = null,
            RestartAttempt = 0
        });
    }

    private void OnServerRequestReceived(object? sender, CodexAppServerRequest request)
    {
        Interlocked.Increment(ref _generation);
        if (sender is CodexAppServerClient client)
        {
            _ = client.ReplyFailClosedAsync(
                request.Id,
                "unexpected_server_request",
                CancellationToken.None);
        }
        FailClosed(
            CodexVoiceAvailability.CapabilityBlocked,
            "unexpected_server_request");
    }

    private void OnClientDisconnected(object? sender, EventArgs e)
    {
        if (!_featureEnabled || _disposed)
        {
            return;
        }
        NotifyTransportCrashed();
    }

    private void ScheduleRestart()
    {
        if (!_featureEnabled || _clientFactory is null)
        {
            return;
        }

        TimeSpan delay;
        int attempt;
        lock (_sync)
        {
            if (_restartAttempt >= _restartDelays.Count)
            {
                _snapshot = _snapshot with
                {
                    Availability = CodexVoiceAvailability.Unavailable,
                    SessionStatus = CodexVoiceSessionStatus.BlockedFailure,
                    Activity = VoiceActivity.Failed,
                    Muted = true,
                    LastErrorCode = "voice_restart_exhausted",
                    RestartAttempt = _restartAttempt
                };
                PublishOutsideLock(_snapshot);
                return;
            }
            delay = _restartDelays[_restartAttempt];
            _restartAttempt++;
            attempt = _restartAttempt;
            _snapshot = _snapshot with { RestartAttempt = attempt };
        }
        PublishOutsideLock(Snapshot);

        CancelRestart();
        _restartCancellation = CancellationTokenSource.CreateLinkedTokenSource(_lifetime.Token);
        var token = _restartCancellation.Token;
        _ = Task.Run(async () =>
        {
            try
            {
                if (delay > TimeSpan.Zero)
                {
                    await Task.Delay(delay, token);
                }
                await StartClientAsync(token);
            }
            catch (OperationCanceledException) when (token.IsCancellationRequested)
            {
            }
        }, token);
    }

    private void FailClosed(CodexVoiceAvailability availability, string errorCode)
    {
        var client = DetachClient();
        if (client is not null)
        {
            _ = DisposeDetachedClientAsync(client);
        }
        UpdateSnapshot(snapshot => snapshot with
        {
            Availability = availability,
            SessionStatus = CodexVoiceSessionStatus.BlockedFailure,
            Activity = VoiceActivity.Failed,
            Muted = true,
            TransportAttached = false,
            AppServerProcessId = null,
            LastErrorCode = VoiceTextSafety.SanitizeErrorCode(errorCode)
        });
    }

    private CodexAppServerClient? SwapClient(CodexAppServerClient next)
    {
        lock (_sync)
        {
            var previous = _client;
            if (previous is not null)
            {
                previous.ServerRequestReceived -= OnServerRequestReceived;
                previous.Disconnected -= OnClientDisconnected;
            }
            _client = next;
            return previous;
        }
    }

    private CodexAppServerClient? DetachClient()
    {
        lock (_sync)
        {
            var client = _client;
            _client = null;
            if (client is not null)
            {
                client.ServerRequestReceived -= OnServerRequestReceived;
                client.Disconnected -= OnClientDisconnected;
            }
            return client;
        }
    }

    private async Task DisposeDetachedClientAsync(CodexAppServerClient client)
    {
        client.ServerRequestReceived -= OnServerRequestReceived;
        client.Disconnected -= OnClientDisconnected;
        try
        {
            await client.DisposeAsync();
        }
        catch (Exception exception) when (exception is CodexAppServerProtocolException
            or IOException
            or InvalidOperationException)
        {
        }
    }

    private void UpdateSnapshot(Func<CodexVoiceSnapshot, CodexVoiceSnapshot> transform)
    {
        CodexVoiceSnapshot next;
        lock (_sync)
        {
            _snapshot = transform(ProjectSnapshotLocked(_snapshot));
            next = _snapshot;
        }
        PublishOutsideLock(next);
    }

    private void Publish(CodexVoiceSnapshot snapshot)
    {
        lock (_sync)
        {
            _snapshot = snapshot;
        }
        PublishOutsideLock(snapshot);
    }

    private void PublishLocked()
    {
        _snapshot = ProjectSnapshotLocked(_snapshot);
        PublishOutsideLock(_snapshot);
    }

    private CodexVoiceSnapshot ProjectSnapshotLocked(CodexVoiceSnapshot basis)
    {
        var visibleSessions = string.IsNullOrEmpty(_rootSessionId)
            ? Array.Empty<AgentSessionSummary>()
            : _sessions.Values
                .Where(session => string.Equals(
                    session.RootSessionId,
                    _rootSessionId,
                    StringComparison.Ordinal))
                .OrderByDescending(session => session.UpdatedAt)
                .ThenBy(session => session.SessionId, StringComparer.Ordinal)
                .ToArray();
        var transcript = _transcript.Events.ToArray();
        return basis with
        {
            RootSessionId = _rootSessionId,
            Transcript = transcript,
            TranscriptPreview = transcript.LastOrDefault()?.Text,
            Sessions = visibleSessions,
            VisibleSessionCount = visibleSessions.Length
        };
    }

    private void PublishOutsideLock(CodexVoiceSnapshot snapshot)
    {
        var handlers = SnapshotChanged;
        if (handlers is null)
        {
            return;
        }
        foreach (EventHandler<CodexVoiceSnapshot> handler in handlers.GetInvocationList())
        {
            try
            {
                handler(this, snapshot);
            }
            catch (InvalidOperationException)
            {
            }
        }
    }

    private void CancelRestart()
    {
        var cancellation = Interlocked.Exchange(ref _restartCancellation, null);
        if (cancellation is null)
        {
            return;
        }
        cancellation.Cancel();
        cancellation.Dispose();
    }

    private void ThrowIfDisposed()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;
        _featureEnabled = false;
        Interlocked.Increment(ref _generation);
        CancelRestart();
        _lifetime.Cancel();
        var client = DetachClient();
        if (client is not null)
        {
            DisposeDetachedClientAsync(client).GetAwaiter().GetResult();
        }
        _lifetime.Dispose();
        Publish(CodexVoiceSnapshot.Disabled);
    }
}
