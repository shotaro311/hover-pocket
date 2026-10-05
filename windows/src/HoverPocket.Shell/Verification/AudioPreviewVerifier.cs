using System.Text.Json;
using HoverPocket.Shell.Capture;
using HoverPocket.Shell.Windows;

namespace HoverPocket.Shell.Verification;

internal static class AudioPreviewVerifier
{
    internal static async Task RunAsync(HoverShellController controller)
    {
        var fixture = Environment.GetEnvironmentVariable("HOVERPOCKET_ASSET_AUDIO_FIXTURE");
        if (string.IsNullOrEmpty(fixture)) { VerifyConsole.WriteLine("SKIP AAC playback: HOVERPOCKET_ASSET_AUDIO_FIXTURE not supplied"); return; }
        var store = controller.PanelBridgeController.AssetLibrary;
        var folder = await store.AddCategoryAsync("folder", "Generated audio recovery");
        var files = new CaptureFiles(store); var stage = files.CreateStage();
        File.Copy(fixture, Path.Combine(stage, "Generated audio.m4a"));
        CaptureFiles.MarkComplete(stage, ["Generated audio.m4a"], folder);
        if (await files.RetryPendingAsync() is not { Saved: 1, Failed: 0 }) throw new Exception("AAC pending recovery failed");
        var audio = (await store.QueryAsync(new(FolderId: folder))).Items.Single();
        if (audio.Kind != "other" || !File.ReadAllBytes(store.OriginalPath(audio)).SequenceEqual(File.ReadAllBytes(fixture))) throw new Exception("AAC recovery changed kind/bytes");
        await controller.PanelBridgeController.SelectProviderFromShellAsync("assets");
        await controller.ShowPanelForUiVerifyAsync();
        var web = controller.Panel.WebView!;
        await web.ExecuteScriptAsync($$"""
            window.__audioProbe={done:false};
            import('/js/bridge.js').then(async({request})=>{
              let player;
              try {
                const result=await request('assets.preview',{id:'{{audio.Id}}'});
                if(!result.audioUrl || result.videoUrl || result.error) throw Error('audio preview contract');
                player=document.createElement('audio');player.muted=true;player.src=result.audioUrl;document.body.append(player);
                await player.play();player.currentTime=.5;
                await new Promise((resolve,reject)=>{if(!player.seeking)return resolve();player.onseeked=resolve;setTimeout(()=>reject(Error('seek timeout')),4000)});
                const seek=player.currentTime>=.45&&!player.paused;
                const full=await fetch(result.audioUrl);const bytes=new Uint8Array(await full.arrayBuffer());
                const digest=[...new Uint8Array(await crypto.subtle.digest('SHA-256',bytes))].map(b=>b.toString(16).padStart(2,'0')).join('');
                const range=await fetch(result.audioUrl,{headers:{Range:'bytes=1-127'} });const part=new Uint8Array(await range.arrayBuffer());
                player.pause();player.removeAttribute('src');player.load();player.remove();player=null;
                await request('assets.endPreview');const revoked=await fetch(result.audioUrl);
                window.__audioProbe={done:true,ok:seek&&full.headers.get('Content-Type')==='audio/mp4'&&digest==='{{audio.Sha256}}'&&range.status===206&&part.length===127&&part.every((b,i)=>b===bytes[i+1])&&revoked.status===403,seek,revoked:revoked.status};
              }catch(error){window.__audioProbe={done:true,ok:false,error:error.message};}
              finally{if(player){player.pause();player.removeAttribute('src');player.load();player.remove();} }
            });
            """);
        var deadline = DateTime.UtcNow.AddSeconds(15);
        while (DateTime.UtcNow < deadline && await web.ExecuteScriptAsync("window.__audioProbe.done") != "true") await Task.Delay(40);
        var raw = await web.ExecuteScriptAsync("window.__audioProbe");
        using var result = JsonDocument.Parse(raw);
        if (!result.RootElement.TryGetProperty("ok", out var ok) || !ok.GetBoolean()) throw new Exception("AAC playback/range/lease failed: " + raw);
        using (new FileStream(store.OriginalPath(audio), FileMode.Open, FileAccess.Read, FileShare.None)) { }
        VerifyConsole.WriteLine("PASS generated AAC: pending-file recovery, original bytes/folder, muted native playback/seek, range bytes, revoked lease and released file handle");
        await web.ExecuteScriptAsync($$"""
            window.__audioUi={done:false};
            (async()=>{try{
              const wait=async predicate=>{for(let i=0;i<150;i++){if(predicate())return;await new Promise(r=>setTimeout(r,30));}throw Error('audio UI timeout');};
              await wait(()=>document.querySelector('[data-asset-id="{{audio.Id}}"]'));
              document.querySelector('[data-asset-id="{{audio.Id}}"]')?.dispatchEvent(new MouseEvent('dblclick',{bubbles:true}));
              await wait(()=>document.querySelector('.assets-media audio')?.src);
              const player=document.querySelector('.assets-media audio'),paused=player.paused;
              player.muted=true;await player.play();
              document.querySelector('[data-action=endPreview]').click();
              await wait(()=>!document.querySelector('.assets-media audio'));
              window.__audioUi={done:true,ok:paused&&player.paused&&!player.getAttribute('src')};
            }catch(error){window.__audioUi={done:true,ok:false,error:error.message};} })();
            """);
        deadline = DateTime.UtcNow.AddSeconds(12);
        while (DateTime.UtcNow < deadline && await web.ExecuteScriptAsync("window.__audioUi.done") != "true") await Task.Delay(40);
        raw = await web.ExecuteScriptAsync("window.__audioUi");
        using var ui = JsonDocument.Parse(raw);
        if (!ui.RootElement.TryGetProperty("ok", out var uiOk) || !uiOk.GetBoolean()) throw new Exception("Shared audio UI failed: " + raw);
        VerifyConsole.WriteLine("PASS shared audio UI: real card opens controls without autoplay; end-preview pauses and releases source");
    }
}
