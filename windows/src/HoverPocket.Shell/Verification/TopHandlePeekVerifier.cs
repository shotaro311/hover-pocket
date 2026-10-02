using System.Diagnostics;
using System.Drawing.Imaging;
using System.Text.Json;
using HoverPocket.Shell.Bridge;
using HoverPocket.Shell.Configuration;
using HoverPocket.Shell.Interop;
using HoverPocket.Shell.Windows;

namespace HoverPocket.Shell.Verification;

internal sealed class TopHandlePeekVerifier(HoverShellController controller)
{
    public async Task RunAsync()
    {
        var dispatcher = new BridgeDispatcher();
        using var attachment = controller.PanelBridgeController.Attach(dispatcher);
        var bounds = controller.Layouts[0].Monitor.Bounds;
        var far = (X: bounds.Left + 10, Y: bounds.Bottom - 10);
        controller.SetPointerSimulationForVerify(far.X, far.Y);
        await controller.HidePanelForVerifyAsync();
        try
        {
            await Send("settings.setAutoHideTopHandle", new { enabled = true });
            foreach (var size in PanelSizeCatalog.All)
            foreach (var wide in new[] { true, false })
            {
                await Send("settings.setPanelSize", new { panelSize = size.Id });
                await Send("settings.setShowTopHandleSideArea", new { visible = wide });
                var layout = controller.Layouts[0];
                var entry = layout.AccessSurface.PhysicalRect;
                var surface = controller.AccessSurfaces[0];
                var near = (X: entry.Left + entry.Width / 2, Y: entry.Top + (int)Math.Round(24 * layout.Monitor.ScaleY));
                Require(!surface.IsVisible && !NativeMethods.IsWindowShown(surface.Hwnd), "entry was visible while away");
                await controller.RunHealthCheckForVerifyAsync();
                Require(!NativeMethods.IsWindowShown(surface.Hwnd), "health recovery exposed the hidden entry");

                controller.SimulatePointerMoveForVerify(near.X, near.Y);
                Require(!controller.Panel.IsVisible, "proximity immediately opened the panel");
                await Wait(() => surface.PeekReady);
                Require(!controller.Panel.IsVisible && !surface.IsPeeking, "proximity did not settle with only the entry visible");
                Require(NativeMethods.LiquidWindowAtPoint(near.X, near.Y) != surface.Hwnd, "invisible proximity area intercepted input");
                if (size.Id == "medium" && wide && controller.Panel.WebView is not null) CaptureEntry(surface);

                controller.SimulatePointerMoveForVerify(near.X, entry.Top + entry.Height / 2);
                await Wait(() => controller.Panel.IsVisible && !controller.Panel.IsAnimating);
                Require(controller.PanelExpectedVisibleForVerify, "entry hover did not open the panel");
                controller.SimulatePointerMoveForVerify(far.X, far.Y);
                await Wait(() => !controller.Panel.IsVisible && !surface.IsVisible && !surface.IsPeeking);
                Require(!NativeMethods.IsWindowShown(surface.Hwnd), "entry left a native window after closing");
                VerifyConsole.WriteLine($"PASS top-entry peek: size={size.Id}, wide={wide}, hidden=true, proximity_only=true, hover_open=true, leave_hide=true, idle=true");
            }

            // Passing near the entry must not open a panel, even during a reveal/reversal.
            var current = controller.Layouts[0];
            var nearX = current.AccessSurface.PhysicalRect.Left + current.AccessSurface.PhysicalRect.Width / 2;
            var nearY = current.AccessSurface.PhysicalRect.Top + (int)Math.Round(24 * current.Monitor.ScaleY);
            controller.SimulatePointerMoveForVerify(nearX, nearY);
            await Task.Delay(40);
            controller.SimulatePointerMoveForVerify(far.X, far.Y);
            await Task.Delay(280);
            controller.SimulatePointerMoveForVerify(nearX, nearY);
            await Wait(() => controller.AccessSurface.PeekReady);
            Require(!controller.Panel.IsVisible, "passing/reentering proximity opened a panel");
            controller.SimulatePointerMoveForVerify(far.X, far.Y);
            await Wait(() => !controller.AccessSurface.IsVisible);

            // Inject a native visibility fault and ensure hidden mode survives repair.
            NativeMethods.ShowNoActivate(controller.AccessSurface.Hwnd);
            await controller.RunHealthCheckForVerifyAsync();
            Require(!NativeMethods.IsWindowShown(controller.AccessSurface.Hwnd), "repair did not restore native hidden state");

            await Send("settings.setPanelAttachment", new { reduceMotion = true });
            controller.SimulatePointerMoveForVerify(nearX, nearY);
            Require(controller.AccessSurface.PeekReady && !controller.AccessSurface.IsPeeking && !controller.Panel.IsVisible,
                "Reduce Motion did not reveal only the entry immediately");
            controller.SimulatePointerMoveForVerify(far.X, far.Y);
            await Wait(() => !controller.AccessSurface.IsVisible);
            await Send("settings.setAutoHideTopHandle", new { enabled = false });
            Require(controller.AccessSurface.PeekReady, "always-visible setting was not restored");
            VerifyConsole.WriteLine("PASS top-entry peek: pass-through/reentry=true, hidden_native_repair=true, reduce_motion=true, always_visible_restored=true");
        }
        finally
        {
            await controller.HidePanelForVerifyAsync();
            await Send("settings.setPanelAttachment", new { reduceMotion = false });
            await Send("settings.setAutoHideTopHandle", new { enabled = false });
            await Send("settings.setShowTopHandleSideArea", new { visible = true });
            await Send("settings.setPanelSize", new { panelSize = "medium" });
            controller.ClearPointerSimulationForVerify();
        }

        async Task Send(string method, object parameters)
        {
            var result = await dispatcher.ProcessRawMessageAsync(JsonSerializer.Serialize(new { id = "peek", method, @params = parameters }));
            using var reply = JsonDocument.Parse(result ?? "{}");
            Require(reply.RootElement.TryGetProperty("error", out var error) && error.ValueKind == JsonValueKind.Null, "settings bridge rejected request");
        }
    }

    private static async Task Wait(Func<bool> condition)
    {
        var timer = Stopwatch.StartNew();
        while (timer.Elapsed < TimeSpan.FromSeconds(4))
        {
            if (condition()) return;
            await Task.Delay(20);
        }
        throw new TimeoutException("Top-entry peek did not reach expected state");
    }

    private static void CaptureEntry(AccessSurfaceWindow surface)
    {
        var log = Environment.GetEnvironmentVariable("HOVERPOCKET_VERIFY_LOG");
        if (string.IsNullOrEmpty(log) || !NativeMethods.TryGetWindowRect(surface.Hwnd, out var frame)) return;
        using var image = new System.Drawing.Bitmap(frame.Width, frame.Height, PixelFormat.Format24bppRgb);
        using (var graphics = System.Drawing.Graphics.FromImage(image))
            graphics.CopyFromScreen(frame.Left, frame.Top, 0, 0, image.Size);
        image.Save(Path.Combine(Path.GetDirectoryName(log)!, "top-entry-peek.png"), ImageFormat.Png);
    }

    private static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException("Top-entry peek: " + message);
    }
}
