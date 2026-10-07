using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using HoverPocket.Shell.Capture;
using Point = System.Windows.Point;
using Button = System.Windows.Controls.Button;

namespace HoverPocket.Shell.Verification;

internal static class ScreenshotOverlayVerifier
{
    internal static async Task RunAsync(BitmapSource snapshot, System.Drawing.Rectangle bounds, List<string> failures)
    {
        var attempts = 0; BitmapSource? saved = null;
        var window = new ScreenshotSelectionWindow(snapshot, bounds, async (_, result) =>
        {
            attempts++;
            if (attempts == 1) throw new IOException("Synthetic save failure");
            await Task.Delay(80); saved = result.Image;
        });
        try
        {
            window.Show(); await Task.Delay(150);
            window.Hover(new Point(window.ActualWidth / 2, window.ActualHeight / 2));
            var expected = window.Region;
            if (expected.Width <= 0 || expected.Height <= 0 || !window.WindowsForVerify.Any(r => r.Contains(bounds.Left + bounds.Width / 2, bounds.Top + bounds.Height / 2))) failures.Add("screenshot hover did not identify generated app window");
            var monitor = new System.Drawing.Rectangle(-1920, 0, 1920, 1080);
            if (ScreenshotSelectionWindow.TargetAt(new(-1800, 800), [], monitor) != monitor) failures.Add("screenshot empty desktop did not select its monitor");
            var bottom = new System.Drawing.Rectangle(-1850, 50, 600, 400); var top = new System.Drawing.Rectangle(-1800, 100, 500, 300);
            if (ScreenshotSelectionWindow.TargetAt(new(-1700, 200), [top, bottom], monitor) != top) failures.Add("screenshot overlapping windows lost frontmost target");
            window.RaiseEvent(new System.Windows.Input.KeyEventArgs(System.Windows.Input.Keyboard.PrimaryDevice, PresentationSource.FromVisual(window), Environment.TickCount, System.Windows.Input.Key.Enter) { RoutedEvent = System.Windows.Input.Keyboard.KeyDownEvent });
            await UntilAsync(() => window.EditorForVerify is not null);
            var editor = window.EditorForVerify!;
            if (!window.IsVisible || window.Result is not null || editor.FloatingToolbar is null) failures.Add("screenshot selection did not stay open for editing");
            editor.AddAnnotationsForVerify();
            var annotatedImage = editor.RenderImage(); var annotated = Pixels(annotatedImage);
            var bar = editor.FloatingToolbar!;
            var commands = Descendants<Button>(bar).ToArray();
            if (!new[] { "四角", "楕円", "矢印", "ペン", "テキスト", "消しゴム", "キャンセル  Esc", "保存  Enter / ダブルクリック" }.All(name => commands.Any(b => b.Tag as string == name))) failures.Add("screenshot floating tools missing");
            var barPosition = bar.TranslatePoint(new Point(), window);
            if (barPosition.X < 0 || barPosition.Y < 0 || barPosition.X + bar.ActualWidth > window.ActualWidth + 1 || barPosition.Y + bar.ActualHeight > window.ActualHeight + 1) failures.Add("screenshot toolbar clipped outside capture surface");
            if (Environment.GetEnvironmentVariable("HOVERPOCKET_VERIFY_LOG") is { Length: > 0 } log)
            {
                var preview = new RenderTargetBitmap((int)Math.Ceiling(window.ActualWidth), (int)Math.Ceiling(window.ActualHeight), 96, 96, PixelFormats.Pbgra32); preview.Render(window); preview.Freeze();
                await CaptureFiles.WritePngAsync(Path.Combine(Path.GetDirectoryName(Path.GetFullPath(log))!, "screenshot-inline-editor.png"), preview);
            }
            commands.Single(b => b.Tag as string == "保存  Enter / ダブルクリック").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            await UntilAsync(() => attempts == 1 && !editor.IsSaving);
            if (!window.IsVisible || !annotated.SequenceEqual(Pixels(editor.RenderImage()))) failures.Add("screenshot save failure discarded annotations or closed overlay");
            commands.Single(b => b.Tag as string == "ペン").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            await Task.Delay(100);
            annotatedImage = editor.RenderImage(); annotated = Pixels(annotatedImage);
            var clicks = new List<string>();
            editor.InkSurfaceForVerify.AddHandler(System.Windows.Input.Mouse.PreviewMouseDownEvent, new System.Windows.Input.MouseButtonEventHandler((_, e) => clicks.Add($"down:{e.ClickCount}:{e.Handled}")), true);
            editor.InkSurfaceForVerify.AddHandler(System.Windows.Input.Mouse.PreviewMouseUpEvent, new System.Windows.Input.MouseButtonEventHandler((_, e) => clicks.Add($"up:{e.ClickCount}:{e.Handled}")), true);
            var point = editor.InkSurfaceForVerify.PointToScreen(new Point(expected.Width * .72, expected.Height * .35));
            GetCursorPos(out var prior);
            try
            {
                SetCursorPos((int)point.X, (int)point.Y); await Task.Delay(80);
                for (var i = 0; i < 2; i++) { MouseEvent(0x0002, 0, 0, 0, 0); await Task.Delay(25); MouseEvent(0x0004, 0, 0, 0, 0); await Task.Delay(40); }
            }
            finally { MouseEvent(0x0004, 0, 0, 0, 0); SetCursorPos(prior.X, prior.Y); }
            try { await UntilAsync(() => !window.IsVisible); }
            catch (TimeoutException) { throw new TimeoutException($"Screenshot double-click: attempts={attempts}, saving={editor.IsSaving}, pointer={point}, result={window.Result is not null}, clicks={string.Join(";",clicks)}, status={editor.StatusForVerify}"); }
            if (attempts != 2 || saved is null || window.Result is null || saved.PixelWidth != expected.Width || saved.PixelHeight != expected.Height || !annotated.SequenceEqual(Pixels(saved)))
            {
                var changed = saved is null ? [] : annotated.Zip(Pixels(saved), (a,b) => a != b).Select((different,index) => (different,index)).Where(x => x.different).Select(x => x.index / 4).Distinct().ToArray();
                failures.Add($"screenshot double-click save: attempts={attempts}, result={window.Result is not null}, dimensions={saved?.PixelWidth}x{saved?.PixelHeight}, expected={expected.Width}x{expected.Height}, changedPixels={changed.Length}, box={(changed.Length == 0 ? "none" : $"{changed.Min(i => i % expected.Width)},{changed.Min(i => i / expected.Width)} - {changed.Max(i => i % expected.Width)},{changed.Max(i => i / expected.Width)}")}");
                if (saved is not null && Environment.GetEnvironmentVariable("HOVERPOCKET_VERIFY_LOG") is { Length: > 0 } mismatchLog)
                {
                    var directory = Path.GetDirectoryName(Path.GetFullPath(mismatchLog))!;
                    await CaptureFiles.WritePngAsync(Path.Combine(directory, "doubleclick-before.png"), annotatedImage);
                    await CaptureFiles.WritePngAsync(Path.Combine(directory, "doubleclick-after.png"), saved);
                }
            }
            VerifyConsole.WriteLine("PASS screenshot overlay: app hover, desktop/negative monitor fallback, overlapping windows, Enter selection, inline tools, failed save retained, native double-click saved identical annotation pixels once");
        }
        finally { window.Close(); }
        var cancelled = new ScreenshotSelectionWindow(snapshot, bounds, (_, _) => { failures.Add("cancelled screenshot saved unexpectedly"); return Task.CompletedTask; });
        try
        {
            cancelled.Show(); await Task.Delay(100); cancelled.CompleteSelection(new(10, 10, 130, 80));
            var cancel = Descendants<Button>(cancelled.EditorForVerify!.FloatingToolbar!).Single(b => b.Tag as string == "キャンセル  Esc");
            cancel.RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); await UntilAsync(() => !cancelled.IsVisible);
            if (cancelled.Result is not null) failures.Add("screenshot cancel retained save result");
            VerifyConsole.WriteLine("PASS screenshot overlay cancel: X closes without saving");
        }
        finally { cancelled.Close(); }
    }
    private static byte[] Pixels(BitmapSource source) { var image = new FormatConvertedBitmap(source, PixelFormats.Bgra32, null, 0); var pixels = new byte[image.PixelWidth * image.PixelHeight * 4]; image.CopyPixels(pixels, image.PixelWidth * 4, 0); return pixels; }
    private static async Task UntilAsync(Func<bool> ready) { var end = DateTime.UtcNow.AddSeconds(6); while (!ready()) { if (DateTime.UtcNow > end) throw new TimeoutException("Screenshot overlay verification timed out."); await Task.Delay(25); } }
    private static IEnumerable<T> Descendants<T>(DependencyObject parent) where T : DependencyObject { for (var i = 0; i < VisualTreeHelper.GetChildrenCount(parent); i++) { var child = VisualTreeHelper.GetChild(parent, i); if (child is T value) yield return value; foreach (var nested in Descendants<T>(child)) yield return nested; } }
    [StructLayout(LayoutKind.Sequential)] private struct NativePoint { public int X, Y; }
    [DllImport("user32.dll")] private static extern bool GetCursorPos(out NativePoint point);
    [DllImport("user32.dll")] private static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll", EntryPoint = "mouse_event")] private static extern void MouseEvent(uint flags, uint x, uint y, uint data, nuint extra);
}
