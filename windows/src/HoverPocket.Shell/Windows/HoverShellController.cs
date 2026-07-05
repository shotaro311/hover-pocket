using System.Windows;
using System.Windows.Threading;
using HoverPocket.Shell.Bridge;
using HoverPocket.Shell.Configuration;
using HoverPocket.Shell.Display;
using HoverPocket.Shell.Interop;
using HoverPocket.Shell.Providers;
using Microsoft.Win32;
using System.Runtime.InteropServices;
using WinForms = System.Windows.Forms;

namespace HoverPocket.Shell.Windows;

internal sealed class HoverShellController : IDisposable
{
    public static readonly TimeSpan CloseDelay = TimeSpan.FromMilliseconds(60);
    public static readonly TimeSpan PollingInterval = TimeSpan.FromMilliseconds(120);
    public const double HoverToleranceDips = 4;

    private readonly Dispatcher _dispatcher;
    private readonly ShellSettings _settings;
    private readonly PanelBridgeController _panelBridgeController;
    private readonly DisplayLayoutService _displayLayoutService = new();
    private readonly List<AccessSurfaceWindow> _accessSurfaces = [];
    private readonly Dictionary<AccessSurfaceWindow, DisplaySurfaceLayout> _surfaceLayouts = [];
    private readonly PanelWindow _panel;
    private readonly DispatcherTimer _pollingTimer;
    private readonly DispatcherTimer _closeDelayTimer;
    private readonly DispatcherTimer _resyncTimer;
    private IReadOnlyList<DisplaySurfaceLayout> _layouts = [];
    private DisplaySurfaceLayout? _activeLayout;
    private bool _systemEventsSubscribed;
    private bool _disposed;

    public HoverShellController(
        Dispatcher dispatcher,
        ShellSettings settings,
        ProviderRegistry providerRegistry,
        UserSettingsStore userSettingsStore,
        bool enablePanelWebView)
    {
        _dispatcher = dispatcher;
        _settings = settings;
        var userSettings = userSettingsStore.Load(providerRegistry.ProviderIds);
        _panelBridgeController = new PanelBridgeController(providerRegistry, userSettingsStore, userSettings);
        _panelBridgeController.SettingsChanged += OnPanelSettingsChanged;
        _panel = new PanelWindow(_panelBridgeController, enablePanelWebView);

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
            if (!IsPointerInHoverRegion(out _))
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

    public async Task ShowPanelForVerifyAsync()
    {
        await ShowPanelAsync(ResolveLayoutForPointer());
    }

    public async Task ShowPanelForUiVerifyAsync()
    {
        await _panel.EnsureWebViewInitializedAsync();
        await ShowPanelAsync(ResolveLayoutForPointer());
    }

    public async Task HidePanelForVerifyAsync()
    {
        _closeDelayTimer.Stop();
        await HidePanelAsync();
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

        _activeLayout = layout;
        _closeDelayTimer.Stop();
        await _panel.EnsureWebViewInitializedAsync();
        await _panel.OpenAsync(layout);
    }

    private async Task HidePanelAsync()
    {
        if (_activeLayout is null)
        {
            return;
        }

        await _panel.CloseAsync(_activeLayout);
    }

    private void PollPointer()
    {
        if (IsPointerInHoverRegion(out var hoveredLayout))
        {
            _closeDelayTimer.Stop();
            if (!_panel.IsVisible || _panel.Opacity < 0.99)
            {
                _ = ShowPanelAsync(hoveredLayout ?? ResolveLayoutForPointer());
            }

            return;
        }

        if (_panel.IsVisible && !_closeDelayTimer.IsEnabled)
        {
            _closeDelayTimer.Start();
        }
    }

    private bool IsPointerInHoverRegion(out DisplaySurfaceLayout? hoveredLayout)
    {
        hoveredLayout = null;
        var pointer = WinForms.Control.MousePosition;
        foreach (var accessSurface in _accessSurfaces)
        {
            if (!IsInsideInflatedWindow(accessSurface.Hwnd, pointer.X, pointer.Y))
            {
                continue;
            }

            hoveredLayout = _surfaceLayouts.GetValueOrDefault(accessSurface);
            return true;
        }

        return _panel.IsVisible && IsInsideInflatedWindow(_panel.Hwnd, pointer.X, pointer.Y);
    }

    private static bool IsInsideInflatedWindow(IntPtr hwnd, int x, int y)
    {
        if (hwnd == IntPtr.Zero || !NativeMethods.TryGetWindowRect(hwnd, out var rect))
        {
            return false;
        }

        var padding = (int)Math.Ceiling(HoverToleranceDips * NativeMethods.GetScaleForWindow(hwnd));
        return rect.Inflate(padding).Contains(x, y);
    }

    private void ResyncDisplayLayout()
    {
        if (_disposed)
        {
            return;
        }

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

        _activeLayout = ResolveLayoutForPointer() ?? _layouts.FirstOrDefault();

        if (!_panel.IsVisible)
        {
            if (_activeLayout is not null)
            {
                _panel.ApplyPlacement(_activeLayout.PanelCollapsed, show: false);
            }

            _panel.Opacity = 0;
            return;
        }

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
        if (sender is AccessSurfaceWindow accessSurface && _surfaceLayouts.TryGetValue(accessSurface, out var layout))
        {
            _ = ShowPanelAsync(layout);
            return;
        }

        ShowPanelFromUser();
    }

    private DisplaySurfaceLayout? ResolveLayoutForPointer()
    {
        if (_layouts.Count == 0)
        {
            return null;
        }

        var pointer = WinForms.Control.MousePosition;
        return _layouts.FirstOrDefault(layout => layout.Monitor.Bounds.Contains(pointer.X, pointer.Y))
            ?? _activeLayout
            ?? _layouts[0];
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
