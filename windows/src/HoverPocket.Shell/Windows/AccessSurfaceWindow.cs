using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace HoverPocket.Shell.Windows;

internal sealed class AccessSurfaceWindow : NoActivateWindow
{
    public const double SurfaceWidth = 168;
    public const double SurfaceHeight = 9;

    public event EventHandler? HoverEntered;

    public AccessSurfaceWindow()
    {
        Width = SurfaceWidth;
        Height = SurfaceHeight;
        MinWidth = SurfaceWidth;
        MinHeight = SurfaceHeight;
        MaxWidth = SurfaceWidth;
        MaxHeight = SurfaceHeight;

        Content = new Border
        {
            Background = new SolidColorBrush(System.Windows.Media.Color.FromArgb(238, 13, 15, 20)),
            BorderBrush = new SolidColorBrush(System.Windows.Media.Color.FromArgb(80, 255, 255, 255)),
            BorderThickness = new Thickness(1, 0, 1, 1),
            CornerRadius = new CornerRadius(0, 0, 7, 7),
            SnapsToDevicePixels = true
        };

        MouseEnter += (_, _) => HoverEntered?.Invoke(this, EventArgs.Empty);
    }
}
