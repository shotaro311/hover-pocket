using System.IO;
using System.Diagnostics;
using System.Text;
using System.Text.Json;
using HoverPocket.Shell.Capabilities;
using HoverPocket.Shell.Configuration;
using HoverPocket.Shell.Providers;
using HoverPocket.Shell.Providers.Calculator;
using HoverPocket.Shell.Providers.Calendar;
using HoverPocket.Shell.Providers.Clipboard;
using HoverPocket.Shell.Providers.Controls;
using HoverPocket.Shell.Providers.Sticky;
using HoverPocket.Shell.Providers.Timer;
using HoverPocket.Shell.PocketApps;
using HoverPocket.Shell.Services;
using HoverPocket.Shell.Settings;
using HoverPocket.Shell.Voice;

namespace HoverPocket.Shell.Bridge;

internal enum BridgeSurface
{
    Panel,
    Settings
}

internal sealed class PanelBridgeController : IDisposable
{
    private readonly ProviderRegistry _providerRegistry;
    private readonly UserSettingsStore _settingsStore;
    private readonly IStartupRegistrationService _startupRegistration;
    private readonly UpdaterService _updaterService;
    private readonly CalculatorBridgeHandlers _calculatorBridgeHandlers = new();
    private readonly CalendarBridgeController _calendarBridgeController;
    private readonly ClipboardBridgeController _clipboardBridgeController;
    private readonly ControlsBridgeController _controlsBridgeController = new();
    private readonly StickyBridgeController _stickyBridgeController;
    private readonly TimerBridgeHandlers _timerBridgeHandlers;
    private readonly PocketCapabilityHandlerSet _capabilityHandlers;
    private readonly CapabilityBroker? _capabilityBroker;
    private readonly TodayFocusTextAdapter? _todayFocusTextAdapter;
    private readonly PocketAppHostController? _pocketAppHostController;
    private readonly PocketAppActivationLease? _aiNativeExecutionLease;
    private readonly PocketAppGenerationController? _pocketAppGenerationController;
    private readonly PocketAppRuntimeActivationRegistry? _generatedPocketApps;
    private readonly CodexVoiceCoordinator _voiceCoordinator;
    private readonly VoiceTimerApprovalCoordinator _voiceTimerApprovalCoordinator = new();
    private readonly SemaphoreSlim _voiceSettingsTransitionGate = new(1, 1);
    private readonly Dictionary<BridgeDispatcher, BridgeSurface> _dispatchers = [];
    private readonly AsyncLocal<BridgeSurface?> _requestSurface = new();
    private readonly object _previewFrameSync = new();
    private Func<string, CancellationToken, Task<PocketAppStateTransitionLease>>? _pocketAppStateTransitionBegin;
    private Func<PocketAppStateTransitionLease, Task>? _pocketAppStateTransitionComplete;
    private Func<System.Windows.Window?>? _voiceApprovalOwner;
    private string _selectedProviderId;
    private MediaPreviewFrame? _pendingPreviewFrame;
    private bool _previewPostScheduled;
    private bool _panelOpen;
    private VoiceLaneMode _resolvedVoiceLaneMode;
    private volatile bool _voiceRuntimeActive;
    private bool _disposed;

    public PanelBridgeController(
        ProviderRegistry providerRegistry,
        UserSettingsStore settingsStore,
        UserSettings settings,
        IStartupRegistrationService? startupRegistration = null,
        object? aiLaneController = null,
        UpdaterService? updaterService = null,
        CodexVoiceCoordinator? voiceCoordinator = null)
    {
        _providerRegistry = providerRegistry;
        _settingsStore = settingsStore;
        _startupRegistration = startupRegistration ?? new RunKeyStartupRegistrationService();
        _updaterService = updaterService ?? new UpdaterService();
        _calendarBridgeController = new CalendarBridgeController();
        _ = aiLaneController; // Compatibility-only: the legacy AI command lane is intentionally not mounted.
        var stickyStore = new StickyNotesStore(Path.Combine(settingsStore.RootDirectory, "sticky"));
        var timerStore = new TimerStore(Path.Combine(settingsStore.RootDirectory, "timer"));
        _stickyBridgeController = new StickyBridgeController(stickyStore);
        _timerBridgeHandlers = new TimerBridgeHandlers(timerStore);
        _capabilityHandlers = ProviderCapabilityCompositionRoot.Create(
            new GoogleCalendarCapabilityDataSource(_calendarBridgeController.Store),
            timerStore,
            stickyStore,
            new LiveControlsCapabilityDataSource(_controlsBridgeController));
        _timerBridgeHandlers.AlertFired += OnTimerAlertFired;
        _timerBridgeHandlers.AlertChanged += OnTimerAlertChanged;
        CurrentSettings = UserSettingsStore.NormalizeForBootstrap(settings, providerRegistry.ProviderIds);
        try
        {
            var brokerRoot = Path.Combine(settingsStore.RootDirectory, "CapabilityBroker");
            _capabilityBroker = new CapabilityBroker(
                new CapabilityRegistry(_capabilityHandlers),
                new CapabilityBrokerLedger(brokerRoot),
                new CapabilityBrokerAuditLog(brokerRoot),
                approvalPresentationResolver: new HostCapabilityApprovalPresentationResolver(stickyStore));
            _todayFocusTextAdapter = new TodayFocusTextAdapter(_capabilityBroker);
        }
        catch (Exception ex) when (ex is CapabilityBrokerException
            or IOException
            or UnauthorizedAccessException)
        {
            _capabilityBroker = null;
            _todayFocusTextAdapter = null;
        }
        var voiceTools = _capabilityBroker is null
            ? null
            : new CodexVoiceCapabilityRuntime(
                _capabilityBroker,
                RequestVoiceTimerApprovalAsync,
                () => CurrentSettings.VoiceCalendarAccessGranted,
                CapabilityTimeZoneId);
        _voiceCoordinator = voiceCoordinator ?? CodexVoiceRuntimeComposition.Create(
            CurrentSettings.VoiceEnabled,
            voiceTools);
        _voiceRuntimeActive = _voiceCoordinator.Snapshot.Availability != CodexVoiceAvailability.Disabled;
        _resolvedVoiceLaneMode = VoicePanelGeometry.PreferredMode(CurrentSettings);
        _voiceCoordinator.SnapshotChanged += OnVoiceSnapshotChanged;
        _voiceCoordinator.TransportSignal += OnVoiceTransportSignal;
        _aiNativeExecutionLease = CurrentSettings.AiNativeEnabled
            ? new PocketAppActivationLease()
            : null;
        if (CurrentSettings.AiNativeEnabled)
        {
            try
            {
                if (_capabilityBroker is null)
                {
                    throw new CapabilityBrokerException("CAPABILITY_UNAVAILABLE", "broker");
                }
                var packageRoot = Path.Combine(
                    AppContext.BaseDirectory,
                    "PocketApps",
                    "local.example.today-focus");
                var package = new PocketAppPackageRuntime().Load(packageRoot);
                var userStateStore = new PocketAppUserStateStore(
                    package.Manifest.Id,
                    package.StateProperties,
                    Path.Combine(settingsStore.RootDirectory, "PocketApps", "UserData"));
                _pocketAppHostController = new PocketAppHostController(
                    new PocketAppExecutionRuntime(
                        package,
                        _capabilityBroker,
                        "local-user",
                        new HashSet<string>(
                            ["calendar.events.read", "sticky.read", "sticky.write", "timer.read", "timer.write"],
                            StringComparer.Ordinal),
                        userStateStore: userStateStore,
                        activationLease: _aiNativeExecutionLease),
                    () => CurrentSettings);
            }
            catch (Exception ex) when (ex is CapabilityBrokerException
                or PocketAppPackageRuntimeException
                or PocketAppUserStateStoreException
                or IOException
                or UnauthorizedAccessException)
            {
                _pocketAppHostController = null;
            }
        }
        if (CurrentSettings.AiNativeEnabled)
        {
            PocketAppRuntimeActivationRegistry? activationRegistry = null;
            try
            {
                var pocketAppsRoot = Path.Combine(settingsStore.RootDirectory, "PocketApps");
                var generatedHostRoot = Path.Combine(pocketAppsRoot, "GeneratedHost");
                var generationRoot = Path.Combine(pocketAppsRoot, "Generation");
                if (_capabilityBroker is not null)
                {
                    activationRegistry = new PocketAppRuntimeActivationRegistry(
                        generatedHostRoot,
                        Path.Combine(pocketAppsRoot, "UserData"),
                        _capabilityBroker,
                        "local-user",
                        () => CurrentSettings);
                    _ = activationRegistry.RestoreEnabledApps();
                }
                IPocketAppGenerationAdapter? generator = null;
                if (CodexPocketAppGenerationAdapter.ResolveExecutable() is { } executable)
                {
                    generator = new CodexPocketAppGenerationAdapter(
                        executable,
                        Path.Combine(generationRoot, "CodexWorkspaces"));
                }
                try
                {
                    _pocketAppGenerationController = new PocketAppGenerationController(
                        generatedHostRoot,
                        Path.Combine(pocketAppsRoot, "UserData"),
                        Path.Combine(generationRoot, "Drafts"),
                        generator,
                        runtimeActivationReadback: receipt => activationRegistry?.Synchronize(receipt)
                            ?? throw new PocketAppRuntimeActivationException("RUNTIME_ACTIVATION_UNAVAILABLE"),
                        postRefreshHook: OnGeneratedPocketAppsRefreshed);
                    _generatedPocketApps = activationRegistry;
                }
                catch
                {
                    if (generator is IDisposable disposable) { disposable.Dispose(); }
                    activationRegistry?.Dispose();
                    throw;
                }
            }
            catch (Exception ex) when (ex is PocketAppGenerationException
                or PocketAppLifecycleException
                or PocketAppRuntimeActivationException
                or IOException
                or UnauthorizedAccessException)
            {
                _pocketAppGenerationController = null;
                _generatedPocketApps = null;
            }
        }
        CurrentSettings = NormalizeSettings(CurrentSettings);
        _clipboardBridgeController = new ClipboardBridgeController(
            new ClipboardHistoryStore(Path.Combine(settingsStore.RootDirectory, "clipboard")),
            new ClipboardNativeListener(System.Windows.Application.Current?.Dispatcher ?? System.Windows.Threading.Dispatcher.CurrentDispatcher),
            () => CurrentSettings,
            SetClipboardPrivateModeAsync,
            () => IsVisible("clipboard"));
        _clipboardBridgeController.ExternalDragStarted += OnClipboardExternalDragStarted;
        _clipboardBridgeController.ApplySettings(CurrentSettings, IsVisible("clipboard"));
        _selectedProviderId = ResolveInitialProviderId();
        _controlsBridgeController.SnapshotChanged += OnControlsSnapshotChanged;
        _controlsBridgeController.PreviewStateChanged += OnControlsPreviewStateChanged;
        _controlsBridgeController.PreviewFrameArrived += OnControlsPreviewFrameArrived;
        _controlsBridgeController.MediaSourceOpened += OnControlsMediaSourceOpened;
        if (CurrentSettings.VoiceEnabled)
        {
            _ = _voiceCoordinator.InitializeAsync();
        }
    }

    public event EventHandler<UserSettings>? SettingsChanged;

    public event EventHandler? SettingsOpenRequested;

    public event EventHandler<TimerAlert>? TimerAlertFired;

    public event EventHandler<TimerAlert?>? TimerAlertChanged;

    public event EventHandler? ExternalDragStarted;

    public event EventHandler? PanelCloseRequested;

    public UserSettings CurrentSettings { get; private set; }

    public string SelectedProviderId => _selectedProviderId;

    public PocketCapabilityHandlerSet CapabilityHandlers => _capabilityHandlers;

    public CapabilityBroker? CapabilityBroker => _capabilityBroker;

    public TodayFocusTextAdapter? TodayFocusTextAdapter => _todayFocusTextAdapter;

    public VoiceLaneMode ResolvedVoiceLaneMode => _resolvedVoiceLaneMode;

    public VoiceLaneMode PreferredRuntimeVoiceLaneMode => !_voiceRuntimeActive
        ? VoiceLaneMode.Disabled
        : CurrentSettings.VoiceLaneLayout == VoiceLaneLayoutPreference.Expanded
            ? VoiceLaneMode.Expanded
            : VoiceLaneMode.Compact;

    public CodexVoiceSnapshot VoiceSnapshot => _voiceCoordinator.Snapshot;

    public IDisposable Attach(
        BridgeDispatcher dispatcher,
        BridgeSurface surface = BridgeSurface.Panel,
        Func<System.Windows.Window?>? approvalOwner = null,
        Func<bool>? aiNativeEnableDecision = null,
        Func<bool>? voiceCalendarAccessDecision = null,
        Func<bool>? voiceMicrophoneGesture = null)
    {
        _dispatchers[dispatcher] = surface;
        if (surface == BridgeSurface.Panel && approvalOwner is not null)
        {
            _voiceApprovalOwner = approvalOwner;
        }
        void Register(
            string method,
            Func<JsonElement?, CancellationToken, Task<object?>> handler)
        {
            dispatcher.Register(method, async (parameters, cancellationToken) =>
            {
                var previous = _requestSurface.Value;
                _requestSurface.Value = surface;
                try
                {
                    return await handler(parameters, cancellationToken);
                }
                finally
                {
                    _requestSurface.Value = previous;
                }
            });
        }

        Register(
            "app.getState",
            (_, _) => Task.FromResult<object?>(BuildState(surface)));
        Register("app.ready", (_, _) => Task.FromResult<object?>(new { ok = true }));
        Register("diagnostics.echo", (parameters, _) => Task.FromResult<object?>(DeserializeObject(parameters)));
        Register("settings.setPanelSize", SetPanelSizeAsync);
        Register("settings.setDisplayPlacement", SetDisplayPlacementAsync);
        Register("settings.setTextSize", SetTextSizeAsync);
        Register("settings.setSwitchingMode", SetSwitchingModeAsync);
        Register("settings.setLanguage", SetLanguageAsync);
        Register("settings.setProviderVisibility", SetProviderVisibilityAsync);
        Register("settings.moveProvider", MoveProviderAsync);
        Register("settings.setProviderOrder", SetProviderOrderAsync);
        Register("settings.setProviderSelection", SetProviderSelectionAsync);
        Register("settings.setPreferredProvider", SetPreferredProviderAsync);
        Register("settings.setHandleIcon", SetHandleIconAsync);
        Register("settings.setShowTopHandleSideArea", SetShowTopHandleSideAreaAsync);
        Register("settings.setDisableTopEdgeInFullscreen", SetDisableTopEdgeInFullscreenAsync);
        Register("settings.setStartWithWindows", SetStartWithWindowsAsync);
        Register("settings.setAutoCheckForUpdates", SetAutoCheckForUpdatesAsync);
        Register("settings.setClipboardPrivateMode", SetClipboardPrivateModeAsync);
        Register("settings.resetDefaults", ResetDefaultsAsync);
        Register("settings.resetPanelBinding", ResetPanelBindingAsync);
        Register("settings.openDataFolder", OpenDataFolderAsync);
        Register("settings.open", OpenSettingsAsync);
        Register("settings.openPlaceholder", OpenSettingsAsync);
        Register("updates.check", CheckForUpdatesAsync);
        if (surface == BridgeSurface.Panel)
        {
            Register("provider.select", SelectProviderAsync);
            Register(
                "voice.requestMicrophone",
                (parameters, cancellationToken) => RequestVoiceMicrophoneAsync(
                    parameters,
                    voiceMicrophoneGesture,
                    cancellationToken));
            Register("voice.startRealtime", StartVoiceRealtimeAsync);
            Register("voice.confirmRealtime", ConfirmVoiceRealtimeAsync);
            Register("voice.abortRealtime", AbortVoiceRealtimeAsync);
            Register("voice.setMuted", SetVoiceMutedAsync);
            Register("voice.setLayout", SetVoiceLayoutAsync);
            Register("voice.endSession", EndVoiceSessionAsync);
            Register("provider.refreshPlaceholder", RefreshPlaceholderAsync);
            Register("todayFocus.startFromCalendar", StartTodayFocusFromCalendarAsync);
            if (_pocketAppHostController is not null || _generatedPocketApps is not null)
            {
                Register("pocketApp.load", RoutePocketAppLoadAsync);
                Register("pocketApp.invokeWorkflow", RoutePocketAppInvokeWorkflowAsync);
                Register("pocketApp.updateState", RoutePocketAppUpdateStateAsync);
            }
        }
        if (surface == BridgeSurface.Settings)
        {
            Register("settings.setVoiceEnabled", SetVoiceEnabledAsync);
            Register("settings.setVoiceLayout", SetVoiceLayoutAsync);
            Register(
                "settings.setVoiceCalendarAccess",
                (parameters, cancellationToken) => SetVoiceCalendarAccessAsync(
                    parameters,
                    approvalOwner,
                    voiceCalendarAccessDecision,
                    cancellationToken));
            Register(
                "settings.setAiNativeEnabled",
                (parameters, cancellationToken) => SetAiNativeEnabledAsync(
                    parameters,
                    approvalOwner,
                    aiNativeEnableDecision,
                    cancellationToken));
            _pocketAppGenerationController?.AttachSettings(dispatcher, approvalOwner);
        }
        _calculatorBridgeHandlers.Register(dispatcher);
        _controlsBridgeController.Attach(dispatcher);
        _calendarBridgeController.Attach(dispatcher);
        _clipboardBridgeController.Attach(dispatcher);
        _stickyBridgeController.Attach(dispatcher);
        _timerBridgeHandlers.Register(dispatcher);
        return new BridgeAttachment(() =>
        {
            _dispatchers.Remove(dispatcher);
            if (surface == BridgeSurface.Panel
                && approvalOwner is not null
                && ReferenceEquals(_voiceApprovalOwner, approvalOwner))
            {
                _voiceApprovalOwner = null;
            }
        });
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _timerBridgeHandlers.AlertFired -= OnTimerAlertFired;
        _timerBridgeHandlers.AlertChanged -= OnTimerAlertChanged;
        _timerBridgeHandlers.Dispose();
        _clipboardBridgeController.ExternalDragStarted -= OnClipboardExternalDragStarted;
        _clipboardBridgeController.Dispose();
        _controlsBridgeController.SnapshotChanged -= OnControlsSnapshotChanged;
        _controlsBridgeController.PreviewStateChanged -= OnControlsPreviewStateChanged;
        _controlsBridgeController.PreviewFrameArrived -= OnControlsPreviewFrameArrived;
        _controlsBridgeController.MediaSourceOpened -= OnControlsMediaSourceOpened;
        _controlsBridgeController.Dispose();
        _voiceCoordinator.SnapshotChanged -= OnVoiceSnapshotChanged;
        _voiceCoordinator.TransportSignal -= OnVoiceTransportSignal;
        _voiceCoordinator.Dispose();
        _aiNativeExecutionLease?.Invalidate();
        _pocketAppHostController?.Dispose();
        _pocketAppGenerationController?.Dispose();
        _generatedPocketApps?.Dispose();
    }

    public object BuildState(BridgeSurface surface = BridgeSurface.Panel)
    {
        var includeGeneration = surface == BridgeSurface.Settings;
        var includePocketSurface = surface == BridgeSurface.Panel;
        var orderedProviders = OrderedProviders().ToArray();
        var selected = orderedProviders.FirstOrDefault(provider => string.Equals(provider.Id, _selectedProviderId, StringComparison.OrdinalIgnoreCase))
            ?? orderedProviders.FirstOrDefault();

        if (selected is not null)
        {
            _selectedProviderId = selected.Id;
        }

        var metrics = PanelSizeCatalog.Get(CurrentSettings.PanelSize);
        var voiceSnapshot = _voiceCoordinator.Snapshot;
        var voiceLaneHeight = VoicePanelGeometry.Height(CurrentSettings.PanelSize, _resolvedVoiceLaneMode);
        var builtInPocketAppAvailable = CurrentSettings.AiNativeEnabled
            && _pocketAppHostController?.IsActivationActive == true;
        var generatedRoute = SelectedGeneratedRoute();
        var selectedPocketSurface = includePocketSurface
            ? selected?.Id == "today-focus" && builtInPocketAppAvailable
                ? _pocketAppHostController?.BuildSurfaceState()
                : generatedRoute is null
                    ? null
                    : _generatedPocketApps?.SurfaceRegistry
                        .HostController(generatedRoute.AppId, generatedRoute.SurfaceId)?
                        .BuildSurfaceState(generatedRoute.SurfaceId)
            : null;
        var allProviders = AvailableProviders().ToArray();
        return new
        {
            settings = new
            {
                displayPlacement = ToWireValue(CurrentSettings.DisplayPlacement),
                panelSize = ToWireValue(CurrentSettings.PanelSize),
                textSize = ToWireValue(CurrentSettings.TextSize),
                switchingMode = ToWireValue(CurrentSettings.SwitchingMode),
                language = ToWireValue(CurrentSettings.Language),
                startWithWindows = CurrentSettings.StartWithWindows,
                startWithWindowsRegistered = IsStartupRegistered(),
                autoCheckForUpdates = CurrentSettings.AutoCheckForUpdates,
                aiNativeEnabled = CurrentSettings.AiNativeEnabled,
                voiceEnabled = CurrentSettings.VoiceEnabled,
                voiceCalendarAccessGranted = CurrentSettings.VoiceCalendarAccessGranted,
                voiceLaneLayout = ToWireValue(CurrentSettings.VoiceLaneLayout),
                clipboardPrivateMode = CurrentSettings.ClipboardPrivateMode,
                rememberLastSelectedProvider = CurrentSettings.RememberLastSelectedProvider,
                preferredProviderId = CurrentSettings.PreferredProviderId,
                lastSelectedProviderId = CurrentSettings.LastSelectedProviderId,
                handleIcon = ToWireValue(CurrentSettings.HandleIconStyle),
                showTopHandleSideArea = CurrentSettings.ShowTopHandleSideArea,
                disableTopEdgeInFullscreen = CurrentSettings.DisableTopEdgeInFullscreen,
                providerOrder = EffectiveProviderOrder(),
                providerVisibility = CurrentSettings.ProviderVisibility
            },
            updater = _updaterService.Snapshot,
            panel = new
            {
                headerHeight = PanelSizeCatalog.HeaderHeight,
                aiLaneHeight = PanelSizeCatalog.AiLaneHeight,
                voiceLaneHeight,
                voiceLaneMode = ToWireValue(_resolvedVoiceLaneMode),
                width = metrics.Width,
                providerHeight = metrics.ProviderHeight,
                baselineHeight = metrics.TotalHeight,
                totalHeight = metrics.TotalHeight + voiceLaneHeight,
                sizes = PanelSizeCatalog.All.Select(size => new
                {
                    id = size.Id,
                    label = size.Label,
                    width = size.Width,
                    providerHeight = size.ProviderHeight,
                    totalHeight = size.TotalHeight
                })
            },
            providers = orderedProviders.Select(provider => new
            {
                id = provider.Id,
                title = ProviderText(provider, ProviderTextKind.Title),
                icon = provider.Icon,
                summary = ProviderText(provider, ProviderTextKind.Summary),
                body = ProviderText(provider, ProviderTextKind.Body),
                selected = selected is not null && string.Equals(provider.Id, selected.Id, StringComparison.OrdinalIgnoreCase)
            }),
            allProviders = allProviders.Select(provider => new
            {
                id = provider.Id,
                title = ProviderText(provider, ProviderTextKind.Title),
                icon = provider.Icon,
                summary = ProviderText(provider, ProviderTextKind.Summary),
                body = ProviderText(provider, ProviderTextKind.Body)
            }),
            selectedProvider = selected is null
                ? null
                : new
                {
                    id = selected.Id,
                    title = ProviderText(selected, ProviderTextKind.Title),
                    icon = selected.Icon,
                    summary = ProviderText(selected, ProviderTextKind.Summary),
                    body = ProviderText(selected, ProviderTextKind.Body)
                }
            ,
            voiceLane = surface == BridgeSurface.Panel
                ? (object)new
                {
                    mode = ToWireValue(_resolvedVoiceLaneMode),
                    preferredLayout = ToWireValue(CurrentSettings.VoiceLaneLayout),
                    expansionBlocked = CurrentSettings.VoiceEnabled
                        && CurrentSettings.VoiceLaneLayout == VoiceLaneLayoutPreference.Expanded
                        && _resolvedVoiceLaneMode != VoiceLaneMode.Expanded,
                    availability = ToVoiceAvailabilityWireValue(voiceSnapshot.Availability),
                    sessionStatus = ToWireValue(voiceSnapshot.SessionStatus),
                    activity = ToWireValue(voiceSnapshot.Activity),
                    muted = voiceSnapshot.Muted,
                    uiAttached = voiceSnapshot.UiAttached,
                    transportAttached = voiceSnapshot.TransportAttached,
                    realtimeAttached = voiceSnapshot.RealtimeAttached,
                    rootSessionId = voiceSnapshot.RootSessionId,
                    visibleSessionCount = voiceSnapshot.VisibleSessionCount,
                    transcriptPreview = voiceSnapshot.TranscriptPreview,
                    transcript = voiceSnapshot.Transcript.Select(item => new
                    {
                        id = item.Id,
                        role = item.Role,
                        text = item.Text,
                        isFinal = item.IsFinal,
                        timestamp = item.Timestamp
                    }),
                    sessions = voiceSnapshot.Sessions.Select(item => new
                    {
                        sessionId = item.SessionId,
                        rootSessionId = item.RootSessionId,
                        parentSessionId = item.ParentSessionId,
                        title = item.Title,
                        status = ToWireValue(item.Status),
                        safeSummary = item.SafeSummary,
                        progress = item.Progress,
                        updatedAt = item.UpdatedAt,
                        navigation = "lane_detail"
                    }),
                    safeErrorCode = voiceSnapshot.LastErrorCode
                }
                : null,
            pocketSurface = selectedPocketSurface,
            pocketApps = !builtInPocketAppAvailable || _pocketAppHostController is null
                ? Array.Empty<object>()
                : new[] { _pocketAppHostController.BuildManagerState() },
            pocketAppGeneration = includeGeneration && CurrentSettings.AiNativeEnabled
                ? _pocketAppGenerationController?.BuildState()
                : null
        };
    }

    public void SetPocketAppStateFlush(
        Func<string, CancellationToken, Task<PocketAppStateTransitionLease>>? begin,
        Func<PocketAppStateTransitionLease, Task>? complete = null)
    {
        _pocketAppStateTransitionBegin = begin;
        _pocketAppStateTransitionComplete = complete;
        _pocketAppGenerationController?.SetBeforeDeactivate(begin, complete);
    }

    private Task<object?> RoutePocketAppLoadAsync(
        JsonElement? parameters,
        CancellationToken cancellationToken) =>
        ResolveSelectedPocketAppHost(parameters).LoadAsync(parameters, cancellationToken);

    private Task<object?> RoutePocketAppInvokeWorkflowAsync(
        JsonElement? parameters,
        CancellationToken cancellationToken) =>
        ResolveSelectedPocketAppHost(parameters).InvokeWorkflowAsync(parameters, cancellationToken);

    private Task<object?> RoutePocketAppUpdateStateAsync(
        JsonElement? parameters,
        CancellationToken cancellationToken) =>
        ResolveSelectedPocketAppHost(parameters).UpdateStateAsync(parameters, cancellationToken);

    private PocketAppHostController ResolveSelectedPocketAppHost(JsonElement? parameters)
    {
        var appId = ReadRequiredString(parameters, "appId");
        if (_pocketAppHostController is not null
            && string.Equals(_selectedProviderId, "today-focus", StringComparison.OrdinalIgnoreCase)
            && string.Equals(_pocketAppHostController.AppId, appId, StringComparison.Ordinal))
        {
            return _pocketAppHostController;
        }

        var route = SelectedGeneratedRoute();
        if (route is not null
            && string.Equals(route.AppId, appId, StringComparison.Ordinal)
            && _generatedPocketApps?.SurfaceRegistry.HostController(appId, route.SurfaceId) is { } generatedHost)
        {
            return generatedHost;
        }

        throw new CapabilityBrokerException("CAPABILITY_UNAVAILABLE", "pocket_app_route");
    }

    private async Task<object?> SelectProviderAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        var providerId = ReadRequiredString(parameters, "id");
        var provider = FindProvider(providerId);
        if (provider is null || !IsVisible(provider.Id))
        {
            throw new InvalidOperationException($"Provider is not visible: {providerId}");
        }

        _selectedProviderId = provider.Id;
        PersistLastSelectedProvider(provider.Id);
        return await PublishStateAsync(cancellationToken);
    }

    private async Task<object?> RefreshPlaceholderAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        _ = parameters;
        return await PublishStateAsync(cancellationToken);
    }

    private async Task<object?> SetPanelSizeAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        var panelSize = ParsePanelSize(ReadRequiredString(parameters, "panelSize"));
        if (CurrentSettings.PanelSize != panelSize)
        {
            var updated = CurrentSettings.Clone();
            updated.PanelSize = panelSize;
            SaveSettings(updated);
        }

        return await PublishStateAsync(cancellationToken);
    }

    private async Task<object?> SetDisplayPlacementAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        var placement = ParseDisplayPlacement(ReadRequiredString(parameters, "displayPlacement"));
        if (CurrentSettings.DisplayPlacement != placement)
        {
            var updated = CurrentSettings.Clone();
            updated.DisplayPlacement = placement;
            SaveSettings(updated);
        }

        return await PublishStateAsync(cancellationToken);
    }

    private async Task<object?> SetTextSizeAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        var textSize = ParseTextSize(ReadRequiredString(parameters, "textSize"));
        if (CurrentSettings.TextSize != textSize)
        {
            var updated = CurrentSettings.Clone();
            updated.TextSize = textSize;
            SaveSettings(updated);
        }

        return await PublishStateAsync(cancellationToken);
    }

    private async Task<object?> SetSwitchingModeAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        var switchingMode = ParseSwitchingMode(ReadRequiredString(parameters, "switchingMode"));
        if (CurrentSettings.SwitchingMode != switchingMode)
        {
            var updated = CurrentSettings.Clone();
            updated.SwitchingMode = switchingMode;
            SaveSettings(updated);
        }

        return await PublishStateAsync(cancellationToken);
    }

    private async Task<object?> SetLanguageAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        var language = ParseLanguage(ReadRequiredString(parameters, "language"));
        if (CurrentSettings.Language != language)
        {
            var updated = CurrentSettings.Clone();
            updated.Language = language;
            SaveSettings(updated);
        }

        return await PublishStateAsync(cancellationToken);
    }

    private async Task<object?> SetProviderVisibilityAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        var providerId = ReadRequiredString(parameters, "id");
        var visible = ReadRequiredBool(parameters, "visible");
        if (FindProvider(providerId) is null)
        {
            throw new InvalidOperationException($"Unknown provider: {providerId}");
        }

        var updated = CurrentSettings.Clone();
        updated.ProviderVisibility[providerId] = visible;
        if (updated.ProviderVisibility.Count > 0 && updated.ProviderVisibility.Values.All(value => !value))
        {
            updated.ProviderVisibility[providerId] = true;
        }

        SaveSettings(updated);
        return await PublishStateAsync(cancellationToken);
    }

    private async Task<object?> MoveProviderAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        var providerId = ReadRequiredString(parameters, "id");
        var direction = ReadRequiredString(parameters, "direction");
        var updated = CurrentSettings.Clone();
        var index = updated.ProviderOrder.FindIndex(id => string.Equals(id, providerId, StringComparison.OrdinalIgnoreCase));
        if (index < 0)
        {
            throw new InvalidOperationException($"Unknown provider: {providerId}");
        }

        var nextIndex = direction.Equals("up", StringComparison.OrdinalIgnoreCase)
            ? Math.Max(0, index - 1)
            : Math.Min(updated.ProviderOrder.Count - 1, index + 1);
        if (nextIndex != index)
        {
            (updated.ProviderOrder[index], updated.ProviderOrder[nextIndex]) =
                (updated.ProviderOrder[nextIndex], updated.ProviderOrder[index]);
            SaveSettings(updated);
        }

        return await PublishStateAsync(cancellationToken);
    }

    private async Task<object?> SetProviderOrderAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        var order = ReadRequiredStringArray(parameters, "providerOrder");
        var updated = CurrentSettings.Clone();
        updated.ProviderOrder = order;
        SaveSettings(updated);
        return await PublishStateAsync(cancellationToken);
    }

    private async Task<object?> SetProviderSelectionAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        var rememberLast = ReadRequiredBool(parameters, "rememberLast");
        if (CurrentSettings.RememberLastSelectedProvider != rememberLast)
        {
            var updated = CurrentSettings.Clone();
            updated.RememberLastSelectedProvider = rememberLast;
            SaveSettings(updated);
        }

        if (!rememberLast)
        {
            _selectedProviderId = ResolvePreferredProviderId();
        }

        return await PublishStateAsync(cancellationToken);
    }

    private async Task<object?> SetPreferredProviderAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        var providerId = ReadRequiredString(parameters, "id");
        var provider = FindProvider(providerId);
        if (provider is null || !IsVisible(provider.Id))
        {
            throw new InvalidOperationException($"Provider is not visible: {providerId}");
        }

        var updated = CurrentSettings.Clone();
        updated.PreferredProviderId = provider.Id;
        SaveSettings(updated);
        if (!updated.RememberLastSelectedProvider)
        {
            _selectedProviderId = provider.Id;
        }

        return await PublishStateAsync(cancellationToken);
    }

    private async Task<object?> SetHandleIconAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        var style = ParseHandleIcon(ReadRequiredString(parameters, "handleIcon"));
        if (CurrentSettings.HandleIconStyle != style)
        {
            var updated = CurrentSettings.Clone();
            updated.HandleIconStyle = style;
            SaveSettings(updated);
        }

        return await PublishStateAsync(cancellationToken);
    }

    private async Task<object?> SetShowTopHandleSideAreaAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        var visible = ReadRequiredBool(parameters, "visible");
        if (CurrentSettings.ShowTopHandleSideArea != visible)
        {
            var updated = CurrentSettings.Clone();
            updated.ShowTopHandleSideArea = visible;
            SaveSettings(updated);
        }

        return await PublishStateAsync(cancellationToken);
    }

    private async Task<object?> SetDisableTopEdgeInFullscreenAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        var disabled = ReadRequiredBool(parameters, "disabled");
        if (CurrentSettings.DisableTopEdgeInFullscreen != disabled)
        {
            var updated = CurrentSettings.Clone();
            updated.DisableTopEdgeInFullscreen = disabled;
            SaveSettings(updated);
        }

        return await PublishStateAsync(cancellationToken);
    }

    private async Task<object?> SetStartWithWindowsAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        var enabled = ReadRequiredBool(parameters, "enabled");
        if (CurrentSettings.StartWithWindows != enabled || IsStartupRegistered() != enabled)
        {
            _startupRegistration.SetRegistered(enabled);
            var updated = CurrentSettings.Clone();
            updated.StartWithWindows = enabled;
            SaveSettings(updated);
        }

        return await PublishStateAsync(cancellationToken);
    }

    private async Task<object?> SetAutoCheckForUpdatesAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        var enabled = ReadRequiredBool(parameters, "enabled");
        if (CurrentSettings.AutoCheckForUpdates != enabled)
        {
            var updated = CurrentSettings.Clone();
            updated.AutoCheckForUpdates = enabled;
            SaveSettings(updated);
        }

        return await PublishStateAsync(cancellationToken);
    }

    private async Task<object?> SetAiNativeEnabledAsync(
        JsonElement? parameters,
        Func<System.Windows.Window?>? approvalOwner,
        Func<bool>? enableDecision,
        CancellationToken cancellationToken)
    {
        var enabled = ReadRequiredBool(parameters, "enabled");
        PocketAppStateTransitionLease? stateTransition = null;
        if (enabled && !CurrentSettings.AiNativeEnabled)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var approved = enableDecision is not null
                ? enableDecision()
                : ShowAiNativeEnableApproval(approvalOwner?.Invoke());
            cancellationToken.ThrowIfCancellationRequested();
            if (!approved)
            {
                return await PublishStateAsync(cancellationToken);
            }
        }
        if (!enabled)
        {
            stateTransition = await BeginSelectedPocketAppStateTransitionAsync(cancellationToken);
            if (!stateTransition.Saved)
            {
                await CompletePocketAppStateTransitionAsync(stateTransition);
                stateTransition = null;
                return await PublishStateAsync(cancellationToken);
            }
        }
        try
        {
            if (!enabled)
            {
                _aiNativeExecutionLease?.Invalidate();
                _pocketAppGenerationController?.SetEnabled(false);
                _generatedPocketApps?.SetEnabled(false);
            }
            if (CurrentSettings.AiNativeEnabled != enabled)
            {
                var updated = CurrentSettings.Clone();
                updated.AiNativeEnabled = enabled;
                SaveSettings(updated);
            }

            // Never hot-create a generation composition root. If one exists from startup, disabling
            // cancels an in-flight Codex process immediately and gates every generation bridge route.
            if (enabled && _aiNativeExecutionLease?.IsActive == true)
            {
                _generatedPocketApps?.SetEnabled(true);
                _pocketAppGenerationController?.SetEnabled(true);
            }
            var published = await PublishStateAsync(cancellationToken);
            await CompletePocketAppStateTransitionAsync(stateTransition);
            stateTransition = null;
            return published;
        }
        catch
        {
            await CompletePocketAppStateTransitionAsync(stateTransition);
            throw;
        }
    }

    private bool ShowAiNativeEnableApproval(System.Windows.Window? owner)
    {
        var english = CurrentSettings.Language == AppLanguage.English;
        var message = english
            ? "Enable AI-native features? HoverPocket will make the Capability Broker and Pocket App management available after restart. Real Codex generation remains unavailable until the local-file confinement gate passes."
            : "AIネイティブ機能を有効にしますか？ 再起動後にCapability BrokerとPocket App管理が利用可能になります。ローカルファイルの隔離検証が完了するまで、実Codex生成は利用できません。";
        var title = english ? "Enable AI-native features" : "AIネイティブ機能を有効化";
        var result = owner is null
            ? System.Windows.MessageBox.Show(
                message,
                title,
                System.Windows.MessageBoxButton.YesNo,
                System.Windows.MessageBoxImage.Warning,
                System.Windows.MessageBoxResult.No)
            : System.Windows.MessageBox.Show(
                owner,
                message,
                title,
                System.Windows.MessageBoxButton.YesNo,
                System.Windows.MessageBoxImage.Warning,
                System.Windows.MessageBoxResult.No);
        return result == System.Windows.MessageBoxResult.Yes;
    }

    private async Task<object?> SetClipboardPrivateModeAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        return await SetClipboardPrivateModeAsync(ReadRequiredBool(parameters, "enabled"), cancellationToken);
    }

    private async Task<object?> SetClipboardPrivateModeAsync(bool enabled, CancellationToken cancellationToken)
    {
        if (CurrentSettings.ClipboardPrivateMode != enabled)
        {
            var updated = CurrentSettings.Clone();
            updated.ClipboardPrivateMode = enabled;
            SaveSettings(updated);
        }

        return await PublishStateAsync(cancellationToken);
    }

    private async Task<object?> ResetDefaultsAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        _ = parameters;
        var stateTransition = await BeginSelectedPocketAppStateTransitionAsync(cancellationToken);
        if (!stateTransition.Saved)
        {
            await CompletePocketAppStateTransitionAsync(stateTransition);
            return await PublishStateAsync(cancellationToken);
        }
        try
        {
            _startupRegistration.SetRegistered(false);
            _aiNativeExecutionLease?.Invalidate();
            _pocketAppGenerationController?.SetEnabled(false);
            _generatedPocketApps?.SetEnabled(false);
            SaveSettings(UserSettingsStore.CreateDefault(_providerRegistry.ProviderIds));
            await _voiceCoordinator.SetFeatureEnabledAsync(false, cancellationToken);
            _resolvedVoiceLaneMode = VoiceLaneMode.Disabled;
            var published = await PublishStateAsync(cancellationToken);
            await CompletePocketAppStateTransitionAsync(stateTransition);
            stateTransition = null;
            return published;
        }
        catch
        {
            await CompletePocketAppStateTransitionAsync(stateTransition);
            throw;
        }
    }

    private async Task<object?> ResetPanelBindingAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        _ = parameters;
        var updated = CurrentSettings.Clone();
        updated.DisplayPlacement = DisplayPlacement.Main;
        SaveSettings(updated);
        return await PublishStateAsync(cancellationToken);
    }

    private Task<object?> OpenDataFolderAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        _ = parameters;
        cancellationToken.ThrowIfCancellationRequested();
        Directory.CreateDirectory(_settingsStore.RootDirectory);
        using var process = Process.Start(new ProcessStartInfo(_settingsStore.RootDirectory)
        {
            UseShellExecute = true
        });
        return Task.FromResult<object?>(new { opened = true });
    }

    private async Task<object?> OpenSettingsAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        _ = parameters;
        cancellationToken.ThrowIfCancellationRequested();
        SettingsOpenRequested?.Invoke(this, EventArgs.Empty);
        return await Task.FromResult<object?>(new { opened = true });
    }

    private async Task<object?> CheckForUpdatesAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        _ = parameters;
        cancellationToken.ThrowIfCancellationRequested();
        return await _updaterService.CheckWithPromptsAsync(cancellationToken: cancellationToken);
    }

    private async Task<object?> SetVoiceEnabledAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        await _voiceSettingsTransitionGate.WaitAsync(cancellationToken);
        try
        {
            var enabled = ReadRequiredBool(parameters, "enabled");
            if (CurrentSettings.VoiceEnabled != enabled)
            {
                var updated = CurrentSettings.Clone();
                updated.VoiceEnabled = enabled;
                if (enabled)
                {
                    _resolvedVoiceLaneMode = VoicePanelGeometry.PreferredMode(updated);
                }
                SaveSettings(updated);
            }
            await _voiceCoordinator.SetFeatureEnabledAsync(
                enabled,
                enabled ? cancellationToken : CancellationToken.None);
            return await PublishStateAsync(cancellationToken);
        }
        finally
        {
            _voiceSettingsTransitionGate.Release();
        }
    }

    private async Task<object?> SetVoiceLayoutAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        var layout = ParseVoiceLaneLayout(ReadRequiredString(parameters, "layout"));
        if (CurrentSettings.VoiceLaneLayout != layout)
        {
            var updated = CurrentSettings.Clone();
            updated.VoiceLaneLayout = layout;
            _resolvedVoiceLaneMode = VoicePanelGeometry.PreferredMode(updated);
            SaveSettings(updated);
        }
        return await PublishStateAsync(cancellationToken);
    }

    private async Task<object?> SetVoiceCalendarAccessAsync(
        JsonElement? parameters,
        Func<System.Windows.Window?>? approvalOwner,
        Func<bool>? approvalDecision,
        CancellationToken cancellationToken)
    {
        await _voiceSettingsTransitionGate.WaitAsync(cancellationToken);
        try
        {
            var enabled = ReadRequiredBool(parameters, "enabled");
            cancellationToken.ThrowIfCancellationRequested();
            if (enabled
                && !CurrentSettings.VoiceCalendarAccessGranted
                && !ApproveVoiceCalendarAccess(approvalOwner, approvalDecision))
            {
                return await PublishStateAsync(cancellationToken);
            }
            if (CurrentSettings.VoiceCalendarAccessGranted == enabled)
            {
                return await PublishStateAsync(cancellationToken);
            }

            var voiceWasEnabled = CurrentSettings.VoiceEnabled;
            var stoppedForRevocation = false;
            if (!enabled && voiceWasEnabled)
            {
                await _voiceCoordinator.SetFeatureEnabledAsync(false, CancellationToken.None);
                stoppedForRevocation = true;
            }

            var updated = CurrentSettings.Clone();
            updated.VoiceCalendarAccessGranted = enabled;
            SaveSettings(updated);
            if (voiceWasEnabled)
            {
                if (!stoppedForRevocation)
                {
                    await _voiceCoordinator.SetFeatureEnabledAsync(false, cancellationToken);
                }
                await _voiceCoordinator.SetFeatureEnabledAsync(true, cancellationToken);
            }
            return await PublishStateAsync(cancellationToken);
        }
        finally
        {
            _voiceSettingsTransitionGate.Release();
        }
    }

    private bool ApproveVoiceCalendarAccess(
        Func<System.Windows.Window?>? approvalOwner,
        Func<bool>? approvalDecision)
    {
        if (approvalDecision is not null)
        {
            return approvalDecision();
        }
        var owner = approvalOwner?.Invoke();
        if (owner is null || !owner.IsVisible)
        {
            return false;
        }
        var english = CurrentSettings.Language == AppLanguage.English;
        var result = System.Windows.MessageBox.Show(
            owner,
            english
                ? "Voice Lane may send today's Calendar event titles and times to Codex.\n\nAllow Calendar access for Voice Lane?"
                : "Voice Laneは今日のCalendar予定名と時刻をCodexへ送信する場合があります。\n\nVoice LaneのCalendarアクセスを許可しますか？",
            english ? "Allow Voice Calendar access" : "VoiceのCalendarアクセスを許可",
            System.Windows.MessageBoxButton.YesNo,
            System.Windows.MessageBoxImage.Warning,
            System.Windows.MessageBoxResult.No);
        return result == System.Windows.MessageBoxResult.Yes;
    }

    private async Task<object?> SetVoiceMutedAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        _voiceCoordinator.SetMuted(ReadRequiredBool(parameters, "muted"));
        return await PublishStateAsync(cancellationToken);
    }

    private Task<object?> RequestVoiceMicrophoneAsync(
        JsonElement? parameters,
        Func<bool>? registerGesture,
        CancellationToken cancellationToken)
    {
        _ = parameters;
        cancellationToken.ThrowIfCancellationRequested();
        if (!CurrentSettings.VoiceEnabled
            || !_panelOpen
            || _voiceCoordinator.Snapshot.Availability != CodexVoiceAvailability.Ready
            || registerGesture?.Invoke() != true)
        {
            throw new CodexAppServerProtocolException("microphone_request_not_allowed");
        }
        _voiceCoordinator.BeginMicrophonePermissionRequest();
        return Task.FromResult<object?>(new { allowedForPrompt = true });
    }

    private async Task<object?> StartVoiceRealtimeAsync(
        JsonElement? parameters,
        CancellationToken cancellationToken)
    {
        var sdp = ReadRequiredString(parameters, "sdp");
        var result = await _voiceCoordinator.StartRealtimeAsync(sdp, cancellationToken);
        return new { generation = result.Generation, threadId = result.ThreadId };
    }

    private Task<object?> ConfirmVoiceRealtimeAsync(
        JsonElement? parameters,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        _voiceCoordinator.ConfirmRealtimeConnected(
            ReadRequiredInt(parameters, "generation"),
            ReadRequiredString(parameters, "threadId"));
        return Task.FromResult<object?>(new { connected = true });
    }

    private async Task<object?> AbortVoiceRealtimeAsync(
        JsonElement? parameters,
        CancellationToken cancellationToken)
    {
        await _voiceCoordinator.AbortRealtimeStartAsync(
            ReadRequiredString(parameters, "reason"),
            cancellationToken);
        return new { aborted = true };
    }

    private async Task<object?> EndVoiceSessionAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        _ = parameters;
        await _voiceCoordinator.StopRealtimeAsync(cancellationToken);
        return await PublishStateAsync(cancellationToken);
    }

    private async Task<bool> RequestVoiceTimerApprovalAsync(
        VoiceTimerApprovalRequest request,
        CancellationToken cancellationToken)
    {
        return await _voiceTimerApprovalCoordinator.RequestAsync(
            request,
            PresentVoiceTimerApprovalAsync,
            cancellationToken).ConfigureAwait(false);
    }

    private async Task<bool> PresentVoiceTimerApprovalAsync(
        VoiceTimerApprovalRequest request,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var owner = _voiceApprovalOwner?.Invoke();
        if (owner is null)
        {
            return false;
        }
        return await VoiceTimerApprovalDialog.ShowAsync(
            owner,
            request,
            CurrentSettings.Language == AppLanguage.English,
            cancellationToken).ConfigureAwait(false);
    }

    private async Task<object?> StartTodayFocusFromCalendarAsync(
        JsonElement? parameters,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!CurrentSettings.AiNativeEnabled
            || _capabilityBroker is null
            || _todayFocusTextAdapter is null
            || _aiNativeExecutionLease is null)
        {
            throw new CapabilityBrokerException("CAPABILITY_UNAVAILABLE", "today_focus");
        }
        _aiNativeExecutionLease.RequireActive();
        using var linkedCancellation = CancellationTokenSource.CreateLinkedTokenSource(
            cancellationToken,
            _aiNativeExecutionLease.CancellationToken);
        var effectiveCancellation = linkedCancellation.Token;
        effectiveCancellation.ThrowIfCancellationRequested();

        var eventRef = ReadRequiredString(parameters, "eventRef");
        if (string.IsNullOrEmpty(eventRef) || eventRef.EnumerateRunes().Count() > 256)
        {
            throw new CapabilityBrokerException("CAPABILITY_PLAN_INVALID", "event_ref");
        }

        var principal = new CapabilityPrincipal("local-user");
        var permissions = new CapabilityPermissionSet(
            principal,
            new HashSet<string>(
                ["calendar.events.read", "sticky.write", "timer.write"],
                StringComparer.Ordinal));
        var now = DateTimeOffset.Now;
        var events = await _todayFocusTextAdapter.ListTodayAsync(
            CapabilityTimeZoneId(),
            principal,
            permissions,
            now,
            effectiveCancellation);
        var selected = events.FirstOrDefault(item => item.EventRef == eventRef)
            ?? throw new CapabilityBrokerException("CAPABILITY_UNAVAILABLE", "calendar_event");
        var purpose = string.IsNullOrEmpty(selected.SafeTitle) ? "今日の予定" : selected.SafeTitle;
        var draft = _todayFocusTextAdapter.PrepareFocus(
            selected,
            1_500,
            purpose,
            principal,
            permissions,
            now);
        var request = draft.Preparation.ApprovalRequest
            ?? throw new CapabilityBrokerException("CAPABILITY_APPROVAL_REQUIRED", draft.Plan.Id);

        var english = CurrentSettings.Language == AppLanguage.English;
        var result = System.Windows.MessageBox.Show(
            english
                ? $"{draft.ApprovalText}\n\nStart a 25-minute Timer and save this purpose to Sticky Notes?"
                : $"{draft.ApprovalText}\n\n25分Timerを開始し、この目的をSticky Notesへ保存します。",
            english ? "Approve Today Focus" : "Today Focusを承認",
            System.Windows.MessageBoxButton.YesNo,
            System.Windows.MessageBoxImage.Question,
            System.Windows.MessageBoxResult.No);
        effectiveCancellation.ThrowIfCancellationRequested();
        if (result != System.Windows.MessageBoxResult.Yes)
        {
            try
            {
                _ = _capabilityBroker.DecideApproval(
                    request.Id,
                    draft.Preparation.PlanDigest,
                    CapabilityApprovalDecision.Reject,
                    now);
            }
            catch (CapabilityBrokerException ex) when (ex.Code == "CAPABILITY_APPROVAL_REJECTED")
            {
            }
            return new { status = "rejected" };
        }

        var receipt = await _todayFocusTextAdapter.ApproveAndExecuteAsync(
            draft,
            permissions,
            DateTimeOffset.Now,
            effectiveCancellation);
        return new
        {
            status = receipt.Status.WireValue(),
            replayed = receipt.Replayed,
            readbackVerified = receipt.Steps.All(step => step.Readback.Status == CapabilityReadbackStatus.Verified),
            capabilities = receipt.Steps.Select(step => step.Capability.Id).ToArray()
        };
    }

    private static string CapabilityTimeZoneId()
    {
        var identifier = TimeZoneInfo.Local.Id;
        if (identifier == "UTC" || identifier.Contains('/'))
        {
            return identifier;
        }
        if (TimeZoneInfo.TryConvertWindowsIdToIanaId(identifier, out var converted)
            && !string.IsNullOrEmpty(converted))
        {
            return converted;
        }
        throw new CapabilityBrokerException("CAPABILITY_UNAVAILABLE", "timezone");
    }

    public async Task NotifyPanelOpenedAsync()
    {
        _panelOpen = true;
        _voiceCoordinator.SetUiAttached(true);
        if (!CurrentSettings.RememberLastSelectedProvider)
        {
            _selectedProviderId = ResolvePreferredProviderId();
        }

        await SynchronizeControlsLifecycleAsync();
        await PostStateEventAsync("panel.opened");
    }

    public async Task NotifyPanelClosedAsync()
    {
        _panelOpen = false;
        _voiceCoordinator.SetMuted(true);
        _voiceCoordinator.SetUiAttached(false);
        await SynchronizeControlsLifecycleAsync();
        await PostEventAsync("panel.closed", new { closed = true });
    }

    public async Task SelectProviderFromShellAsync(string providerId, CancellationToken cancellationToken = default)
    {
        var provider = FindProvider(providerId);
        if (provider is null || !IsVisible(provider.Id))
        {
            return;
        }

        _selectedProviderId = provider.Id;
        PersistLastSelectedProvider(provider.Id);
        await PublishStateAsync(cancellationToken);
    }

    public void SetResolvedVoiceLaneMode(VoiceLaneMode mode)
    {
        if (_resolvedVoiceLaneMode == mode)
        {
            return;
        }
        _resolvedVoiceLaneMode = mode;
        _ = PostStateEventOnUiThreadAsync("state.changed");
    }

    public Task NotifySystemTransitionAsync(CancellationToken cancellationToken = default)
    {
        return _voiceCoordinator.NotifySystemTransitionAsync(cancellationToken);
    }

    private void OnVoiceSnapshotChanged(object? sender, CodexVoiceSnapshot snapshot)
    {
        _ = sender;
        var runtimeActive = snapshot.Availability != CodexVoiceAvailability.Disabled;
        if (_voiceRuntimeActive != runtimeActive)
        {
            _voiceRuntimeActive = runtimeActive;
            _resolvedVoiceLaneMode = runtimeActive
                ? CurrentSettings.VoiceLaneLayout == VoiceLaneLayoutPreference.Expanded
                    ? VoiceLaneMode.Expanded
                    : VoiceLaneMode.Compact
                : VoiceLaneMode.Disabled;
            SettingsChanged?.Invoke(this, CurrentSettings);
        }
        _ = PostStateEventOnUiThreadAsync("voice.stateChanged");
    }

    private void OnVoiceTransportSignal(object? sender, VoiceTransportSignal signal)
    {
        _ = sender;
        _ = PostPanelEventOnUiThreadAsync(
            "voice.transportSignal",
            new
            {
                generation = signal.Generation,
                threadId = signal.ThreadId,
                type = "answer",
                sdp = signal.Sdp
            });
    }

    private void SaveSettings(UserSettings settings)
    {
        CurrentSettings = NormalizeSettings(settings);
        _clipboardBridgeController.ApplySettings(CurrentSettings, IsVisible("clipboard"));
        _settingsStore.Save(CurrentSettings);
        SettingsChanged?.Invoke(this, CurrentSettings);
    }

    private async Task<object> PublishStateAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var state = BuildState(_requestSurface.Value ?? BridgeSurface.Panel);
        await SynchronizeControlsLifecycleAsync(cancellationToken);
        await PostStateEventAsync("state.changed");
        return state;
    }

    private Task SynchronizeControlsLifecycleAsync(CancellationToken cancellationToken = default)
    {
        var shouldBeActive = _panelOpen
            && string.Equals(_selectedProviderId, "controls", StringComparison.OrdinalIgnoreCase)
            && IsVisible("controls");
        return _controlsBridgeController.SetActiveAsync(shouldBeActive, cancellationToken);
    }

    private void OnControlsSnapshotChanged(object? sender, ControlsSnapshot snapshot)
    {
        _ = sender;
        _ = PostEventOnUiThreadAsync("controls.stateChanged", snapshot);
    }

    private void OnControlsMediaSourceOpened(object? sender, EventArgs e)
    {
        _ = sender;
        _ = e;
        PanelCloseRequested?.Invoke(this, EventArgs.Empty);
    }

    private void OnControlsPreviewStateChanged(object? sender, MediaPreviewState preview)
    {
        _ = sender;
        _ = PostEventOnUiThreadAsync("controls.previewState", preview);
    }

    private void OnControlsPreviewFrameArrived(object? sender, MediaPreviewFrame frame)
    {
        _ = sender;
        lock (_previewFrameSync)
        {
            _pendingPreviewFrame = frame;
            if (_previewPostScheduled)
            {
                return;
            }

            _previewPostScheduled = true;
        }

        var dispatcher = System.Windows.Application.Current?.Dispatcher;
        if (dispatcher is null)
        {
            lock (_previewFrameSync)
            {
                _previewPostScheduled = false;
            }

            return;
        }

        _ = dispatcher.InvokeAsync(DrainPreviewFramesAsync).Task.Unwrap();
    }

    private async Task DrainPreviewFramesAsync()
    {
        while (true)
        {
            MediaPreviewFrame? frame;
            lock (_previewFrameSync)
            {
                frame = _pendingPreviewFrame;
                _pendingPreviewFrame = null;
                if (frame is null)
                {
                    _previewPostScheduled = false;
                    return;
                }
            }

            await PostEventAsync("controls.previewFrame", frame);
        }
    }

    private Task PostEventOnUiThreadAsync(string eventName, object? payload)
    {
        var dispatcher = System.Windows.Application.Current?.Dispatcher;
        if (dispatcher is null || dispatcher.CheckAccess())
        {
            return PostEventAsync(eventName, payload);
        }

        return dispatcher.InvokeAsync(() => PostEventAsync(eventName, payload)).Task.Unwrap();
    }

    private Task PostPanelEventOnUiThreadAsync(string eventName, object? payload)
    {
        var dispatcher = System.Windows.Application.Current?.Dispatcher;
        if (dispatcher is null || dispatcher.CheckAccess())
        {
            return PostPanelEventAsync(eventName, payload);
        }
        return dispatcher.InvokeAsync(() => PostPanelEventAsync(eventName, payload)).Task.Unwrap();
    }

    private Task PostStateEventOnUiThreadAsync(string eventName)
    {
        var dispatcher = System.Windows.Application.Current?.Dispatcher;
        if (dispatcher is null || dispatcher.CheckAccess())
        {
            return PostStateEventAsync(eventName);
        }

        return dispatcher.InvokeAsync(() => PostStateEventAsync(eventName)).Task.Unwrap();
    }

    private async Task PostEventAsync(string eventName, object? payload)
    {
        foreach (var dispatcher in _dispatchers.Keys.ToArray())
        {
            await dispatcher.PostEventAsync(eventName, payload);
        }
    }

    private async Task PostPanelEventAsync(string eventName, object? payload)
    {
        foreach (var item in _dispatchers.ToArray())
        {
            if (item.Value == BridgeSurface.Panel)
            {
                await item.Key.PostEventAsync(eventName, payload);
            }
        }
    }

    private async Task PostStateEventAsync(string eventName)
    {
        foreach (var item in _dispatchers.ToArray())
        {
            await item.Key.PostEventAsync(
                eventName,
                BuildState(item.Value));
        }
    }

    private string ResolveInitialProviderId()
    {
        if (CurrentSettings.RememberLastSelectedProvider
            && IsSelectableProvider(CurrentSettings.LastSelectedProviderId))
        {
            return CurrentSettings.LastSelectedProviderId!;
        }

        if (IsSelectableProvider(CurrentSettings.PreferredProviderId))
        {
            return CurrentSettings.PreferredProviderId!;
        }

        return OrderedProviders().FirstOrDefault()?.Id
            ?? _providerRegistry.Providers.FirstOrDefault()?.Id
            ?? string.Empty;
    }

    private IEnumerable<ProviderDescriptor> OrderedProviders()
    {
        var yielded = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var providerId in CurrentSettings.ProviderOrder)
        {
            var provider = FindProvider(providerId);
            if (provider is not null && IsVisible(provider.Id))
            {
                yielded.Add(provider.Id);
                yield return provider;
            }
        }
        foreach (var provider in AvailableProviders())
        {
            if (yielded.Add(provider.Id) && IsVisible(provider.Id))
            {
                yield return provider;
            }
        }
    }

    private bool IsVisible(string providerId)
    {
        var provider = FindProvider(providerId);
        if (provider is null
            || (!provider.DefaultVisible && !CurrentSettings.AiNativeEnabled))
        {
            return false;
        }
        return !CurrentSettings.ProviderVisibility.TryGetValue(providerId, out var visible) || visible;
    }

    private string ResolvePreferredProviderId()
    {
        return IsSelectableProvider(CurrentSettings.PreferredProviderId)
            ? CurrentSettings.PreferredProviderId!
            : OrderedProviders().FirstOrDefault()?.Id ?? string.Empty;
    }

    private bool IsSelectableProvider(string? providerId)
    {
        return !string.IsNullOrWhiteSpace(providerId)
            && FindProvider(providerId) is not null
            && IsVisible(providerId);
    }

    private void PersistLastSelectedProvider(string providerId)
    {
        if (!CurrentSettings.RememberLastSelectedProvider
            || string.Equals(CurrentSettings.LastSelectedProviderId, providerId, StringComparison.OrdinalIgnoreCase))
        {
            return;
        }

        var updated = CurrentSettings.Clone();
        updated.LastSelectedProviderId = providerId;
        CurrentSettings = NormalizeSettings(updated);
        _settingsStore.Save(CurrentSettings);
    }

    private void OnGeneratedPocketAppsRefreshed()
    {
        CurrentSettings = NormalizeSettings(CurrentSettings.Clone());
        if (!IsSelectableProvider(_selectedProviderId))
        {
            _selectedProviderId = ResolveInitialProviderId();
        }
        _settingsStore.Save(CurrentSettings);
        SettingsChanged?.Invoke(this, CurrentSettings);
        _ = PostStateEventOnUiThreadAsync("state.changed");
    }

    private UserSettings NormalizeSettings(UserSettings settings)
    {
        var activeProviderIds = AvailableProviderIds();
        if (_generatedPocketApps is null
            || !_generatedPocketApps.TryGetManagedAppIds(out var managedAppIds))
        {
            return UserSettingsStore.NormalizeForBootstrap(settings, activeProviderIds);
        }
        var knownProviderIds = activeProviderIds
            .Concat(managedAppIds.Select(PocketSurfaceRegistry.GeneratedProviderId))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();
        return UserSettingsStore.Normalize(settings, knownProviderIds);
    }

    private IReadOnlyList<ProviderDescriptor> AvailableProviders()
    {
        var generated = _generatedPocketApps?.SurfaceRegistry.Routes
            .Select(route => new ProviderDescriptor(
                route.ProviderId,
                route.Title,
                "target",
                "Personal Pocket App",
                "A generated Pocket App running through the shared Capability Broker."))
            ?? Enumerable.Empty<ProviderDescriptor>();
        return _providerRegistry.Providers
            .Concat(generated)
            .GroupBy(provider => provider.Id, StringComparer.OrdinalIgnoreCase)
            .Select(group => group.First())
            .ToArray();
    }

    private IReadOnlyList<string> AvailableProviderIds() =>
        AvailableProviders().Select(provider => provider.Id).ToArray();

    private IReadOnlyList<string> EffectiveProviderOrder()
    {
        var available = AvailableProviderIds();
        var availableSet = available.ToHashSet(StringComparer.OrdinalIgnoreCase);
        var ordered = CurrentSettings.ProviderOrder
            .Where(availableSet.Contains)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();
        var orderedSet = ordered.ToHashSet(StringComparer.OrdinalIgnoreCase);
        ordered.AddRange(available.Where(orderedSet.Add));
        return ordered;
    }

    private ProviderDescriptor? FindProvider(string id) =>
        AvailableProviders().FirstOrDefault(
            provider => string.Equals(provider.Id, id, StringComparison.OrdinalIgnoreCase));

    private PocketSurfaceRegistry.Route? SelectedGeneratedRoute() =>
        _generatedPocketApps?.SurfaceRegistry.Routes.FirstOrDefault(
            route => string.Equals(route.ProviderId, _selectedProviderId, StringComparison.OrdinalIgnoreCase));

    private string? SelectedPocketSurfaceAppId() =>
        string.Equals(_selectedProviderId, "today-focus", StringComparison.OrdinalIgnoreCase)
            ? _pocketAppHostController?.AppId
            : SelectedGeneratedRoute()?.AppId;

    private async Task<PocketAppStateTransitionLease> BeginSelectedPocketAppStateTransitionAsync(
        CancellationToken cancellationToken)
    {
        var appId = SelectedPocketSurfaceAppId();
        if (appId is null) { return PocketAppStateTransitionLease.Noop(string.Empty); }
        var begin = _pocketAppStateTransitionBegin;
        if (begin is null) { return PocketAppStateTransitionLease.Noop(appId); }
        try
        {
            return await begin(appId, cancellationToken);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch
        {
            return PocketAppStateTransitionLease.Failed(appId);
        }
    }

    private async Task CompletePocketAppStateTransitionAsync(PocketAppStateTransitionLease? lease)
    {
        var complete = _pocketAppStateTransitionComplete;
        if (lease is null || complete is null) { return; }
        try
        {
            await complete(lease);
        }
        catch
        {
        }
    }

    private static object? DeserializeObject(JsonElement? parameters)
    {
        if (parameters is null)
        {
            return null;
        }

        return JsonSerializer.Deserialize<object>(parameters.Value.GetRawText(), BridgeJson.Options);
    }

    private static string ReadRequiredString(JsonElement? parameters, string propertyName)
    {
        if (parameters is null
            || !parameters.Value.TryGetProperty(propertyName, out var property)
            || property.ValueKind != JsonValueKind.String)
        {
            throw new InvalidOperationException($"Missing string parameter: {propertyName}");
        }

        return property.GetString() ?? string.Empty;
    }

    private static bool ReadRequiredBool(JsonElement? parameters, string propertyName)
    {
        if (parameters is null
            || !parameters.Value.TryGetProperty(propertyName, out var property)
            || property.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
        {
            throw new InvalidOperationException($"Missing bool parameter: {propertyName}");
        }

        return property.GetBoolean();
    }

    private static int ReadRequiredInt(JsonElement? parameters, string propertyName)
    {
        if (parameters is null
            || !parameters.Value.TryGetProperty(propertyName, out var property)
            || property.ValueKind != JsonValueKind.Number
            || !property.TryGetInt32(out var value)
            || value <= 0)
        {
            throw new InvalidOperationException($"Missing integer parameter: {propertyName}");
        }
        return value;
    }

    private static List<string> ReadRequiredStringArray(JsonElement? parameters, string propertyName)
    {
        if (parameters is null
            || !parameters.Value.TryGetProperty(propertyName, out var property)
            || property.ValueKind != JsonValueKind.Array)
        {
            throw new InvalidOperationException($"Missing string array parameter: {propertyName}");
        }

        return property.EnumerateArray()
            .Where(item => item.ValueKind == JsonValueKind.String)
            .Select(item => item.GetString() ?? string.Empty)
            .Where(value => !string.IsNullOrWhiteSpace(value))
            .ToList();
    }

    private static PanelSize ParsePanelSize(string value)
    {
        return value.ToLowerInvariant() switch
        {
            "small" => PanelSize.Small,
            "large" => PanelSize.Large,
            _ => PanelSize.Medium
        };
    }

    private static DisplayPlacement ParseDisplayPlacement(string value)
    {
        return value.ToLowerInvariant() switch
        {
            "sub" => DisplayPlacement.Sub,
            "all" => DisplayPlacement.All,
            _ => DisplayPlacement.Main
        };
    }

    private static HandleIconStyle ParseHandleIcon(string value)
    {
        return value.ToLowerInvariant() switch
        {
            "c" => HandleIconStyle.C,
            "none" => HandleIconStyle.None,
            _ => HandleIconStyle.B
        };
    }

    private static ProviderSwitchingMode ParseSwitchingMode(string value)
    {
        return value.Equals("hover", StringComparison.OrdinalIgnoreCase)
            ? ProviderSwitchingMode.Hover
            : ProviderSwitchingMode.Click;
    }

    private static PanelTextSize ParseTextSize(string value)
    {
        return value.ToLowerInvariant() switch
        {
            "small" => PanelTextSize.Small,
            "large" => PanelTextSize.Large,
            _ => PanelTextSize.Medium
        };
    }

    private static AppLanguage ParseLanguage(string value)
    {
        return value.Equals("en", StringComparison.OrdinalIgnoreCase)
            ? AppLanguage.English
            : AppLanguage.Japanese;
    }

    private static VoiceLaneLayoutPreference ParseVoiceLaneLayout(string value)
    {
        return value.Equals("expanded", StringComparison.OrdinalIgnoreCase)
            ? VoiceLaneLayoutPreference.Expanded
            : VoiceLaneLayoutPreference.Compact;
    }

    private bool IsStartupRegistered()
    {
        try
        {
            return _startupRegistration.IsRegistered();
        }
        catch (UnauthorizedAccessException)
        {
            return CurrentSettings.StartWithWindows;
        }
        catch (InvalidOperationException)
        {
            return CurrentSettings.StartWithWindows;
        }
    }

    private void OnTimerAlertFired(object? sender, TimerAlert alert)
    {
        _ = sender;
        TimerAlertFired?.Invoke(this, alert);
    }

    private void OnTimerAlertChanged(object? sender, TimerAlert? alert)
    {
        _ = sender;
        TimerAlertChanged?.Invoke(this, alert);
    }

    private void OnClipboardExternalDragStarted(object? sender, EventArgs e)
    {
        _ = sender;
        _ = e;
        ExternalDragStarted?.Invoke(this, EventArgs.Empty);
    }

    private static string ToWireValue(PanelSize panelSize)
    {
        return panelSize switch
        {
            PanelSize.Small => "small",
            PanelSize.Large => "large",
            _ => "medium"
        };
    }

    private static string ToWireValue(DisplayPlacement placement)
    {
        return placement switch
        {
            DisplayPlacement.Sub => "sub",
            DisplayPlacement.All => "all",
            _ => "main"
        };
    }

    private static string ToWireValue(HandleIconStyle style)
    {
        return style switch
        {
            HandleIconStyle.C => "c",
            HandleIconStyle.None => "none",
            _ => "b"
        };
    }

    private static string ToWireValue(PanelTextSize textSize)
    {
        return textSize switch
        {
            PanelTextSize.Small => "small",
            PanelTextSize.Large => "large",
            _ => "medium"
        };
    }

    private static string ToWireValue(ProviderSwitchingMode switchingMode)
    {
        return switchingMode == ProviderSwitchingMode.Hover ? "hover" : "click";
    }

    private static string ToWireValue(AppLanguage language)
    {
        return language == AppLanguage.English ? "en" : "ja";
    }

    private static string ToWireValue(VoiceLaneLayoutPreference layout)
    {
        return layout == VoiceLaneLayoutPreference.Expanded ? "expanded" : "compact";
    }

    private static string ToWireValue(VoiceLaneMode mode)
    {
        return mode switch
        {
            VoiceLaneMode.Compact => "compact",
            VoiceLaneMode.Expanded => "expanded",
            _ => "disabled"
        };
    }

    internal static string ToVoiceAvailabilityWireValue(CodexVoiceAvailability availability) =>
        availability switch
        {
            CodexVoiceAvailability.Disabled => "disabled",
            CodexVoiceAvailability.Ready => "ready",
            CodexVoiceAvailability.Unavailable => "unavailable",
            CodexVoiceAvailability.SignedOut => "signedOut",
            CodexVoiceAvailability.SchemaMismatch => "schemaMismatch",
            CodexVoiceAvailability.CapabilityBlocked => "capabilityBlocked",
            _ => "unavailable"
        };

    private static string ToWireValue(CodexVoiceSessionStatus status) =>
        status switch
        {
            CodexVoiceSessionStatus.RequestingPermission => "requesting_permission",
            CodexVoiceSessionStatus.RecoverableFailure => "recoverable_failure",
            CodexVoiceSessionStatus.BlockedFailure => "blocked_failure",
            _ => status.ToString().ToLowerInvariant()
        };

    private static string ToWireValue(VoiceActivity activity) =>
        activity == VoiceActivity.WaitingForApproval
            ? "waiting_for_approval"
            : activity.ToString().ToLowerInvariant();

    private static string ToWireValue(AgentSessionStatus status) =>
        status == AgentSessionStatus.WaitingForUser
            ? "waiting_for_user"
            : status.ToString().ToLowerInvariant();

    private string ProviderText(ProviderDescriptor provider, ProviderTextKind kind)
    {
        if (CurrentSettings.Language == AppLanguage.English)
        {
            return kind switch
            {
                ProviderTextKind.Summary => provider.Summary,
                ProviderTextKind.Body => provider.Body,
                _ => provider.Title
            };
        }

        return (provider.Id.ToLowerInvariant(), kind) switch
        {
            ("controls", ProviderTextKind.Title) => "コントロール",
            ("controls", ProviderTextKind.Summary) => "ディスプレイ・音量・メディア",
            ("controls", ProviderTextKind.Body) => "明るさ、音量、ミュート、再生中のメディアを操作します。",
            ("calculator", ProviderTextKind.Title) => "電卓",
            ("calculator", ProviderTextKind.Summary) => "履歴付き電卓",
            ("calculator", ProviderTextKind.Body) => "四則演算、履歴、キーボード入力、コピーに対応しています。",
            ("calendar", ProviderTextKind.Title) => "カレンダー",
            ("calendar", ProviderTextKind.Summary) => "Google カレンダー",
            ("calendar", ProviderTextKind.Body) => "月間予定の確認と予定の追加・編集・削除ができます。",
            ("today-focus", ProviderTextKind.Title) => "Today Focus",
            ("today-focus", ProviderTextKind.Summary) => "今日の予定に集中",
            ("today-focus", ProviderTextKind.Body) => "予定を選び、タイマーと今日の目的をまとめて開始します。",
            ("clipboard", ProviderTextKind.Title) => "クリップボード",
            ("clipboard", ProviderTextKind.Summary) => "クリップボード履歴",
            ("clipboard", ProviderTextKind.Body) => "テキストと画像の履歴を確認し、お気に入り、全体プレビュー、コピー、個別削除を行えます。",
            ("sticky", ProviderTextKind.Title) => "付箋",
            ("sticky", ProviderTextKind.Summary) => "付箋ボード",
            ("sticky", ProviderTextKind.Body) => "付箋の作成、編集、色分け、並び替え、アーカイブができます。",
            ("timer", ProviderTextKind.Title) => "タイマー",
            ("timer", ProviderTextKind.Summary) => "タイマーとポモドーロ",
            ("timer", ProviderTextKind.Body) => "タイマーの同時実行、プリセット、休止、再開に対応しています。",
            _ => kind switch
            {
                ProviderTextKind.Summary => provider.Summary,
                ProviderTextKind.Body => provider.Body,
                _ => provider.Title
            }
        };
    }

    private enum ProviderTextKind
    {
        Title,
        Summary,
        Body
    }

    private sealed class BridgeAttachment : IDisposable
    {
        private readonly Action _dispose;
        private bool _disposed;

        public BridgeAttachment(Action dispose)
        {
            _dispose = dispose;
        }

        public void Dispose()
        {
            if (_disposed)
            {
                return;
            }

            _disposed = true;
            _dispose();
        }
    }
}
