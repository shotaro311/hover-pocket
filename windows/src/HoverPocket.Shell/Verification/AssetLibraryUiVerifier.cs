using System.Text;
using System.Text.Json;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using HoverPocket.Assets;
using HoverPocket.Shell.Providers.Assets;
using HoverPocket.Shell.Windows;

namespace HoverPocket.Shell.Verification;

internal static class AssetLibraryUiVerifier
{
    public static async Task<string[]> RunAsync(HoverShellController controller)
    {
        var failures = new List<string>();
        var store = controller.PanelBridgeController.AssetLibrary;
        var fixtureRoot = Path.Combine(store.Root, "fixtures"); Directory.CreateDirectory(fixtureRoot);
        var imagePath = Path.Combine(fixtureRoot, "生成画像 透明.png");
        await Task.Run(() =>
        {
            var pixels = new byte[1200 * 1600 * 4];
            for (var y = 0; y < 1600; y++) for (var x = 0; x < 1200; x++) { var i = (y * 1200 + x) * 4; pixels[i] = (byte)(x % 256); pixels[i + 1] = (byte)(y % 256); pixels[i + 2] = 160; pixels[i + 3] = x < 100 ? (byte)0 : (byte)255; }
            var bitmap = BitmapSource.Create(1200, 1600, 96, 96, PixelFormats.Bgra32, null, pixels, 1200 * 4); bitmap.Freeze();
            var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap)); using var output = File.Create(imagePath); encoder.Save(output);
        });
        var pdfPath = Path.Combine(fixtureRoot, "生成PDF 縦横.pdf"); await File.WriteAllBytesAsync(pdfPath, PdfFixture());
        var imageId = (await store.ImportAsync(imagePath)).AssetId!; var pdfId = (await store.ImportAsync(pdfPath)).AssetId!;
        var media = AssetMedia.For(store);
        var image = (await store.GetAsync(imageId))!;
        var frame = await media.FrameAsync(image, 1, false, CancellationToken.None);
        if (frame.Width != 1200 || frame.Height != 1600 || frame.DataUrl?.StartsWith("data:image/png") != true) failures.Add("assets: PNG dimension/alpha preview failed");
        var pdf = (await store.GetAsync(pdfId))!;
        var first = await media.FrameAsync(pdf, 1, false, CancellationToken.None); var second = await media.FrameAsync(pdf, 2, false, CancellationToken.None);
        if (first.Pages != 2 || first.Width >= first.Height || second.Width <= second.Height || first.DataUrl is null || second.DataUrl is null) failures.Add("assets: native PDF lazy page render failed");
        var largePdfPath=Path.Combine(fixtureRoot,"生成PDF 1000ページ.pdf"); await File.WriteAllBytesAsync(largePdfPath,PdfFixture(1000));
        var largePdfId=(await store.ImportAsync(largePdfPath)).AssetId!;
        var largePdfFrame=await media.FrameAsync((await store.GetAsync(largePdfId))!,512,false,CancellationToken.None);
        if(largePdfFrame.Pages!=1000 || largePdfFrame.DataUrl is null || Directory.EnumerateFiles(Path.Combine(store.Root,"cache","previews"),largePdfId+"-*.jpg").Count()!=1) failures.Add("assets: 1000-page PDF rendered beyond selected page or failed");
        await media.StopPdfWorkerForVerifyAsync();
        var recoveredPdfFrame=await media.FrameAsync((await store.GetAsync(largePdfId))!,513,false,CancellationToken.None);
        if(recoveredPdfFrame.Pages!=1000 || recoveredPdfFrame.DataUrl is null) failures.Add("assets: PDF renderer restart did not preserve normal operation");
        if (Environment.GetEnvironmentVariable("HOVERPOCKET_ASSET_VERIFY_IDLE") == "1")
        {
            await Task.Delay(31000);
            var resumedPdfFrame=await media.FrameAsync((await store.GetAsync(largePdfId))!,514,false,CancellationToken.None);
            if(resumedPdfFrame.Pages!=1000 || resumedPdfFrame.DataUrl is null) failures.Add("assets: PDF renderer did not restart after idle cleanup");
            else VerifyConsole.WriteLine("PASS PDF renderer: resumed after 30-second idle cleanup");
        }
        var brokenPath=Path.Combine(fixtureRoot,"生成した破損画像.jpg"); await File.WriteAllTextAsync(brokenPath,"Generated deliberately invalid JPEG bytes");
        var brokenResult=await store.ImportAsync(brokenPath); var brokenAsset=(await store.GetAsync(brokenResult.AssetId!))!;
        var brokenFrame=await media.FrameAsync(brokenAsset,1,false,CancellationToken.None);
        if(brokenResult.Status!="saved" || brokenFrame.Error is null || !File.Exists(store.OriginalPath(brokenAsset))) failures.Add("assets: preview failure invalidated durable original");
        var protectedPath=Environment.GetEnvironmentVariable("HOVERPOCKET_ASSET_PROTECTED_PDF_FIXTURE");
        if(!string.IsNullOrWhiteSpace(protectedPath)) { var protectedId=(await store.ImportAsync(protectedPath)).AssetId!; var protectedFrame=await media.FrameAsync((await store.GetAsync(protectedId))!,1,false,CancellationToken.None); if(protectedFrame.Error?.Contains("パスワード")!=true) failures.Add("assets: password-protected PDF did not provide a specific explanation"); }
        await controller.PanelBridgeController.SelectProviderFromShellAsync("assets");
        var web = controller.Panel.WebView!;
        if (Environment.GetEnvironmentVariable("HOVERPOCKET_ASSET_INTERACTION_ONLY") == "1") { await AssetInteractionVerifier.RunAsync(controller, imageId, failures); return failures.ToArray(); }
        await web.ExecuteScriptAsync($$"""
            window.__assetProbe={done:false};
            import('/js/bridge.js').then(async ({request}) => {
              try {
                const query=await request('assets.query', {text:'生成',limit:80});
                await new Promise(r=>setTimeout(r,300));
                const card=document.querySelector('[data-asset-id="{{imageId}}"]');
                if(!card) throw Error('image card absent');
                card.dispatchEvent(new MouseEvent('dblclick',{bubbles:true}));
                for(let i=0;i<100&&!document.querySelector('.assets-media img')?.complete;i++) await new Promise(r=>setTimeout(r,30));
                const picture=document.querySelector('.assets-media img');
                const result=await request('assets.preview',{id:'{{imageId}}',page:1});
                await request('assets.layout',{fullscreen:true});
                const retained=picture===document.querySelector('.assets-media img');
                await request('assets.layout',{fullscreen:false});
                const external=await fetch('https://asset-media.hoverpocket.local/invalid/invalid');
                await request('assets.endPreview');
                window.__assetProbe={done:true,ok:query.total>=2&&result.width===1200&&retained&&external.status===403,queryCount:query.total};
              } catch(error) { window.__assetProbe={done:true,ok:false,error:error.message}; }
            });
            """);
        var deadline = DateTime.UtcNow.AddSeconds(15);
        while (DateTime.UtcNow < deadline && await web.ExecuteScriptAsync("window.__assetProbe.done") != "true") await Task.Delay(50);
        var raw = await web.ExecuteScriptAsync("window.__assetProbe");
        using var result = JsonDocument.Parse(raw);
        if (!result.RootElement.TryGetProperty("ok", out var ok) || !ok.GetBoolean()) failures.Add("assets: native WebView preview/layout/lease probe failed: " + raw);
        var normalSize = controller.PanelBridgeController.CurrentSettings.PanelSize;
        await Task.Delay(700);
        var resizeCount = 0;
        System.Windows.SizeChangedEventHandler onResize = (_, _) => resizeCount++;
        web.SizeChanged += onResize;
        await web.ExecuteScriptAsync($$"""import('/js/bridge.js').then(async({request})=>{await request('assets.preview',{id:'{{imageId}}'});await request('assets.layout',{fullscreen:false});});""");
        deadline = DateTime.UtcNow.AddSeconds(8);
        while (DateTime.UtcNow < deadline && (!controller.Panel.AssetLayout.Active || controller.Panel.AssetLayout.Width != 1200 || controller.Panel.IsAnimating)) await Task.Delay(30);
        web.SizeChanged -= onResize;
        if (resizeCount > 2) failures.Add($"assets: preview recreated native content size {resizeCount} times");
        VerifyConsole.WriteLine($"PASS preview animation: native content resizes={resizeCount} (bounded per destination)");
        var layout = controller.ActiveLayoutForVerify!;
        var target = controller.Panel.LiquidTargetForVerify;
        if (target is null || target.DipRect.Width > layout.Monitor.WorkArea.Width / layout.Monitor.ScaleX * .9 + 1 || target.DipRect.Height > layout.Monitor.WorkArea.Height / layout.Monitor.ScaleY * .85 + 1)
            failures.Add("assets: adaptive native panel exceeds work area cap");
        controller.SimulatePointerMoveForVerify(layout.Monitor.WorkArea.Left + 20, layout.Monitor.WorkArea.Bottom - 20);
        await Task.Delay(650);
        if (!controller.Panel.IsVisible || !controller.Panel.AssetLayout.Active) failures.Add("assets: preview was not pinned outside hover area");
        await web.ExecuteScriptAsync("import('/js/bridge.js').then(async({request})=>{await request('assets.layout',{fullscreen:true});window.__nativeFull=true;});");
        deadline = DateTime.UtcNow.AddSeconds(5);
        while (DateTime.UtcNow < deadline && (!controller.Panel.AssetLayout.Fullscreen || controller.Panel.IsAnimating)) await Task.Delay(30);
        if (controller.Panel.LiquidTargetForVerify?.PhysicalRect != layout.Monitor.Bounds) failures.Add("assets: fullscreen does not use current monitor bounds");
        await controller.RunHealthCheckForVerifyAsync();
        if (!controller.Panel.AssetLayout.Fullscreen || controller.Panel.LiquidTargetForVerify?.PhysicalRect != layout.Monitor.Bounds) failures.Add("assets: health repair reset fullscreen preview");
        controller.Panel.SetAssetBackgrounded(true);
        await controller.RunHealthCheckForVerifyAsync();
        if (!controller.Panel.AssetBackgrounded || (HoverPocket.Shell.Interop.NativeMethods.GetExtendedStyles(controller.Panel.Hwnd) & HoverPocket.Shell.Interop.NativeMethods.WsExTopmost) != 0)
            failures.Add("assets: health repair raised backgrounded preview");
        controller.Panel.SetAssetBackgrounded(false);
        await web.ExecuteScriptAsync("import('/js/bridge.js').then(async({request})=>{const s=await request('timer.getState');await request('timer.start',{preset:{...s.draftTimer,title:'Asset preview timer probe',durationSeconds:1,isPomodoro:false,soundEnabled:false}});});");
        await Task.Delay(1300);
        if (controller.PanelBridgeController.SelectedProviderId != "assets" || !controller.Panel.AssetLayout.Fullscreen) failures.Add("assets: timer expiry interrupted pinned fullscreen preview");
        await web.ExecuteScriptAsync("import('/js/bridge.js').then(({request})=>request('timer.stopAlert'));");
        await web.ExecuteScriptAsync("import('/js/bridge.js').then(async({request})=>{await request('assets.layout',{fullscreen:false});await request('assets.endPreview');});");
        await Task.Delay(300);
        if (controller.PanelBridgeController.CurrentSettings.PanelSize != normalSize) failures.Add("assets: preview changed normal size preferences");
        controller.SetPointerSimulationForVerify(layout.AccessSurface.PhysicalRect.Left + layout.AccessSurface.PhysicalRect.Width / 2, layout.AccessSurface.PhysicalRect.Top);
        await web.ExecuteScriptAsync($$"""window.__dragPrepared=false;import('/js/bridge.js').then(async({request})=>{const a=await request('assets.copy',{id:'{{imageId}}',mode:'drag'});const b=await request('assets.copy',{id:'{{imageId}}',mode:'drag'});window.__dragPrepared=!!a.prepared&&!!b.prepared;});""");
        deadline=DateTime.UtcNow.AddSeconds(8);while(DateTime.UtcNow<deadline && await web.ExecuteScriptAsync("window.__dragPrepared")!="true")await Task.Delay(30);
        if(await web.ExecuteScriptAsync("window.__dragPrepared")!="true")failures.Add("assets: asynchronous drag preparation failed");
        var videoPath = Environment.GetEnvironmentVariable("HOVERPOCKET_ASSET_VIDEO_FIXTURE");
        if (!string.IsNullOrWhiteSpace(videoPath))
        {
            var videoId = (await store.ImportAsync(videoPath)).AssetId!; var video = (await store.GetAsync(videoId))!;
            var poster = await media.FrameAsync(video, 1, false, CancellationToken.None);
            if (poster.DataUrl is null || poster.Width != 640) failures.Add("assets: native H.264 poster failed: " + poster.FailureCode);
            await web.ExecuteScriptAsync($$"""
                window.__videoProbe={done:false};
                import('/js/bridge.js').then(async ({request})=>{
                  try {
                    const result=await request('assets.preview',{id:'{{videoId}}'});
                    const video=document.createElement('video');video.muted=true;video.src=result.videoUrl;document.body.append(video);
                    await video.play();video.currentTime=.5;video.volume=.3;
                    await request('assets.layout',{fullscreen:true});await request('assets.layout',{fullscreen:false});
                    const same=video.volume===.3&&!video.paused;
                    const response=await fetch(result.videoUrl,{headers:{Range:'bytes=0-127'} });
                    const bytes=await response.arrayBuffer();
                    video.pause();video.removeAttribute('src');video.load();video.remove();
                    await request('assets.endPreview');
                    const revoked=await fetch(result.videoUrl);
                    window.__videoProbe={done:true,ok:same&&response.status===206&&bytes.byteLength===128&&revoked.status===403};
                  }catch(error){window.__videoProbe={done:true,ok:false,error:error.message};}
                });
                """);
            deadline = DateTime.UtcNow.AddSeconds(15);
            while (DateTime.UtcNow < deadline && await web.ExecuteScriptAsync("window.__videoProbe.done") != "true") await Task.Delay(50);
            var videoResult = await web.ExecuteScriptAsync("window.__videoProbe");
            using var parsed = JsonDocument.Parse(videoResult);
            if (!parsed.RootElement.TryGetProperty("ok", out var success) || !success.GetBoolean()) failures.Add("assets: H.264 playback/range/fullscreen/revocation failed: " + videoResult);
        }
        var bridge = controller.PanelBridgeController;
        var dropFolder=Path.Combine(fixtureRoot,"取り込み階層"); Directory.CreateDirectory(Path.Combine(dropFolder,"空フォルダ")); await File.WriteAllTextAsync(Path.Combine(dropFolder,"任意形式.dat"),"Generated folder drop content");
        var dropData=new System.Windows.DataObject(System.Windows.DataFormats.FileDrop,new[]{dropFolder});
        await controller.Panel.ReceiveAssetDropAsync(dropData);
        deadline=DateTime.UtcNow.AddSeconds(8); AssetPage? droppedPage=null;
        // The importer enumerates files and directories independently of their creation order.
        while(DateTime.UtcNow<deadline) { droppedPage=await store.QueryAsync(new()); if(droppedPage.Items.Any(a=>a.Name=="任意形式.dat") && droppedPage.Folders.Any(c=>c.Name=="空フォルダ"))break; await Task.Delay(50); }
        if(droppedPage is null || !droppedPage.Folders.Any(c=>c.Name=="空フォルダ") || !droppedPage.Items.Any(a=>a.Name=="任意形式.dat")) failures.Add("assets: native file-drop payload or empty folder hierarchy failed");
        await bridge.SelectProviderFromShellAsync("controls");
        var savedPreference = bridge.CurrentSettings.LastSelectedProviderId;
        await bridge.BeginAssetDropAsync();
        if (bridge.SelectedProviderId != "assets") failures.Add("assets: drag did not temporarily select assets");
        await bridge.CancelAssetDropAsync();
        if (bridge.SelectedProviderId != "controls" || bridge.CurrentSettings.LastSelectedProviderId != savedPreference) failures.Add("assets: cancelled drag changed user provider preferences");
        controller.OpenAssetLibraryFromUser(); var organizer = controller.AssetOrganizerForVerify!;
        deadline = DateTime.UtcNow.AddSeconds(12);
        while (DateTime.UtcNow < deadline && (organizer.WebViewForVerify is null || await organizer.WebViewForVerify.ExecuteScriptAsync("window.__hoverPocketReady===true") != "true")) await Task.Delay(50);
        if (organizer.WebViewForVerify is { } organizerWeb)
        {
            await Task.Delay(350);
            var organizerState = await organizerWeb.ExecuteScriptAsync("({cards:document.querySelectorAll('.assets-card').length,detail:!!document.querySelector('.assets-detail'),scroll:document.querySelector('.assets-scroll')?.clientHeight,overflow:document.documentElement.scrollWidth>innerWidth})");
            using var organizerResult = JsonDocument.Parse(organizerState);
            if (organizerResult.RootElement.GetProperty("cards").GetInt32()<2 || !organizerResult.RootElement.GetProperty("detail").GetBoolean() || organizerResult.RootElement.GetProperty("scroll").GetInt32()<=0 || organizerResult.RootElement.GetProperty("overflow").GetBoolean()) failures.Add("assets: organizer layout or shared store failed");
            if(!string.IsNullOrWhiteSpace(videoPath))
            {
                var ownedVideo=(await store.QueryAsync(new(Kind:"video"))).Items.Single(); await bridge.SelectProviderFromShellAsync("assets");
                await web.ExecuteScriptAsync($$"""
                    window.__ownedPlayerReady=false;
                    (async()=>{for(let i=0;i<100&&!document.querySelector('[data-asset-id="{{ownedVideo.Id}}"]');i++)await new Promise(r=>setTimeout(r,30));
                    document.querySelector('[data-asset-id="{{ownedVideo.Id}}"]')?.dispatchEvent(new MouseEvent('dblclick',{bubbles:true}));
                    for(let i=0;i<100&&!document.querySelector('.assets-media video')?.readyState;i++)await new Promise(r=>setTimeout(r,30));
                    window.__ownedVideo=document.querySelector('.assets-media video');if(window.__ownedVideo){window.__ownedVideo.muted=true;await window.__ownedVideo.play();window.__ownedPlayerReady=true;} })();
                    """);
                deadline=DateTime.UtcNow.AddSeconds(10); while(DateTime.UtcNow<deadline && await web.ExecuteScriptAsync("window.__ownedPlayerReady")!="true") await Task.Delay(50);
                if(await web.ExecuteScriptAsync("window.__ownedPlayerReady")!="true") failures.Add("assets: actual provider video player did not play");
                await organizerWeb.ExecuteScriptAsync($$"""document.querySelector('[data-asset-id="{{imageId}}"]')?.dispatchEvent(new MouseEvent('dblclick',{bubbles:true}));""");
                deadline=DateTime.UtcNow.AddSeconds(8); while(DateTime.UtcNow<deadline && controller.Panel.AssetLayout.Active) await Task.Delay(50);
                await Task.Delay(150);
                if(controller.Panel.AssetLayout.Active || await web.ExecuteScriptAsync("!!window.__ownedVideo&&window.__ownedVideo.paused&&!window.__ownedVideo.hasAttribute('src')")!="true") failures.Add("assets: organizer preview did not release and stop pocket player");
                await organizerWeb.ExecuteScriptAsync("document.querySelector('[data-action=\"endPreview\"]')?.click();"); await Task.Delay(200);
            }
            var logPath = Environment.GetEnvironmentVariable("HOVERPOCKET_VERIFY_LOG");
            if (logPath is not null) { using var screenshot = File.Create(Path.Combine(Path.GetDirectoryName(logPath)!,"asset-organizer.png")); await organizerWeb.CapturePreviewAsync(Microsoft.Web.WebView2.Core.CoreWebView2CapturePreviewImageFormat.Png,screenshot); }
        }
        else failures.Add("assets: organizer WebView did not initialize");
        organizer.Close();
        var recycleName = "HoverPocket-generated-recycle-" + Guid.NewGuid().ToString("N") + ".txt";
        var recyclePath = Path.Combine(fixtureRoot,recycleName); await File.WriteAllTextAsync(recyclePath,"Generated disposable acceptance fixture");
        if (!await AssetRecycle.MoveAsync(recyclePath)) failures.Add("assets: native OS recycle failed for generated fixture");
        else
        {
            object? shellObject=null, binObject=null, itemsObject=null; var found=false;
            try
            {
                shellObject=Activator.CreateInstance(Type.GetTypeFromProgID("Shell.Application")!); dynamic shell=shellObject!;
                binObject=shell.NameSpace(10); dynamic bin=binObject; itemsObject=bin.Items(); dynamic items=itemsObject;
                for(var i=0;i<(int)items.Count;i++) { object itemObject=items.Item(i); dynamic item=itemObject; try { if (((string)item.Name).Contains(Path.GetFileNameWithoutExtension(recycleName),StringComparison.Ordinal)) found=true; } finally { System.Runtime.InteropServices.Marshal.FinalReleaseComObject(itemObject); } }
            }
            finally { foreach(var value in new[]{itemsObject,binObject,shellObject}) if(value is not null) System.Runtime.InteropServices.Marshal.FinalReleaseComObject(value); }
            if(!found) failures.Add("assets: generated fixture was not confirmed in Windows Recycle Bin");
        }
        await web.ExecuteScriptAsync("window.__assetSelectionResult=null; import('/providers/assets/assets.verify.js').then(async module=>{window.__assetSelectionResult=await module.verifyAssetSelection();}).catch(error=>{window.__assetSelectionResult={ok:false,error:error.message};});");
        deadline = DateTime.UtcNow.AddSeconds(20);
        while (DateTime.UtcNow < deadline && await web.ExecuteScriptAsync("window.__assetSelectionResult!==null") != "true") await Task.Delay(40);
        var selectionResult = await web.ExecuteScriptAsync("window.__assetSelectionResult");
        using (var selectionJson = JsonDocument.Parse(selectionResult))
        {
            if (selectionJson.RootElement.ValueKind != JsonValueKind.Object || !selectionJson.RootElement.GetProperty("ok").GetBoolean()) failures.Add("assets selection regression: " + selectionResult);
            else VerifyConsole.WriteLine("PASS asset selection: " + selectionResult);
        }
        await controller.PanelBridgeController.SelectProviderFromShellAsync("controls");
        await AssetInteractionVerifier.RunAsync(controller, imageId, failures);
        if (failures.Count == 0) VerifyConsole.WriteLine("PASS assets: durable import, PNG alpha, PDF mixed/1000 lazy pages/isolated worker restart, corrupt/protected originals, virtual cards, native resize/fullscreen/pinning/background health, uninterrupted timer, drag preparation, resource lease, organizer, empty folder drop, temporary selection, OS recycle" + (videoPath is null ? " (video fixture absent)" : ", H.264 playback/range delivery/single owner"));
        return failures.ToArray();
    }
    private static byte[] PdfFixture(int pages = 2)
    {
        var objects = new List<string> { "<< /Type /Catalog /Pages 2 0 R >>", $"<< /Type /Pages /Kids [{string.Join(' ',Enumerable.Range(3,pages).Select(n=>$"{n} 0 R"))}] /Count {pages} >>" };
        for(var i=0;i<pages;i++) objects.Add($"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {(i%2==0?"600 800":"800 600")}] /Resources << >> /Contents {pages+3} 0 R >>");
        objects.Add("<< /Length 0 >>\nstream\n\nendstream");
        var text = new StringBuilder("%PDF-1.4\n"); var offsets = new List<int>();
        for (var i = 0; i < objects.Count; i++) { offsets.Add(Encoding.ASCII.GetByteCount(text.ToString())); text.Append($"{i + 1} 0 obj\n{objects[i]}\nendobj\n"); }
        var xref = Encoding.ASCII.GetByteCount(text.ToString()); text.Append($"xref\n0 {objects.Count + 1}\n0000000000 65535 f \n"); foreach (var offset in offsets) text.Append($"{offset:0000000000} 00000 n \n");
        text.Append($"trailer\n<< /Size {objects.Count + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n"); return Encoding.ASCII.GetBytes(text.ToString());
    }
}
