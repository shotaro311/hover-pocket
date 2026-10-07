using System.Text.Json;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using HoverPocket.Shell.Bridge;
using HoverPocket.Shell.Providers.Assets;
using HoverPocket.Shell.Windows;

namespace HoverPocket.Shell.Verification;

internal static class LibraryMediaVerifier
{
    internal static async Task<int> RunAsync(HoverShellController controller)
    {
        try
        {
            var host = controller.PanelBridgeController; var store = host.AssetLibrary;
            var fixture = Environment.GetEnvironmentVariable("HOVERPOCKET_LIBRARY_MEDIA_FIXTURES") ?? throw new Exception("fixtures required");
            var media = AssetMedia.For(store);
            var imported = new List<HoverPocket.Assets.Asset>();
            foreach (var path in Directory.GetFiles(fixture).Order())
            {
                var result = await store.ImportAsync(path); var asset = await store.GetAsync(result.AssetId!); if (asset is null) throw new Exception("import failed");
                imported.Add(asset);
                var kind = AssetPreviewFormats.Kind(asset.Extension);
                if (kind is "text" or "document" or "image" or "pdf" or "video")
                {
                    var frame = await media.FrameAsync(asset, 1, false, CancellationToken.None);
                    if (frame.Error is not null || frame.DataUrl is null && frame.TextContent is null) throw new Exception(asset.Extension + ": " + frame.Error);
                    if (kind is "text" or "document" && !frame.TextContent!.Contains("Library fixture")) throw new Exception(asset.Extension + " lost fixture content");
                    var thumb = await media.FrameAsync(asset, 1, true, CancellationToken.None);
                    if (thumb.DataUrl is null && thumb.TextContent is null) throw new Exception(asset.Extension + " thumbnail failed");
                    if (thumb.DataUrl is not null && Convert.FromBase64String(thumb.DataUrl[(thumb.DataUrl.IndexOf(',') + 1)..]).Length > 65536) throw new Exception(asset.Extension + " thumbnail exceeded byte budget");
                    VerifyConsole.WriteLine("PASS file preview + thumbnail: " + asset.Extension);
                }
            }
            var settings = new BridgeDispatcher(); using var settingsAttachment = host.Attach(settings, BridgeSurface.Settings);
            async Task Change(bool enabled, string method = "settings.setLibraryAutoImportClipboardImages")
            {
                var raw = await settings.ProcessRawMessageAsync(JsonSerializer.Serialize(new { id = "clipboard-option", method, @params = new { enabled } }));
                if (raw?.Contains("\"error\":{") == true) throw new Exception("setting rejected");
            }
            var history = host.ClipboardHistoryForVerify;
            BitmapSource Image(byte value) => BitmapSource.Create(3, 3, 96, 96, PixelFormats.Bgra32, null, Enumerable.Repeat(value, 36).ToArray(), 12);
            var before = (await store.QueryAsync(new(Limit: 1))).Total;
            history.AddImage(Image(50), "WM_CLIPBOARDUPDATE"); await Task.Delay(200);
            if ((await store.QueryAsync(new(Limit: 1))).Total != before) throw new Exception("default off imported clipboard");
            await Change(true);
            history.AddImage(Image(80), "WM_CLIPBOARDUPDATE");
            var deadline = DateTime.UtcNow.AddSeconds(8);
            while (DateTime.UtcNow < deadline && (await store.QueryAsync(new(Limit: 1))).Total == before) await Task.Delay(30);
            if ((await store.QueryAsync(new(Limit: 1))).Total != before + 1) throw new Exception("enabled import did not save one image");
            history.AddImage(Image(80), "WM_CLIPBOARDUPDATE"); await Task.Delay(300);
            if ((await store.QueryAsync(new(Limit: 1))).Total != before + 1) throw new Exception("duplicate clipboard copied twice");
            await Change(true, "settings.setClipboardPrivateMode"); history.AddImage(Image(95), "WM_CLIPBOARDUPDATE"); await Task.Delay(200);
            if ((await store.QueryAsync(new(Limit: 1))).Total != before + 1) throw new Exception("private mode imported image");
            await Change(false, "settings.setClipboardPrivateMode"); await Change(false);
            history.AddImage(Image(110), "WM_CLIPBOARDUPDATE"); await Task.Delay(200);
            if ((await store.QueryAsync(new(Limit: 1))).Total != before + 1) throw new Exception("disabled import changed library");
            VerifyConsole.WriteLine("PASS clipboard option: default off, enable, duplicate, private mode, disable preserves saved asset");
            await host.SelectProviderFromShellAsync("assets"); await controller.ShowPanelForUiVerifyAsync();
            var web = controller.Panel.WebView!;
            var playable = imported.Where(a => AssetPreviewFormats.Kind(a.Extension) is "audio" or "video")
                .Select(a => new { id = a.Id, kind = AssetPreviewFormats.Kind(a.Extension), extension = a.Extension });
            await web.ExecuteScriptAsync($$$"""
              window.__mediaProbe={done:false};
              (async()=>{try{
                const {request}=await import('/js/bridge.js');
                const checks=[];
                for(const asset of {{{JsonSerializer.Serialize(playable)}}}) {
                  await request('assets.preview',{id:asset.id,page:1});
                  const result=await request('assets.playbackFallback',{id:asset.id});
                  if(!result?.url)throw Error(asset.extension+' missing playback URL');
                  const player=document.createElement(asset.kind);player.muted=true;player.preload='auto';player.style.display='none';document.body.append(player);
                  try {
                    const loaded=new Promise((resolve,reject)=>{player.onloadeddata=resolve;player.onerror=()=>reject(Error(asset.extension+' decode failed'));setTimeout(()=>reject(Error(asset.extension+' load timeout')),15000);});
                    player.src=result.url;player.load();await loaded;
                    if(!(player.duration>0))throw Error(asset.extension+' no duration');
                    const sought=new Promise((resolve,reject)=>{player.onseeked=resolve;setTimeout(()=>reject(Error(asset.extension+' seek timeout')),5000);});
                    player.currentTime=player.duration/2;await sought;checks.push(asset.extension);
                  } finally {player.pause();player.removeAttribute('src');player.load();player.remove();}
                  await request('assets.endPreview');
                }
                window.__mediaProbe={done:true,ok:true,checks};
              }catch(e){window.__mediaProbe={done:true,ok:false,error:e.message};}})();
              """);
            var mediaDeadline = DateTime.UtcNow.AddMinutes(4);
            while (DateTime.UtcNow < mediaDeadline && await web.ExecuteScriptAsync("window.__mediaProbe.done") != "true") await Task.Delay(100);
            var mediaProbe = await web.ExecuteScriptAsync("window.__mediaProbe");
            if (!JsonDocument.Parse(mediaProbe).RootElement.GetProperty("ok").GetBoolean()) throw new Exception(mediaProbe);
            VerifyConsole.WriteLine("PASS actual browser decode + seek after compatible playback: " + mediaProbe);
            var textAsset = imported.Single(x => x.Name == "fixture.txt");
            await web.ExecuteScriptAsync("document.querySelector('.assets-search-field input').value='fixture.txt';document.querySelector('.assets-search-field input').dispatchEvent(new Event('input',{bubbles:true}))");
            await web.ExecuteScriptAsync($$$"""
              window.__documentProbe={done:false};
              (async()=>{try{
                const wait=async p=>{for(let i=0;i<200;i++){if(p())return;await new Promise(r=>setTimeout(r,25));}throw Error('UI timeout');};
                await wait(()=>document.querySelector('[data-asset-id="{{{textAsset.Id}}}"] .assets-card-excerpt'));
                document.querySelector('[data-asset-id="{{{textAsset.Id}}}"]')?.dispatchEvent(new MouseEvent('dblclick',{bubbles:true}));
                await wait(()=>document.querySelector('.assets-document-text'));
                const content=document.querySelector('.assets-document-text');
                const safe=content.textContent.includes('Library fixture')&&!content.querySelector('script')&&!window.fixtureExecuted;
                window.__documentProbe={done:true,ok:safe&&content.scrollWidth<=content.clientWidth+1};
              }catch(e){window.__documentProbe={done:true,ok:false,error:e.message};}})();
              """);
            deadline = DateTime.UtcNow.AddSeconds(15);
            while (DateTime.UtcNow < deadline && await web.ExecuteScriptAsync("window.__documentProbe.done") != "true") await Task.Delay(30);
            var probe = await web.ExecuteScriptAsync("window.__documentProbe");
            if (!JsonDocument.Parse(probe).RootElement.GetProperty("ok").GetBoolean()) throw new Exception(probe);
            var target = controller.Layouts[0].AccessSurface.PhysicalRect;
            controller.SimulatePointerMoveForVerify(target.Left + target.Width / 2, target.Top + 20);
            controller.SimulatePointerMoveForVerify(target.Left - 500, target.Top + 1000);
            deadline = DateTime.UtcNow.AddSeconds(3);
            while (DateTime.UtcNow < deadline && controller.Panel.IsVisible) await Task.Delay(30);
            if (controller.PanelExpectedVisibleForVerify || controller.Panel.IsVisible) throw new Exception("library preview did not close on hover exit: expected=" + controller.PanelExpectedVisibleForVerify + ", visible=" + controller.Panel.IsVisible + ", layout=" + controller.Panel.AssetLayout + ", owned=" + string.Join(",", controller.Panel.OwnedWindows.OfType<System.Windows.Window>().Where(w => w.IsVisible).Select(w => w.Title)) + ", chat=" + host.KeepPanelForChat + ", contains=" + controller.Panel.ContainsPhysicalPoint(target.Left - 500, target.Top + 1000));
            VerifyConsole.WriteLine("PASS real document UI: literal safe text, thumbnail, no overflow, preview closes on hover exit");
            foreach (var asset in imported) if (Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(await File.ReadAllBytesAsync(store.OriginalPath(asset)))).ToLowerInvariant() != asset.Sha256) throw new Exception("original changed");
            return 0;
        }
        catch (Exception ex) { VerifyConsole.WriteLine("FAIL library media: " + ex); return 1; }
    }
}
