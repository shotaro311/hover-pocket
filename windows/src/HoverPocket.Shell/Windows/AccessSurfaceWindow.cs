using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using WpfColor = System.Windows.Media.Color;

namespace HoverPocket.Shell.Windows;

internal sealed class AccessSurfaceWindow : NoActivateWindow
{
    public const double SurfaceWidth = 168;
    public const double SurfaceHeight = 9;

    private static readonly WpfColor DefaultBackgroundColor = WpfColor.FromArgb(238, 13, 15, 20);
    private static readonly WpfColor DefaultBorderColor = WpfColor.FromArgb(80, 255, 255, 255);
    private readonly Border _surface;

    public event EventHandler? HoverEntered;

    public AccessSurfaceWindow()
    {
        Width = SurfaceWidth;
        Height = SurfaceHeight;
        MinWidth = SurfaceWidth;
        MinHeight = SurfaceHeight;
        MaxWidth = SurfaceWidth;
        MaxHeight = SurfaceHeight;

        _surface = new Border
        {
            Background = new SolidColorBrush(DefaultBackgroundColor),
            BorderBrush = new SolidColorBrush(DefaultBorderColor),
            BorderThickness = new Thickness(1, 0, 1, 1),
            CornerRadius = new CornerRadius(0, 0, 7, 7),
            SnapsToDevicePixels = true
        };
        Content = _surface;

        MouseEnter += (_, _) => HoverEntered?.Invoke(this, EventArgs.Empty);
    }

    public void SetAlertHighlight(WpfColor? color)
    {
        if (color is null)
        {
            _surface.Background = new SolidColorBrush(DefaultBackgroundColor);
            _surface.BorderBrush = new SolidColorBrush(DefaultBorderColor);
            return;
        }

        var highlight = color.Value;
        _surface.Background = new SolidColorBrush(WpfColor.FromArgb(246, highlight.R, highlight.G, highlight.B));
        _surface.BorderBrush = new SolidColorBrush(WpfColor.FromArgb(230, 255, 255, 255));
    }
}
