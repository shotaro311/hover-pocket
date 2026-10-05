using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Windows;
using System.Windows.Controls;
using HoverPocket.Shell.Providers.Assets;
using HoverPocket.Shell.Windows;
using DataObject = System.Windows.DataObject;
using DataFormats = System.Windows.DataFormats;
using Point = System.Windows.Point;

namespace HoverPocket.Shell.Verification;

internal static class LibraryExtensionsVerifier
{
    internal static async Task<int> RunAsync(HoverShellController controller)
    {
        var store = controller.PanelBridgeController.AssetLibrary;
        var fixture = Path.Combine(store.Root, "extension-fixtures"); Directory.CreateDirectory(fixture);
        var sourceFile = Path.Combine(fixture, "generated-external.txt"); await File.WriteAllTextAsync(sourceFile, "Generated external drop fixture " + Guid.NewGuid());
        var hash = SHA256.HashData(await File.ReadAllBytesAsync(sourceFile));
        Window? source = null; AssetDropOverlayWindow? overlay = null;
        GetCursorPos(out var previous);
        try
        {
            var existing = (await store.ImportAsync(sourceFile)).AssetId!;
            var outbox = Path.Combine(store.Root, "outbox"); var before = Directory.GetFiles(outbox, "*", SearchOption.AllDirectories).Length;
            var lazy = new DataObject(new AssetDragDataObject(store, [existing], "probe"));
            if (!lazy.GetDataPresent(DataFormats.FileDrop) || lazy.GetData(AssetDragDataObject.Marker) as string != "probe" || Directory.GetFiles(outbox, "*", SearchOption.AllDirectories).Length != before) throw new Exception("Internal drag eagerly copied the original");
            if (AssetDropPayload.Supports(lazy)) throw new Exception("Internal drag was accepted as external import");
            var copies = lazy.GetData(DataFormats.FileDrop) as string[] ?? throw new Exception("File paths unavailable");
            if (copies.Length != 1 || !SHA256.HashData(await File.ReadAllBytesAsync(copies[0])).SequenceEqual(hash)) throw new Exception("External drag copy bytes differ");
            await File.AppendAllTextAsync(copies[0], "receiver edits copy");
            if (!SHA256.HashData(await File.ReadAllBytesAsync(store.OriginalPath((await store.GetAsync(existing))!))).SequenceEqual(hash)) throw new Exception("External drag altered original");
            VerifyConsole.WriteLine("PASS lazy drag data: internal marker creates no copies; external file consumer receives editable independent copy");
            var folder = await store.AddCategoryAsync("folder", "Drop destination");
            await controller.Panel.ReceiveAssetPayloadAsync(new([sourceFile]), folder);
            // A duplicate is retained as one original, not copied a second time.
            if ((await store.QueryAsync(new())).Total != 1 || !(await store.GetAsync(existing))!.FolderIds.Contains(folder)) throw new Exception("Duplicate external import lost its classification or added an original");
            controller.SetPointerSimulationForVerify(50, 150);
            await controller.HidePanelForVerifyAsync();
            sourceFile = Path.Combine(fixture, "generated-native-drop.txt"); await File.WriteAllTextAsync(sourceFile, "Native drop fixture " + Guid.NewGuid());
            source = new Window { Title = "HoverPocket generated drag source", Width = 320, Height = 180, Left = SystemParameters.WorkArea.Left + 50, Top = SystemParameters.WorkArea.Top + 150, Topmost = true, Content = new TextBlock { Text = "Generated file — native drag", Padding = new Thickness(25) }, Background = System.Windows.Media.Brushes.DimGray };
            var dragging = false;
            object dragData = new DataObject(DataFormats.FileDrop, new[] { sourceFile });
            source.MouseMove += (_, args) =>
            {
                if (dragging || args.LeftButton != System.Windows.Input.MouseButtonState.Pressed) return;
                dragging = true;
                var effect = DragDrop.DoDragDrop(source, dragData, System.Windows.DragDropEffects.Copy);
                VerifyConsole.WriteLine($"MEASURE native fixture drag: formats={string.Join(',', ((DataObject)dragData).GetFormats(false))}, effect={effect}, overlayVisible={overlay?.IsVisible}");
            };
            source.Show(); source.Activate(); await Task.Delay(120);
            overlay = new(store, controller.Panel.ReceiveAssetPayloadAsync); overlay.ShowAt(controller.AccessSurface);
            var start = source.PointToScreen(new Point(80, 75)); var finish = overlay.PointToScreen(new Point(80, 60));
            SetCursorPos((int)start.X, (int)start.Y);
            var gesture = Task.Run(async () =>
            {
                try
                {
                    MouseEvent(2, 0, 0, 0, 0); await Task.Delay(40); SetCursorPos((int)start.X + 22, (int)start.Y + 8); await Task.Delay(70);
                    SetCursorPos((int)finish.X, (int)finish.Y - 35); await Task.Delay(120);
                    SetCursorPos((int)finish.X, (int)finish.Y); await Task.Delay(150);
                }
                finally { MouseEvent(4, 0, 0, 0, 0); }
            });
            await gesture;
            var deadline = DateTime.UtcNow.AddSeconds(12);
            while (DateTime.UtcNow < deadline && (await store.QueryAsync(new())).Total < 2) await Task.Delay(50);
            if (!dragging || (await store.QueryAsync(new())).Total != 2) throw new Exception("Native source drop did not import: " + overlay.StatusForVerify);
            if (!File.Exists(sourceFile)) throw new Exception("Native drop moved source instead of copying it");
            VerifyConsole.WriteLine("PASS external overlay: native WPF/OLE source drag imported its generated file; original retained");
            var virtualFiles = new VirtualFileDropFixture(); dragData = new DataObject(virtualFiles); dragging = false;
            if (!AssetDropPayload.Supports((DataObject)dragData)) throw new Exception("Virtual source formats not advertised: " + string.Join(",", ((DataObject)dragData).GetFormats()));
            while (overlay.BusyForVerify) await Task.Delay(30);
            source.Activate(); overlay.ShowNoActivate(); await Task.Delay(80);
            start = source.PointToScreen(new Point(80, 75)); finish = overlay.PointToScreen(new Point(80, 100));
            VerifyConsole.WriteLine($"MEASURE virtual target: overlay={overlay.Hwnd}, top-window={WindowFromPoint(new NativePoint { X=(int)finish.X, Y=(int)finish.Y-75 })}, origin={overlay.PointToScreen(new Point())}, actual={overlay.ActualWidth}x{overlay.ActualHeight}");
            SetCursorPos((int)start.X, (int)start.Y);
            await Task.Run(async () =>
            {
                try { MouseEvent(2, 0, 0, 0, 0); await Task.Delay(40); SetCursorPos((int)start.X + 22, (int)start.Y + 8); await Task.Delay(70); SetCursorPos((int)finish.X, (int)finish.Y - 75); await Task.Delay(120); SetCursorPos((int)finish.X, (int)finish.Y); await Task.Delay(180); }
                finally { MouseEvent(4, 0, 0, 0, 0); }
            });
            deadline = DateTime.UtcNow.AddSeconds(12);
            while (DateTime.UtcNow < deadline && (await store.QueryAsync(new())).Total < 4) await Task.Delay(50);
            foreach (var file in virtualFiles.Files)
            {
                var asset = (await store.QueryAsync(new(Text: file.Name))).Items.SingleOrDefault();
                if (asset is null || !asset.FolderIds.Contains(folder) || !File.ReadAllBytes(store.OriginalPath(asset)).SequenceEqual(file.Bytes)) throw new Exception($"Virtual file lindex/folder/bytes mismatch: dragged={dragging}, item={asset?.Id}, folder={string.Join(',', asset?.FolderIds ?? [])}, status={overlay.StatusForVerify}, trace={overlay.TraceForVerify}");
            }
            VerifyConsole.WriteLine("PASS native virtual-file drop: both indexed files imported with exact bytes into selected folder");
            while (overlay.BusyForVerify) await Task.Delay(30);
            overlay.Close(); overlay = null;
            sourceFile = Path.Combine(fixture, "Generated automatic top-edge.txt"); await File.WriteAllTextAsync(sourceFile, Guid.NewGuid().ToString());
            dragData = new DataObject(DataFormats.FileDrop, new[] { sourceFile }); dragging = false;
            await controller.HidePanelForVerifyAsync();
            controller.AccessSurface.SetPeekVisible(true, immediate: true); controller.AccessSurface.ShowNoActivate();
            source.Activate(); start = source.PointToScreen(new Point(80, 75));
            var entry = controller.AccessSurface.PointToScreen(new Point(controller.AccessSurface.ActualWidth / 2, 3));
            SetCursorPos((int)start.X, (int)start.Y);
            await Task.Run(async () =>
            {
                try
                {
                    MouseEvent(2, 0, 0, 0, 0); await Task.Delay(40); SetCursorPos((int)start.X + 22, (int)start.Y + 8); await Task.Delay(70);
                    SetCursorPos((int)entry.X, (int)entry.Y);
                    var wait = DateTime.UtcNow.AddSeconds(4);
                    while (controller.DropOverlayForVerify is null && DateTime.UtcNow < wait) await Task.Delay(30);
                    finish = await source.Dispatcher.InvokeAsync(() =>
                    {
                        overlay = controller.DropOverlayForVerify ?? throw new Exception("Top-edge drag did not reveal overlay");
                        return overlay.PointToScreen(new Point(80, 25));
                    });
                    SetCursorPos((int)finish.X, (int)finish.Y); await Task.Delay(150); SetCursorPos((int)finish.X, (int)finish.Y + 35); await Task.Delay(150);
                }
                finally { MouseEvent(4, 0, 0, 0, 0); }
            });
            deadline = DateTime.UtcNow.AddSeconds(8);
            while (DateTime.UtcNow < deadline && (await store.QueryAsync(new())).Total < 5) await Task.Delay(50);
            if ((await store.QueryAsync(new())).Total != 5 || controller.Panel.IsVisible || !File.Exists(sourceFile)) throw new Exception("Automatic top-edge drop or panel suppression failed: " + overlay?.StatusForVerify);
            while (overlay!.BusyForVerify) await Task.Delay(30);
            overlay.Hide(); overlay = null;
            VerifyConsole.WriteLine("PASS automatic top-edge native drag: overlay revealed from access surface, imported file without opening main panel, source preserved");
            await VerifyDirectUrlAsync(controller);
            await AudioPreviewVerifier.RunAsync(controller);
            using (var deviceCapture = new Capture.DeviceCaptureController(store))
            {
                deviceCapture.Open("cameraPhoto", folder); await Task.Delay(200);
                await deviceCapture.CaptureAsync(new("cameraPhoto", null, null, folder));
                if (deviceCapture.Recording || deviceCapture.Busy || !deviceCapture.Status.Contains("完了できません")) throw new Exception("Invalid device did not fail without recording");
                var devices = await Capture.DeviceCaptureController.DevicesAsync();
                VerifyConsole.WriteLine($"PASS device capture UI/device enumeration/missing-device recovery; cameras={devices.Cameras.Length}, microphones={devices.Microphones.Length}; hardware capture not exercised");
            }
            return 0;
        }
        catch (Exception ex) { VerifyConsole.WriteLine("FAIL library extensions: " + ex); return 1; }
        finally { MouseEvent(4, 0, 0, 0, 0); overlay?.Close(); source?.Close(); SetCursorPos(previous.X, previous.Y); }
    }
    private static async Task VerifyDirectUrlAsync(HoverShellController controller)
    {
        var listener = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, 0); listener.Start();
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(15));
        try
        {
            var port = ((System.Net.IPEndPoint)listener.LocalEndpoint).Port;
            var png = Convert.FromBase64String("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aSqoAAAAASUVORK5CYII=");
            var server = Task.Run(async () =>
            {
                for (var index = 0; index < 2; index++)
                {
                    using var client = await listener.AcceptTcpClientAsync(timeout.Token); using var stream = client.GetStream();
                    var request = new byte[4096]; var received = 0;
                    while (received < request.Length)
                    {
                        var read = await stream.ReadAsync(request.AsMemory(received), timeout.Token);
                        if (read == 0) throw new IOException("Incomplete fixture HTTP request");
                        received += read;
                        if (System.Text.Encoding.ASCII.GetString(request, 0, received).Contains("\r\n\r\n")) break;
                    }
                    var body = index == 0 ? png : System.Text.Encoding.UTF8.GetBytes("<html>Generated page</html>");
                    var headers = System.Text.Encoding.ASCII.GetBytes($"HTTP/1.1 200 OK\r\nContent-Type: {(index == 0 ? "image/png" : "text/html")}\r\nContent-Length: {body.Length}\r\nConnection: close\r\n\r\n");
                    await stream.WriteAsync(headers, timeout.Token); await stream.WriteAsync(body, timeout.Token);
                }
            });
            var store = controller.PanelBridgeController.AssetLibrary;
            var payload = AssetDropPayload.Capture(new DataObject(DataFormats.UnicodeText, $"http://127.0.0.1:{port}/generated-image"), store.Root);
            await controller.Panel.ReceiveAssetPayloadAsync(payload);
            var downloaded = (await store.QueryAsync(new(Kind: "image"))).Items.Single();
            if (!File.ReadAllBytes(store.OriginalPath(downloaded)).SequenceEqual(png) || !downloaded.InternetOrigin) throw new Exception("Direct URL bytes/origin mismatch");
            payload = AssetDropPayload.Capture(new DataObject(DataFormats.UnicodeText, $"http://127.0.0.1:{port}/page"), store.Root);
            var rejected = false; try { await controller.Panel.ReceiveAssetPayloadAsync(payload); } catch (ArgumentException) { rejected = true; }
            if (!rejected) throw new Exception("HTML page accepted as media");
            await server;
            VerifyConsole.WriteLine("PASS direct media URL: generated PNG bytes and Internet origin retained; HTML page rejected");
        }
        finally { listener.Stop(); }
    }
    [StructLayout(LayoutKind.Sequential)] private struct NativePoint { public int X, Y; }
    [DllImport("user32.dll")] private static extern bool GetCursorPos(out NativePoint point);
    [DllImport("user32.dll")] private static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] private static extern nint WindowFromPoint(NativePoint point);
    [DllImport("user32.dll", EntryPoint = "mouse_event")] private static extern void MouseEvent(uint flags, uint dx, uint dy, uint data, nuint extra);
}
