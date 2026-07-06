using HoverPocket.Shell.Interop;
using HoverPocket.Shell.Windows;
using HoverPocket.Shell.Display;
using System.Diagnostics;

namespace HoverPocket.Shell.Verification;

internal sealed class ShellVerifier
{
    private const int StressCycles = 25;
    private readonly HoverShellController _controller;
    private readonly List<string> _failures = [];

    public ShellVerifier(HoverShellController controller)
    {
        _controller = controller;
    }

    public async Task<int> RunAsync()
    {
        await Task.Delay(200);

        var beforeWindowCount = _controller.CountCurrentProcessTopLevelWindows();
        if (_controller.AccessSurfaces.Count == 0)
        {
            _failures.Add("access surface: no windows created");
        }

        for (var index = 0; index < _controller.AccessSurfaces.Count; index++)
        {
            VerifyWindow($"access surface {index}", _controller.AccessSurfaces[index].Hwnd);
        }

        VerifyWindow("panel", _controller.Panel.Hwnd);
        await VerifySecondInstanceAsync();
        await ResetPanelAfterSecondInstanceProbeAsync();
        await VerifyPanelPositionStableWhilePointerMovesAsync();
        await VerifyPointerOutsideClosesPanelAsync();

        for (var cycle = 0; cycle < StressCycles; cycle++)
        {
            await _controller.ShowPanelForVerifyAsync();
            await WaitForPanelPlacementAsync(_controller.ActiveLayoutForVerify);
            await _controller.HidePanelForVerifyAsync();
            await WaitForPanelHiddenAsync();
        }

        var afterWindowCount = _controller.CountCurrentProcessTopLevelWindows();
        if (afterWindowCount != beforeWindowCount)
        {
            _failures.Add($"top-level window count changed: before={beforeWindowCount}, after={afterWindowCount}");
        }

        if (_failures.Count == 0)
        {
            VerifyConsole.WriteLine(
                $"PASS shell verify: windows={afterWindowCount}, cycles={StressCycles}, stable_position=true, outside_close=true");
            return 0;
        }

        VerifyConsole.WriteLine("FAIL shell verify:");
        foreach (var failure in _failures)
        {
            VerifyConsole.WriteLine($"- {failure}");
        }

        return 1;
    }

    private void VerifyWindow(string name, IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero)
        {
            _failures.Add($"{name}: HWND is zero");
            return;
        }

        var styles = NativeMethods.GetExtendedStyles(hwnd);
        CheckStyle(name, styles, NativeMethods.WsExNoActivate, "WS_EX_NOACTIVATE");
        CheckStyle(name, styles, NativeMethods.WsExToolWindow, "WS_EX_TOOLWINDOW");
        CheckStyle(name, styles, NativeMethods.WsExTopmost, "WS_EX_TOPMOST");
    }

    private void CheckStyle(string name, long styles, long expected, string label)
    {
        if ((styles & expected) != expected)
        {
            _failures.Add($"{name}: missing {label}; exStyle=0x{styles:X}");
        }
    }

    private async Task VerifyPanelPositionStableWhilePointerMovesAsync()
    {
        var layout = _controller.Layouts.FirstOrDefault();
        if (layout is null)
        {
            _failures.Add("panel stability: no display layout available");
            return;
        }

        var accessCenter = CenterOf(layout.AccessSurface.PhysicalRect);
        _controller.SetPointerSimulationForVerify(accessCenter.X, accessCenter.Y);

        try
        {
            await _controller.ShowPanelForVerifyAsync();

            var activeLayout = _controller.ActiveLayoutForVerify;
            if (activeLayout is null)
            {
                _failures.Add("panel stability: active layout is null after open");
                return;
            }

            await WaitForPanelPlacementAsync(activeLayout);
            var baseline = CapturePanelPosition("panel stability baseline");
            if (baseline is null)
            {
                return;
            }

            foreach (var point in SampleInteriorPoints(activeLayout.PanelTarget.PhysicalRect))
            {
                _controller.SimulatePointerMoveForVerify(point.X, point.Y);
                await Task.Delay(30);

                var current = CapturePanelPosition("panel stability sample");
                if (current is null)
                {
                    return;
                }

                if (!SamePanelPosition(baseline.Value, current.Value))
                {
                    _failures.Add(
                        "panel stability: panel moved while pointer stayed inside; "
                        + $"before=({baseline.Value.WpfLeft:0.###},{baseline.Value.WpfTop:0.###})/"
                        + $"{baseline.Value.PhysicalLeft},{baseline.Value.PhysicalTop}, "
                        + $"after=({current.Value.WpfLeft:0.###},{current.Value.WpfTop:0.###})/"
                        + $"{current.Value.PhysicalLeft},{current.Value.PhysicalTop}");
                    return;
                }
            }
        }
        finally
        {
            _controller.ClearPointerSimulationForVerify();
            await _controller.HidePanelForVerifyAsync();
        }
    }

    private async Task VerifyPointerOutsideClosesPanelAsync()
    {
        var layout = _controller.Layouts.FirstOrDefault();
        if (layout is null)
        {
            _failures.Add("outside close: no display layout available");
            return;
        }

        var accessCenter = CenterOf(layout.AccessSurface.PhysicalRect);
        _controller.SetPointerSimulationForVerify(accessCenter.X, accessCenter.Y);

        try
        {
            await _controller.ShowPanelForVerifyAsync();
            var activeLayout = _controller.ActiveLayoutForVerify;
            if (activeLayout is null)
            {
                _failures.Add("outside close: active layout is null after open");
                return;
            }

            await WaitForPanelPlacementAsync(activeLayout);
            var outsidePoint = OutsideOf(activeLayout);
            _controller.SimulatePointerMoveForVerify(outsidePoint.X, outsidePoint.Y);
            await WaitForPanelHiddenAsync();

            if (_controller.Panel.IsVisible)
            {
                _failures.Add(
                    "outside close: panel remained visible after simulated pointer left hover region; "
                    + $"pointer={outsidePoint.X},{outsidePoint.Y}");
            }
        }
        finally
        {
            _controller.ClearPointerSimulationForVerify();
            if (_controller.Panel.IsVisible)
            {
                await _controller.HidePanelForVerifyAsync();
            }
        }
    }

    private async Task ResetPanelAfterSecondInstanceProbeAsync()
    {
        _controller.ClearPointerSimulationForVerify();
        if (!_controller.Panel.IsVisible)
        {
            return;
        }

        await _controller.HidePanelForVerifyAsync();
        await WaitForPanelHiddenAsync();
    }

    private async Task VerifySecondInstanceAsync()
    {
        var processPath = Environment.ProcessPath;
        if (string.IsNullOrWhiteSpace(processPath))
        {
            _failures.Add("second instance: current process path is unavailable");
            return;
        }

        using var process = Process.Start(new ProcessStartInfo(processPath)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            ArgumentList = { "--second-instance-probe" }
        });

        if (process is null)
        {
            _failures.Add("second instance: process failed to start");
            return;
        }

        var completed = await Task.Run(() => process.WaitForExit(5000));
        if (!completed)
        {
            try
            {
                process.Kill(entireProcessTree: true);
            }
            catch (InvalidOperationException)
            {
            }

            _failures.Add("second instance: process did not exit within 5s");
            return;
        }

        if (process.ExitCode != 0)
        {
            _failures.Add($"second instance: exit code {process.ExitCode}");
        }
    }

    private async Task WaitForPanelPlacementAsync(DisplaySurfaceLayout? layout)
    {
        if (layout is null)
        {
            return;
        }

        var deadline = DateTimeOffset.UtcNow + TimeSpan.FromSeconds(2);
        while (DateTimeOffset.UtcNow < deadline)
        {
            var position = CapturePanelPosition("panel placement wait");
            if (position is null)
            {
                return;
            }

            if (PositionMatches(position.Value, layout.PanelTarget.PhysicalRect, layout.PanelTarget.DipRect))
            {
                return;
            }

            await Task.Delay(20);
        }

        _failures.Add(
            "panel placement wait: panel did not settle at target; "
            + $"expected=({layout.PanelTarget.DipRect.Left:0.###},{layout.PanelTarget.DipRect.Top:0.###})/"
            + $"{layout.PanelTarget.PhysicalRect.Left},{layout.PanelTarget.PhysicalRect.Top}");
    }

    private async Task WaitForPanelHiddenAsync()
    {
        var deadline = DateTimeOffset.UtcNow + TimeSpan.FromSeconds(2);
        while (DateTimeOffset.UtcNow < deadline)
        {
            if (!_controller.Panel.IsVisible)
            {
                return;
            }

            await Task.Delay(20);
        }
    }

    private PanelPosition? CapturePanelPosition(string label)
    {
        if (!NativeMethods.TryGetWindowRect(_controller.Panel.Hwnd, out var rect))
        {
            _failures.Add($"{label}: GetWindowRect failed");
            return null;
        }

        return new PanelPosition(
            _controller.Panel.Left,
            _controller.Panel.Top,
            rect.Left,
            rect.Top);
    }

    private static bool SamePanelPosition(PanelPosition expected, PanelPosition actual)
    {
        return Math.Abs(expected.WpfLeft - actual.WpfLeft) <= 0.5
            && Math.Abs(expected.WpfTop - actual.WpfTop) <= 0.5
            && Math.Abs(expected.PhysicalLeft - actual.PhysicalLeft) <= 1
            && Math.Abs(expected.PhysicalTop - actual.PhysicalTop) <= 1;
    }

    private static bool PositionMatches(PanelPosition actual, PhysicalRect expectedPhysical, System.Windows.Rect expectedDip)
    {
        return Math.Abs(actual.WpfLeft - expectedDip.Left) <= 0.5
            && Math.Abs(actual.WpfTop - expectedDip.Top) <= 0.5
            && Math.Abs(actual.PhysicalLeft - expectedPhysical.Left) <= 1
            && Math.Abs(actual.PhysicalTop - expectedPhysical.Top) <= 1;
    }

    private static IEnumerable<(int X, int Y)> SampleInteriorPoints(PhysicalRect rect)
    {
        yield return CenterOf(rect);
        yield return InsideAt(rect, 0.25, 0.35);
        yield return InsideAt(rect, 0.75, 0.65);
    }

    private static (int X, int Y) CenterOf(PhysicalRect rect)
    {
        return InsideAt(rect, 0.5, 0.5);
    }

    private static (int X, int Y) InsideAt(PhysicalRect rect, double xFraction, double yFraction)
    {
        var minX = rect.Left + 1;
        var maxX = Math.Max(minX, rect.Right - 1);
        var minY = rect.Top + 1;
        var maxY = Math.Max(minY, rect.Bottom - 1);
        return (
            (int)Math.Round(minX + ((maxX - minX) * xFraction), MidpointRounding.AwayFromZero),
            (int)Math.Round(minY + ((maxY - minY) * yFraction), MidpointRounding.AwayFromZero));
    }

    private static (int X, int Y) OutsideOf(DisplaySurfaceLayout layout)
    {
        var paddingX = (int)Math.Ceiling(HoverShellController.HoverToleranceDips * layout.Monitor.ScaleX);
        var paddingY = (int)Math.Ceiling(HoverShellController.HoverToleranceDips * layout.Monitor.ScaleY);
        return (
            layout.PanelTarget.PhysicalRect.Right + paddingX + 32,
            layout.PanelTarget.PhysicalRect.Bottom + paddingY + 32);
    }

    private readonly record struct PanelPosition(
        double WpfLeft,
        double WpfTop,
        int PhysicalLeft,
        int PhysicalTop);
}
