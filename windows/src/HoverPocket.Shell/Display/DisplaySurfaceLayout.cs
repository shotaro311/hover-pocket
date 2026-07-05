namespace HoverPocket.Shell.Display;

internal sealed record DisplaySurfaceLayout(
    DisplayMonitor Monitor,
    WindowPlacement AccessSurface,
    WindowPlacement PanelTarget,
    WindowPlacement PanelCollapsed);
