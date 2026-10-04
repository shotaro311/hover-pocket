using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using HoverPocket.Assets;
using HoverPocket.Shell.Capture;
using HoverPocket.Shell.Interop;
using Point = System.Windows.Point;

namespace HoverPocket.Shell.Verification;

internal static class ScreenshotToastVerifier
{
    internal static async Task RunAsync(AssetStore store, BitmapSource image, List<string> failures)
    {
        var stage = new CaptureFiles(store).CreateStage(); var path = Path.Combine(stage, "toast-fixture.png");
        await CaptureFiles.WritePngAsync(path, image);
        CaptureFiles.MarkComplete(stage, [path], null);
        var ids = await new CaptureFiles(store).ImportCompletedAsync(stage);
        var asset = (await store.GetAsync(ids[0]))!; var original = store.ReadOriginalPath(asset);
        var hash = SHA256.HashData(await File.ReadAllBytesAsync(original));
        var copy = await store.CopyOutAsync(asset.Id);
        var thumbnail = await Task.Run(() => ScreenshotToastWindow.LoadThumbnail(copy));
        if (thumbnail.PixelWidth > 600 || thumbnail.PixelHeight > 360 || !thumbnail.IsFrozen || copy == original || !SHA256.HashData(await File.ReadAllBytesAsync(copy)).SequenceEqual(hash)) failures.Add("toast thumbnail/copy differs from saved screenshot");
        var target = new Window { Title = "HoverPocket verification — screenshot drop target", Width = 340, Height = 220, Left = SystemParameters.WorkArea.Left + 40, Top = SystemParameters.WorkArea.Top + 100, Topmost = true, AllowDrop = true, Content = new TextBlock { Text = "Generated screenshot drop target", Padding = new(20) }, Background = System.Windows.Media.Brushes.DimGray };
        string[]? dropped = null;
        target.DragOver += (_, e) => { e.Effects = e.Data.GetDataPresent(System.Windows.DataFormats.FileDrop) ? System.Windows.DragDropEffects.Copy : System.Windows.DragDropEffects.None; e.Handled = true; };
        target.Drop += (_, e) => { dropped = e.Data.GetData(System.Windows.DataFormats.FileDrop) as string[]; e.Effects = System.Windows.DragDropEffects.Copy; e.Handled = true; };
        ScreenshotToastWindow? toast = null;
        GetCursorPos(out var prior);
        try
        {
            target.Show(); target.Activate(); await Task.Delay(150);
            var foreground = GetForegroundWindow();
            toast = new(copy, thumbnail, TimeSpan.FromSeconds(1));
            var hoverTrace = new List<string>();
            toast.MouseEnter += (_, _) => hoverTrace.Add("enter"); toast.MouseLeave += (_, _) => hoverTrace.Add("leave");
            ShowToast(toast, target);
            await Task.Delay(80);
            if (GetForegroundWindow() != foreground || (NativeMethods.GetExtendedStyles(toast.Hwnd) & NativeMethods.WsExNoActivate) == 0) failures.Add("screenshot toast stole keyboard focus");
            if (Environment.GetEnvironmentVariable("HOVERPOCKET_VERIFY_LOG") is { Length: > 0 } log)
            {
                var render = new RenderTargetBitmap((int)toast.ActualWidth, (int)toast.ActualHeight, 96, 96, PixelFormats.Pbgra32); render.Render(toast); render.Freeze();
                await CaptureFiles.WritePngAsync(Path.Combine(Path.GetDirectoryName(Path.GetFullPath(log))!, "screenshot-toast.png"), render);
            }
            var start = toast.CardForVerify.PointToScreen(new Point(90, 100));
            SetCursorPos((int)start.X, (int)start.Y); await Task.Delay(100);
            GetCursorPos(out var moved); NativeMethods.TryGetWindowRect(toast.Hwnd, out var actual);
            var hit = WindowFromPoint(moved); GetWindowThreadProcessId(hit, out var process); NativeMethods.TryGetWindowRect(hit, out var hitRect);
            VerifyConsole.WriteLine($"MEASURE toast hit: process={process}, own={Environment.ProcessId}, rect={hitRect.Left},{hitRect.Top},{hitRect.Width},{hitRect.Height}, inside={toast.InputHitTest(new Point(90,100))?.GetType().Name}, style={NativeMethods.GetExtendedStyles(toast.Hwnd):X}");
            VerifyConsole.WriteLine($"MEASURE toast: start={start}, cursor={moved.X},{moved.Y}, actual={actual.Left},{actual.Top},{actual.Width},{actual.Height}, dip={toast.Left},{toast.Top},{toast.ActualWidth},{toast.ActualHeight}, over={toast.IsMouseOver}, hit={WindowFromPoint(moved)}, hwnd={toast.Hwnd}, events={string.Join(',',hoverTrace)}");
            await Task.Delay(1100);
            if (!toast.IsVisible) throw new InvalidOperationException($"toast expired while hovered: events={string.Join(',',hoverTrace)}");
            var finish = target.PointToScreen(new Point(120, 110));
            var draggingToast = toast;
            // OLE runs a nested message loop; the worker drives input only between fixture surfaces.
            var gesture = Task.Run(async () =>
            {
                try
                {
                    MouseEvent(0x0002, 0, 0, 0, 0); await Task.Delay(100);
                    SetCursorPos((int)start.X + 24, (int)start.Y + 24);
                    var deadline = DateTime.UtcNow.AddSeconds(5);
                    while (!draggingToast.DraggingForVerify && DateTime.UtcNow < deadline) await Task.Delay(30);
                    if (!draggingToast.DraggingForVerify) throw new TimeoutException("screenshot toast native drag did not start");
                    await Task.Delay(1250);
                    for (var i = 1; i <= 8; i++) { SetCursorPos((int)(start.X + (finish.X - start.X) * i / 8), (int)(start.Y + (finish.Y - start.Y) * i / 8)); await Task.Delay(40); }
                    await Task.Delay(100);
                }
                finally { MouseEvent(0x0004, 0, 0, 0, 0); }
            });
            await gesture; await Task.Delay(160);
            if (dropped is not { Length: 1 } || dropped[0] != copy || toast.IsVisible || !File.Exists(copy)) failures.Add("screenshot toast did not drop its independent PNG copy and dismiss");
            await File.AppendAllTextAsync(copy, "receiver may edit its copy");
            if (!SHA256.HashData(await File.ReadAllBytesAsync(original)).SequenceEqual(hash)) failures.Add("screenshot toast drop changed library original");
            toast = new(await store.CopyOutAsync(asset.Id), thumbnail, TimeSpan.FromSeconds(1)); ShowToast(toast, target);
            await Task.Delay(100);
            var hover = toast.CardForVerify.PointToScreen(new Point(90, 100)); SetCursorPos((int)hover.X, (int)hover.Y);
            await Task.Delay(1200);
            if (!toast.IsVisible) failures.Add("toast hover did not pause expiry");
            SetCursorPos((int)finish.X, (int)finish.Y); await Task.Delay(1300);
            if (toast.IsVisible) failures.Add("toast countdown did not resume after hover");
            VerifyConsole.WriteLine("PASS screenshot toast: frozen thumbnail, no focus steal, hover and drag pause, native PNG file drop, recipient edits preserve library original, successful drop closes, remaining timeout resumes");
        }
        finally { MouseEvent(0x0004, 0, 0, 0, 0); toast?.Dismiss(); target.Close(); SetCursorPos(prior.X, prior.Y); }
    }
    private static void ShowToast(ScreenshotToastWindow toast, Window target)
    {
        toast.ShowAtPointer();
        // System notification surfaces can sit above application topmost windows.
        // Keep the gesture fixture beside its own drop target, away from that area.
        var origin = target.PointToScreen(new Point(target.ActualWidth + 30, 0));
        var scale = NativeMethods.GetScaleForWindow(toast.Hwnd);
        var physical = new Display.PhysicalRect((int)origin.X, (int)origin.Y, (int)(300 * scale), (int)(244 * scale));
        toast.ApplyPlacement(new(new Rect(origin.X / scale, origin.Y / scale, 300, 244), physical), true);
    }
    [StructLayout(LayoutKind.Sequential)] private struct NativePoint { public int X, Y; }
    [DllImport("user32.dll")] private static extern bool GetCursorPos(out NativePoint point);
    [DllImport("user32.dll")] private static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] private static extern nint GetForegroundWindow();
    [DllImport("user32.dll")] private static extern nint WindowFromPoint(NativePoint point);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(nint hwnd, out uint processId);
    [DllImport("user32.dll", EntryPoint = "mouse_event")] private static extern void MouseEvent(uint flags, uint dx, uint dy, uint data, nuint extra);
}
