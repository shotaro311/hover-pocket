using System.IO;
using System.Diagnostics;
using System.Text;
using System.Text.Json;
using HoverPocket.Shell.Capabilities;
using HoverPocket.Shell.Configuration;
using HoverPocket.Shell.Providers;
using HoverPocket.Shell.Providers.AiLane;
using HoverPocket.Shell.Providers.Calculator;
using HoverPocket.Shell.Providers.Calendar;
using HoverPocket.Shell.Providers.Clipboard;
using HoverPocket.Shell.Providers.Controls;
using HoverPocket.Shell.Providers.Sticky;
using HoverPocket.Shell.Providers.Timer;
using HoverPocket.Shell.PocketApps;
using HoverPocket.Shell.Services;
using HoverPocket.Shell.Settings;

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
    private readonly AiLaneController _aiLaneController;
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
    private readonly Dictionary<BridgeDispatcher, BridgeSurface> _dispatchers = [];
    private readonly AsyncLocal<BridgeSurface?> _requestSurface = new();
    private readonly object _previewFrameSync = new();
    private string _selectedProviderId;
    private MediaPreviewFrame? _pendingPreviewFrame;
    private bool _previewPostScheduled;
    private bool _panelOpen;
    private bool _disposed;

    public PanelBridgeController(
        ProviderRegistry providerRegistry,
        UserSettingsStore settingsStore,
        UserSettings settings,
        IStartupRegistrationService? startupRegistration = null,
        AiLaneController? aiLaneController = null,
        UpdaterService? updaterService = null)
    {
        _providerRegistry = providerRegistry;
        _settingsStore = settingsStore;
        _startupRegistration = startupRegistration ?? new RunKeyStartupRegistrationService();
        _updaterService = updaterService ?? new UpdaterService();
        _calendarBridgeController = new CalendarBridgeController();
        _aiLaneController = aiLaneController ?? new AiLaneController(
            new AiLaneAuditLog(settingsStore.RootDirectory),
            new CalendarAiLaneConnector(_calendarBridgeController.Store));
        var stickyStore = new StickyNotesStore(Path.Combine(settingsStore.RootDirectory, "sticky"));
        var timerStore = new TimerStore(Path.Combine(settingsStore.RootDirectory, "timer"));
        _stickyBridgeController = new StickyBridgeController(stickyStore);
        _timerBridgeHandlers = new TimerBridgeHandlers(timerStore);
        _capabilityHandlers = ProviderCapabilityCompositionRoot.Create(
            new GoogleCalendarCapabilityDataSource(_calendarBridgeController.Store),
            timerStore,
            stickyStore);
        _timerBridgeHandlers.AlertFired += OnTimerAlertFired;
        _timerBridgeHandlers.AlertChanged += OnTimerAlertChanged;
        CurrentSettings = UserSettingsStore.NormalizeForBootstrap(settings, providerRegistry.ProviderIds);
        _aiNativeExecutionLease = CurrentSettings.AiNativeEnabled
            ? new PocketAppActivationLease()
            : null;
        if (CurrentSettings.AiNativeEnabled)
        {
            try
            {
                var brokerRoot = Path.Combine(settingsStore.RootDirectory, "CapabilityBroker");
                _capabilityBroker = new CapabilityBroker(
                    new CapabilityRegistry(_capabilityHandlers),
                    new CapabilityBrokerLedger(brokerRoot),
                    new CapabilityBrokerAuditLog(brokerRoot));
                _todayFocusTextAdapter = new TodayFocusTextAdapter(_capabilityBroker);
                var packageRoot = Path.Combine(
                    AppContext.BaseDirectory,
                    "PocketApps",
                    "local.example.today-focus");
                var package = new PocketAppPackageRuntime().Load(packageRoot);
                var userStateStore = new PocketAppUserStateStore(
                    package.Manifest.Id,
                    package.StatePropertyNames,
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
                _capabilityBroker = null;
                _todayFocusTextAdapter = null;
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
                        postRefreshHook: () => _ = PostStateEventOnUiThreadAsync("state.changed"));
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
        CurrentSettings = UserSettingsStore.Normalize(CurrentSettings, AvailableProviderIds());
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

    public IDisposable Attach(
        BridgeDispatcher dispatcher,
        BridgeSurface surface = BridgeSurface.Panel,
        Func<System.Windows.Window?>? approvalOwner = null,
        Func<bool>? aiNativeEnableDecision = null)
    {
        _dispatchers[dispatcher] = surface;
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
        Register("ailane.submit", SubmitAiLaneAsync);
        Register("ailane.approve", ApproveAiLaneAsync);
        Register("ailane.reject", RejectAiLaneAsync);
        if (surface == BridgeSurface.Panel)
        {
            Register("provider.select", SelectProviderAsync);
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
        return new BridgeAttachment(() => _dispatchers.Remove(dispatcher));
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
        _aiNativeExecutionLease?.Invalidate();
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
                width = metrics.Width,
                providerHeight = metrics.ProviderHeight,
                totalHeight = metrics.TotalHeight,
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
            aiLane = _aiLaneController.CurrentState,
            pocketSurface = selectedPocketSurface,
            pocketApps = !builtInPocketAppAvailable || _pocketAppHostController is null
                ? Array.Empty<object>()
                : new[] { _pocketAppHostController.BuildManagerState() },
            pocketAppGeneration = includeGeneration && CurrentSettings.AiNativeEnabled
                ? _pocketAppGenerationController?.BuildState()
                : null
        };
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
        return await PublishStateAsync(cancellationToken);
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
        _startupRegistration.SetRegistered(false);
        _aiNativeExecutionLease?.Invalidate();
        _pocketAppGenerationController?.SetEnabled(false);
        _generatedPocketApps?.SetEnabled(false);
        SaveSettings(UserSettingsStore.CreateDefault(_providerRegistry.ProviderIds));
        return await PublishStateAsync(cancellationToken);
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

    private async Task<object?> SubmitAiLaneAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        await _aiLaneController.SubmitAsync(ReadRequiredString(parameters, "text"), cancellationToken);
        return await PublishStateAsync(cancellationToken);
    }

    private async Task<object?> ApproveAiLaneAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        await _aiLaneController.ApproveAsync(ReadRequiredString(parameters, "actionId"), cancellationToken);
        return await PublishStateAsync(cancellationToken);
    }

    private async Task<object?> RejectAiLaneAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        _aiLaneController.Reject(ReadRequiredString(parameters, "actionId"));
        return await PublishStateAsync(cancellationToken);
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

    private void SaveSettings(UserSettings settings)
    {
        CurrentSettings = UserSettingsStore.Normalize(settings, AvailableProviderIds());
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
        CurrentSettings = UserSettingsStore.Normalize(updated, AvailableProviderIds());
        _settingsStore.Save(CurrentSettings);
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
