using System.Windows;
using System.Windows.Media;
using System.Windows.Threading;
using System.IO;
using HoverPocket.Shell.Bridge;
using HoverPocket.Shell.Configuration;
using HoverPocket.Shell.Display;
using HoverPocket.Shell.Interop;
using HoverPocket.Shell.Providers;
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
    public const double HoverToleranceDips = 4;

    private readonly Dispatcher _dispatcher;
    private readonly ShellSettings _settings;
    private readonly bool _enableDevTools;
    private readonly PanelBridgeController _panelBridgeController;
    private readonly DisplayLayoutService _displayLayoutService = new();
    private readonly List<AccessSurfaceWindow> _accessSurfaces = [];
    private readonly Dictionary<AccessSurfaceWindow, DisplaySurfaceLayout> _surfaceLayouts = [];
    private readonly string? _hoverTracePath = NormalizeTracePath();
    private readonly PanelWindow _panel;
    private readonly DispatcherTimer _pollingTimer;
    private readonly DispatcherTimer _closeDelayTimer;
    private readonly DispatcherTimer _resyncTimer;
    private IReadOnlyList<DisplaySurfaceLayout> _layouts = [];
    private DisplaySurfaceLayout? _activeLayout;
    private TimerAlert? _activeTimerAlert;
    private SettingsWindow? _settingsWindow;
    private (int X, int Y)? _pointerOverrideForVerify;
    private Task? _closingTask;
    private bool _systemEventsSubscribed;
    private bool _timerAlertActive;
    private bool _disposed;

    public HoverShellController(
        Dispatcher dispatcher,
        ShellSettings settings,
        ProviderRegistry providerRegistry,
        UserSettingsStore userSettingsStore,
        bool enablePanelWebView,
        bool enableDevTools,
        Services.UpdaterService? updaterService = null)
    {
        _dispatcher = dispatcher;
        _settings = settings;
        _enableDevTools = enableDevTools;
        var userSettings = userSettingsStore.Load(providerRegistry.ProviderIds);
        _panelBridgeController = new PanelBridgeController(
            providerRegistry,
            userSettingsStore,
            userSettings,
            updaterService: updaterService);
        _panelBridgeController.SettingsChanged += OnPanelSettingsChanged;
        _panelBridgeController.SettingsOpenRequested += OnSettingsOpenRequested;
        _panelBridgeController.TimerAlertFired += OnTimerAlertFired;
        _panelBridgeController.TimerAlertChanged += OnTimerAlertChanged;
        _panelBridgeController.ExternalDragStarted += OnExternalDragStarted;
        _panel = new PanelWindow(_panelBridgeController, enablePanelWebView, enableDevTools);

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
            if (!_timerAlertActive && !inside)
            {
                _ = HidePanelAsync();
            }
        };

        _resyncTimer = new DispatcherTimer(DispatcherPriority.Background, _dispatcher)
        {
            Interval = TimeSpan.FromMilliseconds(180)
        };
        _resyncTimer.Tick += (_, _) =>
        {
            _resyncTimer.Stop();
            ResyncDisplayLayout();
        };

        TrySubscribeSystemEvents();
    }

    public AccessSurfaceWindow AccessSurface => _accessSurfaces[0];

    public IReadOnlyList<AccessSurfaceWindow> AccessSurfaces => _accessSurfaces;

    public IReadOnlyList<DisplaySurfaceLayout> Layouts => _layouts;

    public PanelWindow Panel => _panel;

    public PanelBridgeController PanelBridgeController => _panelBridgeController;

    public DisplaySurfaceLayout? ActiveLayoutForVerify => _activeLayout;

    public void Start()
    {
        _panel.EnsureHandle();
        _panel.Win32MessageReceived += OnWindowWin32MessageReceived;
        ResyncDisplayLayout();
        _pollingTimer.Start();
    }

    public void ShowPanelFromUser()
    {
        _ = ShowPanelAsync(ResolveLayoutForPointer());
    }

    public void OpenSettingsFromUser()
    {
        _ = OpenSettingsAsync();
    }

    public async Task ShowPanelForVerifyAsync()
    {
        await RunWithPollingPausedForVerifyAsync(() => ShowPanelAsync(ResolveLayoutForPointer()));
    }

    public async Task ShowPanelForUiVerifyAsync()
    {
        await _panel.EnsureWebViewInitializedAsync();
        await RunWithPollingPausedForVerifyAsync(() => ShowPanelAsync(ResolveLayoutForPointer()));
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
        _resyncTimer.Stop();
        if (_systemEventsSubscribed)
        {
            SystemEvents.DisplaySettingsChanged -= OnDisplaySettingsChanged;
            SystemEvents.PowerModeChanged -= OnPowerModeChanged;
            _systemEventsSubscribed = false;
        }

        _panel.Win32MessageReceived -= OnWindowWin32MessageReceived;
        _panelBridgeController.SettingsChanged -= OnPanelSettingsChanged;
        _panelBridgeController.SettingsOpenRequested -= OnSettingsOpenRequested;
        _panelBridgeController.TimerAlertFired -= OnTimerAlertFired;
        _panelBridgeController.TimerAlertChanged -= OnTimerAlertChanged;
        _panelBridgeController.ExternalDragStarted -= OnExternalDragStarted;
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

    private async Task ShowPanelAsync(DisplaySurfaceLayout? layout)
    {
        layout ??= _layouts.FirstOrDefault();
        if (layout is null)
        {
            return;
        }

        if (_closingTask is { IsCompleted: false })
        {
            await _closingTask;
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

    private async Task HidePanelAsync()
    {
        if (_closingTask is { IsCompleted: false } closingTask)
        {
            await closingTask;
            return;
        }

        _closingTask = HidePanelCoreAsync();
        await _closingTask;
    }

    private async Task HidePanelCoreAsync()
    {
        if (_activeLayout is null)
        {
            return;
        }

        TraceHover("close", GetPointerPosition(), false, _activeLayout, "panel-close");
        await _panel.CloseAsync(_activeLayout);
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

        _settingsWindow = new SettingsWindow(_panelBridgeController, _enableDevTools);
        _settingsWindow.Closed += (_, _) => _settingsWindow = null;
        _settingsWindow.Show();
        _settingsWindow.Activate();
    }

    private void PollPointer()
    {
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

    private void ResyncDisplayLayout()
    {
        if (_disposed)
        {
            return;
        }

        var previousActiveLayout = _activeLayout;
        _layouts = _displayLayoutService.CreateLayouts(
            _settings.DisplayPlacement,
            _panelBridgeController.CurrentSettings.PanelSize);
        EnsureAccessSurfaceCount(_layouts.Count);
        _surfaceLayouts.Clear();

        for (var index = 0; index < _layouts.Count; index++)
        {
            var accessSurface = _accessSurfaces[index];
            var layout = _layouts[index];
            _surfaceLayouts[accessSurface] = layout;
            accessSurface.ApplyPlacement(layout.AccessSurface, show: true);
        }

        if (!_panel.IsVisible)
        {
            _activeLayout = ResolveLayoutForPointer() ?? _layouts.FirstOrDefault();
            if (_activeLayout is not null)
            {
                _panel.ApplyPlacement(_activeLayout.PanelCollapsed, show: false);
            }

            _panel.Opacity = 0;
            return;
        }

        _activeLayout = ResolveLayoutMatching(previousActiveLayout) ?? _layouts.FirstOrDefault();
        if (_activeLayout is not null)
        {
            _panel.ApplyPlacement(_activeLayout.PanelTarget, show: true);
        }
    }

    private void EnsureAccessSurfaceCount(int count)
    {
        while (_accessSurfaces.Count < count)
        {
            var accessSurface = new AccessSurfaceWindow();
            accessSurface.HoverEntered += OnAccessSurfaceHoverEntered;
            accessSurface.Win32MessageReceived += OnWindowWin32MessageReceived;
            accessSurface.EnsureHandle();
            if (_activeTimerAlert is not null)
            {
                accessSurface.SetAlertHighlight(ToHighlightColor(_activeTimerAlert.Color));
            }

            _accessSurfaces.Add(accessSurface);
        }

        while (_accessSurfaces.Count > count)
        {
            var lastIndex = _accessSurfaces.Count - 1;
            var accessSurface = _accessSurfaces[lastIndex];
            accessSurface.HoverEntered -= OnAccessSurfaceHoverEntered;
            accessSurface.Win32MessageReceived -= OnWindowWin32MessageReceived;
            accessSurface.Close();
            _surfaceLayouts.Remove(accessSurface);
            _accessSurfaces.RemoveAt(lastIndex);
        }
    }

    private void OnAccessSurfaceHoverEntered(object? sender, EventArgs e)
    {
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

    private void ScheduleDisplayResync()
    {
        if (_disposed)
        {
            return;
        }

        if (!_dispatcher.CheckAccess())
        {
            _dispatcher.BeginInvoke(ScheduleDisplayResync);
            return;
        }

        _resyncTimer.Stop();
        _resyncTimer.Start();
    }

    private void OnWindowWin32MessageReceived(object? sender, Win32MessageEventArgs e)
    {
        if (e.Message is NativeMethods.WmDisplayChange or NativeMethods.WmDpiChanged)
        {
            ScheduleDisplayResync();
        }
    }

    private void OnDisplaySettingsChanged(object? sender, EventArgs e)
    {
        ScheduleDisplayResync();
    }

    private void OnPowerModeChanged(object? sender, PowerModeChangedEventArgs e)
    {
        if (e.Mode == PowerModes.Resume)
        {
            ScheduleDisplayResync();
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
        await ShowPanelAsync(ResolveLayoutForPointer());
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

        _panel.ApplyPanelSize(settings.PanelSize);
        ResyncDisplayLayout();
    }

    private void TrySubscribeSystemEvents()
    {
        var displaySubscribed = false;
        var powerSubscribed = false;
        try
        {
            SystemEvents.DisplaySettingsChanged += OnDisplaySettingsChanged;
            displaySubscribed = true;
            SystemEvents.PowerModeChanged += OnPowerModeChanged;
            powerSubscribed = true;
            _systemEventsSubscribed = true;
        }
        catch (ExternalException)
        {
            RollBackSystemEventSubscriptions(displaySubscribed, powerSubscribed);
            _systemEventsSubscribed = false;
        }
        catch (InvalidOperationException)
        {
            RollBackSystemEventSubscriptions(displaySubscribed, powerSubscribed);
            _systemEventsSubscribed = false;
        }
    }

    private void RollBackSystemEventSubscriptions(bool displaySubscribed, bool powerSubscribed)
    {
        if (displaySubscribed)
        {
            SystemEvents.DisplaySettingsChanged -= OnDisplaySettingsChanged;
        }

        if (powerSubscribed)
        {
            SystemEvents.PowerModeChanged -= OnPowerModeChanged;
        }
    }
}
