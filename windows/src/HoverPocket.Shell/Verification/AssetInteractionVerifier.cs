using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using HoverPocket.Shell.Capture;
using HoverPocket.Shell.Windows;
using Microsoft.Web.WebView2.Core;
using Button = System.Windows.Controls.Button;
using Point = System.Windows.Point;

namespace HoverPocket.Shell.Verification;

internal static class AssetInteractionVerifier
{
    public static async Task RunAsync(HoverShellController controller, string imageId, List<string> failures)
    {
        var target = controller.ActiveLayoutForVerify!.PanelTarget.PhysicalRect;
        controller.SimulatePointerMoveForVerify(target.Left + target.Width / 2, target.Top + 60);
        try { await VerifyAsync(controller, imageId, failures); }
        finally { controller.SetPointerSimulationForVerify(target.Left + target.Width / 2, target.Top + 60); await controller.ShowPanelForUiVerifyAsync(); }
    }
    private static async Task VerifyAsync(HoverShellController controller, string imageId, List<string> failures)
    {
        var store = controller.PanelBridgeController.AssetLibrary;
        await controller.PanelBridgeController.SelectProviderFromShellAsync("assets");
        controller.ShowPanelFromUser();
        var web = controller.Panel.WebView!;
        await UntilAsync(async () => await web.ExecuteScriptAsync($$"""!!document.querySelector('[data-asset-id="{{imageId}}"]')""") == "true");
        var original = (await store.GetAsync(imageId))!;
        var originalBytes = await File.ReadAllBytesAsync(store.ReadOriginalPath(original));
        var before = (await store.QueryAsync(new(Limit: 200))).Items.Select(item => item.Id).ToHashSet();
        await web.ExecuteScriptAsync($$"""
            window.__editProbeDone=false;
            (async()=>{
              document.querySelector('[data-asset-id="{{imageId}}"]')?.dispatchEvent(new MouseEvent('dblclick',{bubbles:true}));
              for(let i=0;i<100&&!document.querySelector('.assets-edit-image');i++) await new Promise(r=>setTimeout(r,30));
              document.querySelector('.assets-edit-image')?.click();
            })();
            """);
        ScreenshotEditorWindow? editor = null;
        try
        {
            await UntilAsync(() => Task.FromResult((editor = System.Windows.Application.Current.Windows.OfType<ScreenshotEditorWindow>().FirstOrDefault(window => window.IsVisible)) is not null));
            editor!.AddAnnotationsForVerify();
            if (Environment.GetEnvironmentVariable("HOVERPOCKET_VERIFY_LOG") is { Length: > 0 } log)
            {
                var evidence = Path.Combine(Path.GetDirectoryName(Path.GetFullPath(log))!, "library-editor.png");
                if (!File.Exists(evidence))
                {
                    var bitmap = new RenderTargetBitmap((int)editor.ActualWidth, (int)editor.ActualHeight, 96, 96, PixelFormats.Pbgra32);
                    bitmap.Render(editor); bitmap.Freeze(); await CaptureFiles.WritePngAsync(evidence, bitmap);
                }
            }
            var save = Descendants<Button>(editor).Single(button => button.Content as string == "編集したコピーを保存");
            save.RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); editor = null;
            await UntilAsync(async () => (await store.QueryAsync(new(Limit: 200))).Items.Any(item => !before.Contains(item.Id)));
            var saved = (await store.QueryAsync(new(Limit: 200))).Items.Single(item => !before.Contains(item.Id));
            if (!(await File.ReadAllBytesAsync(store.ReadOriginalPath(original))).SequenceEqual(originalBytes) || saved.Id == original.Id)
                failures.Add("assets: preview annotation save modified source");
            VerifyConsole.WriteLine("PASS library editor: double click -> edit button -> native annotations -> save button -> new asset and original byte readback");
        }
        finally { editor?.Close(); }
        await web.ExecuteScriptAsync("document.querySelector('[data-action=\"endPreview\"]')?.click()");
        await UntilAsync(() => Task.FromResult(!controller.Panel.IsAnimating && !controller.Panel.AssetLayout.Active));
        await UntilAsync(async () => await web.ExecuteScriptAsync($$"""!!document.querySelector('[data-asset-id="{{imageId}}"]')""") == "true");

        await NativeDropAsync(web, web.CoreWebView2, () => controller.Panel.InternalAssetDragForVerify, imageId, intoTrash: false);
        if ((await store.GetAsync(imageId))!.Trashed) failures.Add("assets: non-trash drop archived media");
        await NativeDropAsync(web, web.CoreWebView2, () => controller.Panel.InternalAssetDragForVerify, imageId, intoTrash: true);
        try { await UntilAsync(async () => (await store.GetAsync(imageId))!.Trashed); }
        catch (TimeoutException) { throw new TimeoutException($"Native trash did not archive: {controller.Panel.DragStateForVerify}; {controller.Panel.DragTraceForVerify}; " + await web.ExecuteScriptAsync("window.__dragEvents")); }
        if (!File.Exists(store.ReadOriginalPath(original))) failures.Add("assets: drag trash removed original file");
        await web.ExecuteScriptAsync("import('/js/bridge.js').then(({request})=>request('assets.undo'))");
        await UntilAsync(async () => !(await store.GetAsync(imageId))!.Trashed);
        if (!(await File.ReadAllBytesAsync(store.ReadOriginalPath(original))).SequenceEqual(originalBytes)) failures.Add("assets: drag undo changed original");
        VerifyConsole.WriteLine("PASS native drag: outside target preserves item, bottom target archives, undo restores identical original bytes");
        controller.OpenAssetLibraryFromUser();
        var organizer = System.Windows.Application.Current.Windows.OfType<AssetOrganizerWindow>().Single(window => window.IsVisible);
        try
        {
            await UntilAsync(() => Task.FromResult(organizer.WebViewForVerify is not null));
            var libraryWeb = organizer.WebViewForVerify!;
            await NativeDropAsync(organizer.WebSurfaceForVerify, libraryWeb, () => organizer.InternalAssetDragForVerify, imageId, intoTrash: false);
            if ((await store.GetAsync(imageId))!.Trashed) failures.Add("assets: organizer outside drop archived media");
            await NativeDropAsync(organizer.WebSurfaceForVerify, libraryWeb, () => organizer.InternalAssetDragForVerify, imageId, intoTrash: true);
            try { await UntilAsync(async () => (await store.GetAsync(imageId))!.Trashed); }
            catch (TimeoutException) { throw new TimeoutException($"Organizer trash: {organizer.DragStateForVerify}; {organizer.DragTraceForVerify}; " + await libraryWeb.ExecuteScriptAsync("({events:window.__dragEvents,status:document.querySelector('.assets-status').textContent})")); }
            await libraryWeb.ExecuteScriptAsync("import('/js/bridge.js').then(({request})=>request('assets.undo'))");
            await UntilAsync(async () => !(await store.GetAsync(imageId))!.Trashed);
            if (!(await File.ReadAllBytesAsync(store.ReadOriginalPath(original))).SequenceEqual(originalBytes)) failures.Add("assets: organizer trash/undo changed source");
            VerifyConsole.WriteLine("PASS organizer native drag: outside target unchanged, DOM trash target archives, undo restores original bytes");
        }
        finally { organizer.Close(); }

    }

    private static async Task NativeDropAsync(FrameworkElement surface, CoreWebView2 web, Func<bool> dragActive, string id, bool intoTrash)
    {
        await UntilAsync(async () => await web.ExecuteScriptAsync($$"""!!document.querySelector('[data-asset-id="{{id}}"]')""") == "true");
        await web.ExecuteScriptAsync($$"""(()=>{const card=document.querySelector('[data-asset-id="{{id}}"]');const search=document.querySelector('.assets-search');search.value=card.querySelector('.assets-card-name').title;search.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true}));})()""");
        await UntilAsync(async () => await web.ExecuteScriptAsync("document.querySelectorAll('.assets-card').length===1 && document.querySelector('.assets-summary').textContent.startsWith('1')") == "true");
        await web.ExecuteScriptAsync($$"""document.querySelector('[data-asset-id="{{id}}"]')?.click()""");
        await UntilAsync(async () => await web.ExecuteScriptAsync("!!document.querySelector('.assets-selection button') && document.querySelector('.assets-preview').hidden") == "true");
        await web.ExecuteScriptAsync("window.__dragEvents=[];for(const name of ['dragstart','dragover','drop'])document.addEventListener(name,event=>{if(window.__dragEvents.length<30)window.__dragEvents.push([name,event.clientX,event.clientY])},{capture:true})");
        await web.ExecuteScriptAsync($$"""document.querySelector('[data-asset-id="{{id}}"]')?.scrollIntoView({block:'center'})""");
        if (Window.GetWindow(surface) is PanelWindow panelWindow)
            await UntilAsync(() => Task.FromResult(panelWindow.IsVisible && !panelWindow.IsAnimating && panelWindow.RevealForVerify == 1));
        await Task.Delay(80);
        var card = await RectAsync(web, $"[data-asset-id='{id}']");
        var rawTarget = await web.ExecuteScriptAsync(intoTrash
            ? "(()=>{const target=document.querySelector('.assets-trash-drop');target.hidden=false;const bounds=target.getBoundingClientRect().toJSON();target.hidden=true;return JSON.stringify(bounds)})()"
            : "JSON.stringify(document.querySelector('.assets-search').getBoundingClientRect().toJSON())");
        using var targetJson = JsonDocument.Parse(JsonSerializer.Deserialize<string>(rawTarget)!); var bounds = targetJson.RootElement;
        var targetPoint = surface.PointToScreen(new Point(bounds.GetProperty("x").GetDouble() + bounds.GetProperty("width").GetDouble()/2, bounds.GetProperty("y").GetDouble() + bounds.GetProperty("height").GetDouble()/2));
        GetCursorPos(out var previous);
        try
        {
            var start = surface.PointToScreen(new Point(card.X + card.Width / 2, card.Y + card.Height / 2));
            SetCursorPos((int)start.X, (int)start.Y); MouseEvent(0x0002, 0, 0, 0, 0);
            await Task.Delay(120); // Deliver the native mouse-down before the synthetic DOM drag-start.
            // OLE can delay WebView calls until the gesture ends. Drive only native input on a worker.
            var gesture = Task.Run(async () =>
            {
                try
                {
                    var deadline = DateTime.UtcNow.AddSeconds(8);
                    while (!dragActive() && DateTime.UtcNow < deadline) await Task.Delay(20);
                    if (!dragActive()) throw new TimeoutException("Native drag did not start.");
                    await Task.Delay(60);
                    for (var step = 1; step <= 6; step++)
                    { SetCursorPos((int)(start.X + (targetPoint.X - start.X) * step / 6), (int)(start.Y + (targetPoint.Y - start.Y) * step / 6)); await Task.Delay(40); }
                    await Task.Delay(160);
                }
                finally { MouseEvent(0x0004, 0, 0, 0, 0); }
            });
            await web.ExecuteScriptAsync($$"""document.querySelector('[data-asset-id="{{id}}"]')?.dispatchEvent(new DragEvent('dragstart',{bubbles:true,cancelable:true}))""");
            try { await gesture; }
            catch (TimeoutException)
            {
                var hostState = Window.GetWindow(surface) switch { PanelWindow panel => panel.DragStateForVerify, AssetOrganizerWindow organizer => organizer.DragStateForVerify, _ => "unknown" };
                var uiState = await web.ExecuteScriptAsync("({dragging:document.querySelector('.assets-root').classList.contains('is-dragging'),status:document.querySelector('.assets-status').textContent,selected:document.querySelector('.assets-selection').textContent,starts:window.__dragEvents})");
                throw new TimeoutException($"Native drag state={hostState}; UI={uiState}");
            }
            await UntilAsync(() => Task.FromResult(!dragActive()));
            await UntilAsync(async () => await web.ExecuteScriptAsync("document.querySelector('.assets-trash-drop')?.hidden===true") == "true");
        }
        finally { MouseEvent(0x0004, 0, 0, 0, 0); SetCursorPos(previous.X, previous.Y); }
    }

    private static async Task<Rect> RectAsync(CoreWebView2 web, string selector)
    {
        var raw = await web.ExecuteScriptAsync($"JSON.stringify(document.querySelector({JsonSerializer.Serialize(selector)}).getBoundingClientRect().toJSON())");
        using var document = JsonDocument.Parse(JsonSerializer.Deserialize<string>(raw)!); var r = document.RootElement;
        return new(r.GetProperty("x").GetDouble(), r.GetProperty("y").GetDouble(), r.GetProperty("width").GetDouble(), r.GetProperty("height").GetDouble());
    }
    private static async Task UntilAsync(Func<Task<bool>> ready, [System.Runtime.CompilerServices.CallerLineNumber] int line = 0)
    {
        var deadline = DateTime.UtcNow.AddSeconds(10);
        while (!await ready()) { if (DateTime.UtcNow > deadline) throw new TimeoutException($"Asset interaction verification timed out at line {line}."); await Task.Delay(30); }
    }
    private static IEnumerable<T> Descendants<T>(DependencyObject parent) where T : DependencyObject
    {
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(parent); i++)
        { var child = VisualTreeHelper.GetChild(parent, i); if (child is T item) yield return item; foreach (var nested in Descendants<T>(child)) yield return nested; }
    }
    [StructLayout(LayoutKind.Sequential)] private struct NativePoint { public int X, Y; }
    [DllImport("user32.dll")] private static extern bool GetCursorPos(out NativePoint point);
    [DllImport("user32.dll")] private static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll", EntryPoint = "mouse_event")] private static extern void MouseEvent(uint flags, uint x, uint y, uint data, nuint extra);
}
