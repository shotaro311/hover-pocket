using System.Windows;
using System.Windows.Media;
using System.Windows.Threading;
using System.IO;
using HoverPocket.Shell.Bridge;
using HoverPocket.Shell.Configuration;
using HoverPocket.Shell.Display;
using HoverPocket.Shell.Interop;
using HoverPocket.Shell.Providers;
using HoverPocket.Shell.Providers.Calendar;
using HoverPocket.Shell.Providers.Timer;
using HoverPocket.Shell.Services;
using HoverPocket.Shell.Settings;
using HoverPocket.Shell.Voice;
using Microsoft.Win32;
using System.Runtime.InteropServices;
using WinForms = System.Windows.Forms;
using WpfColor = System.Windows.Media.Color;

namespace HoverPocket.Shell.Windows;

internal sealed class HoverShellController : IDisposable
{
    public static readonly TimeSpan CloseDelay = TimeSpan.FromMilliseconds(60);
    public static readonly TimeSpan PollingInterval = TimeSpan.FromMilliseconds(120);
    internal static readonly TimeSpan AutoHidePollingInterval = TimeSpan.FromMilliseconds(30);
    public static readonly TimeSpan HealthCheckInterval = TimeSpan.FromSeconds(2);
    internal static readonly TimeSpan[] RecoveryDelays =
    [
        TimeSpan.Zero,
        TimeSpan.FromMilliseconds(450),
        TimeSpan.FromMilliseconds(1400)
    ];
    public const double HoverToleranceDips = 4;
    internal const double PeekSidePaddingDips = 80;
    internal const double PeekDepthDips = 72;

    private readonly Dispatcher _dispatcher;
    private readonly bool _enablePanelWebView;
    private readonly bool _enableDevTools;
    private readonly HoverPocketApplicationData _applicationData;
    private readonly PanelBridgeController _panelBridgeController;
    private readonly DisplayLayoutService _displayLayoutService = new();
    private readonly List<AccessSurfaceWindow> _accessSurfaces = [];
    private readonly Dictionary<AccessSurfaceWindow, DisplaySurfaceLayout> _surfaceLayouts = [];
    private readonly string? _hoverTracePath = NormalizeTracePath();
    private PanelWindow _panel;
    private readonly DispatcherTimer _pollingTimer;
    private readonly DispatcherTimer _closeDelayTimer;
    private readonly DispatcherTimer _healthTimer;
    private IReadOnlyList<DisplaySurfaceLayout> _layouts = [];
    private DisplaySurfaceLayout? _activeLayout;
    private TimerAlert? _activeTimerAlert;
    private SettingsWindow? _settingsWindow;
    private (int X, int Y)? _pointerOverrideForVerify;
    private Task? _closingTask;
    private Task<ShellHealthReport>? _healthRecoveryTask;
    private Task? _recoveryTask;
    private CancellationTokenSource? _recoveryCancellation;
    private UserSettings _lastAppliedSettings;
    private bool _systemEventsSubscribed;
    private bool _panelExpectedVisible;
    private bool _previewFocusDismissed;
    private AssetOrganizerWindow? _assetOrganizer;
    private CodexChatWindow? _chatWindow;
    private Task OpenChatAsync()
    {
        if (_chatWindow is null)
        {
            _chatWindow = new CodexChatWindow(_panelBridgeController.CreateChatCoordinator(),
                _panelBridgeController.CurrentSettings.Language == AppLanguage.English, _panelBridgeController.LoginChatAsync);
            _chatWindow.Closed += (_, _) => _chatWindow = null;
            _chatWindow.Show();
        }
        _chatWindow.Activate();
        return Task.CompletedTask;
    }
    private bool _assetDragActive;
    private int _assetDragRevision;
    private async void OnAssetDragChanged(bool active)
    {
        var revision = ++_assetDragRevision;
        _assetDragActive = active;
        if (active)
        {
            if (!_panelBridgeController.AssetsVisible) { _assetDragActive = false; return; }
            _closeDelayTimer.Stop(); await _panelBridgeController.BeginAssetDropAsync();
            await ShowPanelAsync(ResolveLayoutForPointer());
        }
        else
        {
            await Task.Delay(100);
            if (revision == _assetDragRevision && !_assetDragActive) await _panelBridgeController.CancelAssetDropAsync();
        }
    }
    public void OpenAssetLibraryFromUser()
    {
        if (_assetOrganizer is not null) { _assetOrganizer.Activate(); return; }
        _assetOrganizer = new AssetOrganizerWindow(_panelBridgeController, _applicationData.RootDirectory);
        _assetOrganizer.Closed += (_, _) => _assetOrganizer = null;
        _assetOrganizer.Show(); _assetOrganizer.Activate();
    }
    internal async Task<bool> OpenAssetLibraryForVoiceAsync(string? assetId, CancellationToken token)
    {
        if (_assetOrganizer is null)
        {
            _assetOrganizer = new AssetOrganizerWindow(_panelBridgeController, _applicationData.RootDirectory) { ShowActivated = false };
            _assetOrganizer.Closed += (_, _) => _assetOrganizer = null;
            _assetOrganizer.Show();
        }
        return await _assetOrganizer.ShowForVoiceAsync(assetId, token);
    }
    private bool _captureOrganizerVisible;
    private bool _captureSuppressed;
    internal async Task HideForCaptureAsync()
    {
        _captureSuppressed = true;
        _pollingTimer.Stop(); _healthTimer.Stop(); _closeDelayTimer.Stop();
        await HidePanelAsync();
        foreach (var surface in _accessSurfaces) surface.Hide();
        _captureOrganizerVisible = _assetOrganizer?.IsVisible == true; if (_captureOrganizerVisible) _assetOrganizer!.Hide();
    }
    internal void RestoreAfterCapture()
    { if (_disposed) return; _captureSuppressed = false; if (_captureOrganizerVisible) _assetOrganizer?.Show(); _captureOrganizerVisible = false; ResyncDisplayLayout(); _pollingTimer.Start(); _healthTimer.Start(); }
    private bool _timerAlertActive;
    private bool _disposed;
    private int _recoveryStageCountForVerify;
    private int _voiceTransitionCountForVerify;

    public HoverShellController(
        Dispatcher dispatcher,
        ShellSettings settings,
        ProviderRegistry providerRegistry,
        HoverPocketApplicationData applicationData,
        UserSettingsStore userSettingsStore,
        bool enablePanelWebView,
        bool enableDevTools,
        UpdaterService? updaterService = null,
        IOpenAIRealtimeCredentialStore? openAIRealtimeCredentialStore = null,
        CalendarStore? calendarStore = null,
        IStartupRegistrationService? startupRegistration = null,
        VoiceE2EReceiptStore? voiceE2EReceiptStore = null,
        UserSettings? isolatedVoiceE2EDefaults = null)
    {
        _dispatcher = dispatcher;
        _enablePanelWebView = enablePanelWebView;
        _enableDevTools = enableDevTools;
        _applicationData = applicationData;
        var userSettings = userSettingsStore.LoadForBootstrap(providerRegistry.ProviderIds);
        if (settings.DisplayPlacementOverride is { } displayPlacementOverride)
        {
            userSettings.DisplayPlacement = displayPlacementOverride;
        }

        _lastAppliedSettings = userSettings.Clone();
        _panelBridgeController = new PanelBridgeController(
            providerRegistry,
            userSettingsStore,
            userSettings,
            startupRegistration: startupRegistration,
            updaterService: updaterService,
            openAIRealtimeCredentialStore: openAIRealtimeCredentialStore,
            calendarStore: calendarStore,
            externalIntegrationsEnabled: applicationData.ExternalIntegrationsEnabled,
            voiceE2EReceiptStore: voiceE2EReceiptStore,
            isolatedVoiceE2EDefaults: isolatedVoiceE2EDefaults);
        _panelBridgeController.SettingsChanged += OnPanelSettingsChanged;
        _panelBridgeController.ChatRequested = OpenChatAsync;
        _panelBridgeController.ChatApprovalOwner = () => _chatWindow;
        _panelBridgeController.SettingsOpenRequested += OnSettingsOpenRequested;
        _panelBridgeController.TimerAlertFired += OnTimerAlertFired;
        _panelBridgeController.TimerAlertChanged += OnTimerAlertChanged;
        _panelBridgeController.ExternalDragStarted += OnExternalDragStarted;
        _panelBridgeController.PanelCloseRequested += OnPanelCloseRequested;
        _panel = CreatePanelWindow();
        _panelBridgeController.SetPocketAppStateFlush(
            (appId, cancellationToken) => _panel.BeginPocketAppStateTransitionAsync(appId, cancellationToken),
            lease => _panel.CompletePocketAppStateTransitionAsync(lease));

        _pollingTimer = new DispatcherTimer(DispatcherPriority.Background, _dispatcher)
        {
            Interval = userSettings.AutoHideTopHandle ? AutoHidePollingInterval : PollingInterval
        };
        _pollingTimer.Tick += (_, _) => PollPointer();

        _closeDelayTimer = new DispatcherTimer(DispatcherPriority.Background, _dispatcher)
        {
            Interval = CloseDelay
        };
        _closeDelayTimer.Tick += (_, _) =>
        {
            _closeDelayTimer.Stop();
            var pointer = GetPointerPosition();
            var inside = IsPointerInHoverRegion(pointer, out var hoveredLayout);
            TraceHover("close-delay", pointer, inside, hoveredLayout, inside ? "keep-open" : "close");
            if (!_timerAlertActive && !KeepPanelForVoice && !_panel.AssetLayout.PinOnly && !_assetDragActive && !inside)
            {
                _ = HidePanelAsync();
            }
        };

        _healthTimer = new DispatcherTimer(DispatcherPriority.Background, _dispatcher)
        {
            Interval = HealthCheckInterval
        };
        _healthTimer.Tick += OnHealthTimerTick;

        TrySubscribeSystemEvents();
    }

    public AccessSurfaceWindow AccessSurface => _accessSurfaces[0];

    public IReadOnlyList<AccessSurfaceWindow> AccessSurfaces => _accessSurfaces;

    public IReadOnlyList<DisplaySurfaceLayout> Layouts => _layouts;

    public PanelWindow Panel => _panel;

    public PanelBridgeController PanelBridgeController => _panelBridgeController;
    internal AssetOrganizerWindow? AssetOrganizerForVerify => _assetOrganizer;

    public DisplaySurfaceLayout? ActiveLayoutForVerify => _activeLayout;

    public int RecoveryStageCountForVerify => _recoveryStageCountForVerify;
    public int VoiceTransitionCountForVerify => _voiceTransitionCountForVerify;

    public bool PollingEnabledForVerify => _pollingTimer.IsEnabled;

    internal TimeSpan PointerPollingIntervalForVerify => _pollingTimer.Interval;

    public bool HealthTimerEnabledForVerify => _healthTimer.IsEnabled;

    public bool PanelExpectedVisibleForVerify => _panelExpectedVisible;

    public void Start()
    {
        AttachPanelWindow(_panel);
        ResyncDisplayLayout();
        _pollingTimer.Start();
        _healthTimer.Start();
    }

    public void ShowPanelFromUser()
    {
        _ = ShowPanelAsync(ResolveLayoutForPointer(), bypassFullscreenSuppression: true);
    }

    public void OpenSettingsFromUser()
    {
        _ = OpenSettingsAsync();
    }

    public async Task ShowPanelForVerifyAsync()
    {
        await RunWithPollingPausedForVerifyAsync(() => ShowPanelAsync(ResolveLayoutForPointer(), bypassFullscreenSuppression: true));
    }

    public async Task ShowPanelForUiVerifyAsync()
    {
        await _panel.EnsureWebViewInitializedAsync();
        await RunWithPollingPausedForVerifyAsync(() => ShowPanelAsync(ResolveLayoutForPointer(), bypassFullscreenSuppression: true));
    }

    public async Task HidePanelForVerifyAsync()
    {
        _closeDelayTimer.Stop();
        await RunWithPollingPausedForVerifyAsync(HidePanelAsync);
    }

    public void SimulatePointerMoveForVerify(int x, int y)
    {
        SetPointerSimulationForVerify(x, y);
        PollPointer();
    }

    public void SetPointerSimulationForVerify(int x, int y)
    {
        _pointerOverrideForVerify = (x, y);
    }

    public void ClearPointerSimulationForVerify()
    {
        _pointerOverrideForVerify = null;
    }

    public Task<ShellHealthReport> RunHealthCheckForVerifyAsync()
    {
        return RunHealthCheckAsync();
    }

    public void ScheduleStagedRecoveryForVerify()
    {
        ScheduleStagedRecovery();
    }

    private async Task RunWithPollingPausedForVerifyAsync(Func<Task> action)
    {
        var restartPolling = _pollingTimer.IsEnabled;
        if (restartPolling)
        {
            _pollingTimer.Stop();
        }

        try
        {
            await action();
        }
        finally
        {
            if (restartPolling && !_disposed)
            {
                _pollingTimer.Start();
            }
        }
    }

    public int CountCurrentProcessTopLevelWindows()
    {
        return NativeMethods.CountTopLevelWindowsForCurrentProcess();
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _pollingTimer.Stop();
        _closeDelayTimer.Stop();
        _healthTimer.Stop();
        _healthTimer.Tick -= OnHealthTimerTick;
        _recoveryCancellation?.Cancel();
        _recoveryCancellation?.Dispose();
        _recoveryCancellation = null;
        _recoveryTask = null;
        if (_systemEventsSubscribed)
        {
            SystemEvents.DisplaySettingsChanged -= OnDisplaySettingsChanged;
            SystemEvents.PowerModeChanged -= OnPowerModeChanged;
            SystemEvents.SessionSwitch -= OnSessionSwitch;
            _systemEventsSubscribed = false;
        }

        _panel.Win32MessageReceived -= OnWindowWin32MessageReceived;
        _assetOrganizer?.Close();
        _chatWindow?.Close();
        _panelBridgeController.SettingsChanged -= OnPanelSettingsChanged;
        _panelBridgeController.SettingsOpenRequested -= OnSettingsOpenRequested;
        _panelBridgeController.TimerAlertFired -= OnTimerAlertFired;
        _panelBridgeController.TimerAlertChanged -= OnTimerAlertChanged;
        _panelBridgeController.ExternalDragStarted -= OnExternalDragStarted;
        _panelBridgeController.PanelCloseRequested -= OnPanelCloseRequested;
        _panel.ReleaseBridgeAttachment();
        _panelBridgeController.Dispose();
        if (_settingsWindow is not null)
        {
            _settingsWindow.Close();
            _settingsWindow = null;
        }

        _panel.Close();
        foreach (var accessSurface in _accessSurfaces)
        {
            accessSurface.HoverEntered -= OnAccessSurfaceHoverEntered;
            accessSurface.Win32MessageReceived -= OnWindowWin32MessageReceived;
            accessSurface.Close();
        }

        _accessSurfaces.Clear();
        _surfaceLayouts.Clear();
    }

    private async Task ShowPanelAsync(
        DisplaySurfaceLayout? layout,
        bool bypassFullscreenSuppression = false)
    {
        if (_captureSuppressed) return;
        if (bypassFullscreenSuppression) _previewFocusDismissed = false;
        if (!bypassFullscreenSuppression
            && _pointerOverrideForVerify is null
            && IsTopEdgeSuppressed())
        {
            return;
        }

        layout ??= _layouts.FirstOrDefault();
        if (layout is null)
        {
            return;
        }

        _panelExpectedVisible = true;
        _panel.SetAssetBackgrounded(false);
        var entryLayout = _panel.IsVisible ? _activeLayout ?? layout : layout;
        foreach (var (surface, surfaceLayout) in _surfaceLayouts)
            if (surfaceLayout.Monitor.Id == entryLayout.Monitor.Id)
                surface.SetPeekVisible(true, immediate: true);

        if (_closingTask is { IsCompleted: false })
        {
            _activeLayout = layout;
            _closeDelayTimer.Stop();
            TraceHover("reopen", GetPointerPosition(), true, layout, "reverse-close");
            await _panel.OpenAsync(layout, EffectivePanelTarget(layout));
            _closingTask = null;
            await _panelBridgeController.NotifyPanelOpenedAsync();
            return;
        }

        if (_panel.IsVisible)
        {
            _activeLayout ??= layout;
            _closeDelayTimer.Stop();
            TraceHover("open-skip", GetPointerPosition(), true, _activeLayout, "panel-already-visible");
            return;
        }

        _activeLayout = layout;
        _closeDelayTimer.Stop();
        TraceHover("open", GetPointerPosition(), true, layout, "panel-open");
        await Task.WhenAll(
            _panel.OpenAsync(layout, EffectivePanelTarget(layout)),
            _panel.EnsureWebViewInitializedAsync());
        await _panelBridgeController.NotifyPanelOpenedAsync();
    }

    private Task HidePanelAsync()
    {
        if (_closingTask is { IsCompleted: false } closingTask)
        {
            return closingTask;
        }

        // Hide() can pump window messages and re-enter this method, so publish the
        // in-flight task before starting the synchronous part of the close path.
        var completion = new TaskCompletionSource<bool>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        _closingTask = completion.Task;
        _ = CompleteHidePanelAsync(completion);
        return _closingTask;
    }

    private async Task CompleteHidePanelAsync(TaskCompletionSource<bool> completion)
    {
        try
        {
            await HidePanelCoreAsync();
            completion.TrySetResult(true);
        }
        catch (Exception exception)
        {
            completion.TrySetException(exception);
        }
    }

    private async Task HidePanelCoreAsync()
    {
        if (_activeLayout is null)
        {
            _panelExpectedVisible = false;
            return;
        }

        TraceHover("close", GetPointerPosition(), false, _activeLayout, "panel-close");
        _panelExpectedVisible = false;
        _panel.EndAssetPreview();
        await _panel.CloseAsync(_activeLayout);
        if (!_panelExpectedVisible && !_panel.IsOpening)
            await _panelBridgeController.NotifyPanelClosedAsync();
    }

    private async Task OpenSettingsAsync()
    {
        if (_disposed)
        {
            return;
        }

        _closeDelayTimer.Stop();
        await HidePanelAsync();

        if (_settingsWindow is not null)
        {
            _settingsWindow.Activate();
            _settingsWindow.Focus();
            return;
        }

        _settingsWindow = new SettingsWindow(
            _panelBridgeController,
            _enableDevTools,
            _applicationData.SettingsWebViewDataDirectory,
            _applicationData.ExternalIntegrationsEnabled);
        _settingsWindow.Closed += (_, _) => _settingsWindow = null;
        _settingsWindow.Show();
        _settingsWindow.Activate();
    }

    private bool KeepPanelForVoice => _panelBridgeController.VoiceSnapshot.RealtimeAttached
        || _panel.OwnedWindows.OfType<Window>().Any(window => window.IsVisible);
    private void PollPointer()
    {
        if (_captureSuppressed) return;
        if (_panel.AssetLayout.PinOnly || _assetDragActive || KeepPanelForVoice) { _closeDelayTimer.Stop(); return; }
        var pointer = GetPointerPosition();
        if (_previewFocusDismissed)
        {
            if (IsPointerInHoverRegion(pointer, out _)) { _closeDelayTimer.Stop(); return; }
            _previewFocusDismissed = false;
        }
        if (_pointerOverrideForVerify is null
            && !_panel.IsVisible
            && IsTopEdgeSuppressed())
        {
            RefreshAccessSurfaceVisibility(pointer, allowProximity: false);
            _closeDelayTimer.Stop();
            return;
        }

        RefreshAccessSurfaceVisibility(pointer);
        if (IsPointerInHoverRegion(pointer, out var hoveredLayout))
        {
            _closeDelayTimer.Stop();
            TraceHover("poll", pointer, true, hoveredLayout, _panel.IsVisible ? "keep-open" : "open");
            if (!_panel.IsVisible || _closingTask is { IsCompleted: false })
            {
                _ = ShowPanelAsync(hoveredLayout ?? ResolveLayoutForPointer(pointer));
            }

            return;
        }

        if (_panel.IsVisible
            && _closingTask is not { IsCompleted: false }
            && !_closeDelayTimer.IsEnabled
            && !_timerAlertActive)
        {
            TraceHover("poll", pointer, false, _activeLayout, "start-close-delay");
            _closeDelayTimer.Start();
        }
    }

    private bool IsPointerInHoverRegion((int X, int Y) pointer, out DisplaySurfaceLayout? hoveredLayout)
    {
        hoveredLayout = null;
        if (_panel.IsVisible)
        {
            var activeLayout = _activeLayout;
            if (activeLayout is null)
            {
                return false;
            }

            hoveredLayout = activeLayout;
            return IsInsideInflatedPlacement(activeLayout.AccessSurface, activeLayout.Monitor, pointer)
                || _panel.ContainsPhysicalPoint(pointer.X, pointer.Y, HoverToleranceDips);
        }

        foreach (var layout in _surfaceLayouts.Values)
        {
            var inside = _panelBridgeController.CurrentSettings.AutoHideTopHandle
                ? layout.AccessSurface.PhysicalRect.Contains(pointer.X, pointer.Y)
                : IsInsideInflatedPlacement(layout.AccessSurface, layout.Monitor, pointer);
            if (inside)
            {
                hoveredLayout = layout;
                return true;
            }
        }

        return false;
    }

    private (int X, int Y) GetPointerPosition()
    {
        if (_pointerOverrideForVerify is { } pointer)
        {
            return pointer;
        }

        var mousePosition = WinForms.Control.MousePosition;
        return (mousePosition.X, mousePosition.Y);
    }

    internal static PhysicalRect PeekProximityBounds(DisplaySurfaceLayout layout)
    {
        var access = layout.AccessSurface.PhysicalRect;
        var padding = (int)Math.Ceiling(access.Width / 2.0 + PeekSidePaddingDips * layout.Monitor.ScaleX);
        return new PhysicalRect(access.Left - padding, access.Top, access.Width + padding * 2,
            (int)Math.Ceiling(PeekDepthDips * layout.Monitor.ScaleY)).ClampTo(layout.Monitor.Bounds);
    }

    private bool ShouldRevealAccessSurface(DisplaySurfaceLayout layout, (int X, int Y) pointer, bool allowProximity = true)
    {
        if (!_panelBridgeController.CurrentSettings.AutoHideTopHandle) return true;
        if (_panel.IsVisible || _panelExpectedVisible)
            return layout.Monitor.Id == _activeLayout?.Monitor.Id;
        return allowProximity && PeekProximityBounds(layout).Contains(pointer.X, pointer.Y);
    }

    private bool ReducePeekMotion => _panelBridgeController.CurrentSettings.ReduceMotion || !SystemParameters.ClientAreaAnimation;

    private void RefreshAccessSurfaceVisibility((int X, int Y) pointer, bool allowProximity = true)
    {
        foreach (var (surface, layout) in _surfaceLayouts)
            surface.UpdatePeekVisibility(ShouldRevealAccessSurface(layout, pointer, allowProximity), ReducePeekMotion);
    }

    private WindowPlacement EffectivePanelTarget(DisplaySurfaceLayout layout)
    {
        if (_panel.AssetLayout is { Active: true } asset && (!asset.PinOnly || asset.Width > 0 && asset.Height > 0 || asset.Fullscreen || asset.Organizer))
        {
            var monitor = layout.Monitor;
            if (asset.Fullscreen)
            {
                var bounds = monitor.Bounds;
                return new WindowPlacement(new System.Windows.Rect(bounds.Left / monitor.ScaleX, bounds.Top / monitor.ScaleY, bounds.Width / monitor.ScaleX, bounds.Height / monitor.ScaleY), bounds);
            }
            var normal = layout.PanelTarget.DipRect;
            var maxWidth = monitor.WorkArea.Width / monitor.ScaleX * .9;
            var maxHeight = Math.Min(monitor.WorkArea.Height / monitor.ScaleY * .85, (monitor.WorkArea.Bottom / monitor.ScaleY) - normal.Top);
            var naturalWidth = asset.Organizer ? maxWidth : asset.Width / monitor.ScaleX;
            var naturalHeight = asset.Organizer ? maxHeight - 120 : asset.Height / monitor.ScaleY;
            var scale = Math.Min(1, Math.Min((maxWidth - 32) / Math.Max(1, naturalWidth), (maxHeight - 120) / Math.Max(1, naturalHeight)));
            var width = Math.Min(maxWidth, Math.Max(normal.Width, naturalWidth * scale + 32));
            var height = Math.Min(maxHeight, Math.Max(normal.Height, naturalHeight * scale + 120));
            var left = Math.Clamp(normal.Left + (normal.Width - width) / 2, monitor.WorkArea.Left / monitor.ScaleX, monitor.WorkArea.Right / monitor.ScaleX - width);
            return new WindowPlacement(new System.Windows.Rect(left, normal.Top, width, height), new PhysicalRect((int)Math.Round(left * monitor.ScaleX), layout.PanelTarget.PhysicalRect.Top, (int)Math.Round(width * monitor.ScaleX), (int)Math.Round(height * monitor.ScaleY)));
        }
        var target = VoicePanelGeometry.ExtendDownward(
            layout.PanelTarget,
            layout.Monitor,
            _panelBridgeController.CurrentSettings.PanelSize,
            _panelBridgeController.PreferredRuntimeVoiceLaneMode,
            out var resolvedMode);
        _panelBridgeController.SetResolvedVoiceLaneMode(resolvedMode);
        return target;
    }

    private static bool IsInsideInflatedPlacement(
        WindowPlacement placement,
        DisplayMonitor monitor,
        (int X, int Y) pointer)
    {
        var paddingX = DipPaddingToPhysical(monitor.ScaleX);
        var paddingY = DipPaddingToPhysical(monitor.ScaleY);
        return placement.PhysicalRect.Inflate(paddingX, paddingY).Contains(pointer.X, pointer.Y);
    }

    private static int DipPaddingToPhysical(double scale)
    {
        return Math.Max(0, (int)Math.Ceiling(HoverToleranceDips * scale));
    }

    private void ResyncDisplayLayout(bool animateVisiblePanel = false)
    {
        if (_disposed || _captureSuppressed)
        {
            return;
        }

        var previousActiveLayout = _activeLayout;
        var userSettings = _panelBridgeController.CurrentSettings;
        var accessWidth = userSettings.ShowTopHandleSideArea
            ? AccessSurfaceWindow.ExpandedWidth
            : AccessSurfaceWindow.CompactWidth;
        _layouts = _displayLayoutService.CreateLayouts(
            userSettings.DisplayPlacement,
            userSettings.PanelSize,
            accessWidth);
        EnsureAccessSurfaceCount(_layouts.Count);
        _surfaceLayouts.Clear();

        for (var index = 0; index < _layouts.Count; index++)
        {
            var accessSurface = _accessSurfaces[index];
            var layout = _layouts[index];
            accessSurface.UpdateAppearance(userSettings);
            _surfaceLayouts[accessSurface] = layout;
            accessSurface.ApplyPlacement(layout.AccessSurface, show: false);
            accessSurface.SetPeekVisible(ShouldRevealAccessSurface(layout, GetPointerPosition()), immediate: true);
        }

        if (!_panelExpectedVisible)
        {
            _activeLayout = ResolveLayoutForPointer() ?? _layouts.FirstOrDefault();
            if (_activeLayout is not null)
            {
                _ = EffectivePanelTarget(_activeLayout);
                _panel.PrepareCollapsedState();
                _panel.ApplyPlacement(_activeLayout.PanelCollapsed, show: false);
            }

            _panel.Opacity = 0;
            return;
        }

        _activeLayout = ResolveLayoutMatching(previousActiveLayout) ?? _layouts.FirstOrDefault();
        if (_activeLayout is not null)
        {
            if (animateVisiblePanel)
            {
                _ = _panel.ResizeAsync(EffectivePanelTarget(_activeLayout));
            }
            else
            {
                _ = _panel.OpenAsync(_activeLayout, EffectivePanelTarget(_activeLayout));
            }
        }
    }

    private void EnsureAccessSurfaceCount(int count)
    {
        while (_accessSurfaces.Count < count)
        {
            _accessSurfaces.Add(CreateAccessSurfaceWindow());
        }

        while (_accessSurfaces.Count > count)
        {
            var lastIndex = _accessSurfaces.Count - 1;
            var accessSurface = _accessSurfaces[lastIndex];
            DetachAndCloseAccessSurface(accessSurface);
            _surfaceLayouts.Remove(accessSurface);
            _accessSurfaces.RemoveAt(lastIndex);
        }
    }

    private AccessSurfaceWindow CreateAccessSurfaceWindow()
    {
        var accessSurface = new AccessSurfaceWindow();
        accessSurface.CanImportAssets = () => _panelBridgeController.AssetsVisible;
        accessSurface.UpdateAppearance(_panelBridgeController.CurrentSettings);
        accessSurface.HoverEntered += OnAccessSurfaceHoverEntered;
        accessSurface.AssetDragChanged += OnAssetDragChanged;
        accessSurface.AssetDropped += async data =>
        {
            if (!_panelBridgeController.AssetsVisible) return;
            await _panelBridgeController.BeginAssetDropAsync(); await ShowPanelAsync(ResolveLayoutForPointer());
            await _panelBridgeController.FinishAssetDropAsync(true); await _panel.ReceiveAssetDropAsync(data);
        };
        accessSurface.Win32MessageReceived += OnWindowWin32MessageReceived;
        accessSurface.EnsureHandle();
        if (_activeTimerAlert is not null)
        {
            accessSurface.SetAlertHighlight(ToHighlightColor(_activeTimerAlert.Color));
        }

        return accessSurface;
    }

    private void DetachAndCloseAccessSurface(AccessSurfaceWindow accessSurface)
    {
        accessSurface.HoverEntered -= OnAccessSurfaceHoverEntered;
        accessSurface.Win32MessageReceived -= OnWindowWin32MessageReceived;
        try
        {
            accessSurface.Close();
        }
        catch (InvalidOperationException)
        {
        }
    }

    private PanelWindow CreatePanelWindow()
    {
        return new PanelWindow(
            _panelBridgeController,
            _enablePanelWebView,
            _enableDevTools,
            _applicationData.PanelWebViewDataDirectory,
            _applicationData.ExternalIntegrationsEnabled);
    }

    private void AttachPanelWindow(PanelWindow panel)
    {
        panel.AssetDragChanged += OnAssetDragChanged;
        panel.AssetOrganizerRequested += OpenAssetLibraryFromUser;
        panel.AssetPreviewDismissRequested += () =>
        {
            if (panel != _panel) return;
            _previewFocusDismissed = true;
            _ = HidePanelAsync();
        };
        panel.AssetLayoutChanged += value =>
        {
            if (value.Fullscreen) foreach (var surface in _accessSurfaces) surface.SetPeekVisible(false, immediate: true);
            _closeDelayTimer.Stop();
            if (value.PinOnly) return;
            if (_activeLayout is { } layout && _panelExpectedVisible) _ = panel.ResizeAsync(EffectivePanelTarget(layout));
        };
        panel.EnsureHandle();
        panel.Win32MessageReceived += OnWindowWin32MessageReceived;
    }

    private void OnHealthTimerTick(object? sender, EventArgs e)
    {
        _ = sender;
        _ = e;
        _ = RunHealthCheckFromTimerAsync();
    }

    private async Task RunHealthCheckFromTimerAsync()
    {
        try
        {
            await RunHealthCheckAsync();
        }
        catch (InvalidOperationException)
        {
        }
        catch (ExternalException)
        {
        }
    }

    private Task<ShellHealthReport> RunHealthCheckAsync()
    {
        if (_disposed || _captureSuppressed)
        {
            return Task.FromResult(ShellHealthReport.Empty);
        }

        if (_healthRecoveryTask is { IsCompleted: false })
        {
            return _healthRecoveryTask;
        }

        _healthRecoveryTask = RunHealthCheckCoreAsync();
        return _healthRecoveryTask;
    }

    private async Task<ShellHealthReport> RunHealthCheckCoreAsync()
    {
        if (_layouts.Count == 0 || _layouts.Count != _accessSurfaces.Count)
        {
            ResyncDisplayLayout();
        }

        var accessRecreated = 0;
        var accessRepaired = 0;
        for (var index = 0; index < _layouts.Count && index < _accessSurfaces.Count; index++)
        {
            var layout = _layouts[index];
            var accessSurface = _accessSurfaces[index];
            if (!NativeMethods.IsWindowHandleValid(accessSurface.Hwnd))
            {
                _surfaceLayouts.Remove(accessSurface);
                DetachAndCloseAccessSurface(accessSurface);
                var replacement = CreateAccessSurfaceWindow();
                _accessSurfaces[index] = replacement;
                _surfaceLayouts[replacement] = layout;
                replacement.ApplyPlacement(layout.AccessSurface, show: false);
                replacement.SetPeekVisible(ShouldRevealAccessSurface(layout, GetPointerPosition()), immediate: true);
                accessRecreated++;
                continue;
            }

            if (!accessSurface.IsPeeking && NeedsNativeRepair(
                    accessSurface.Hwnd,
                    accessSurface.IsVisible,
                    expectedVisible: accessSurface.PeekTargetVisible,
                    layout.AccessSurface.PhysicalRect,
                    checkFrame: true,
                    requireNoActivate: true))
            {
                RepairStyles(accessSurface.Hwnd, requireNoActivate: true);
                accessSurface.UpdateAppearance(_panelBridgeController.CurrentSettings);
                accessSurface.ApplyPlacement(layout.AccessSurface, show: accessSurface.PeekTargetVisible);
                accessSurface.SetPeekVisible(accessSurface.PeekTargetVisible, immediate: true);
                accessRepaired++;
            }
        }

        var panelRecreated = false;
        var panelRepaired = false;
        var panelLayout = ResolveLayoutMatching(_activeLayout) ?? _layouts.FirstOrDefault();
        if (!NativeMethods.IsWindowHandleValid(_panel.Hwnd))
        {
            await RecreatePanelWindowAsync(panelLayout);
            panelRecreated = true;
        }
        else if (panelLayout is not null && !_panel.IsAnimating)
        {
            var expectedPlacement = _panelExpectedVisible
                ? EffectivePanelTarget(panelLayout)
                : panelLayout.PanelCollapsed;
            if (NeedsNativeRepair(
                    _panel.Hwnd,
                    _panel.IsVisible,
                    _panelExpectedVisible,
                    expectedPlacement.PhysicalRect,
                    checkFrame: true,
                    requireNoActivate: !_panel.KeyboardInteractionEnabled,
                    requireTopmost: !_panel.AssetBackgrounded))
            {
                RepairStyles(_panel.Hwnd, requireNoActivate: !_panel.KeyboardInteractionEnabled, requireTopmost: !_panel.AssetBackgrounded);
                if (_panelExpectedVisible)
                {
                    await _panel.OpenAsync(panelLayout, expectedPlacement);
                    _panel.Opacity = 1;
                    _panel.ShowNoActivate();
                }
                else
                {
                    if (_panel.IsVisible)
                    {
                        _panel.Hide();
                    }

                    _panel.PrepareCollapsedState();
                    _panel.ApplyPlacement(expectedPlacement, show: false);
                    _panel.Opacity = 0;
                    NativeMethods.HideWindow(_panel.Hwnd);
                }

                panelRepaired = true;
            }
        }

        return new ShellHealthReport(accessRecreated, accessRepaired, panelRecreated, panelRepaired);
    }

    private async Task RecreatePanelWindowAsync(DisplaySurfaceLayout? layout)
    {
        var previous = _panel;
        previous.Win32MessageReceived -= OnWindowWin32MessageReceived;
        previous.ReleaseBridgeAttachment();
        try
        {
            previous.Close();
        }
        catch (InvalidOperationException)
        {
        }

        _closingTask = null;
        var replacement = CreatePanelWindow();
        _panel = replacement;
        AttachPanelWindow(replacement);
        if (layout is null)
        {
            return;
        }

        _activeLayout = layout;
        if (_panelExpectedVisible)
        {
            try
            {
                await replacement.EnsureWebViewInitializedAsync();
            }
            catch (InvalidOperationException) when (_disposed)
            {
                return;
            }

            if (_disposed || _captureSuppressed)
            {
                return;
            }

            await replacement.OpenAsync(layout, EffectivePanelTarget(layout));
            replacement.Opacity = 1;
            replacement.ShowNoActivate();
        }
        else
        {
            replacement.PrepareCollapsedState();
            replacement.ApplyPlacement(layout.PanelCollapsed, show: false);
            replacement.Opacity = 0;
            NativeMethods.HideWindow(replacement.Hwnd);
        }
    }

    private static bool NeedsNativeRepair(
        IntPtr hwnd,
        bool wpfVisible,
        bool expectedVisible,
        PhysicalRect expectedFrame,
        bool checkFrame,
        bool requireNoActivate,
        bool requireTopmost = true)
    {
        var styles = NativeMethods.GetExtendedStyles(hwnd);
        var requiredStyles = NativeMethods.WsExToolWindow | (requireTopmost ? NativeMethods.WsExTopmost : 0);
        if (requireNoActivate)
        {
            requiredStyles |= NativeMethods.WsExNoActivate;
        }

        var styleHealthy = (styles & requiredStyles) == requiredStyles
            && ((styles & NativeMethods.WsExTopmost) != 0) == requireTopmost
            && (requireNoActivate || (styles & NativeMethods.WsExNoActivate) == 0);
        var visibilityHealthy = wpfVisible == expectedVisible
            && NativeMethods.IsWindowShown(hwnd) == expectedVisible;
        var frameHealthy = !checkFrame
            || (NativeMethods.TryGetWindowRect(hwnd, out var actual)
                && FrameMatches(actual, expectedFrame));
        return !styleHealthy || !visibilityHealthy || !frameHealthy;
    }

    private static void RepairStyles(IntPtr hwnd, bool requireNoActivate, bool requireTopmost = true)
    {
        NativeMethods.AddExtendedStyles(
            hwnd,
            NativeMethods.WsExToolWindow | (requireNoActivate ? NativeMethods.WsExNoActivate : 0));
        NativeMethods.SetNoActivateStyle(hwnd, requireNoActivate);
        NativeMethods.SetTopmostNoActivate(hwnd, requireTopmost);
    }

    private static bool FrameMatches(NativeRect actual, PhysicalRect expected)
    {
        const int tolerance = 2;
        return Math.Abs(actual.Left - expected.Left) <= tolerance
            && Math.Abs(actual.Top - expected.Top) <= tolerance
            && Math.Abs(actual.Width - expected.Width) <= tolerance
            && Math.Abs(actual.Height - expected.Height) <= tolerance;
    }

    private void OnAccessSurfaceHoverEntered(object? sender, EventArgs e)
    {
        if (_previewFocusDismissed) return;
        if (!_panel.IsVisible && IsTopEdgeSuppressed())
        {
            return;
        }

        if (_panel.IsVisible)
        {
            if (sender is AccessSurfaceWindow entered && _surfaceLayouts.TryGetValue(entered, out var enteredLayout)
                && enteredLayout.Monitor.Id != _activeLayout?.Monitor.Id) return;
            _panel.SetAssetBackgrounded(false);
            _closeDelayTimer.Stop();
            if (_closingTask is { IsCompleted: false }) _ = ShowPanelAsync(_activeLayout);
            TraceHover("surface-enter", GetPointerPosition(), true, _activeLayout, "panel-already-visible");
            return;
        }

        if (sender is AccessSurfaceWindow accessSurface && _surfaceLayouts.TryGetValue(accessSurface, out var layout))
        {
            _ = ShowPanelAsync(layout);
            return;
        }

        ShowPanelFromUser();
    }

    private DisplaySurfaceLayout? ResolveLayoutForPointer((int X, int Y)? pointer = null)
    {
        if (_layouts.Count == 0)
        {
            return null;
        }

        var resolvedPointer = pointer ?? GetPointerPosition();
        return _layouts.FirstOrDefault(layout => layout.Monitor.Bounds.Contains(resolvedPointer.X, resolvedPointer.Y))
            ?? _activeLayout
            ?? _layouts[0];
    }

    private DisplaySurfaceLayout? ResolveLayoutMatching(DisplaySurfaceLayout? previousLayout)
    {
        if (previousLayout is null)
        {
            return null;
        }

        return _layouts.FirstOrDefault(layout => layout.Monitor.Id == previousLayout.Monitor.Id)
            ?? _layouts.FirstOrDefault(layout =>
                layout.Monitor.Bounds.Left == previousLayout.Monitor.Bounds.Left
                && layout.Monitor.Bounds.Top == previousLayout.Monitor.Bounds.Top
                && layout.Monitor.Bounds.Width == previousLayout.Monitor.Bounds.Width
                && layout.Monitor.Bounds.Height == previousLayout.Monitor.Bounds.Height);
    }

    private void TraceHover(
        string eventName,
        (int X, int Y) pointer,
        bool inside,
        DisplaySurfaceLayout? layout,
        string decision)
    {
        if (string.IsNullOrWhiteSpace(_hoverTracePath))
        {
            return;
        }

        try
        {
            var directory = Path.GetDirectoryName(_hoverTracePath);
            if (!string.IsNullOrWhiteSpace(directory))
            {
                Directory.CreateDirectory(directory);
            }

            File.AppendAllText(
                _hoverTracePath,
                string.Join(
                    '\t',
                    DateTimeOffset.UtcNow.ToString("O"),
                    $"event={eventName}",
                    $"pointer={pointer.X},{pointer.Y}",
                    $"inside={inside}",
                    $"decision={decision}",
                    $"active={_activeLayout?.Monitor.Id ?? "null"}",
                    $"layout={layout?.Monitor.Id ?? "null"}",
                    $"access={FormatTraceRect(layout?.AccessSurface.PhysicalRect)}",
                    $"panel={FormatTraceRect(layout is null ? null : EffectivePanelTarget(layout).PhysicalRect)}")
                + Environment.NewLine);
        }
        catch (IOException)
        {
        }
        catch (UnauthorizedAccessException)
        {
        }
        catch (ArgumentException)
        {
        }
    }

    private static string? NormalizeTracePath()
    {
        var path = Environment.GetEnvironmentVariable("HOVERPOCKET_HOVER_TRACE");
        return string.IsNullOrWhiteSpace(path) ? null : path;
    }

    private static string FormatTraceRect(PhysicalRect? rect)
    {
        return rect is null
            ? "null"
            : $"{rect.Value.Left},{rect.Value.Top},{rect.Value.Width},{rect.Value.Height}";
    }

    private void ScheduleStagedRecovery()
    {
        if (_disposed || _captureSuppressed)
        {
            return;
        }

        if (!_dispatcher.CheckAccess())
        {
            _dispatcher.BeginInvoke(ScheduleStagedRecovery);
            return;
        }

        _pollingTimer.Stop();
        _pollingTimer.Start();
        _healthTimer.Stop();
        _healthTimer.Start();
        _recoveryCancellation?.Cancel();
        _recoveryCancellation?.Dispose();
        var cancellation = new CancellationTokenSource();
        _recoveryCancellation = cancellation;
        _recoveryTask = RunStagedRecoveryAsync(cancellation.Token);
    }

    private async Task RunStagedRecoveryAsync(CancellationToken cancellationToken)
    {
        var previousDelay = TimeSpan.Zero;
        try
        {
            cancellationToken.ThrowIfCancellationRequested();
            await _panelBridgeController.NotifySystemTransitionAsync(cancellationToken);
            _voiceTransitionCountForVerify++;
            foreach (var targetDelay in RecoveryDelays)
            {
                var delay = targetDelay - previousDelay;
                previousDelay = targetDelay;
                if (delay > TimeSpan.Zero)
                {
                    await Task.Delay(delay, cancellationToken);
                }

                cancellationToken.ThrowIfCancellationRequested();
                await RunRecoveryStageAsync();
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
    }

    private async Task RunRecoveryStageAsync()
    {
        if (_disposed || _captureSuppressed)
        {
            return;
        }

        if (!_dispatcher.CheckAccess())
        {
            await _dispatcher.InvokeAsync(RunRecoveryStageAsync).Task.Unwrap();
            return;
        }

        _pollingTimer.Stop();
        _pollingTimer.Start();
        _healthTimer.Stop();
        _healthTimer.Start();
        ResyncDisplayLayout();
        await RunHealthCheckAsync();
        _recoveryStageCountForVerify++;
    }

    private void OnWindowWin32MessageReceived(object? sender, Win32MessageEventArgs e)
    {
        if (e.Message is NativeMethods.WmDisplayChange or NativeMethods.WmDpiChanged)
        {
            ScheduleStagedRecovery();
        }
    }

    private void OnDisplaySettingsChanged(object? sender, EventArgs e)
    {
        ScheduleStagedRecovery();
    }

    private void OnPowerModeChanged(object? sender, PowerModeChangedEventArgs e)
    {
        if (e.Mode == PowerModes.Resume)
        {
            ScheduleStagedRecovery();
        }
    }

    private void OnSessionSwitch(object? sender, SessionSwitchEventArgs e)
    {
        if (e.Reason is SessionSwitchReason.SessionUnlock
            or SessionSwitchReason.ConsoleConnect
            or SessionSwitchReason.RemoteConnect)
        {
            ScheduleStagedRecovery();
        }
    }

    private void OnSettingsOpenRequested(object? sender, EventArgs e)
    {
        OpenSettingsFromUser();
    }

    private void OnExternalDragStarted(object? sender, EventArgs e)
    {
        _ = sender;
        _ = e;
        if (!_dispatcher.CheckAccess())
        {
            _dispatcher.BeginInvoke(() => OnExternalDragStarted(sender, e));
            return;
        }

        _closeDelayTimer.Stop();
        _ = HidePanelAsync();
    }

    private void OnPanelCloseRequested(object? sender, EventArgs e)
    {
        _ = sender;
        _ = e;
        if (!_dispatcher.CheckAccess())
        {
            _dispatcher.BeginInvoke(() => OnPanelCloseRequested(sender, e));
            return;
        }

        _closeDelayTimer.Stop();
        _ = HidePanelAsync();
    }

    private void OnTimerAlertFired(object? sender, TimerAlert alert)
    {
        _ = sender;
        if (!_dispatcher.CheckAccess())
        {
            _dispatcher.BeginInvoke(() => OnTimerAlertFired(sender, alert));
            return;
        }

        _ = ShowTimerAlertAsync(alert);
    }

    private void OnTimerAlertChanged(object? sender, TimerAlert? alert)
    {
        _ = sender;
        if (!_dispatcher.CheckAccess())
        {
            _dispatcher.BeginInvoke(() => OnTimerAlertChanged(sender, alert));
            return;
        }

        _timerAlertActive = alert is not null;
        _activeTimerAlert = alert;
        if (alert is null)
        {
            foreach (var accessSurface in _accessSurfaces)
            {
                accessSurface.SetAlertHighlight(null);
            }

            return;
        }

        ApplyTimerAlertHighlight(alert);
    }

    private async Task ShowTimerAlertAsync(TimerAlert alert)
    {
        if (_disposed)
        {
            return;
        }

        _timerAlertActive = true;
        _activeTimerAlert = alert;
        _closeDelayTimer.Stop();
        ApplyTimerAlertHighlight(alert);
        if (_panel.AssetLayout.Active) return;
        await _panelBridgeController.SelectProviderFromShellAsync("timer");
        await ShowPanelAsync(ResolveLayoutForPointer(), bypassFullscreenSuppression: true);
    }

    private void ApplyTimerAlertHighlight(TimerAlert alert)
    {
        var color = ToHighlightColor(alert.Color);
        foreach (var accessSurface in _accessSurfaces)
        {
            accessSurface.SetAlertHighlight(color);
        }
    }

    private static WpfColor ToHighlightColor(TimerColor color)
    {
        return color switch
        {
            TimerColor.Green => WpfColor.FromRgb(36, 188, 126),
            TimerColor.Orange => WpfColor.FromRgb(246, 149, 62),
            TimerColor.Pink => WpfColor.FromRgb(232, 95, 151),
            _ => WpfColor.FromRgb(65, 145, 255)
        };
    }

    private void OnPanelSettingsChanged(object? sender, UserSettings settings)
    {
        if (!_dispatcher.CheckAccess())
        {
            _dispatcher.BeginInvoke(() => OnPanelSettingsChanged(sender, settings));
            return;
        }

        var panelSizeChanged = _lastAppliedSettings.PanelSize != settings.PanelSize
            || _lastAppliedSettings.PanelAttachmentStyle != settings.PanelAttachmentStyle
            || _lastAppliedSettings.AutomaticScreenEdgeAttachment != settings.AutomaticScreenEdgeAttachment
            || _lastAppliedSettings.ReduceMotion != settings.ReduceMotion;
        var voiceGeometryChanged = _lastAppliedSettings.VoiceEnabled != settings.VoiceEnabled
            || _lastAppliedSettings.VoiceLaneLayout != settings.VoiceLaneLayout;
        var placementChanged = _lastAppliedSettings.DisplayPlacement != settings.DisplayPlacement;
        _lastAppliedSettings = settings.Clone();
        _pollingTimer.Interval = settings.AutoHideTopHandle ? AutoHidePollingInterval : PollingInterval;
        ResyncDisplayLayout(
            animateVisiblePanel: (panelSizeChanged || voiceGeometryChanged) && !placementChanged);
    }

    private bool IsTopEdgeSuppressed()
    {
        return _panelBridgeController.CurrentSettings.DisableTopEdgeInFullscreen
            && NativeMethods.IsForegroundWindowFullscreen();
    }

    private void TrySubscribeSystemEvents()
    {
        var displaySubscribed = false;
        var powerSubscribed = false;
        var sessionSubscribed = false;
        try
        {
            SystemEvents.DisplaySettingsChanged += OnDisplaySettingsChanged;
            displaySubscribed = true;
            SystemEvents.PowerModeChanged += OnPowerModeChanged;
            powerSubscribed = true;
            SystemEvents.SessionSwitch += OnSessionSwitch;
            sessionSubscribed = true;
            _systemEventsSubscribed = true;
        }
        catch (ExternalException)
        {
            RollBackSystemEventSubscriptions(displaySubscribed, powerSubscribed, sessionSubscribed);
            _systemEventsSubscribed = false;
        }
        catch (InvalidOperationException)
        {
            RollBackSystemEventSubscriptions(displaySubscribed, powerSubscribed, sessionSubscribed);
            _systemEventsSubscribed = false;
        }
    }

    private void RollBackSystemEventSubscriptions(
        bool displaySubscribed,
        bool powerSubscribed,
        bool sessionSubscribed)
    {
        if (displaySubscribed)
        {
            SystemEvents.DisplaySettingsChanged -= OnDisplaySettingsChanged;
        }

        if (powerSubscribed)
        {
            SystemEvents.PowerModeChanged -= OnPowerModeChanged;
        }

        if (sessionSubscribed)
        {
            SystemEvents.SessionSwitch -= OnSessionSwitch;
        }
    }
}

internal readonly record struct ShellHealthReport(
    int AccessRecreated,
    int AccessRepaired,
    bool PanelRecreated,
    bool PanelRepaired)
{
    public static ShellHealthReport Empty { get; } = new(0, 0, false, false);
}
