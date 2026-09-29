namespace HoverPocket.Shell.Voice;

internal static class VoiceProviderIds
{
    public const string Off = "off";
    public const string OpenAIRealtimeByok = "openai_realtime_byok";
    public const string CodexAppServer = "codex_app_server";

    public static string Normalize(string? value) => value switch
    {
        OpenAIRealtimeByok => OpenAIRealtimeByok,
        CodexAppServer => CodexAppServer,
        _ => Off
    };

    public static bool IsSelectable(string? value) => value is OpenAIRealtimeByok or CodexAppServer or Off;
}

internal sealed record VoiceRealtimeFunctionResult(
    bool Handled,
    string? CallId,
    string? Output);

internal interface IVoiceRuntimeCoordinator : IDisposable
{
    string ProviderId { get; }

    event EventHandler<CodexVoiceSnapshot>? SnapshotChanged;

    event EventHandler<VoiceTransportSignal>? TransportSignal;

    CodexVoiceSnapshot Snapshot { get; }

    Task InitializeAsync(CancellationToken cancellationToken = default);

    Task SetFeatureEnabledAsync(bool enabled, CancellationToken cancellationToken = default);

    void SetUiAttached(bool attached);

    void SetMuted(bool muted);

    void BeginMicrophonePermissionRequest();

    Task<VoiceRealtimeStartResult> StartRealtimeAsync(
        string sdp,
        CancellationToken cancellationToken = default);

    void ConfirmRealtimeConnected(int generation, string threadId);

    Task StopRealtimeAsync(CancellationToken cancellationToken = default);

    Task AbortRealtimeStartAsync(string reason, CancellationToken cancellationToken = default);

    Task<VoiceRealtimeFunctionResult> HandleRealtimeFunctionEventAsync(
        int generation,
        string threadId,
        System.Text.Json.JsonElement eventPayload,
        CancellationToken cancellationToken = default);

    Task NotifySystemTransitionAsync(CancellationToken cancellationToken = default);
}

/// <summary>
/// Owns the explicit Voice provider selection and serializes provider replacement.
/// OFF never constructs a provider, so it cannot read credentials or touch a transport.
/// </summary>
internal sealed class VoiceProviderCoordinator : IDisposable
{
    private readonly Func<IVoiceRuntimeCoordinator> _codexFactory;
    private readonly Func<IVoiceRuntimeCoordinator> _openAIRealtimeFactory;
    private readonly SemaphoreSlim _transitionGate = new(1, 1);
    private IVoiceRuntimeCoordinator? _active;
    private IVoiceRuntimeCoordinator? _codex;
    private IVoiceRuntimeCoordinator? _openAIRealtime;
    private string _providerId;
    private bool _featureEnabled;
    private bool _uiAttached;
    private bool _muted = true;
    private bool _disposed;

    public VoiceProviderCoordinator(
        bool featureEnabled,
        string providerId,
        Func<IVoiceRuntimeCoordinator> codexFactory,
        Func<IVoiceRuntimeCoordinator> openAIRealtimeFactory)
    {
        _featureEnabled = featureEnabled;
        _providerId = VoiceProviderIds.Normalize(providerId);
        _codexFactory = codexFactory;
        _openAIRealtimeFactory = openAIRealtimeFactory;
    }

    public event EventHandler<CodexVoiceSnapshot>? SnapshotChanged;

    public event EventHandler<VoiceTransportSignal>? TransportSignal;

    public string ProviderId => _providerId;

    public CodexVoiceSnapshot Snapshot => _active?.Snapshot ?? CodexVoiceSnapshot.Disabled;

    public async Task InitializeAsync(CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        await _transitionGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (!_featureEnabled || _providerId == VoiceProviderIds.Off)
            {
                PublishDisabled();
                return;
            }
            await EnsureActiveAsync(cancellationToken).ConfigureAwait(false);
            if (_active is not null)
            {
                await _active.SetFeatureEnabledAsync(true, cancellationToken).ConfigureAwait(false);
            }
        }
        finally
        {
            _transitionGate.Release();
        }
    }

    public async Task SetFeatureEnabledAsync(bool enabled, CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        await _transitionGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (_featureEnabled == enabled)
            {
                if (enabled && _providerId != VoiceProviderIds.Off && _active is null)
                {
                    await EnsureActiveAsync(cancellationToken).ConfigureAwait(false);
                    if (_active is not null)
                    {
                        await _active.SetFeatureEnabledAsync(true, cancellationToken).ConfigureAwait(false);
                    }
                }
                else if (!enabled || _providerId == VoiceProviderIds.Off)
                {
                    PublishDisabled();
                }
                return;
            }

            _featureEnabled = enabled;
            if (!enabled)
            {
                await StopAndDisposeActiveAsync(CancellationToken.None).ConfigureAwait(false);
                PublishDisabled();
                return;
            }

            if (_providerId == VoiceProviderIds.Off)
            {
                PublishDisabled();
                return;
            }

            await EnsureActiveAsync(cancellationToken).ConfigureAwait(false);
            if (_active is not null)
            {
                await _active.SetFeatureEnabledAsync(true, cancellationToken).ConfigureAwait(false);
            }
        }
        finally
        {
            _transitionGate.Release();
        }
    }

    public async Task SetProviderAsync(string providerId, CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        var normalized = VoiceProviderIds.Normalize(providerId);
        await _transitionGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (string.Equals(_providerId, normalized, StringComparison.Ordinal))
            {
                return;
            }

            // Teardown is intentionally non-cancellable once provider replacement starts.
            // This prevents a cancelled settings request from overlapping old/new transports.
            await StopAndDisposeActiveAsync(CancellationToken.None).ConfigureAwait(false);
            _providerId = normalized;
            _muted = true;
            if (!_featureEnabled || normalized == VoiceProviderIds.Off)
            {
                PublishDisabled();
                return;
            }

            await EnsureActiveAsync(cancellationToken).ConfigureAwait(false);
            if (_active is not null)
            {
                await _active.SetFeatureEnabledAsync(true, cancellationToken).ConfigureAwait(false);
            }
        }
        finally
        {
            _transitionGate.Release();
        }
    }

    public async Task RestartSelectedProviderAsync(CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        await _transitionGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await StopAndDisposeActiveAsync(CancellationToken.None).ConfigureAwait(false);
            _muted = true;
            if (!_featureEnabled || _providerId == VoiceProviderIds.Off)
            {
                PublishDisabled();
                return;
            }
            await EnsureActiveAsync(cancellationToken).ConfigureAwait(false);
            if (_active is not null)
            {
                await _active.SetFeatureEnabledAsync(true, cancellationToken).ConfigureAwait(false);
            }
        }
        finally
        {
            _transitionGate.Release();
        }
    }

    public void SetUiAttached(bool attached)
    {
        ThrowIfDisposed();
        _uiAttached = attached;
        _active?.SetUiAttached(attached);
    }

    public void SetMuted(bool muted)
    {
        ThrowIfDisposed();
        _muted = muted;
        _active?.SetMuted(muted);
    }

    public void BeginMicrophonePermissionRequest()
    {
        ThrowIfDisposed();
        RequireActive().BeginMicrophonePermissionRequest();
    }

    public Task<VoiceRealtimeStartResult> StartRealtimeAsync(
        string sdp,
        CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        return RequireActive().StartRealtimeAsync(sdp, cancellationToken);
    }

    public void ConfirmRealtimeConnected(int generation, string threadId)
    {
        ThrowIfDisposed();
        RequireActive().ConfirmRealtimeConnected(generation, threadId);
    }

    public Task StopRealtimeAsync(CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        return _active?.StopRealtimeAsync(cancellationToken) ?? Task.CompletedTask;
    }

    public Task AbortRealtimeStartAsync(string reason, CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        return _active?.AbortRealtimeStartAsync(reason, cancellationToken) ?? Task.CompletedTask;
    }

    public Task<VoiceRealtimeFunctionResult> HandleRealtimeFunctionEventAsync(
        int generation,
        string threadId,
        System.Text.Json.JsonElement eventPayload,
        CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        return RequireActive().HandleRealtimeFunctionEventAsync(
            generation,
            threadId,
            eventPayload,
            cancellationToken);
    }

    public Task NotifySystemTransitionAsync(CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        return _active?.NotifySystemTransitionAsync(cancellationToken) ?? Task.CompletedTask;
    }

    private async Task EnsureActiveAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (_active is not null || !_featureEnabled || _providerId == VoiceProviderIds.Off)
        {
            return;
        }

        var candidate = _providerId switch
        {
            VoiceProviderIds.OpenAIRealtimeByok => _openAIRealtime ??= _openAIRealtimeFactory(),
            VoiceProviderIds.CodexAppServer => _codex ??= _codexFactory(),
            _ => throw new CodexAppServerProtocolException("voice_provider_invalid")
        };
        if (!string.Equals(candidate.ProviderId, _providerId, StringComparison.Ordinal))
        {
            candidate.Dispose();
            throw new CodexAppServerProtocolException("voice_provider_factory_mismatch");
        }
        _active = candidate;
        candidate.SnapshotChanged += OnSnapshotChanged;
        candidate.TransportSignal += OnTransportSignal;
        candidate.SetUiAttached(_uiAttached);
        candidate.SetMuted(true);
        _muted = true;
        await Task.CompletedTask.ConfigureAwait(false);
    }

    private async Task StopAndDisposeActiveAsync(CancellationToken cancellationToken)
    {
        var previous = _active;
        _active = null;
        if (previous is null)
        {
            return;
        }
        previous.SnapshotChanged -= OnSnapshotChanged;
        previous.TransportSignal -= OnTransportSignal;
        await previous.SetFeatureEnabledAsync(false, cancellationToken).ConfigureAwait(false);
    }

    private IVoiceRuntimeCoordinator RequireActive()
    {
        if (!_featureEnabled || _providerId == VoiceProviderIds.Off || _active is null)
        {
            throw new CodexAppServerProtocolException("voice_provider_off");
        }
        return _active;
    }

    private void OnSnapshotChanged(object? sender, CodexVoiceSnapshot snapshot)
    {
        _ = sender;
        SnapshotChanged?.Invoke(this, snapshot);
    }

    private void OnTransportSignal(object? sender, VoiceTransportSignal signal)
    {
        _ = sender;
        TransportSignal?.Invoke(this, signal);
    }

    private void PublishDisabled()
    {
        SnapshotChanged?.Invoke(this, CodexVoiceSnapshot.Disabled);
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
        _transitionGate.Wait();
        try
        {
            StopAndDisposeActiveAsync(CancellationToken.None).GetAwaiter().GetResult();
            _codex?.Dispose();
            if (!ReferenceEquals(_openAIRealtime, _codex))
            {
                _openAIRealtime?.Dispose();
            }
            _codex = null;
            _openAIRealtime = null;
        }
        finally
        {
            _transitionGate.Release();
            _transitionGate.Dispose();
        }
    }
}
