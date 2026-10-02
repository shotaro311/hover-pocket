using System.Text.Json;
using System.IO;
using System.Diagnostics;
using HoverPocket.Shell.Bridge;
using HoverPocket.Shell.Configuration;
using HoverPocket.Shell.Interop;
using HoverPocket.Shell.Windows;
using Point = System.Windows.Point;

namespace HoverPocket.Shell.Verification;

internal sealed class LiquidMotionVerifier(HoverShellController controller)
{
    public async Task RunAsync()
    {
        VerifySpringAndShapes();
        var dispatcher = new BridgeDispatcher();
        using var attachment = controller.PanelBridgeController.Attach(dispatcher);
        var layout = controller.Layouts[0];
        var entry = layout.AccessSurface.PhysicalRect;
        controller.SetPointerSimulationForVerify(entry.Left + entry.Width / 2, entry.Top + 1);
        try
        {
            foreach (var size in PanelSizeCatalog.All)
            foreach (var mode in new[] { "preserveMenu", "coverMenu" })
            {
                await Send("settings.setPanelSize", new { panelSize = size.Id });
                await Send("settings.setPanelAttachment", new { style = mode, automatic = false });
                await controller.ShowPanelForVerifyAsync();
                await Task.Delay(200);
                await Settle();
                var panel = controller.Panel;
                var target = panel.LiquidTargetForVerify!;
                var width = target.PhysicalRect.Width;
                var center = width / 2;
                Require(target.PhysicalRect.Top == controller.ActiveLayoutForVerify!.Monitor.Bounds.Top, "native window detached from screen top");
                Require(NativeMethods.LiquidRegionContains(panel.Hwnd, center, 0), "native region has a top gap");
                Require(panel.ContainsPhysicalPoint(target.PhysicalRect.Left + center, target.PhysicalRect.Top), "logical hit test excludes entry");
                if (mode == "coverMenu")
                    Require(NativeMethods.LiquidRegionContains(panel.Hwnd, 8, 0), "cover mode does not reach top corners");
                else
                    Require(!NativeMethods.LiquidRegionContains(panel.Hwnd, 8, 0), "narrow-entry mode filled the menu sides");
                NativeMethods.TryGetWindowRect(panel.Hwnd, out var nativeFrame);
                Require(NativeMethods.LiquidWindowAtPoint(nativeFrame.Left + center, nativeFrame.Top + nativeFrame.Height / 2) == panel.Hwnd,
                    "Windows hit test does not reach visible panel content");
                Require(NativeMethods.LiquidWindowAtPoint(nativeFrame.Left, nativeFrame.Bottom - 1) != panel.Hwnd,
                    "Windows hit test includes the clipped corner");
                Require(!NativeMethods.LiquidRegionContains(panel.Hwnd, 0, target.PhysicalRect.Height - 1),
                    $"native region includes outside bottom corner: size={size.Id}, mode={mode}, target={target.PhysicalRect}, frame={nativeFrame.Width}x{nativeFrame.Height}, reveal={panel.RevealForVerify}, shape={panel.ShapeForVerify?.Path.Bounds}");
                if (panel.WebView is not null) CaptureNativeSurface(panel, size.Id, mode);
                if (size.Id == "medium" && panel.WebView is not null)
                {
                    using var process = Process.GetCurrentProcess();
                    using var browser = Process.GetProcessById((int)panel.WebView.CoreWebView2.BrowserProcessId);
                    var cpu = process.TotalProcessorTime;
                    var browserCpu = browser.TotalProcessorTime;
                    var elapsed = Stopwatch.StartNew();
                    await Task.Delay(3000);
                    process.Refresh();
                    browser.Refresh();
                    var cpuPercent = 100 * (process.TotalProcessorTime - cpu).TotalSeconds / elapsed.Elapsed.TotalSeconds;
                    var browserPercent = 100 * (browser.TotalProcessorTime - browserCpu).TotalSeconds / elapsed.Elapsed.TotalSeconds;
                    Require(!panel.IsAnimating, "idle panel resumed its spring rendering loop");
                    VerifyConsole.WriteLine($"liquid idle CPU: mode={mode}, main_one_core_percent={cpuPercent:0.00}, browser_one_core_percent={browserPercent:0.00}, seconds={elapsed.Elapsed.TotalSeconds:0.0}, spring_loop=false; renderer/GPU excluded");
                }
                for (var i = 0; i < 300; i++)
                    controller.SimulatePointerMoveForVerify(entry.Left + entry.Width / 2, entry.Top + 1);
                await Task.Delay(600);
                Require(panel.IsVisible && !panel.IsAnimating && panel.RevealForVerify == 1, "stationary entry hover oscillated or kept rendering");
                var close = panel.CloseAsync(controller.ActiveLayoutForVerify!);
                await Task.Delay(70);
                var value = panel.RevealForVerify;
                var opening = panel.OpenAsync(controller.ActiveLayoutForVerify!, target);
                Require(Math.Abs(value - panel.RevealForVerify) < .000001, "reversal reset reveal position");
                await Task.WhenAll(close, opening);
                await controller.HidePanelForVerifyAsync();
                Require(!panel.IsVisible && !panel.IsAnimating, "closed panel left a visible surface");
                VerifyConsole.WriteLine($"PASS liquid native: size={size.Id}, mode={mode}, top_gap=0, stationary_hover=300, reversal=true, idle=true");
            }
            await Send("settings.setPanelAttachment", new { style = "preserveMenu", automatic = true });
            var settings = controller.PanelBridgeController.CurrentSettings;
            Require(settings.PanelAttachmentStyle == PanelAttachmentStyle.PreserveMenu
                && PanelAttachment.Resolve(settings) == PanelAttachmentStyle.CoverMenu, "automatic mode overwrote manual choice");
            await Send("settings.setPanelAttachment", new { automatic = false, reduceMotion = true });
            await controller.ShowPanelForVerifyAsync();
            Require(!controller.Panel.IsAnimating && controller.Panel.RevealForVerify == 1, "Reduce Motion animated open");
            await controller.HidePanelForVerifyAsync();
            Require(!controller.Panel.IsVisible, "Reduce Motion animated close");
            await Send("settings.setPanelAttachment", new { reduceMotion = false });
            await Send("settings.setPanelSize", new { panelSize = "medium" });

            // Exercise the polling/delay/controller path, including cancellation of close notifications.
            for (var cycle = 0; cycle < 30; cycle++)
            {
                await controller.ShowPanelForVerifyAsync();
                var active = controller.ActiveLayoutForVerify!;
                var outside = active.Monitor.Bounds;
                controller.SimulatePointerMoveForVerify(outside.Left + 10, outside.Bottom - 10);
                await Task.Delay(150);
                var before = controller.Panel.RevealForVerify;
                controller.SimulatePointerMoveForVerify(entry.Left + entry.Width / 2, entry.Top + 1);
                Require(Math.Abs(before - controller.Panel.RevealForVerify) < .000001, "polling reentry jumped");
                await Settle();
                Require(controller.PanelExpectedVisibleForVerify && controller.Panel.IsOpening, "reentry did not cancel close");
                await controller.HidePanelForVerifyAsync();
            }
            VerifyConsole.WriteLine("PASS liquid native: reentry_reversals=30, automatic_manual_preserved=true, reduce_motion=true");
        }
        finally
        {
            await controller.HidePanelForVerifyAsync();
            controller.ClearPointerSimulationForVerify();
        }
        async Task Send(string method, object parameters)
        {
            var json = JsonSerializer.Serialize(new { id = "liquid", method, @params = parameters });
            var result = await dispatcher.ProcessRawMessageAsync(json);
            using var reply = JsonDocument.Parse(result ?? "{}");
            Require(reply.RootElement.TryGetProperty("error", out var error) && error.ValueKind == JsonValueKind.Null, "bridge rejected liquid settings");
        }
        async Task Settle()
        {
            var deadline = DateTime.UtcNow.AddSeconds(3);
            var stable = 0;
            while (DateTime.UtcNow < deadline)
            {
                var panel = controller.Panel;
                var target = panel.LiquidTargetForVerify?.PhysicalRect;
                var matches = NativeMethods.TryGetWindowRect(panel.Hwnd, out var frame) && target is { } rect
                    && Math.Abs(frame.Width - rect.Width) <= 1 && Math.Abs(frame.Height - rect.Height) <= 1;
                stable = !panel.IsAnimating && matches ? stable + 1 : 0;
                if (stable >= 5) return;
                await Task.Delay(20);
            }
            throw new InvalidOperationException("Liquid: spring/native placement failed to settle");
        }
    }

    internal static void VerifySpringAndShapes()
    {
        var a = new LiquidSpring(0) { Target = 1 };
        var b = new LiquidSpring(0) { Target = 1 };
        for (var i = 0; i < 60; i++) a.Step(1.0 / 60, .32);
        for (var i = 0; i < 120; i++) b.Step(1.0 / 120, .32);
        Require(Math.Abs(a.Value - b.Value) < 1e-10 && Math.Abs(a.Velocity - b.Velocity) < 1e-10, "spring depends on refresh rate");
        foreach (var size in PanelSizeCatalog.All)
        foreach (var origin in new[] { 72.0, 168.0 })
        foreach (var blend in new[] { 0.0, 1.0 })
        for (var i = 0; i <= 100; i++)
        {
            var shape = LiquidPanelGeometry.Shape(i / 100.0, size.Width, size.TotalHeight + 9, origin, 9, blend);
            Require(shape.Path.Bounds.Top == 0, "shape left a screen-edge gap");
            Require(shape.Contains(new Point(size.Width / 2, .01)), "entry is outside shape");
            Require(!shape.Contains(new Point(-1, 1)), "shape protrudes outside frame");
            if (i == 0) Require(Math.Abs(shape.Path.Bounds.Width - origin) < 1e-8, "closed shape has side protrusions");
        }
        VerifyConsole.WriteLine("PASS liquid geometry: shapes=1616, refresh_rate=60/120, top_gap=0, closed_protrusions=0");
    }

    private static void CaptureNativeSurface(PanelWindow panel, string size, string mode)
    {
        var log = Environment.GetEnvironmentVariable("HOVERPOCKET_VERIFY_LOG");
        if (string.IsNullOrEmpty(log) || panel.ShapeForVerify is not { } shape
            || !NativeMethods.TryGetWindowRect(panel.Hwnd, out var frame)) return;
        using var capture = new System.Drawing.Bitmap(frame.Width, frame.Height, System.Drawing.Imaging.PixelFormat.Format24bppRgb);
        using (var screen = System.Drawing.Graphics.FromImage(capture))
            screen.CopyFromScreen(frame.Left, frame.Top, 0, 0, capture.Size);
        // Keep only this product's native silhouette; neighboring desktop pixels are discarded.
        using var output = new System.Drawing.Bitmap(frame.Width, frame.Height);
        using var graphics = System.Drawing.Graphics.FromImage(output);
        using var path = new System.Drawing.Drawing2D.GraphicsPath();
        var sx = frame.Width / panel.Width;
        var sy = frame.Height / panel.Height;
        foreach (var figure in shape.Path.GetFlattenedPathGeometry().Figures)
        {
            var points = new List<System.Drawing.PointF> { ToPixel(figure.StartPoint) };
            foreach (var segment in figure.Segments)
                if (segment is System.Windows.Media.PolyLineSegment line)
                    points.AddRange(line.Points.Select(ToPixel));
            path.AddPolygon(points.ToArray());
        }
        graphics.SetClip(path);
        graphics.DrawImageUnscaled(capture, 0, 0);
        var destination = Path.Combine(Path.GetDirectoryName(log)!, $"native-{size}-{mode}.png");
        output.Save(destination, System.Drawing.Imaging.ImageFormat.Png);
        VerifyConsole.WriteLine($"native screen capture: {Path.GetFileName(destination)}, {frame.Width}x{frame.Height}");
        System.Drawing.PointF ToPixel(Point point) => new((float)(point.X * sx), (float)(point.Y * sy));
    }
    private static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException("Liquid: " + message);
    }
}
