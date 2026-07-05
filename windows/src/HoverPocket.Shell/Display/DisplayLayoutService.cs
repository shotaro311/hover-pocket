using System.Windows;
using HoverPocket.Shell.Configuration;
using HoverPocket.Shell.Interop;
using HoverPocket.Shell.Windows;

namespace HoverPocket.Shell.Display;

internal sealed class DisplayLayoutService
{
    public IReadOnlyList<DisplayMonitor> EnumerateMonitors()
    {
        var monitors = NativeMethods.EnumerateDisplayMonitors()
            .Select((monitor, index) => new DisplayMonitor(
                $"monitor-{index}-{monitor.Handle.ToInt64():X}",
                PhysicalRect.FromNative(monitor.MonitorBounds),
                PhysicalRect.FromNative(monitor.WorkArea),
                monitor.IsPrimary,
                monitor.DpiX,
                monitor.DpiY))
            .OrderByDescending(monitor => monitor.IsPrimary)
            .ThenBy(monitor => monitor.Bounds.Left)
            .ThenBy(monitor => monitor.Bounds.Top)
            .ToArray();

        if (monitors.Length == 0)
        {
            return
            [
                new DisplayMonitor(
                    "fallback-primary",
                    new PhysicalRect(0, 0, 1920, 1080),
                    new PhysicalRect(0, 0, 1920, 1040),
                    true,
                    96,
                    96)
            ];
        }

        return monitors;
    }

    public IReadOnlyList<DisplaySurfaceLayout> CreateLayouts(DisplayPlacement placement)
    {
        var monitors = EnumerateMonitors();
        return ResolveTargets(monitors, placement)
            .Select(CreateLayout)
            .ToArray();
    }

    public IReadOnlyList<DisplayMonitor> ResolveTargets(IReadOnlyList<DisplayMonitor> monitors, DisplayPlacement placement)
    {
        if (monitors.Count == 0)
        {
            return [];
        }

        var primary = monitors.FirstOrDefault(monitor => monitor.IsPrimary) ?? monitors[0];
        return placement switch
        {
            DisplayPlacement.All => monitors,
            DisplayPlacement.Sub => [monitors.FirstOrDefault(monitor => !monitor.IsPrimary) ?? primary],
            _ => [primary]
        };
    }

    public DisplaySurfaceLayout CreateLayout(DisplayMonitor monitor)
    {
        var accessWidth = DipToPhysical(AccessSurfaceWindow.SurfaceWidth, monitor.ScaleX);
        var accessHeight = DipToPhysical(AccessSurfaceWindow.SurfaceHeight, monitor.ScaleY);
        var panelWidth = Math.Min(DipToPhysical(PanelWindow.PanelWidth, monitor.ScaleX), monitor.Bounds.Width);
        var panelHeight = Math.Min(
            DipToPhysical(PanelWindow.PanelHeight, monitor.ScaleY),
            Math.Max(1, monitor.Bounds.Height - accessHeight));

        var access = new PhysicalRect(
            monitor.Bounds.Left + (monitor.Bounds.Width - accessWidth) / 2,
            monitor.Bounds.Top,
            Math.Min(accessWidth, monitor.Bounds.Width),
            accessHeight).ClampTo(monitor.Bounds);

        var panelTarget = new PhysicalRect(
            monitor.Bounds.Left + (monitor.Bounds.Width - panelWidth) / 2,
            monitor.Bounds.Top + access.Height,
            panelWidth,
            panelHeight).ClampTo(monitor.Bounds);

        var collapsed = new PhysicalRect(
            panelTarget.Left + (panelTarget.Width - access.Width) / 2,
            panelTarget.Top,
            access.Width,
            access.Height).ClampTo(monitor.Bounds);

        return new DisplaySurfaceLayout(
            monitor,
            ToPlacement(access, monitor),
            ToPlacement(panelTarget, monitor),
            ToPlacement(collapsed, monitor));
    }

    public PhysicalRect DipToPhysical(Rect dipRect, DisplayMonitor monitor)
    {
        return new PhysicalRect(
            DipToPhysical(dipRect.Left, monitor.ScaleX),
            DipToPhysical(dipRect.Top, monitor.ScaleY),
            DipToPhysical(dipRect.Width, monitor.ScaleX),
            DipToPhysical(dipRect.Height, monitor.ScaleY));
    }

    public Rect PhysicalToDip(PhysicalRect physicalRect, DisplayMonitor monitor)
    {
        return new Rect(
            physicalRect.Left / monitor.ScaleX,
            physicalRect.Top / monitor.ScaleY,
            physicalRect.Width / monitor.ScaleX,
            physicalRect.Height / monitor.ScaleY);
    }

    private WindowPlacement ToPlacement(PhysicalRect physicalRect, DisplayMonitor monitor)
    {
        return new WindowPlacement(PhysicalToDip(physicalRect, monitor), physicalRect);
    }

    private static int DipToPhysical(double dips, double scale)
    {
        return Math.Max(1, (int)Math.Round(dips * scale, MidpointRounding.AwayFromZero));
    }
}
