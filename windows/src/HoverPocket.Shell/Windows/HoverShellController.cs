using System.Windows;
using System.Windows.Media;
using System.Windows.Threading;
using System.IO;
using HoverPocket.Shell.Bridge;
using HoverPocket.Shell.Configuration;
using HoverPocket.Shell.Display;
using HoverPocket.Shell.Interop;
using HoverPocket.Shell.Providers;
using HoverPocket.Shell.Providers.CodexVoice;
using HoverPocket.Shell.Providers.Timer;
using HoverPocket.Shell.Settings;
using Microsoft.Win32;
using System.Runtime.InteropServices;
using WinForms = System.Windows.Forms;
using WpfColor = System.Windows.Media.Color;

namespace HoverPocket.Shell.Windows;

internal sealed class HoverShellController : IDisposable
{
    public static readonly TimeSpan CloseDelay = TimeSpan.FromMilliseconds(60);
    public static readonly TimeSpan PollingInterval = TimeSpan.FromMilliseconds(120);
    public static readonly TimeSpan HealthCheckInterval = TimeSpan.FromSeconds(2);
    internal static readonly TimeSpan[] RecoveryDelays =
    [
        TimeSpan.Zero,
        TimeSpan.FromMilliseconds(450),
        TimeSpan.FromMilliseconds(1400)
    ];
    public const double HoverToleranceDips = 4;

    private readonly Dispatcher _dispatcher;
    private readonly HoverPocketApplicationData _applicationData;
    private readonly bool _enablePanelWebView;
    private readonly bool _enableDevTools;
    private readonly bool _deterministicVerification;
    private readonly bool _keepPanelOpenForVoiceE2E;
    private readonly PanelBridgeController _panelBridgeController;
    private readonly DisplayLayoutService _displayLayoutService = new();
    private readonly List<AccessSurfaceWindow> _accessSurfaces = [];
    private readonly Dictionary<AccessSurfaceWindow, DisplaySurfaceLayout> _surfaceLayouts = [];
    private readonly string? _hoverTracePath;
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
    private bool _timerAlertActive;
    private bool _disposed;
    private int _recoveryStageCountForVerify;

    public HoverShellController(
        Dispatcher dispatcher,
        ShellSettings settings,
        ProviderRegistry providerRegistry,
        HoverPocketApplicationData applicationData,
        UserSettingsStore userSettingsStore,
        bool enablePanelWebView,
        bool enableDevTools,
        bool deterministicVerification,
        Services.UpdaterService? updaterService = null,
        CodexVoiceE2EReceiptStore? voiceE2EReceipt = null)
    {
        _dispatcher = dispatcher;
        _applicationData = applicationData;
        _enablePanelWebView = enablePanelWebView;
        _enableDevTools = enableDevTools;
        _deterministicVerification = deterministicVerification;
        _keepPanelOpenForVoiceE2E = ShouldKeepPanelOpenForVoiceE2E(applicationData);
        _hoverTracePath = applicationData.ResolveHoverTracePath(
            Environment.GetEnvironmentVariable("HOVERPOCKET_HOVER_TRACE"));
        var userSettings = userSettingsStore.Load(providerRegistry.ProviderIds);
        if (settings.DisplayPlacementOverride is { } displayPlacementOverride)
        {
            userSettings.DisplayPlacement = displayPlacementOverride;
        }

        _lastAppliedSettings = userSettings.Clone();
        _panelBridgeController = new PanelBridgeController(
            providerRegistry,
            userSettingsStore,
            userSettings,
            updaterService: updaterService,
            applicationData: applicationData,
            voiceE2EReceipt: voiceE2EReceipt);
        _panelBridgeController.SettingsChanged += OnPanelSettingsChanged;
        _panelBridgeController.SettingsOpenRequested += OnSettingsOpenRequested;
        _panelBridgeController.TimerAlertFired += OnTimerAlertFired;
        _panelBridgeController.TimerAlertChanged += OnTimerAlertChanged;
        _panelBridgeController.ExternalDragStarted += OnExternalDragStarted;
        _panelBridgeController.PanelCloseRequested += OnPanelCloseRequested;
        _panel = CreatePanelWindow();

        _pollingTimer = new DispatcherTimer(DispatcherPriority.Background, _dispatcher)
        {
            Interval = PollingInterval
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
            if (!_keepPanelOpenForVoiceE2E && !_timerAlertActive && !inside)
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

    public DisplaySurfaceLayout? ActiveLayoutForVerify => _activeLayout;

    public int RecoveryStageCountForVerify => _recoveryStageCountForVerify;

    public bool PollingEnabledForVerify => _pollingTimer.IsEnabled;

    public bool HealthTimerEnabledForVerify => _healthTimer.IsEnabled;

    public bool PanelExpectedVisibleForVerify => _panelExpectedVisible;

    internal static bool ShouldKeepPanelOpenForVoiceE2E(
        HoverPocketApplicationData applicationData)
    {
        return applicationData.IsIsolatedVoiceE2E;
    }

    internal static bool ShouldRunHealthTimer(
        HoverPocketApplicationData applicationData)
    {
        return !applicationData.IsIsolatedVoiceE2E;
    }

    public void Start()
    {
        AttachPanelWindow(_panel);
        ResyncDisplayLayout();
        _ = _panelBridgeController.StartVoiceRuntimeAsync();
        _pollingTimer.Start();
        if (ShouldRunHealthTimer(_applicationData))
        {
            _healthTimer.Start();
        }
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
        var deterministicLayout = _layouts.FirstOrDefault(layout => layout.Monitor.IsPrimary)
            ?? _layouts.FirstOrDefault();
        await RunWithPollingPausedForVerifyAsync(() => ShowPanelAsync(
            deterministicLayout,
            bypassFullscreenSuppression: true));
        _closeDelayTimer.Stop();
        _pollingTimer.Stop();
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

    public Task PrepareForApplicationShutdownAsync()
    {
        _pollingTimer.Stop();
        _closeDelayTimer.Stop();
        _healthTimer.Stop();
        return _panelBridgeController.PrepareForApplicationShutdownAsync();
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
        await _panelBridgeController.ApplyResolvedVoiceLaneLayoutAsync(layout.VoiceLaneLayout);

        if (_closingTask is { IsCompleted: false })
        {
            _activeLayout = layout;
            _closeDelayTimer.Stop();
            TraceHover("reopen", GetPointerPosition(), true, layout, "reverse-close");
            await _panel.OpenAsync(layout);
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
        await _panel.EnsureWebViewInitializedAsync();
        await _panel.OpenAsync(layout);
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
        await _panel.CloseAsync(_activeLayout);
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
            _applicationData,
            _enableDevTools);
        _settingsWindow.Closed += (_, _) => _settingsWindow = null;
        _settingsWindow.Show();
        _settingsWindow.Activate();
    }

    private void PollPointer()
    {
        if (_pointerOverrideForVerify is null
            && !_panel.IsVisible
            && IsTopEdgeSuppressed())
        {
            _closeDelayTimer.Stop();
            return;
        }

        var pointer = GetPointerPosition();
        if (IsPointerInHoverRegion(pointer, out var hoveredLayout))
        {
            _closeDelayTimer.Stop();
            TraceHover("poll", pointer, true, hoveredLayout, _panel.IsVisible ? "keep-open" : "open");
            if (!_panel.IsVisible)
            {
                _ = ShowPanelAsync(hoveredLayout ?? ResolveLayoutForPointer(pointer));
            }

            return;
        }

        if (_panel.IsVisible
            && _closingTask is not { IsCompleted: false }
            && !_closeDelayTimer.IsEnabled
            && !_keepPanelOpenForVoiceE2E
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
                || IsInsideInflatedPlacement(activeLayout.PanelTarget, activeLayout.Monitor, pointer);
        }

        foreach (var layout in _surfaceLayouts.Values)
        {
            if (IsInsideInflatedPlacement(layout.AccessSurface, layout.Monitor, pointer))
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
        if (_disposed)
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
            accessWidth,
            userSettings.EffectiveVoiceLaneLayout);
        EnsureAccessSurfaceCount(_layouts.Count);
        _surfaceLayouts.Clear();

        for (var index = 0; index < _layouts.Count; index++)
        {
            var accessSurface = _accessSurfaces[index];
            var layout = _layouts[index];
            accessSurface.UpdateAppearance(userSettings);
            _surfaceLayouts[accessSurface] = layout;
            accessSurface.ApplyPlacement(layout.AccessSurface, show: true);
        }

        if (!_panelExpectedVisible)
        {
            _activeLayout = ResolveLayoutForPointer() ?? _layouts.FirstOrDefault();
            if (_activeLayout is not null)
            {
                _ = _panelBridgeController.ApplyResolvedVoiceLaneLayoutAsync(
                    _activeLayout.VoiceLaneLayout);
                _panel.PrepareCollapsedState();
                _panel.ApplyPlacement(_activeLayout.PanelCollapsed, show: false);
            }

            _panel.Opacity = 0;
            return;
        }

        _activeLayout = ResolveLayoutMatching(previousActiveLayout) ?? _layouts.FirstOrDefault();
        if (_activeLayout is not null)
        {
            _ = _panelBridgeController.ApplyResolvedVoiceLaneLayoutAsync(
                _activeLayout.VoiceLaneLayout);
            if (animateVisiblePanel)
            {
                _ = _panel.ResizeAsync(_activeLayout.PanelTarget);
            }
            else
            {
                _panel.ApplyPlacement(_activeLayout.PanelTarget, show: true);
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
        accessSurface.UpdateAppearance(_panelBridgeController.CurrentSettings);
        accessSurface.HoverEntered += OnAccessSurfaceHoverEntered;
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
            _applicationData,
            _enablePanelWebView,
            _enableDevTools);
    }

    private void AttachPanelWindow(PanelWindow panel)
    {
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
        if (_disposed)
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
                replacement.ApplyPlacement(layout.AccessSurface, show: true);
                accessRecreated++;
                continue;
            }

            if (NeedsNativeRepair(
                    accessSurface.Hwnd,
                    accessSurface.IsVisible,
                    expectedVisible: true,
                    layout.AccessSurface.PhysicalRect,
                    checkFrame: true,
                    requireNoActivate: true,
                    requireToolWindow: true))
            {
                RepairStyles(
                    accessSurface.Hwnd,
                    requireNoActivate: true,
                    requireToolWindow: true);
                accessSurface.UpdateAppearance(_panelBridgeController.CurrentSettings);
                accessSurface.ApplyPlacement(layout.AccessSurface, show: true);
                accessSurface.ShowNoActivate();
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
                ? panelLayout.PanelTarget
                : panelLayout.PanelCollapsed;
            if (NeedsNativeRepair(
                    _panel.Hwnd,
                    _panel.IsVisible,
                    _panelExpectedVisible,
                    expectedPlacement.PhysicalRect,
                    checkFrame: true,
                    requireNoActivate: !_panel.KeyboardInteractionEnabled,
                    requireToolWindow: !_panel.ExposesToAutomation))
            {
                RepairStyles(
                    _panel.Hwnd,
                    requireNoActivate: !_panel.KeyboardInteractionEnabled,
                    requireToolWindow: !_panel.ExposesToAutomation);
                if (_panelExpectedVisible)
                {
                    _panel.ApplyPlacement(expectedPlacement, show: true);
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

            if (_disposed)
            {
                return;
            }

            replacement.ApplyPlacement(layout.PanelTarget, show: true);
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
        bool requireToolWindow)
    {
        var styles = NativeMethods.GetExtendedStyles(hwnd);
        var requiredStyles = NativeMethods.WsExTopmost;
        if (requireToolWindow)
        {
            requiredStyles |= NativeMethods.WsExToolWindow;
        }
        if (requireNoActivate)
        {
            requiredStyles |= NativeMethods.WsExNoActivate;
        }

        var styleHealthy = (styles & requiredStyles) == requiredStyles
            && (requireToolWindow || (styles & NativeMethods.WsExToolWindow) == 0)
            && (requireNoActivate || (styles & NativeMethods.WsExNoActivate) == 0);
        var visibilityHealthy = wpfVisible == expectedVisible
            && NativeMethods.IsWindowShown(hwnd) == expectedVisible;
        var frameHealthy = !checkFrame
            || (NativeMethods.TryGetWindowRect(hwnd, out var actual)
                && FrameMatches(actual, expectedFrame));
        return !styleHealthy || !visibilityHealthy || !frameHealthy;
    }

    private static void RepairStyles(
        IntPtr hwnd,
        bool requireNoActivate,
        bool requireToolWindow)
    {
        NativeMethods.SetToolWindowStyle(hwnd, requireToolWindow);
        NativeMethods.SetNoActivateStyle(hwnd, requireNoActivate);
        NativeMethods.SetTopmostNoActivate(hwnd);
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
        if (!_panel.IsVisible && IsTopEdgeSuppressed())
        {
            return;
        }

        if (_panel.IsVisible)
        {
            _closeDelayTimer.Stop();
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
                    $"panel={FormatTraceRect(layout?.PanelTarget.PhysicalRect)}")
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

    private static string FormatTraceRect(PhysicalRect? rect)
    {
        return rect is null
            ? "null"
            : $"{rect.Value.Left},{rect.Value.Top},{rect.Value.Width},{rect.Value.Height}";
    }

    private void ScheduleStagedRecovery()
    {
        if (_disposed)
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
        if (_disposed)
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

        var panelSizeChanged = _lastAppliedSettings.PanelSize != settings.PanelSize;
        var placementChanged = _lastAppliedSettings.DisplayPlacement != settings.DisplayPlacement;
        var voiceLaneChanged = _lastAppliedSettings.EffectiveVoiceLaneLayout != settings.EffectiveVoiceLaneLayout;
        _lastAppliedSettings = settings.Clone();
        ResyncDisplayLayout(
            animateVisiblePanel: (panelSizeChanged || voiceLaneChanged)
                && !placementChanged
                && !_deterministicVerification);
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
