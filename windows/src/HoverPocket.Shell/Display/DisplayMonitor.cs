namespace HoverPocket.Shell.Display;

internal sealed record DisplayMonitor(
    string Id,
    PhysicalRect Bounds,
    PhysicalRect WorkArea,
    bool IsPrimary,
    uint DpiX,
    uint DpiY)
{
    public double ScaleX => Math.Max(1, DpiX / 96.0);
    public double ScaleY => Math.Max(1, DpiY / 96.0);
}
