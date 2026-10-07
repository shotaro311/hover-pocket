namespace HoverPocket.Shell.Configuration;

internal sealed partial record PanelResizeLimits
{
    internal System.Windows.Size Clamp(System.Windows.Size size) => new(
        Math.Clamp(size.Width, MinWidth, MaxWidth), Math.Clamp(size.Height, MinHeight, MaxHeight));
}
