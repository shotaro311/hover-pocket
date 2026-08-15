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
using HoverPocket.Shell.Providers.CodexVoice;
using HoverPocket.Shell.Providers.Sticky;
using HoverPocket.Shell.Providers.Timer;
using HoverPocket.Shell.Services;
using HoverPocket.Shell.Settings;

namespace HoverPocket.Shell.Bridge;

internal sealed class PanelBridgeController : IDisposable
{
    private readonly ProviderRegistry _providerRegistry;
    private readonly HoverPocketApplicationData _applicationData;
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
    private readonly CodexVoiceRuntimeHost _codexVoiceRuntime;
    private readonly CodexVoiceE2EReceiptStore? _voiceE2EReceipt;
    private readonly List<BridgeDispatcher> _dispatchers = [];
    private readonly object _previewFrameSync = new();
    private string _selectedProviderId;
    private VoiceLaneLayoutState _resolvedVoiceLaneLayout;
    private MediaPreviewFrame? _pendingPreviewFrame;
    private bool _previewPostScheduled;
    private bool _panelOpen;
    private bool _disposed;
    private long _codexVoiceAuthorizationEpoch = 1;
    private int _codexVoiceAuthorizationAllowed;

    public PanelBridgeController(
        ProviderRegistry providerRegistry,
        UserSettingsStore settingsStore,
        UserSettings settings,
        IStartupRegistrationService? startupRegistration = null,
        AiLaneController? aiLaneController = null,
        UpdaterService? updaterService = null,
        Func<CancellationToken, Task<CodexAppServerClient>>? codexVoiceClientFactory = null,
        HoverPocketApplicationData? applicationData = null,
        CodexVoiceE2EReceiptStore? voiceE2EReceipt = null)
    {
        _providerRegistry = providerRegistry;
        _applicationData = applicationData
            ?? HoverPocketApplicationData.ForRoot(settingsStore.RootDirectory);
        _settingsStore = settingsStore;
        _startupRegistration = startupRegistration
            ?? (_applicationData.ExternalIntegrationsEnabled
                ? new RunKeyStartupRegistrationService()
                : new InMemoryStartupRegistrationService());
        _updaterService = updaterService
            ?? new UpdaterService(_applicationData.ExternalIntegrationsEnabled);
        _calendarBridgeController = new CalendarBridgeController(
            new CalendarStore(
                new GoogleOAuthService(enabled: _applicationData.ExternalIntegrationsEnabled)));
        CurrentSettings = UserSettingsStore.Normalize(settings, providerRegistry.ProviderIds);
        _aiLaneController = aiLaneController ?? new AiLaneController(
            new AiLaneAuditLog(_applicationData.AiLaneRootDirectory),
            new CalendarAiLaneConnector(_calendarBridgeController.Store));
        var stickyStore = new StickyNotesStore(_applicationData.StickyDirectory);
        var timerStore = new TimerStore(_applicationData.TimerDirectory);
        _stickyBridgeController = new StickyBridgeController(stickyStore);
        _timerBridgeHandlers = new TimerBridgeHandlers(timerStore);
        _capabilityHandlers = ProviderCapabilityCompositionRoot.Create(
            new GoogleCalendarCapabilityDataSource(_calendarBridgeController.Store),
            timerStore,
            stickyStore);
        _timerBridgeHandlers.AlertFired += OnTimerAlertFired;
        _timerBridgeHandlers.AlertChanged += OnTimerAlertChanged;
        _resolvedVoiceLaneLayout = CurrentSettings.EffectiveVoiceLaneLayout;
        if (CurrentSettings.AiNativeEnabled)
        {
            try
            {
                var brokerRoot = _applicationData.CapabilityBrokerDirectory;
                _capabilityBroker = new CapabilityBroker(
                    new CapabilityRegistry(_capabilityHandlers),
                    new CapabilityBrokerLedger(brokerRoot),
                    new CapabilityBrokerAuditLog(brokerRoot));
                _todayFocusTextAdapter = new TodayFocusTextAdapter(_capabilityBroker);
            }
            catch (CapabilityBrokerException)
            {
                _capabilityBroker = null;
                _todayFocusTextAdapter = null;
            }
        }
        var voiceToolAdapter = _capabilityBroker is not null && _todayFocusTextAdapter is not null
            ? new CodexVoiceCapabilityToolAdapter(
                _capabilityBroker,
                _todayFocusTextAdapter,
                RequestCodexVoiceCapabilityApprovalAsync,
                GetCodexVoiceToolAuthorization,
                () => CurrentSettings.CodexVoiceCalendarReadEnabled
                    && _applicationData.ExternalIntegrationsEnabled)
            : null;
        _voiceE2EReceipt = voiceE2EReceipt;
        _codexVoiceRuntime = new CodexVoiceRuntimeHost(
            CurrentSettings.CodexVoiceEnabled,
            _applicationData.VoiceWorkspaceDirectory,
            clientFactory: codexVoiceClientFactory,
            toolAdapter: voiceToolAdapter);
        _codexVoiceRuntime.SnapshotChanged += OnCodexVoiceSnapshotChanged;
        _clipboardBridgeController = new ClipboardBridgeController(
            new ClipboardHistoryStore(_applicationData.ClipboardDirectory),
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

    public IDisposable Attach(BridgeDispatcher dispatcher)
    {
        _dispatchers.Add(dispatcher);
        dispatcher.Register("app.getState", (_, _) => Task.FromResult<object?>(BuildState()));
        dispatcher.Register("app.ready", (_, _) => Task.FromResult<object?>(new { ok = true }));
        dispatcher.Register("diagnostics.echo", (parameters, _) => Task.FromResult<object?>(DeserializeObject(parameters)));
        dispatcher.Register("provider.select", SelectProviderAsync);
        dispatcher.Register("provider.refreshPlaceholder", RefreshPlaceholderAsync);
        dispatcher.Register("settings.setPanelSize", SetPanelSizeAsync);
        dispatcher.Register("settings.setDisplayPlacement", SetDisplayPlacementAsync);
        dispatcher.Register("settings.setTextSize", SetTextSizeAsync);
        dispatcher.Register("settings.setSwitchingMode", SetSwitchingModeAsync);
        dispatcher.Register("settings.setLanguage", SetLanguageAsync);
        dispatcher.Register("settings.setProviderVisibility", SetProviderVisibilityAsync);
        dispatcher.Register("settings.moveProvider", MoveProviderAsync);
        dispatcher.Register("settings.setProviderOrder", SetProviderOrderAsync);
        dispatcher.Register("settings.setProviderSelection", SetProviderSelectionAsync);
        dispatcher.Register("settings.setPreferredProvider", SetPreferredProviderAsync);
        dispatcher.Register("settings.setHandleIcon", SetHandleIconAsync);
        dispatcher.Register("settings.setShowTopHandleSideArea", SetShowTopHandleSideAreaAsync);
        dispatcher.Register("settings.setDisableTopEdgeInFullscreen", SetDisableTopEdgeInFullscreenAsync);
        dispatcher.Register("settings.setStartWithWindows", SetStartWithWindowsAsync);
        dispatcher.Register("settings.setAutoCheckForUpdates", SetAutoCheckForUpdatesAsync);
        dispatcher.Register("settings.setClipboardPrivateMode", SetClipboardPrivateModeAsync);
        dispatcher.Register("settings.setCodexVoiceEnabled", SetCodexVoiceEnabledAsync);
        dispatcher.Register("settings.setCodexVoiceLayout", SetCodexVoiceLayoutAsync);
        dispatcher.Register("settings.setCodexVoiceAutoListen", SetCodexVoiceAutoListenAsync);
        dispatcher.Register("settings.setCodexVoiceCalendarReadEnabled", SetCodexVoiceCalendarReadEnabledAsync);
        dispatcher.Register("codexVoice.mediaEvent", RecordCodexVoiceMediaEventAsync);
        dispatcher.Register("codexVoice.setMuted", SetCodexVoiceMutedAsync);
        dispatcher.Register("codexVoice.startWebRtc", StartCodexVoiceWebRtcAsync);
        dispatcher.Register("codexVoice.transportAttached", AttachCodexVoiceTransportAsync);
        dispatcher.Register("codexVoice.transportDetached", DetachCodexVoiceTransportAsync);
        dispatcher.Register("codexVoice.startFailed", FailCodexVoiceStartAsync);
        dispatcher.Register("codexVoice.stop", StopCodexVoiceAsync);
        dispatcher.Register("settings.resetDefaults", ResetDefaultsAsync);
        dispatcher.Register("settings.resetPanelBinding", ResetPanelBindingAsync);
        dispatcher.Register("settings.openDataFolder", OpenDataFolderAsync);
        dispatcher.Register("settings.open", OpenSettingsAsync);
        dispatcher.Register("settings.openPlaceholder", OpenSettingsAsync);
        dispatcher.Register("updates.check", CheckForUpdatesAsync);
        dispatcher.Register("ailane.submit", SubmitAiLaneAsync);
        dispatcher.Register("ailane.approve", ApproveAiLaneAsync);
        dispatcher.Register("ailane.reject", RejectAiLaneAsync);
        dispatcher.Register("todayFocus.startFromCalendar", StartTodayFocusFromCalendarAsync);
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
        InvalidateCodexVoiceAuthorization(allowed: false);
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
        _codexVoiceRuntime.SnapshotChanged -= OnCodexVoiceSnapshotChanged;
        _voiceE2EReceipt?.RecordMediaEvent(CodexVoiceMediaEventKind.SafeClose);
        _codexVoiceRuntime.DisposeAsync().AsTask().GetAwaiter().GetResult();
        _voiceE2EReceipt?.RecordSnapshot(_codexVoiceRuntime.Snapshot);
    }

    public object BuildState()
    {
        var orderedProviders = OrderedProviders().ToArray();
        var selected = orderedProviders.FirstOrDefault(provider => string.Equals(provider.Id, _selectedProviderId, StringComparison.OrdinalIgnoreCase))
            ?? orderedProviders.FirstOrDefault();

        if (selected is not null)
        {
            _selectedProviderId = selected.Id;
        }

        var metrics = PanelSizeCatalog.Get(
            CurrentSettings.PanelSize,
            _resolvedVoiceLaneLayout);
        var voiceSnapshot = _codexVoiceRuntime.Snapshot;
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
                codexVoiceEnabled = CurrentSettings.CodexVoiceEnabled,
                codexVoiceLayoutMode = ToWireValue(CurrentSettings.CodexVoiceLayoutMode),
                codexVoiceAutoListen = CurrentSettings.CodexVoiceAutoListen,
                codexVoiceCalendarReadEnabled = CurrentSettings.CodexVoiceCalendarReadEnabled,
                providerOrder = CurrentSettings.ProviderOrder,
                providerVisibility = CurrentSettings.ProviderVisibility
            },
            updater = _updaterService.Snapshot,
            panel = new
            {
                headerHeight = PanelSizeCatalog.HeaderHeight,
                aiLaneHeight = PanelSizeCatalog.AiLaneHeight,
                voiceLaneHeight = metrics.AiLaneHeight,
                voiceLaneLayout = ToWireValue(_resolvedVoiceLaneLayout),
                width = metrics.Width,
                providerHeight = metrics.ProviderHeight,
                totalHeight = metrics.TotalHeight,
                sizes = PanelSizeCatalog.GetAll(_resolvedVoiceLaneLayout).Select(size => new
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
            allProviders = _providerRegistry.Providers.Select(provider => new
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
            voiceLane = new
            {
                layout = ToWireValue(_resolvedVoiceLaneLayout),
                expansionBlocked = CurrentSettings.EffectiveVoiceLaneLayout.IsExpanded
                    && !_resolvedVoiceLaneLayout.IsExpanded,
                status = ToWireValue(voiceSnapshot.Availability, voiceSnapshot.SessionStatus),
                availability = ToWireValue(voiceSnapshot.Availability),
                sessionStatus = ToWireValue(voiceSnapshot.SessionStatus),
                isSessionActive = IsSessionActive(voiceSnapshot.SessionStatus),
                isMuted = voiceSnapshot.IsMuted,
                rootThreadId = voiceSnapshot.RootThreadId,
                transcript = voiceSnapshot.Transcript.Select(entry => new
                {
                    threadId = entry.ThreadId,
                    role = entry.Role,
                    text = entry.Text,
                    isComplete = entry.IsComplete,
                    updatedAt = entry.UpdatedAt
                }).ToArray(),
                sessions = voiceSnapshot.Sessions.Select(session =>
                {
                    var end = session.State == CodexVoiceThreadState.Running
                        ? DateTimeOffset.UtcNow
                        : session.UpdatedAt;
                    var elapsed = Math.Clamp(
                        (long)Math.Floor((end - session.CreatedAt).TotalSeconds),
                        0,
                        int.MaxValue);
                    return new
                    {
                        id = session.IsCurrentRoot
                            ? $"root:{session.ThreadId}"
                            : $"thread:{session.ThreadId}",
                        title = session.IsCurrentRoot
                            ? (CurrentSettings.Language == AppLanguage.Japanese
                                ? "この会話"
                                : "This conversation")
                            : session.Title,
                        detail = session.IsCurrentRoot
                            ? ToWireValue(voiceSnapshot.SessionStatus)
                            : session.Detail,
                        state = ToWireValue(session.State),
                        elapsedSeconds = (int)elapsed
                    };
                }).ToArray(),
                lastErrorCode = voiceSnapshot.LastErrorCode,
                restartAttempt = voiceSnapshot.RestartAttempt,
                availableVoiceCount = voiceSnapshot.VoiceCount
            }
        };
    }

    private async Task<object?> SelectProviderAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        var providerId = ReadRequiredString(parameters, "id");
        var provider = _providerRegistry.Find(providerId);
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
        if (_providerRegistry.Find(providerId) is null)
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
        var provider = _providerRegistry.Find(providerId);
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

    private async Task<object?> SetCodexVoiceEnabledAsync(
        JsonElement? parameters,
        CancellationToken cancellationToken)
    {
        var enabled = ReadRequiredBool(parameters, "enabled");
        if (CurrentSettings.CodexVoiceEnabled != enabled)
        {
            var updated = CurrentSettings.Clone();
            updated.CodexVoiceEnabled = enabled;
            SaveSettings(updated);
        }

        if (!enabled)
        {
            _voiceE2EReceipt?.RecordMediaEvent(CodexVoiceMediaEventKind.SafeClose);
        }

        await _codexVoiceRuntime.SetEnabledAsync(enabled, cancellationToken);

        return await PublishStateAsync(cancellationToken);
    }

    private async Task<bool> RequestCodexVoiceCapabilityApprovalAsync(
        CodexVoiceCapabilityApproval approval,
        CancellationToken cancellationToken)
    {
        var dispatcher = System.Windows.Application.Current?.Dispatcher;
        if (dispatcher is null)
        {
            return false;
        }

        var operation = dispatcher.InvokeAsync(() =>
        {
            var expectedAuthorization = GetCodexVoiceToolAuthorization();
            if (!expectedAuthorization.IsAllowed)
            {
                return false;
            }

            var english = CurrentSettings.Language == AppLanguage.English;
            var title = approval.ToolName switch
            {
                CodexVoiceCapabilityToolAdapter.TimerStartTool => english ? "Approve Timer" : "Timerを承認",
                CodexVoiceCapabilityToolAdapter.CalendarCreateTool => english ? "Approve Calendar event" : "カレンダー予定を承認",
                CodexVoiceCapabilityToolAdapter.TodayFocusTool => english ? "Approve Today Focus" : "Today Focusを承認",
                _ => english ? "Approve HoverPocket action" : "HoverPocket操作を承認"
            };
            var fieldLines = approval.Fields.Select(field =>
            {
                var label = (field.Key, english) switch
                {
                    ("title", true) => "Title",
                    ("title", false) => "タイトル",
                    ("durationSeconds", true) => "Duration (seconds)",
                    ("durationSeconds", false) => "時間（秒）",
                    ("start", true) => "Start",
                    ("start", false) => "開始",
                    ("end", true) => "End",
                    ("end", false) => "終了",
                    ("isAllDay", true) => "All day",
                    ("isAllDay", false) => "終日",
                    ("event", true) => "Calendar event",
                    ("event", false) => "予定",
                    ("purpose", true) => "Purpose",
                    ("purpose", false) => "今日の目的",
                    _ => field.Key
                };
                return $"{label}: {field.Value}";
            });
            var message = string.Join(Environment.NewLine, fieldLines)
                + Environment.NewLine
                + Environment.NewLine
                + (english
                    ? "Allow Codex to perform this action through HoverPocket?"
                    : "CodexがHoverPocketでこの操作を実行することを許可しますか？");
            var result = System.Windows.MessageBox.Show(
                message,
                title,
                System.Windows.MessageBoxButton.YesNo,
                System.Windows.MessageBoxImage.Question,
                System.Windows.MessageBoxResult.No);
            var currentAuthorization = GetCodexVoiceToolAuthorization();
            return result == System.Windows.MessageBoxResult.Yes
                && currentAuthorization.IsAllowed
                && currentAuthorization.Epoch == expectedAuthorization.Epoch;
        });
        return await operation.Task.WaitAsync(cancellationToken);
    }

    private async Task<object?> SetCodexVoiceLayoutAsync(
        JsonElement? parameters,
        CancellationToken cancellationToken)
    {
        var layout = ParseVoiceLaneLayoutMode(ReadRequiredString(parameters, "layout"));
        if (CurrentSettings.CodexVoiceLayoutMode != layout)
        {
            var updated = CurrentSettings.Clone();
            updated.CodexVoiceLayoutMode = layout;
            SaveSettings(updated);
        }

        return await PublishStateAsync(cancellationToken);
    }

    private async Task<object?> SetCodexVoiceAutoListenAsync(
        JsonElement? parameters,
        CancellationToken cancellationToken)
    {
        var enabled = ReadRequiredBool(parameters, "enabled");
        if (CurrentSettings.CodexVoiceAutoListen != enabled)
        {
            var updated = CurrentSettings.Clone();
            updated.CodexVoiceAutoListen = enabled;
            SaveSettings(updated);
        }

        return await PublishStateAsync(cancellationToken);
    }

    private async Task<object?> SetCodexVoiceCalendarReadEnabledAsync(
        JsonElement? parameters,
        CancellationToken cancellationToken)
    {
        var enabled = ReadRequiredBool(parameters, "enabled");
        if (CurrentSettings.CodexVoiceCalendarReadEnabled != enabled)
        {
            var updated = CurrentSettings.Clone();
            updated.CodexVoiceCalendarReadEnabled = enabled;
            SaveSettings(updated);
        }

        return await PublishStateAsync(cancellationToken);
    }

    private Task<object?> RecordCodexVoiceMediaEventAsync(
        JsonElement? parameters,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!CodexVoiceE2EReceiptStore.TryParseMediaEvent(
                ReadRequiredString(parameters, "kind"),
                out var eventKind))
        {
            throw new InvalidOperationException("Unknown Codex Voice media event.");
        }

        _voiceE2EReceipt?.RecordMediaEvent(eventKind);
        return Task.FromResult<object?>(new { recorded = _voiceE2EReceipt is not null });
    }

    private async Task<object?> SetCodexVoiceMutedAsync(
        JsonElement? parameters,
        CancellationToken cancellationToken)
    {
        var muted = ReadRequiredBool(parameters, "muted");
        _codexVoiceRuntime.SetMuted(muted);
        return await PublishStateAsync(cancellationToken);
    }

    private async Task<object?> StartCodexVoiceWebRtcAsync(
        JsonElement? parameters,
        CancellationToken cancellationToken)
    {
        if (!CurrentSettings.CodexVoiceEnabled)
        {
            throw new InvalidOperationException("Codex Voice is disabled.");
        }

        var answer = await _codexVoiceRuntime.StartWebRtcAsync(
            ReadRequiredString(parameters, "sdp"),
            cancellationToken);
        return new
        {
            rootThreadId = answer.RootThreadId,
            sdp = answer.Sdp
        };
    }

    private async Task<object?> AttachCodexVoiceTransportAsync(
        JsonElement? parameters,
        CancellationToken cancellationToken)
    {
        _ = parameters;
        cancellationToken.ThrowIfCancellationRequested();
        _codexVoiceRuntime.MarkTransportAttached();
        _voiceE2EReceipt?.RecordMediaEvent(CodexVoiceMediaEventKind.TransportAttached);
        return await PublishStateAsync(cancellationToken);
    }

    private async Task<object?> DetachCodexVoiceTransportAsync(
        JsonElement? parameters,
        CancellationToken cancellationToken)
    {
        var reconnectExpected = ReadRequiredBool(parameters, "reconnectExpected");
        _codexVoiceRuntime.MarkTransportDetached(reconnectExpected);
        _voiceE2EReceipt?.RecordMediaEvent(CodexVoiceMediaEventKind.TransportDetached);
        return await PublishStateAsync(cancellationToken);
    }

    private async Task<object?> StopCodexVoiceAsync(
        JsonElement? parameters,
        CancellationToken cancellationToken)
    {
        _ = parameters;
        await _codexVoiceRuntime.StopRealtimeAsync(cancellationToken);
        _voiceE2EReceipt?.RecordMediaEvent(CodexVoiceMediaEventKind.SafeClose);
        return await PublishStateAsync(cancellationToken);
    }

    private async Task<object?> FailCodexVoiceStartAsync(
        JsonElement? parameters,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        _codexVoiceRuntime.MarkSessionFailure(
            ReadRequiredString(parameters, "errorCode"));
        return await PublishStateAsync(cancellationToken);
    }

    private async Task<object?> ResetDefaultsAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        _ = parameters;
        _startupRegistration.SetRegistered(false);
        var defaults = _settingsStore.CreateDefaultForContext(_providerRegistry.ProviderIds);
        SaveSettings(defaults);
        await _codexVoiceRuntime.SetEnabledAsync(defaults.CodexVoiceEnabled, cancellationToken);
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
            || _todayFocusTextAdapter is null)
        {
            throw new CapabilityBrokerException("CAPABILITY_UNAVAILABLE", "today_focus");
        }

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
            cancellationToken);
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
        cancellationToken.ThrowIfCancellationRequested();
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
            cancellationToken);
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

    public Task StartVoiceRuntimeAsync(CancellationToken cancellationToken = default)
    {
        return _codexVoiceRuntime.StartAsync(cancellationToken);
    }

    public void MarkVoiceMicrophoneRequestStarted()
    {
        if (CurrentSettings.CodexVoiceEnabled)
        {
            _codexVoiceRuntime.MarkSessionRequestingPermission();
        }
    }

    public async Task NotifyPanelOpenedAsync()
    {
        _panelOpen = true;
        InvalidateCodexVoiceAuthorization(
            CurrentSettings.AiNativeEnabled && CurrentSettings.CodexVoiceEnabled);
        if (!CurrentSettings.RememberLastSelectedProvider)
        {
            _selectedProviderId = ResolvePreferredProviderId();
        }

        var state = BuildState();
        await SynchronizeControlsLifecycleAsync();
        await PostEventAsync("panel.opened", state);
    }

    public async Task NotifyPanelClosedAsync()
    {
        _panelOpen = false;
        InvalidateCodexVoiceAuthorization(allowed: false);
        _codexVoiceRuntime.ClearTransientUiState();
        _voiceE2EReceipt?.RecordMediaEvent(CodexVoiceMediaEventKind.SafeClose);
        await SynchronizeControlsLifecycleAsync();
        await PostEventAsync("panel.closed", new { closed = true });
    }

    public async Task SelectProviderFromShellAsync(string providerId, CancellationToken cancellationToken = default)
    {
        var provider = _providerRegistry.Find(providerId);
        if (provider is null || !IsVisible(provider.Id))
        {
            return;
        }

        _selectedProviderId = provider.Id;
        PersistLastSelectedProvider(provider.Id);
        await PublishStateAsync(cancellationToken);
    }

    public async Task ApplyResolvedVoiceLaneLayoutAsync(
        VoiceLaneLayoutState layout,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (_resolvedVoiceLaneLayout == layout)
        {
            return;
        }

        _resolvedVoiceLaneLayout = layout;
        await PostEventAsync("state.changed", BuildState());
    }

    private void SaveSettings(UserSettings settings)
    {
        var normalized = UserSettingsStore.Normalize(settings, _providerRegistry.ProviderIds);
        var authorizationChanged = normalized.AiNativeEnabled != CurrentSettings.AiNativeEnabled
            || normalized.CodexVoiceEnabled != CurrentSettings.CodexVoiceEnabled
            || normalized.CodexVoiceCalendarReadEnabled != CurrentSettings.CodexVoiceCalendarReadEnabled;
        if (authorizationChanged)
        {
            Volatile.Write(ref _codexVoiceAuthorizationAllowed, 0);
            Interlocked.Increment(ref _codexVoiceAuthorizationEpoch);
        }

        CurrentSettings = normalized;
        if (authorizationChanged)
        {
            Volatile.Write(
                ref _codexVoiceAuthorizationAllowed,
                !_disposed
                    && _panelOpen
                    && CurrentSettings.AiNativeEnabled
                    && CurrentSettings.CodexVoiceEnabled
                    ? 1
                    : 0);
        }
        _resolvedVoiceLaneLayout = CurrentSettings.EffectiveVoiceLaneLayout;
        _clipboardBridgeController.ApplySettings(CurrentSettings, IsVisible("clipboard"));
        _settingsStore.Save(CurrentSettings);
        SettingsChanged?.Invoke(this, CurrentSettings);
    }

    private CodexVoiceToolAuthorization GetCodexVoiceToolAuthorization()
    {
        return new CodexVoiceToolAuthorization(
            Volatile.Read(ref _codexVoiceAuthorizationAllowed) != 0,
            Interlocked.Read(ref _codexVoiceAuthorizationEpoch));
    }

    private void InvalidateCodexVoiceAuthorization(bool allowed)
    {
        Volatile.Write(ref _codexVoiceAuthorizationAllowed, 0);
        Interlocked.Increment(ref _codexVoiceAuthorizationEpoch);
        Volatile.Write(
            ref _codexVoiceAuthorizationAllowed,
            allowed && !_disposed ? 1 : 0);
    }

    private async Task<object> PublishStateAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var state = BuildState();
        await SynchronizeControlsLifecycleAsync(cancellationToken);
        await PostEventAsync("state.changed", state);
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

    private void OnCodexVoiceSnapshotChanged(object? sender, CodexVoiceSnapshot snapshot)
    {
        _ = sender;
        _voiceE2EReceipt?.RecordSnapshot(snapshot);
        _ = PostEventOnUiThreadAsync("state.changed", BuildState());
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

    private async Task PostEventAsync(string eventName, object? payload)
    {
        foreach (var dispatcher in _dispatchers.ToArray())
        {
            await dispatcher.PostEventAsync(eventName, payload);
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
        foreach (var providerId in CurrentSettings.ProviderOrder)
        {
            var provider = _providerRegistry.Find(providerId);
            if (provider is not null && IsVisible(provider.Id))
            {
                yield return provider;
            }
        }
    }

    private bool IsVisible(string providerId)
    {
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
            && _providerRegistry.Find(providerId) is not null
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
        CurrentSettings = UserSettingsStore.Normalize(updated, _providerRegistry.ProviderIds);
        _settingsStore.Save(CurrentSettings);
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

    private static VoiceLaneLayoutMode ParseVoiceLaneLayoutMode(string value)
    {
        return value.Equals("expanded", StringComparison.OrdinalIgnoreCase)
            ? VoiceLaneLayoutMode.Expanded
            : VoiceLaneLayoutMode.Compact;
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

    private static string ToWireValue(VoiceLaneLayoutMode layout)
    {
        return layout switch
        {
            VoiceLaneLayoutMode.Expanded => "expanded",
            VoiceLaneLayoutMode.Compact => "compact",
            _ => "disabled"
        };
    }

    private static string ToWireValue(VoiceLaneLayoutState layout)
    {
        return ToWireValue(layout.Mode);
    }

    private static string ToWireValue(CodexVoiceAvailability availability)
    {
        return availability switch
        {
            CodexVoiceAvailability.Disabled => "disabled",
            CodexVoiceAvailability.Starting => "starting",
            CodexVoiceAvailability.Ready => "ready",
            CodexVoiceAvailability.SignedOut => "signedOut",
            CodexVoiceAvailability.Unavailable => "unavailable",
            CodexVoiceAvailability.Incompatible => "incompatible",
            CodexVoiceAvailability.Blocked => "blocked",
            _ => "faulted"
        };
    }

    private static string ToWireValue(CodexVoiceSessionStatus status)
    {
        return status switch
        {
            CodexVoiceSessionStatus.RequestingPermission => "requestingPermission",
            CodexVoiceSessionStatus.Negotiating => "negotiating",
            CodexVoiceSessionStatus.Connecting => "connecting",
            CodexVoiceSessionStatus.Connected => "connected",
            CodexVoiceSessionStatus.Muted => "muted",
            CodexVoiceSessionStatus.Reconnecting => "reconnecting",
            CodexVoiceSessionStatus.Stopping => "stopping",
            CodexVoiceSessionStatus.Closed => "closed",
            CodexVoiceSessionStatus.RecoverableFailure => "recoverableFailure",
            CodexVoiceSessionStatus.BlockedFailure => "blockedFailure",
            _ => "idle"
        };
    }

    private static string ToWireValue(CodexVoiceThreadState state)
    {
        return state switch
        {
            CodexVoiceThreadState.Completed => "completed",
            CodexVoiceThreadState.Failed => "failed",
            _ => "running"
        };
    }

    private static string ToWireValue(
        CodexVoiceAvailability availability,
        CodexVoiceSessionStatus status)
    {
        if (availability != CodexVoiceAvailability.Ready)
        {
            return ToWireValue(availability);
        }

        return ToWireValue(status);
    }

    private static bool IsSessionActive(CodexVoiceSessionStatus status)
    {
        return status is CodexVoiceSessionStatus.RequestingPermission
            or CodexVoiceSessionStatus.Negotiating
            or CodexVoiceSessionStatus.Connecting
            or CodexVoiceSessionStatus.Connected
            or CodexVoiceSessionStatus.Muted
            or CodexVoiceSessionStatus.Reconnecting
            or CodexVoiceSessionStatus.Stopping;
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
