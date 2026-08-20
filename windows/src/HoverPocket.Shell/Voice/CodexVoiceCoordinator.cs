using System.ComponentModel;
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
        var visible = SanitizeVisibleText(value, 80);
        if (string.IsNullOrWhiteSpace(visible))
        {
            return "voice_unavailable";
        }
        var normalized = new string(visible.ToLowerInvariant().Select(character =>
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
    private readonly SemaphoreSlim _featureTransitionGate = new(1, 1);
    private readonly VoiceTranscriptBuffer _transcript = new();
    private readonly Dictionary<string, AgentSessionSummary> _sessions = new(StringComparer.Ordinal);
    private readonly Dictionary<CodexAppServerClient, int> _clientGenerations = [];
    private CancellationTokenSource _lifetime = new();
    private CancellationTokenSource? _restartCancellation;
    private Task? _restartTask;
    private CancellationTokenSource? _startupCancellation;
    private Task? _startupTask;
    private CodexAppServerClient? _client;
    private CodexVoiceSnapshot _snapshot = CodexVoiceSnapshot.Disabled;
    private volatile bool _featureEnabled;
    private string? _rootSessionId;
    private int _restartAttempt;
    private int _generation;
    private volatile bool _disposed;

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

        await RunTrackedStartupAsync(cancellationToken).ConfigureAwait(false);
    }

    public async Task SetFeatureEnabledAsync(bool enabled, CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        await _featureTransitionGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            ThrowIfDisposed();
            await SetFeatureEnabledCoreAsync(enabled, cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _featureTransitionGate.Release();
        }
    }

    private async Task SetFeatureEnabledCoreAsync(bool enabled, CancellationToken cancellationToken)
    {
        if (_featureEnabled == enabled)
        {
            if (enabled && Snapshot.Availability != CodexVoiceAvailability.Ready)
            {
                await InitializeAsync(cancellationToken).ConfigureAwait(false);
            }
            return;
        }

        _featureEnabled = enabled;
        Interlocked.Increment(ref _generation);
        if (!enabled)
        {
            await CancelRestartAsync().ConfigureAwait(false);
            await CancelStartupAsync().ConfigureAwait(false);
            var client = DetachClient();
            if (client is not null)
            {
                await DisposeDetachedClientAsync(client).ConfigureAwait(false);
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

        await InitializeAsync(cancellationToken).ConfigureAwait(false);
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
        if (!muted
            && (Snapshot.Availability != CodexVoiceAvailability.Ready
                || !Snapshot.TransportAttached))
        {
            UpdateSnapshot(snapshot => snapshot with { Muted = true });
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

    public async Task NotifySystemTransitionAsync()
    {
        if (!_featureEnabled)
        {
            return;
        }
        if (_clientFactory is null)
        {
            UpdateSnapshot(snapshot => snapshot with
            {
                Availability = CodexVoiceAvailability.Unavailable,
                SessionStatus = CodexVoiceSessionStatus.BlockedFailure,
                Activity = VoiceActivity.Failed,
                Muted = true,
                TransportAttached = false,
                AppServerProcessId = null,
                LastErrorCode = "production_voice_transport_unconfigured"
            });
            return;
        }
        Interlocked.Increment(ref _generation);
        await CancelRestartAsync().ConfigureAwait(false);
        await CancelStartupAsync().ConfigureAwait(false);
        var client = DetachClient();
        if (client is not null)
        {
            await DisposeDetachedClientAsync(client).ConfigureAwait(false);
        }
        if (!_featureEnabled || _disposed)
        {
            return;
        }
        UpdateSnapshot(snapshot => snapshot with
        {
            Availability = CodexVoiceAvailability.Unavailable,
            Muted = true,
            SessionStatus = CodexVoiceSessionStatus.Recovering,
            Activity = VoiceActivity.Reconnecting,
            TransportAttached = false,
            AppServerProcessId = null
        });
        ScheduleRestart();
    }

    public void NotifyTransportCrashed()
    {
        if (!_featureEnabled)
        {
            return;
        }
        Interlocked.Increment(ref _generation);
        var client = DetachClient();
        if (client is not null)
        {
            _ = DisposeDetachedClientAsync(client);
        }
        PublishTransportCrashAndRestart();
    }

    private void PublishTransportCrashAndRestart()
    {
        if (!_featureEnabled || _disposed)
        {
            return;
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
        if (!_featureEnabled || _disposed || cancellationToken.IsCancellationRequested)
        {
            return;
        }
        var generation = Interlocked.Increment(ref _generation);
        UpdateSnapshot(snapshot => snapshot with
        {
            Availability = CodexVoiceAvailability.Unavailable,
            SessionStatus = CodexVoiceSessionStatus.Connecting,
            Activity = VoiceActivity.Reconnecting,
            Muted = true,
            LastErrorCode = null
        });

        CodexVoiceGate gate;
        try
        {
            gate = await _compatibilityProbe.ProbeAsync(cancellationToken).ConfigureAwait(false);
            cancellationToken.ThrowIfCancellationRequested();
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            return;
        }
        catch (Exception)
        {
            if (!_featureEnabled || generation != Volatile.Read(ref _generation))
            {
                return;
            }
            UpdateSnapshot(snapshot => snapshot with
            {
                Availability = CodexVoiceAvailability.Unavailable,
                SessionStatus = CodexVoiceSessionStatus.RecoverableFailure,
                Activity = VoiceActivity.Reconnecting,
                Muted = true,
                TransportAttached = false,
                AppServerProcessId = null,
                LastErrorCode = "voice_compatibility_probe_failed"
            });
            ScheduleRestart();
            return;
        }
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
            candidate = await _clientFactory!(cancellationToken).ConfigureAwait(false);
            TrackClientGeneration(candidate, generation);
            candidate.ServerRequestReceived += OnServerRequestReceived;
            candidate.Disconnected += OnClientDisconnected;
            candidate.StartReading();
            using var initializeDocument = JsonDocument.Parse(
                """{"clientInfo":{"name":"HoverPocket","version":"an3-a"},"capabilities":{}}""");
            _ = await candidate.InitializeAsync(
                initializeDocument.RootElement.Clone(),
                cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            if (candidate is not null)
            {
                await DisposeDetachedClientAsync(candidate).ConfigureAwait(false);
            }
            if (cancellationToken.IsCancellationRequested
                || !_featureEnabled
                || generation != Volatile.Read(ref _generation))
            {
                return;
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
        catch (Exception exception) when (exception is CodexAppServerProtocolException
            or Win32Exception
            or IOException
            or InvalidOperationException)
        {
            if (candidate is not null)
            {
                await DisposeDetachedClientAsync(candidate).ConfigureAwait(false);
            }
            if (!_featureEnabled || generation != Volatile.Read(ref _generation))
            {
                return;
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
            await DisposeDetachedClientAsync(candidate).ConfigureAwait(false);
            return;
        }

        var previous = SwapClient(candidate);
        if (previous is not null)
        {
            await previous.DisposeAsync().ConfigureAwait(false);
        }
        if (!TryPublishReady(candidate, generation))
        {
            DetachClientIfCurrent(candidate);
            await DisposeDetachedClientAsync(candidate).ConfigureAwait(false);
        }
    }

    private bool TryPublishReady(CodexAppServerClient candidate, int generation)
    {
        CodexVoiceSnapshot ready;
        lock (_sync)
        {
            if (!_featureEnabled
                || _disposed
                || generation != _generation
                || !ReferenceEquals(_client, candidate))
            {
                return false;
            }
            _restartAttempt = 0;
            _snapshot = ProjectSnapshotLocked(_snapshot) with
            {
                Availability = CodexVoiceAvailability.Ready,
                SessionStatus = CodexVoiceSessionStatus.Idle,
                Activity = VoiceActivity.Idle,
                Muted = true,
                TransportAttached = true,
                AppServerProcessId = candidate.ProcessId,
                LastErrorCode = null,
                RestartAttempt = 0
            };
            ready = _snapshot;
        }
        PublishOutsideLock(ready);
        return true;
    }

    private void OnServerRequestReceived(object? sender, CodexAppServerRequest request)
    {
        if (sender is not CodexAppServerClient client)
        {
            return;
        }

        _ = client.ReplyFailClosedAsync(
            request.Id,
            "unexpected_server_request",
            CancellationToken.None);
        var clientGeneration = ClientGeneration(client);
        if (clientGeneration is null
            || !_featureEnabled
            || _disposed
            || Interlocked.CompareExchange(
                ref _generation,
                clientGeneration.Value + 1,
                clientGeneration.Value) != clientGeneration.Value)
        {
            DetachClientIfCurrent(client);
            _ = DisposeDetachedClientAsync(client);
            return;
        }

        CancelRestart();
        DetachClientIfCurrent(client);
        _ = DisposeDetachedClientAsync(client);
        UpdateSnapshot(snapshot => snapshot with
        {
            Availability = CodexVoiceAvailability.CapabilityBlocked,
            SessionStatus = CodexVoiceSessionStatus.BlockedFailure,
            Activity = VoiceActivity.Failed,
            Muted = true,
            TransportAttached = false,
            AppServerProcessId = null,
            LastErrorCode = "unexpected_server_request"
        });
    }

    private void OnClientDisconnected(object? sender, EventArgs e)
    {
        if (sender is not CodexAppServerClient client)
        {
            return;
        }

        var clientGeneration = ClientGeneration(client);
        if (clientGeneration is null)
        {
            return;
        }
        if (!_featureEnabled
            || _disposed
            || Interlocked.CompareExchange(
                ref _generation,
                clientGeneration.Value + 1,
                clientGeneration.Value) != clientGeneration.Value)
        {
            DetachClientIfCurrent(client);
            _ = DisposeDetachedClientAsync(client);
            return;
        }

        DetachClientIfCurrent(client);
        _ = DisposeDetachedClientAsync(client);
        PublishTransportCrashAndRestart();
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
        var restartCancellation = CancellationTokenSource.CreateLinkedTokenSource(_lifetime.Token);
        var startGate = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var restartTask = RunTrackedRestartAsync(delay, restartCancellation.Token, startGate.Task);
        var scheduled = false;
        lock (_sync)
        {
            if (_featureEnabled && !_disposed)
            {
                _restartCancellation = restartCancellation;
                _restartTask = restartTask;
                scheduled = true;
            }
        }
        startGate.SetResult();
        if (!scheduled)
        {
            restartCancellation.Cancel();
            _ = restartTask.ContinueWith(
                _ => restartCancellation.Dispose(),
                CancellationToken.None,
                TaskContinuationOptions.ExecuteSynchronously,
                TaskScheduler.Default);
        }
    }

    private async Task RunTrackedRestartAsync(
        TimeSpan delay,
        CancellationToken cancellationToken,
        Task startGate)
    {
        try
        {
            await startGate.ConfigureAwait(false);
            if (delay > TimeSpan.Zero)
            {
                await Task.Delay(delay, cancellationToken).ConfigureAwait(false);
            }
            await StartClientAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
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

    private void TrackClientGeneration(CodexAppServerClient client, int generation)
    {
        lock (_sync)
        {
            _clientGenerations[client] = generation;
        }
    }

    private int? ClientGeneration(CodexAppServerClient client)
    {
        lock (_sync)
        {
            return _clientGenerations.TryGetValue(client, out var generation)
                ? generation
                : null;
        }
    }

    private bool DetachClientIfCurrent(CodexAppServerClient expected)
    {
        lock (_sync)
        {
            if (!ReferenceEquals(_client, expected))
            {
                return false;
            }
            _client = null;
            expected.ServerRequestReceived -= OnServerRequestReceived;
            expected.Disconnected -= OnClientDisconnected;
            return true;
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
        lock (_sync)
        {
            _clientGenerations.Remove(client);
            client.ServerRequestReceived -= OnServerRequestReceived;
            client.Disconnected -= OnClientDisconnected;
        }
        try
        {
            await client.DisposeAsync().ConfigureAwait(false);
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
        CancellationTokenSource? cancellation;
        Task? restartTask;
        lock (_sync)
        {
            cancellation = _restartCancellation;
            restartTask = _restartTask;
            _restartCancellation = null;
            _restartTask = null;
        }
        if (cancellation is null)
        {
            return;
        }
        cancellation.Cancel();
        if (restartTask is null)
        {
            cancellation.Dispose();
            return;
        }
        _ = restartTask.ContinueWith(
            _ => cancellation.Dispose(),
            CancellationToken.None,
            TaskContinuationOptions.ExecuteSynchronously,
            TaskScheduler.Default);
    }

    private async Task CancelRestartAsync()
    {
        CancellationTokenSource? cancellation;
        Task? restartTask;
        lock (_sync)
        {
            cancellation = _restartCancellation;
            restartTask = _restartTask;
            _restartCancellation = null;
            _restartTask = null;
        }
        if (cancellation is null)
        {
            return;
        }
        cancellation.Cancel();
        try
        {
            if (restartTask is not null)
            {
                await restartTask.ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception exception) when (exception is CodexAppServerProtocolException
            or IOException
            or InvalidOperationException)
        {
        }
        finally
        {
            cancellation.Dispose();
        }
    }

    private async Task RunTrackedStartupAsync(CancellationToken cancellationToken)
    {
        Task startupTask;
        CancellationTokenSource? ownedCancellation = null;
        lock (_sync)
        {
            if (_startupTask is { IsCompleted: false } activeStartup)
            {
                startupTask = activeStartup;
            }
            else
            {
                ownedCancellation = CancellationTokenSource.CreateLinkedTokenSource(
                    cancellationToken,
                    _lifetime.Token);
                startupTask = StartClientAsync(ownedCancellation.Token);
                _startupCancellation = ownedCancellation;
                _startupTask = startupTask;
            }
        }

        try
        {
            await startupTask.ConfigureAwait(false);
        }
        finally
        {
            if (ownedCancellation is not null)
            {
                lock (_sync)
                {
                    if (ReferenceEquals(_startupTask, startupTask))
                    {
                        _startupTask = null;
                        _startupCancellation = null;
                    }
                }
                ownedCancellation.Dispose();
            }
        }
    }

    private async Task CancelStartupAsync()
    {
        Task? startupTask;
        lock (_sync)
        {
            _startupCancellation?.Cancel();
            startupTask = _startupTask;
        }
        if (startupTask is null)
        {
            return;
        }

        try
        {
            await startupTask.ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception exception) when (exception is CodexAppServerProtocolException
            or IOException
            or InvalidOperationException)
        {
        }
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
        CancelRestartAsync().GetAwaiter().GetResult();
        _lifetime.Cancel();
        CancelStartupAsync().GetAwaiter().GetResult();
        var client = DetachClient();
        if (client is not null)
        {
            DisposeDetachedClientAsync(client).GetAwaiter().GetResult();
        }
        _lifetime.Dispose();
        Publish(CodexVoiceSnapshot.Disabled);
    }
}
