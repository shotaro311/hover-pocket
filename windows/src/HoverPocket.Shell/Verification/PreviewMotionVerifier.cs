using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows;
using System.Globalization;
using HoverPocket.Shell.Capture;
using HoverPocket.Shell.Providers.Controls;
using HoverPocket.Shell.Windows;
using Color = System.Windows.Media.Color;
using FlowDirection = System.Windows.FlowDirection;
using Point = System.Windows.Point;
using Pen = System.Windows.Media.Pen;

namespace HoverPocket.Shell.Verification;

internal static class PreviewMotionVerifier
{
    public static async Task<int> RunAsync(HoverShellController controller)
    {
        var store = controller.PanelBridgeController.AssetLibrary;
        await store.Ready;
        var path = Path.Combine(store.Root, "motion-fixture.png");
        var drawing = new DrawingVisual();
        using (var context = drawing.RenderOpen())
        {
            context.DrawRectangle(new SolidColorBrush(Color.FromRgb(30, 33, 40)), null, new Rect(0, 0, 2400, 1400));
            for (var row = 0; row < 42; row++)
            {
                var text = new FormattedText($"{row:00}  HoverPocket プレビュー表示を確認する  ABCDEFG 0123456789  —  fine text, sharp lines and stable pixels", CultureInfo.InvariantCulture, FlowDirection.LeftToRight, new Typeface("Yu Gothic UI"), 21, System.Windows.Media.Brushes.White, 1);
                context.DrawText(text, new Point(32, 22 + row * 32));
                context.DrawLine(new Pen(System.Windows.Media.Brushes.SlateGray, 1), new Point(1600, 22 + row * 32), new Point(2310, 22 + row * 32));
            }
            context.DrawRectangle(System.Windows.Media.Brushes.CornflowerBlue, null, new Rect(1650, 100, 110, 110));
            context.DrawRectangle(System.Windows.Media.Brushes.OrangeRed, null, new Rect(1800, 100, 110, 110));
        }
        var bitmap = new RenderTargetBitmap(2400, 1400, 96, 96, PixelFormats.Pbgra32); bitmap.Render(drawing); bitmap.Freeze();
        await CaptureFiles.WritePngAsync(path, bitmap);
        var id = (await store.ImportAsync(path)).AssetId!;
        await controller.PanelBridgeController.SelectProviderFromShellAsync("assets");
        var web = controller.Panel.WebView!;
        await Task.Delay(800);
        VerifyConsole.WriteLine($"MOTION ready {DateTimeOffset.UtcNow:O}");
        await Task.Delay(1000);
        var resizeCount = 0;
        System.Windows.SizeChangedEventHandler countResize = (_, _) => resizeCount++;
        controller.Panel.SizeChanged += countResize;
        ScreenRecorder? recorder = null;
        try
        {
            if (Environment.GetEnvironmentVariable("HOVERPOCKET_MOTION_RECORDING") is { Length: > 0 } recordingPath)
            {
                using (File.Create(recordingPath)) { }
                var monitor = WindowsGraphicsCapturePreviewService.CreateCaptureItemForMonitor(controller.Layouts[0].Monitor.NativeHandle);
                recorder = await ScreenRecorder.StartAsync(monitor, recordingPath, false, false);
                VerifyConsole.WriteLine($"MOTION recording started {DateTimeOffset.UtcNow:O}");
                await Task.Delay(500);
            }
            for (var cycle = 0; cycle < 3; cycle++)
            {
                var placements = resizeCount;
                VerifyConsole.WriteLine($"MOTION opening {cycle} {DateTimeOffset.UtcNow:O}");
                await web.ExecuteScriptAsync($$"""document.querySelector('[data-asset-id="{{id}}"]')?.dispatchEvent(new MouseEvent('dblclick',{bubbles:true}))""");
                await Task.Delay(1800);
                if (!controller.Panel.AssetLayout.Active || controller.Panel.IsAnimating) return 1;
                var animation = controller.Panel.LastAnimationDiagnostics;
                VerifyConsole.WriteLine($"MEASURE preview animation: frames={animation.FrameCount}, duration_ms={animation.Elapsed.TotalMilliseconds:0.0}, max_gap_ms={animation.MaxFrameGap.TotalMilliseconds:0.0}");
                var openingPlacements = resizeCount - placements;
                placements = resizeCount;
                VerifyConsole.WriteLine($"MOTION closing {cycle} {DateTimeOffset.UtcNow:O}");
                await web.ExecuteScriptAsync("document.querySelector('[data-action=endPreview]')?.click()");
                await Task.Delay(1500);
                if (controller.Panel.AssetLayout.Active || controller.Panel.IsAnimating) return 1;
                var closingPlacements = resizeCount - placements;
                if (openingPlacements is < 1 or > 2 || closingPlacements is < 1 or > 2)
                { VerifyConsole.WriteLine($"FAIL preview native surface resized per frame: open={openingPlacements}, close={closingPlacements}"); return 1; }
                VerifyConsole.WriteLine($"PASS preview native window resizes: open={openingPlacements}, close={closingPlacements}");
            }
            var normalTarget = controller.Panel.LiquidTargetForVerify;
            foreach (var delay in new[] { 30, 120, 300 })
            {
                await web.ExecuteScriptAsync($$"""document.querySelector('[data-asset-id="{{id}}"]')?.dispatchEvent(new MouseEvent('dblclick',{bubbles:true}))""");
                await Task.Delay(delay);
                await web.ExecuteScriptAsync("document.querySelector('[data-action=endPreview]')?.click()");
                await Task.Delay(100);
                var deadline = DateTime.UtcNow.AddSeconds(2);
                while (controller.Panel.IsAnimating && DateTime.UtcNow < deadline) await Task.Delay(30);
                if (controller.Panel.AssetLayout.Active || controller.Panel.IsAnimating || controller.Panel.LiquidTargetForVerify != normalTarget || !web.IsHitTestVisible)
                { VerifyConsole.WriteLine($"FAIL preview reversal at {delay}ms: active={controller.Panel.AssetLayout.Active}, animating={controller.Panel.IsAnimating}, target={controller.Panel.LiquidTargetForVerify}, normal={normalTarget}, hit={web.IsHitTestVisible}, visible={controller.Panel.IsVisible}"); return 1; }
            }
            VerifyConsole.WriteLine("PASS preview reversal: close at 30/120/300ms, normal dimensions and hit testing restored");
            VerifyConsole.WriteLine("PASS preview motion: three native expand/collapse cycles recorded");
            return 0;
        }
        finally
        {
            controller.Panel.SizeChanged -= countResize;
            if (recorder is not null) { recorder.Stop(); await recorder.Completion.WaitAsync(TimeSpan.FromSeconds(20)); recorder.Dispose(); }
        }
    }
}
