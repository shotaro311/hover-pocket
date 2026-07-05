using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using HoverPocket.Shell.Display;
using HoverPocket.Shell.Interop;

namespace HoverPocket.Shell.Windows;

internal sealed class PanelWindow : NoActivateWindow
{
    public const double PanelWidth = 600;
    public const double PanelHeight = 430;
    public const double CollapsedWidth = AccessSurfaceWindow.SurfaceWidth;
    public const double CollapsedHeight = AccessSurfaceWindow.SurfaceHeight;
    public static readonly TimeSpan AnimationDuration = TimeSpan.FromMilliseconds(220);

    private int _animationGeneration;

    public PanelWindow()
    {
        Width = PanelWidth;
        Height = PanelHeight;
        Content = new Border
        {
            Background = new SolidColorBrush(System.Windows.Media.Color.FromArgb(246, 15, 17, 23)),
            BorderBrush = new SolidColorBrush(System.Windows.Media.Color.FromArgb(74, 255, 255, 255)),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(18),
            SnapsToDevicePixels = true,
            Child = new Grid()
        };
    }

    public async Task OpenAsync(DisplaySurfaceLayout layout)
    {
        var generation = ++_animationGeneration;
        WindowPlacement from;

        if (!IsVisible)
        {
            ApplyPlacement(layout.PanelCollapsed, show: true);
            Opacity = 0;
            from = layout.PanelCollapsed;
        }
        else
        {
            ShowNoActivate();
            from = GetCurrentPlacement(layout.PanelCollapsed);
        }

        await AnimateToAsync(from, layout.PanelTarget, 1, generation);
        if (generation == _animationGeneration)
        {
            ApplyPlacement(layout.PanelTarget, show: true);
            Opacity = 1;
        }
    }

    public async Task CloseAsync(DisplaySurfaceLayout layout)
    {
        if (!IsVisible)
        {
            return;
        }

        var generation = ++_animationGeneration;
        var from = GetCurrentPlacement(layout.PanelTarget);

        await AnimateToAsync(from, layout.PanelCollapsed, 0, generation);
        if (generation == _animationGeneration)
        {
            Hide();
            ApplyPlacement(layout.PanelCollapsed, show: false);
            Opacity = 0;
        }
    }

    private WindowPlacement GetCurrentPlacement(WindowPlacement fallback)
    {
        var dipRect = new Rect(Left, Top, Width, Height);
        if (Hwnd == IntPtr.Zero || !NativeMethods.TryGetWindowRect(Hwnd, out var nativeRect))
        {
            return new WindowPlacement(dipRect, fallback.PhysicalRect);
        }

        return new WindowPlacement(dipRect, PhysicalRect.FromNative(nativeRect));
    }

    private async Task AnimateToAsync(
        WindowPlacement from,
        WindowPlacement to,
        double targetOpacity,
        int generation)
    {
        var startOpacity = Opacity;
        var start = DateTimeOffset.UtcNow;

        while (true)
        {
            if (generation != _animationGeneration)
            {
                return;
            }

            var elapsed = DateTimeOffset.UtcNow - start;
            var progress = Math.Clamp(elapsed.TotalMilliseconds / AnimationDuration.TotalMilliseconds, 0, 1);
            var eased = EaseOutCubic(progress);
            ApplyPlacement(Interpolate(from, to, eased), show: true);
            Opacity = Interpolate(startOpacity, targetOpacity, eased);

            if (progress >= 1)
            {
                return;
            }

            await Task.Delay(16);
        }
    }

    private static WindowPlacement Interpolate(WindowPlacement from, WindowPlacement to, double progress)
    {
        return new WindowPlacement(
            new Rect(
                Interpolate(from.DipRect.Left, to.DipRect.Left, progress),
                Interpolate(from.DipRect.Top, to.DipRect.Top, progress),
                Interpolate(from.DipRect.Width, to.DipRect.Width, progress),
                Interpolate(from.DipRect.Height, to.DipRect.Height, progress)),
            new PhysicalRect(
                Interpolate(from.PhysicalRect.Left, to.PhysicalRect.Left, progress),
                Interpolate(from.PhysicalRect.Top, to.PhysicalRect.Top, progress),
                Interpolate(from.PhysicalRect.Width, to.PhysicalRect.Width, progress),
                Interpolate(from.PhysicalRect.Height, to.PhysicalRect.Height, progress)));
    }

    private static int Interpolate(int from, int to, double progress)
    {
        return (int)Math.Round(Interpolate((double)from, to, progress), MidpointRounding.AwayFromZero);
    }

    private static double Interpolate(double from, double to, double progress)
    {
        return from + ((to - from) * progress);
    }

    private static double EaseOutCubic(double progress)
    {
        var inverse = 1 - progress;
        return 1 - (inverse * inverse * inverse);
    }
}
