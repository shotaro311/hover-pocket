using System.Windows;
using HoverPocket.Shell.Configuration;
using HoverPocket.Shell.Display;
using HoverPocket.Shell.Interop;
using HoverPocket.Shell.Windows;

namespace HoverPocket.Shell.Verification;

internal sealed class DisplayVerifier
{
    private readonly HoverShellController _controller;
    private readonly DisplayLayoutService _displayLayoutService = new();
    private readonly List<string> _failures = [];

    public DisplayVerifier(HoverShellController controller)
    {
        _controller = controller;
    }

    public async Task<int> RunAsync()
    {
        await Task.Delay(250);

        var monitors = _displayLayoutService.EnumerateMonitors();
        if (monitors.Count == 0)
        {
            _failures.Add("monitor enumeration returned zero displays");
        }

        foreach (var monitor in monitors)
        {
            VerifyMonitor(monitor);
        }

        VerifyPlacement(monitors, DisplayPlacement.Main);
        VerifyPlacement(monitors, DisplayPlacement.Sub);
        VerifyPlacement(monitors, DisplayPlacement.All);
        VerifyControllerWindows();

        if (_failures.Count == 0)
        {
            VerifyConsole.WriteLine(
                $"PASS display verify: monitors={monitors.Count}, current_surfaces={_controller.AccessSurfaces.Count}");
            foreach (var monitor in monitors)
            {
                VerifyConsole.WriteLine(
                    $"- {monitor.Id}: primary={monitor.IsPrimary}, bounds={Format(monitor.Bounds)}, dpi={monitor.DpiX}x{monitor.DpiY}");
            }

            return 0;
        }

        VerifyConsole.WriteLine("FAIL display verify:");
        foreach (var failure in _failures)
        {
            VerifyConsole.WriteLine($"- {failure}");
        }

        return 1;
    }

    private void VerifyMonitor(DisplayMonitor monitor)
    {
        if (monitor.Bounds.Width <= 0 || monitor.Bounds.Height <= 0)
        {
            _failures.Add($"{monitor.Id}: invalid bounds {Format(monitor.Bounds)}");
        }

        if (monitor.DpiX == 0 || monitor.DpiY == 0)
        {
            _failures.Add($"{monitor.Id}: invalid dpi {monitor.DpiX}x{monitor.DpiY}");
        }

        if (monitor.ScaleX <= 0 || monitor.ScaleY <= 0)
        {
            _failures.Add($"{monitor.Id}: invalid scale {monitor.ScaleX:0.###}x{monitor.ScaleY:0.###}");
        }
    }

    private void VerifyPlacement(IReadOnlyList<DisplayMonitor> monitors, DisplayPlacement placement)
    {
        var targets = _displayLayoutService.ResolveTargets(monitors, placement);
        var layouts = targets.Select(_displayLayoutService.CreateLayout).ToArray();
        var expectedCount = placement == DisplayPlacement.All ? monitors.Count : Math.Min(1, monitors.Count);

        if (layouts.Length != expectedCount)
        {
            _failures.Add($"{placement}: expected {expectedCount} layouts, got {layouts.Length}");
        }

        if (placement == DisplayPlacement.Main && targets.Count > 0 && !targets[0].IsPrimary)
        {
            _failures.Add("Main: first target is not primary");
        }

        if (placement == DisplayPlacement.Sub && targets.Count > 0)
        {
            var hasSub = monitors.Any(monitor => !monitor.IsPrimary);
            if (hasSub && targets[0].IsPrimary)
            {
                _failures.Add("Sub: secondary monitor exists but target fell back to primary");
            }

            if (!hasSub && !targets[0].IsPrimary)
            {
                _failures.Add("Sub: no secondary monitor exists but fallback target is not primary");
            }
        }

        foreach (var layout in layouts)
        {
            VerifyLayout(placement, layout);
        }
    }

    private void VerifyLayout(DisplayPlacement placement, DisplaySurfaceLayout layout)
    {
        var label = $"{placement}/{layout.Monitor.Id}";
        VerifyContained(label, "access", layout.Monitor.Bounds, layout.AccessSurface.PhysicalRect);
        VerifyContained(label, "panel", layout.Monitor.Bounds, layout.PanelTarget.PhysicalRect);
        VerifyContained(label, "collapsed", layout.Monitor.Bounds, layout.PanelCollapsed.PhysicalRect);

        if (layout.AccessSurface.PhysicalRect.Top != layout.Monitor.Bounds.Top)
        {
            _failures.Add($"{label}: access top is not monitor top");
        }

        VerifyRoundTrip(label, "access", layout.Monitor, layout.AccessSurface);
        VerifyRoundTrip(label, "panel", layout.Monitor, layout.PanelTarget);
        VerifyRoundTrip(label, "collapsed", layout.Monitor, layout.PanelCollapsed);
    }

    private void VerifyContained(string label, string name, PhysicalRect bounds, PhysicalRect rect)
    {
        if (!bounds.Contains(rect))
        {
            _failures.Add($"{label}: {name} rect {Format(rect)} is outside monitor {Format(bounds)}");
        }
    }

    private void VerifyRoundTrip(string label, string name, DisplayMonitor monitor, WindowPlacement placement)
    {
        var physicalFromDip = _displayLayoutService.DipToPhysical(placement.DipRect, monitor);
        var dipFromPhysical = _displayLayoutService.PhysicalToDip(placement.PhysicalRect, monitor);

        if (!ApproximatelyEqual(physicalFromDip, placement.PhysicalRect, 1)
            || !ApproximatelyEqual(dipFromPhysical, placement.DipRect, 0.75))
        {
            _failures.Add(
                $"{label}: {name} DIP/physical conversion mismatch, dip={Format(placement.DipRect)}, physical={Format(placement.PhysicalRect)}");
        }
    }

    private void VerifyControllerWindows()
    {
        if (_controller.Layouts.Count != _controller.AccessSurfaces.Count)
        {
            _failures.Add(
                $"controller: layout count {_controller.Layouts.Count} does not match access surface count {_controller.AccessSurfaces.Count}");
        }

        for (var index = 0; index < _controller.AccessSurfaces.Count && index < _controller.Layouts.Count; index++)
        {
            var accessSurface = _controller.AccessSurfaces[index];
            var expected = _controller.Layouts[index].AccessSurface.PhysicalRect;
            if (!NativeMethods.TryGetWindowRect(accessSurface.Hwnd, out var actualNative))
            {
                _failures.Add($"controller: access surface {index} has no window rect");
                continue;
            }

            var actual = PhysicalRect.FromNative(actualNative);
            if (!ApproximatelyEqual(actual, expected, 2))
            {
                _failures.Add(
                    $"controller: access surface {index} rect {Format(actual)} does not match expected {Format(expected)}");
            }
        }
    }

    private static bool ApproximatelyEqual(Rect actual, Rect expected, double tolerance)
    {
        return Math.Abs(actual.Left - expected.Left) <= tolerance
            && Math.Abs(actual.Top - expected.Top) <= tolerance
            && Math.Abs(actual.Width - expected.Width) <= tolerance
            && Math.Abs(actual.Height - expected.Height) <= tolerance;
    }

    private static bool ApproximatelyEqual(PhysicalRect actual, PhysicalRect expected, int tolerance)
    {
        return Math.Abs(actual.Left - expected.Left) <= tolerance
            && Math.Abs(actual.Top - expected.Top) <= tolerance
            && Math.Abs(actual.Width - expected.Width) <= tolerance
            && Math.Abs(actual.Height - expected.Height) <= tolerance;
    }

    private static string Format(PhysicalRect rect)
    {
        return $"{rect.Left},{rect.Top} {rect.Width}x{rect.Height}";
    }

    private static string Format(Rect rect)
    {
        return $"{rect.Left:0.###},{rect.Top:0.###} {rect.Width:0.###}x{rect.Height:0.###}";
    }
}
