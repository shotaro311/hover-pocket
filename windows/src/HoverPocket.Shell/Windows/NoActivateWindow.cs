using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using HoverPocket.Shell.Display;
using HoverPocket.Shell.Interop;

namespace HoverPocket.Shell.Windows;

internal abstract class NoActivateWindow : Window
{
    public IntPtr Hwnd { get; private set; }

    public event EventHandler<Win32MessageEventArgs>? Win32MessageReceived;

    private HwndSource? _source;

    protected NoActivateWindow(bool allowsTransparency = true)
    {
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        ShowActivated = false;
        Topmost = true;
        Focusable = false;
        AllowsTransparency = allowsTransparency;
        Background = allowsTransparency
            ? System.Windows.Media.Brushes.Transparent
            : new SolidColorBrush(System.Windows.Media.Color.FromRgb(3, 3, 5));
    }

    public void EnsureHandle()
    {
        if (Hwnd != IntPtr.Zero)
        {
            return;
        }

        Opacity = 0;
        Show();
        Hide();
        Opacity = 1;
    }

    public void ShowNoActivate()
    {
        if (!IsVisible)
        {
            Show();
        }

        if (Hwnd != IntPtr.Zero)
        {
            NativeMethods.ShowNoActivate(Hwnd);
        }
    }

    public void ApplyPlacement(WindowPlacement placement, bool show)
    {
        Left = placement.DipRect.Left;
        Top = placement.DipRect.Top;
        Width = placement.DipRect.Width;
        Height = placement.DipRect.Height;

        if (show && !IsVisible)
        {
            Show();
        }

        if (Hwnd != IntPtr.Zero)
        {
            NativeMethods.SetWindowBoundsNoActivate(
                Hwnd,
                placement.PhysicalRect.Left,
                placement.PhysicalRect.Top,
                placement.PhysicalRect.Width,
                placement.PhysicalRect.Height,
                show);
        }
    }

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        Hwnd = new WindowInteropHelper(this).Handle;
        NativeMethods.AddExtendedStyles(
            Hwnd,
            NativeMethods.WsExNoActivate | NativeMethods.WsExToolWindow);
        NativeMethods.SetTopmostNoActivate(Hwnd);
        _source = HwndSource.FromHwnd(Hwnd);
        _source?.AddHook(WndProc);
    }

    protected override void OnClosed(EventArgs e)
    {
        if (_source is not null)
        {
            _source.RemoveHook(WndProc);
            _source = null;
        }

        base.OnClosed(e);
    }

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == NativeMethods.WmMouseActivate)
        {
            handled = true;
            return new IntPtr(NativeMethods.MaNoActivate);
        }

        Win32MessageReceived?.Invoke(this, new Win32MessageEventArgs(hwnd, msg, wParam, lParam));
        return IntPtr.Zero;
    }
}

internal sealed class Win32MessageEventArgs : EventArgs
{
    public Win32MessageEventArgs(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam)
    {
        Hwnd = hwnd;
        Message = message;
        WParam = wParam;
        LParam = lParam;
    }

    public IntPtr Hwnd { get; }
    public int Message { get; }
    public IntPtr WParam { get; }
    public IntPtr LParam { get; }
}
