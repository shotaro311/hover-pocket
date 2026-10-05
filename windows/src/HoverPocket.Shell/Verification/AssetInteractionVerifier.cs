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
using Size = System.Windows.Size;

namespace HoverPocket.Shell.Verification;

internal static class AssetInteractionVerifier
{
    public static async Task RunAsync(HoverShellController controller, string imageId, List<string> failures)
    {
        var target = controller.ActiveLayoutForVerify!.PanelTarget.PhysicalRect;
        controller.SimulatePointerMoveForVerify(target.Left + target.Width / 2, target.Top + 60);
        void OnDismiss() => VerifyConsole.WriteLine("TRACE inline focus dismissed: " + Environment.StackTrace);
        controller.Panel.AssetPreviewDismissRequested += OnDismiss;
        try { await VerifyAsync(controller, imageId, failures); }
        finally { controller.Panel.AssetPreviewDismissRequested -= OnDismiss; controller.SetPointerSimulationForVerify(target.Left + target.Width / 2, target.Top + 60); await controller.ShowPanelForUiVerifyAsync(); }
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
        await web.ExecuteScriptAsync($$"""(()=>{const input=document.querySelector('.assets-search');input.value={{JsonSerializer.Serialize(original.Name)}};input.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true}));})()""");
        await UntilAsync(async () => await web.ExecuteScriptAsync("document.querySelectorAll('.assets-card').length===1 && document.querySelector('.assets-summary').textContent.startsWith('1')") == "true");
        if (Environment.GetEnvironmentVariable("HOVERPOCKET_VERIFY_LOG") is { Length: > 0 } dropdownLog)
        {
            foreach (var selector in new[] { ".assets-format", ".assets-sort-by" })
            {
                await ClickSurfaceAsync(web, web.CoreWebView2, selector);
                await Task.Delay(180);
                if (Interop.NativeMethods.TryGetWindowRect(controller.Panel.Hwnd, out var popupBounds))
                {
                    var snapshot = await Task.Run(() => ScreenshotSelectionWindow.CaptureDesktop(new System.Drawing.Rectangle(popupBounds.Left, popupBounds.Top, popupBounds.Width, popupBounds.Height)));
                    await CaptureFiles.WritePngAsync(Path.Combine(Path.GetDirectoryName(Path.GetFullPath(dropdownLog))!, selector[1..] + "-popup.png"), snapshot);
                }
                KeyEvent(0x1B, 0, 0, 0); KeyEvent(0x1B, 0, 0x0002, 0); await Task.Delay(100);
            }
        }
        await ClickSurfaceAsync(web, web.CoreWebView2, $"[data-asset-id='{imageId}'] .assets-card-favorite");
        await UntilAsync(async () => (await store.GetAsync(imageId))!.Favorite != original.Favorite);
        await UntilAsync(async () => await web.ExecuteScriptAsync($"document.querySelector(\"[data-asset-id='{imageId}'] .assets-card-favorite\").getAttribute('aria-pressed')==='{(!original.Favorite).ToString().ToLowerInvariant()}'") == "true");
        await ClickSurfaceAsync(web, web.CoreWebView2, $"[data-asset-id='{imageId}'] .assets-card-favorite");
        await UntilAsync(async () => (await store.GetAsync(imageId))!.Favorite == original.Favorite);
        await UntilAsync(async () => await web.ExecuteScriptAsync($"document.querySelector(\"[data-asset-id='{imageId}'] .assets-card-favorite\").getAttribute('aria-pressed')==='{original.Favorite.ToString().ToLowerInvariant()}'") == "true");
        await ClickSurfaceAsync(web, web.CoreWebView2, $"[data-asset-id='{imageId}']", rightButton: true);
        await UntilAsync(async () => await web.ExecuteScriptAsync("!!document.querySelector('.assets-context-menu[open]')") == "true");
        if (await web.ExecuteScriptAsync("document.querySelector('.assets-preview').hidden && document.querySelector('.assets-footer').contains(document.querySelector('.assets-summary')) && parseFloat(getComputedStyle(document.querySelector('.hp-provider')).paddingTop)===0") != "true") failures.Add("assets: context actions changed preview/footer or retained outer padding");
        if (Environment.GetEnvironmentVariable("HOVERPOCKET_VERIFY_LOG") is { Length: > 0 } menuLog)
        {
            using var screenshot = File.Create(Path.Combine(Path.GetDirectoryName(Path.GetFullPath(menuLog))!, "library-context-menu.png"));
            await web.CoreWebView2.CapturePreviewAsync(CoreWebView2CapturePreviewImageFormat.Png, screenshot);
        }
        KeyEvent(0x1B, 0, 0, 0); KeyEvent(0x1B, 0, 0x0002, 0);
        await UntilAsync(async () => await web.ExecuteScriptAsync("!document.querySelector('.assets-context-menu').open") == "true");
        VerifyConsole.WriteLine("PASS native library controls: hover star toggles and restores favorite, right-click opens menu, Escape closes, footer count and compact header verified");
        var before = (await store.QueryAsync(new(Limit: 200))).Items.Select(item => item.Id).ToHashSet();
        await web.ExecuteScriptAsync($$"""
            window.__editProbeDone=false;
            (async()=>{
              document.querySelector('[data-asset-id="{{imageId}}"]')?.dispatchEvent(new MouseEvent('dblclick',{bubbles:true}));
              for(let i=0;i<100&&!document.querySelector('.assets-edit-image');i++) await new Promise(r=>setTimeout(r,30));
            })();
            """);
        await UntilAsync(async () => await web.ExecuteScriptAsync("!!document.querySelector('.assets-edit-image') && !document.querySelector('.assets-edit-image').disabled") == "true");
        await UntilAsync(() => Task.FromResult(!controller.Panel.IsAnimating));
        await web.ExecuteScriptAsync("document.querySelector('.assets-edit-image').click()");
        ScreenshotEditorView? editor = null;
        try
        {
            await UntilAsync(() => Task.FromResult((editor = Descendants<ScreenshotEditorView>(controller.Panel).FirstOrDefault()) is not null));
            if (Window.GetWindow(editor) != controller.Panel || System.Windows.Application.Current.Windows.OfType<ScreenshotEditorWindow>().Any(window => window.IsVisible)) failures.Add("assets: inline edit opened another window");
            var previewBounds = controller.Panel.LiquidTargetForVerify;
            await controller.RunHealthCheckForVerifyAsync();
            controller.Panel.DismissAssetPreviewOnFocusLoss();
            if (controller.Panel.LiquidTargetForVerify != previewBounds || !controller.Panel.AssetLayout.PinOnly) failures.Add("assets: inline editing lost preview bounds or pin");
            await UntilAsync(() => Task.FromResult(editor!.IsLoaded && Descendants<Button>(editor).Any(button => button.Content as string == "編集したコピーを保存")));
            var headerBounds = await RectAsync(web.CoreWebView2, ".hp-header");
            var headerBottom = (headerBounds.Y + headerBounds.Height) * web.ActualWidth /
                JsonSerializer.Deserialize<double>(await web.ExecuteScriptAsync("innerWidth"));
            if (!web.IsVisible || !web.IsHitTestVisible || Math.Abs(editor!.TranslatePoint(new Point(), web).Y - headerBottom) > 1)
                failures.Add("assets: inline editor hides or overlaps the shell header");
            await web.ExecuteScriptAsync("window.__editorHeaderClicks=0;document.querySelector('.hp-header').addEventListener('click',e=>{if(e.isTrusted)window.__editorHeaderClicks++})");
            var previousSize = JsonSerializer.Deserialize<string>(await web.ExecuteScriptAsync("document.querySelector('[data-size-id][aria-pressed=true]').dataset.sizeId"));
            var otherSize = JsonSerializer.Deserialize<string>(await web.ExecuteScriptAsync("document.querySelector('[data-size-id][aria-pressed=false]').dataset.sizeId"));
            await ClickSurfaceAsync(web, web.CoreWebView2, $"[data-size-id='{otherSize}']");
            try { await UntilAsync(async () => await web.ExecuteScriptAsync($"document.querySelector('[data-size-id={otherSize}]').getAttribute('aria-pressed')==='true'") == "true"); }
            catch (TimeoutException) { throw new TimeoutException($"Native header: active={controller.Panel.IsActive}, animating={controller.Panel.IsAnimating}; " + await web.ExecuteScriptAsync("({clicks:window.__editorHeaderClicks,focus:document.activeElement.tagName,pressed:document.querySelector('[data-size-id][aria-pressed=true]').dataset.sizeId,hit:window.__surfaceClickTarget})")); }
            await ClickSurfaceAsync(web, web.CoreWebView2, $"[data-size-id='{previousSize}']");
            await UntilAsync(async () => await web.ExecuteScriptAsync($"document.querySelector('[data-size-id={previousSize}]').getAttribute('aria-pressed')==='true'") == "true");
            await ClickSurfaceAsync(web, web.CoreWebView2, "[data-refresh]");
            try { await UntilAsync(async () => await web.ExecuteScriptAsync("window.__editorHeaderClicks===3") == "true"); }
            catch (TimeoutException) { throw new TimeoutException("Native header refresh: " + await web.ExecuteScriptAsync("({clicks:window.__editorHeaderClicks,focus:document.activeElement.tagName,hit:window.__surfaceClickTarget,refreshDisabled:document.querySelector('[data-refresh]').disabled})")); }
            if (!editor!.IsVisible || controller.Panel.LiquidTargetForVerify != previewBounds || !controller.Panel.AssetLayout.PinOnly)
                failures.Add("assets: shell header interaction dismissed or resized inline editing");
            VerifyConsole.WriteLine("PASS inline header: original header visible above editor, native size/refresh clicks, editing and bounds preserved");
            editor!.AddAnnotationsForVerify();
            if (Environment.GetEnvironmentVariable("HOVERPOCKET_VERIFY_LOG") is { Length: > 0 } log)
            {
                var evidence = Path.Combine(Path.GetDirectoryName(Path.GetFullPath(log))!, "library-editor.png");
                if (!File.Exists(evidence))
                {
                    var surface = (FrameworkElement)editor.Parent;
                    var bitmap = new RenderTargetBitmap((int)surface.ActualWidth, (int)surface.ActualHeight, 96, 96, PixelFormats.Pbgra32);
                    bitmap.Render(surface); bitmap.Freeze(); await CaptureFiles.WritePngAsync(evidence, bitmap);
                }
            }
            var save = Descendants<Button>(editor).Single(button => button.Content as string == "編集したコピーを保存");
            var write = editor.SaveAsync;
            editor.SaveAsync = _ => throw new IOException("Synthetic save failure");
            save.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            await UntilAsync(() => Task.FromResult(editor.IsEnabled));
            if (!editor.IsVisible || !Descendants<TextBlock>(editor).Any(text => text.Text.Contains("編集内容は残っています"))) failures.Add("assets: failed inline save discarded editing state");
            editor.SaveAsync = write;
            save.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            await UntilAsync(() => Task.FromResult(!Descendants<ScreenshotEditorView>(controller.Panel).Any()));
            editor = null;
            await UntilAsync(async () => (await store.QueryAsync(new(Limit: 200))).Items.Any(item => !before.Contains(item.Id)));
            var saved = (await store.QueryAsync(new(Limit: 200))).Items.Single(item => !before.Contains(item.Id));
            if (!(await File.ReadAllBytesAsync(store.ReadOriginalPath(original))).SequenceEqual(originalBytes) || saved.Id == original.Id)
                failures.Add("assets: preview annotation save modified source");
            VerifyConsole.WriteLine("PASS inline library editor: same window/bounds, focus pin, native annotations, failed save retained/retried, new asset and original byte readback");
        }
        finally { editor?.Cancel(); }
        await UntilAsync(async () => await web.ExecuteScriptAsync("document.querySelector('.assets-root').getAttribute('aria-busy') !== 'true' && !!document.querySelector('.assets-edit-image')") == "true");
        await UntilAsync(() => Task.FromResult(!controller.Panel.IsAnimating));
        await web.ExecuteScriptAsync("document.querySelector('.assets-edit-image')?.click()");
        await UntilAsync(() => Task.FromResult(Descendants<ScreenshotEditorView>(controller.Panel).Any()));
        var cancelledEditor = Descendants<ScreenshotEditorView>(controller.Panel).Single();
        cancelledEditor.AddAnnotationsForVerify(); cancelledEditor.Cancel();
        await UntilAsync(() => Task.FromResult(!Descendants<ScreenshotEditorView>(controller.Panel).Any()));
        await UntilAsync(async () => await web.ExecuteScriptAsync("document.querySelector('.assets-root').getAttribute('aria-busy') !== 'true'") == "true");
        if ((await store.QueryAsync(new(Limit: 200))).Items.Length != before.Count + 1) failures.Add("assets: cancelling inline edit created an asset");
        VerifyConsole.WriteLine("PASS inline cancel: preview restored without creating an asset");
        if (!controller.Panel.IsVisible || !controller.PanelExpectedVisibleForVerify) failures.Add("assets: inline cancel unexpectedly hid the preview");
        await web.ExecuteScriptAsync("document.querySelector('[data-action=\"endPreview\"]')?.click()");
        await UntilAsync(() => Task.FromResult(!controller.Panel.IsAnimating && !controller.Panel.AssetLayout.Active));
        await UntilAsync(async () => await web.ExecuteScriptAsync($$"""!!document.querySelector('[data-asset-id="{{imageId}}"]')""") == "true");

        VerifyConsole.WriteLine($"MEASURE after inline edit: visible={controller.Panel.IsVisible}, expected={controller.PanelExpectedVisibleForVerify}, reveal={controller.Panel.RevealForVerify}, keyboard={controller.Panel.KeyboardInteractionEnabled}");
        if (!controller.Panel.IsVisible) { failures.Add("assets: returning from inline edit hid the list"); await controller.ShowPanelForUiVerifyAsync(); }
        await NativeDropAsync(web, web.CoreWebView2, () => controller.Panel.InternalAssetDragForVerify, imageId, intoTrash: false);
        if ((await store.GetAsync(imageId))!.Trashed) failures.Add("assets: non-trash drop archived media");
        await NativeDropAsync(web, web.CoreWebView2, () => controller.Panel.InternalAssetDragForVerify, imageId, intoTrash: true);
        try { await UntilAsync(async () => (await store.GetAsync(imageId))!.Trashed); }
        catch (TimeoutException) { throw new TimeoutException($"Native trash did not archive: {controller.Panel.DragStateForVerify}; {controller.Panel.DragTraceForVerify}; " + await web.ExecuteScriptAsync("window.__dragEvents")); }
        if (!File.Exists(store.ReadOriginalPath(original))) failures.Add("assets: drag trash removed original file");
        await web.ExecuteScriptAsync("document.body.dispatchEvent(new KeyboardEvent('keydown',{key:'z',ctrlKey:true,bubbles:true}))");
        await UntilAsync(async () => !(await store.GetAsync(imageId))!.Trashed);
        if (!(await File.ReadAllBytesAsync(store.ReadOriginalPath(original))).SequenceEqual(originalBytes)) failures.Add("assets: drag undo changed original");
        VerifyConsole.WriteLine("PASS native drag: outside target preserves item, bottom target archives, undo restores identical original bytes");
        await UntilAsync(async () => await web.ExecuteScriptAsync($$"""!!document.querySelector('[data-asset-id="{{imageId}}"]')""") == "true");
        await web.ExecuteScriptAsync("window.__deleteKeys=[];document.addEventListener('keydown',e=>window.__deleteKeys.push({key:e.key,code:e.code,target:e.target.tagName,trusted:e.isTrusted}),{capture:true})");
        await ClickSurfaceAsync(web, web.CoreWebView2, $"[data-asset-id='{imageId}']");
        await UntilAsync(async () => await web.ExecuteScriptAsync($$"""document.querySelector('[data-asset-id="{{imageId}}"]')?.getAttribute('aria-selected')==='true'""") == "true");
        KeyEvent(0x2E, 0x53, 0x0001, 0); KeyEvent(0x2E, 0x53, 0x0003, 0);
        try { await UntilAsync(async () => (await store.GetAsync(imageId))!.Trashed); }
        catch (TimeoutException) { throw new TimeoutException($"Native Delete: active={controller.Panel.IsActive}, keyboard={controller.Panel.KeyboardInteractionEnabled}; " + await web.ExecuteScriptAsync("({keys:window.__deleteKeys,focus:document.activeElement.outerHTML,selection:document.querySelector('.assets-selection').textContent,status:document.querySelector('.assets-status').textContent})")); }
        if (!File.Exists(store.ReadOriginalPath(original))) failures.Add("assets: Delete removed the original file");
        try { KeyEvent(0x11, 0, 0, 0); KeyEvent(0x5A, 0, 0, 0); KeyEvent(0x5A, 0, 0x0002, 0); }
        finally { KeyEvent(0x11, 0, 0x0002, 0); }
        await UntilAsync(async () => !(await store.GetAsync(imageId))!.Trashed);
        if (!(await File.ReadAllBytesAsync(store.ReadOriginalPath(original))).SequenceEqual(originalBytes)) failures.Add("assets: Delete/Undo changed original bytes");
        VerifyConsole.WriteLine("PASS native Delete/Ctrl+Z: selected image moved to library trash and restored, original bytes preserved");
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
            await libraryWeb.ExecuteScriptAsync("document.body.dispatchEvent(new KeyboardEvent('keydown',{key:'z',ctrlKey:true,bubbles:true}))");
            await UntilAsync(async () => !(await store.GetAsync(imageId))!.Trashed);
            if (!(await File.ReadAllBytesAsync(store.ReadOriginalPath(original))).SequenceEqual(originalBytes)) failures.Add("assets: organizer trash/undo changed source");
            VerifyConsole.WriteLine("PASS organizer native drag: outside target unchanged, DOM trash target archives, undo restores original bytes");
            var fromFolder = await store.AddCategoryAsync("folder", "Native source folder");
            var toFolder = await store.AddCategoryAsync("folder", "Native destination folder");
            await store.OrganizeAsync([imageId], null, new("folder", fromFolder));
            await UntilAsync(async () => await libraryWeb.ExecuteScriptAsync($$"""!!document.querySelector('[data-folder-id="{{toFolder}}"]')""") == "true");
            await libraryWeb.ExecuteScriptAsync($$"""document.querySelector('.assets-root').classList.add('show-sidebar');document.querySelector('[data-folder-id="{{fromFolder}}"]')?.click()""");
            await NativeDropAsync(organizer.WebSurfaceForVerify, libraryWeb, () => organizer.InternalAssetDragForVerify, imageId, false, $"[data-folder-id='{toFolder}']");
            await UntilAsync(async () => (await store.GetAsync(imageId))!.FolderIds.Contains(toFolder));
            if ((await store.GetAsync(imageId))!.FolderIds.Contains(fromFolder)) failures.Add("assets: native folder move kept source membership");
            await libraryWeb.ExecuteScriptAsync("document.body.dispatchEvent(new KeyboardEvent('keydown',{key:'z',ctrlKey:true,bubbles:true}))");
            await UntilAsync(async () => (await store.GetAsync(imageId))!.FolderIds.Contains(fromFolder));
            await store.UpdateAsync([imageId], "trash");
            await libraryWeb.ExecuteScriptAsync("document.querySelector('[data-drop-kind=trash]')?.click()");
            await NativeDropAsync(organizer.WebSurfaceForVerify, libraryWeb, () => organizer.InternalAssetDragForVerify, imageId, false, $"[data-folder-id='{toFolder}']");
            await UntilAsync(async () => !(await store.GetAsync(imageId))!.Trashed);
            var restored = (await store.GetAsync(imageId))!;
            if (!restored.FolderIds.Contains(fromFolder) || !restored.FolderIds.Contains(toFolder)) failures.Add("assets: trash-to-folder lost former membership");
            await libraryWeb.ExecuteScriptAsync("window.__recentReady=false;const recentObserver=new MutationObserver(()=>{window.__recentReady=true;recentObserver.disconnect()});recentObserver.observe(document.querySelector('.assets-sidebar'),{childList:true});document.querySelector('.assets-sidebar button')?.click()");
            VerifyConsole.WriteLine("PASS native sidebar: folder-to-folder move and Undo, trash-to-folder restores former memberships and adds destination");
            await UntilAsync(async () => await libraryWeb.ExecuteScriptAsync($$"""window.__recentReady && !!document.querySelector('[data-asset-id="{{imageId}}"]')""") == "true");
            var bounds = new Size(organizer.ActualWidth, organizer.ActualHeight);
            await libraryWeb.ExecuteScriptAsync($$"""document.querySelector('[data-asset-id="{{imageId}}"]')?.dispatchEvent(new MouseEvent('dblclick',{bubbles:true}));""");
            await UntilAsync(async () => await libraryWeb.ExecuteScriptAsync("!!document.querySelector('.assets-edit-image') && !document.querySelector('.assets-edit-image').disabled") == "true");
            await libraryWeb.ExecuteScriptAsync("document.querySelector('.assets-edit-image').click()");
            await UntilAsync(() => Task.FromResult(Descendants<ScreenshotEditorView>(organizer).Any()));
            var organizerEditor = Descendants<ScreenshotEditorView>(organizer).Single();
            if (Window.GetWindow(organizerEditor) != organizer || bounds != new Size(organizer.ActualWidth, organizer.ActualHeight)) failures.Add("assets: organizer edit changed window or bounds");
            organizerEditor.Cancel();
            await UntilAsync(async () => await libraryWeb.ExecuteScriptAsync("document.querySelector('.assets-root').getAttribute('aria-busy') !== 'true'") == "true");
            if (!organizer.WebSurfaceForVerify.IsVisible || (await store.QueryAsync(new(Limit: 200))).Items.Length != before.Count + 1) failures.Add("assets: organizer edit cancellation did not restore preview");
            VerifyConsole.WriteLine("PASS organizer inline edit/cancel: same window/bounds, preview restored, no new asset");
        }
        finally { organizer.Close(); }

    }

    private static async Task NativeDropAsync(FrameworkElement surface, CoreWebView2 web, Func<bool> dragActive, string id, bool intoTrash, string? targetSelector = null)
    {
        await UntilAsync(async () => await web.ExecuteScriptAsync($$"""!!document.querySelector('[data-asset-id="{{id}}"]')""") == "true");
        await web.ExecuteScriptAsync($$"""(()=>{window.__dragQueryReady=false;const observer=new MutationObserver(()=>{window.__dragQueryReady=true;observer.disconnect();});observer.observe(document.querySelector('.assets-sidebar'),{childList:true});const card=document.querySelector('[data-asset-id="{{id}}"]');const search=document.querySelector('.assets-search');search.value=card.querySelector('.assets-card-name').title;search.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true}));})()""");
        await UntilAsync(async () => await web.ExecuteScriptAsync("window.__dragQueryReady && document.querySelectorAll('.assets-card').length===1 && document.querySelector('.assets-summary').textContent.startsWith('1')") == "true");
        await web.ExecuteScriptAsync($$"""document.querySelector('[data-asset-id="{{id}}"]')?.click()""");
        await UntilAsync(async () => await web.ExecuteScriptAsync($$"""document.querySelector('[data-asset-id="{{id}}"]')?.getAttribute('aria-selected')==='true' && document.querySelector('.assets-preview').hidden""") == "true");
        await web.ExecuteScriptAsync("window.__dragEvents=[];for(const name of ['dragstart','dragover','drop'])document.addEventListener(name,event=>{if(window.__dragEvents.length<30)window.__dragEvents.push([name,event.clientX,event.clientY])},{capture:true})");
        await web.ExecuteScriptAsync($$"""document.querySelector('[data-asset-id="{{id}}"]')?.scrollIntoView({block:'center'})""");
        if (Window.GetWindow(surface) is PanelWindow panelWindow)
            await UntilAsync(() => Task.FromResult(panelWindow.IsVisible && !panelWindow.IsAnimating && panelWindow.RevealForVerify == 1));
        await Task.Delay(80);
        var card = await RectAsync(web, $"[data-asset-id='{id}']");
        if (targetSelector is not null) await web.ExecuteScriptAsync($"document.querySelector({JsonSerializer.Serialize(targetSelector)}).scrollIntoView({{block:'nearest'}})");
        var rawTarget = await web.ExecuteScriptAsync(targetSelector is not null
            ? $"JSON.stringify(document.querySelector({JsonSerializer.Serialize(targetSelector)}).getBoundingClientRect().toJSON())"
            : intoTrash
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

    private static async Task ClickSurfaceAsync(FrameworkElement surface, CoreWebView2 web, string selector, bool rightButton = false)
    {
        await UntilAsync(async () => await web.ExecuteScriptAsync($"!!document.querySelector({JsonSerializer.Serialize(selector)})") == "true");
        await web.ExecuteScriptAsync($"document.querySelector({JsonSerializer.Serialize(selector)}).scrollIntoView({{block:'nearest',inline:'nearest'}})");
        if (Window.GetWindow(surface) is PanelWindow panel) await UntilAsync(() => Task.FromResult(!panel.IsAnimating && panel.RevealForVerify == 1));
        await Task.Delay(100);
        surface.UpdateLayout();
        var rawBounds = await web.ExecuteScriptAsync($$"""
            (()=>{const el=document.querySelector({{JsonSerializer.Serialize(selector)}}), r=el.getBoundingClientRect(), s=el.closest('.assets-scroll')?.getBoundingClientRect();
            const x=Math.max(0,r.left,s?.left||0), y=Math.max(0,r.top,s?.top||0), right=Math.min(innerWidth,r.right,s?.right||innerWidth), bottom=Math.min(innerHeight,r.bottom,s?.bottom||innerHeight);
            return JSON.stringify({x,y,width:right-x,height:bottom-y});})()
            """);
        using var visible = JsonDocument.Parse(JsonSerializer.Deserialize<string>(rawBounds)!);
        var b = visible.RootElement; var bounds = new Rect(b.GetProperty("x").GetDouble(), b.GetProperty("y").GetDouble(), Math.Max(0,b.GetProperty("width").GetDouble()), Math.Max(0,b.GetProperty("height").GetDouble()));
        if (bounds.Width == 0 || bounds.Height == 0) throw new InvalidOperationException("Native click target is outside the viewport: " + selector);
        var ratio = surface.ActualWidth / JsonSerializer.Deserialize<double>(await web.ExecuteScriptAsync("innerWidth"));
        var position = surface.PointToScreen(new Point((bounds.X + bounds.Width / 2) * ratio, (bounds.Y + bounds.Height / 2) * ratio));
        VerifyConsole.WriteLine($"MEASURE native click: target={selector}, right={rightButton}, visible={bounds}, ratio={ratio:0.###}");
        await web.ExecuteScriptAsync($"window.__surfaceClickTarget=document.elementFromPoint({bounds.X + bounds.Width / 2},{bounds.Y + bounds.Height / 2})?.outerHTML");
        GetCursorPos(out var previous);
        try
        {
            SetCursorPos((int)position.X, (int)position.Y); await Task.Delay(80);
            MouseEvent(rightButton ? 0x0008u : 0x0002u, 0, 0, 0, 0); await Task.Delay(40);
            MouseEvent(rightButton ? 0x0010u : 0x0004u, 0, 0, 0, 0); await Task.Delay(80);
        }
        finally { MouseEvent(rightButton ? 0x0010u : 0x0004u, 0, 0, 0, 0); SetCursorPos(previous.X, previous.Y); }
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
    [DllImport("user32.dll", EntryPoint = "keybd_event")] private static extern void KeyEvent(byte key, byte scan, uint flags, nuint extra);
    [DllImport("user32.dll", EntryPoint = "mouse_event")] private static extern void MouseEvent(uint flags, uint x, uint y, uint data, nuint extra);
}
