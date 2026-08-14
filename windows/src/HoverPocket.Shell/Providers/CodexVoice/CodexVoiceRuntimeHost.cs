namespace HoverPocket.Shell.Providers.CodexVoice;

internal sealed class CodexVoiceRuntimeHost : IAsyncDisposable
{
    private readonly Func<CancellationToken, Task<CodexAppServerClient>> _clientFactory;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly object _snapshotSync = new();
    private CodexVoiceCoordinator? _coordinator;
    private CodexVoiceSnapshot _snapshot = DisabledSnapshot();
    private bool _desiredEnabled;
    private int _disposeState;

    public CodexVoiceRuntimeHost(
        bool initiallyEnabled,
        Func<CancellationToken, Task<CodexAppServerClient>>? clientFactory = null)
    {
        _desiredEnabled = initiallyEnabled;
        _clientFactory = clientFactory ?? StartProductionClientAsync;
    }

    public event EventHandler<CodexVoiceSnapshot>? SnapshotChanged;

    public CodexVoiceSnapshot Snapshot
    {
        get
        {
            lock (_snapshotSync)
            {
                return _snapshot;
            }
        }
    }

    public Task StartAsync(CancellationToken cancellationToken = default)
    {
        return SetEnabledAsync(_desiredEnabled, cancellationToken);
    }

    public async Task SetEnabledAsync(
        bool enabled,
        CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        await _gate.WaitAsync(cancellationToken);
        try
        {
            ThrowIfDisposed();
            _desiredEnabled = enabled;
            if (!enabled)
            {
                var previous = _coordinator;
                _coordinator = null;
                if (previous is not null)
                {
                    previous.SnapshotChanged -= OnCoordinatorSnapshotChanged;
                    await previous.DisposeAsync();
                }

                SetSnapshot(DisabledSnapshot());
                return;
            }

            if (_coordinator is not null)
            {
                return;
            }

            var coordinator = new CodexVoiceCoordinator(
                featureEnabled: true,
                clientFactory: _clientFactory);
            coordinator.SnapshotChanged += OnCoordinatorSnapshotChanged;
            _coordinator = coordinator;
            SetSnapshot(coordinator.Snapshot);
            await coordinator.InitializeAsync(cancellationToken);
            SetSnapshot(coordinator.Snapshot);
        }
        finally
        {
            _gate.Release();
        }
    }

    public void ClearTransientUiState()
    {
        _coordinator?.ClearTransientUiState();
    }

    public void SetMuted(bool muted)
    {
        _coordinator?.SetMuted(muted);
    }

    private void OnCoordinatorSnapshotChanged(object? sender, CodexVoiceSnapshot snapshot)
    {
        if (Volatile.Read(ref _disposeState) == 0
            && ReferenceEquals(sender, _coordinator))
        {
            SetSnapshot(snapshot);
        }
    }

    private void SetSnapshot(CodexVoiceSnapshot snapshot)
    {
        lock (_snapshotSync)
        {
            _snapshot = snapshot;
        }

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
            catch (Exception)
            {
                // UI observers cannot own or terminate the app-lifetime runtime.
            }
        }
    }

    private static Task<CodexAppServerClient> StartProductionClientAsync(
        CancellationToken cancellationToken)
    {
        var version = typeof(CodexVoiceRuntimeHost).Assembly.GetName().Version?.ToString()
            ?? "0.0.0";
        return CodexAppServerClient.StartAsync(
            new CodexAppServerClientOptions
            {
                ClientName = "hover_pocket",
                ClientTitle = "HoverPocket Voice Lane",
                ClientVersion = version,
                ExperimentalApi = true,
                RequestTimeout = TimeSpan.FromSeconds(12)
            },
            cancellationToken);
    }

    private static CodexVoiceSnapshot DisabledSnapshot()
    {
        return new CodexVoiceSnapshot(
            FeatureEnabled: false,
            Availability: CodexVoiceAvailability.Disabled,
            SessionStatus: CodexVoiceSessionStatus.Idle,
            RootThreadId: null,
            TransportAttached: false,
            IsMuted: true,
            Transcript: Array.Empty<CodexVoiceTranscriptEntry>(),
            LastErrorCode: null,
            AppServerProcessId: null,
            RestartAttempt: 0,
            VoiceCount: 0);
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

        await _gate.WaitAsync();
        try
        {
            var coordinator = _coordinator;
            _coordinator = null;
            if (coordinator is not null)
            {
                coordinator.SnapshotChanged -= OnCoordinatorSnapshotChanged;
                await coordinator.DisposeAsync();
            }

            lock (_snapshotSync)
            {
                _snapshot = DisabledSnapshot();
            }
        }
        finally
        {
            _gate.Release();
            _gate.Dispose();
        }
    }
}
