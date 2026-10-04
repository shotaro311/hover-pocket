using System.Diagnostics;
using System.Text.Json;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using HoverPocket.Shell.Windows;

namespace HoverPocket.Shell.Verification;

internal static class ClipboardLoadVerifier
{
    public static async Task<int> RunAsync(HoverShellController controller)
    {
        var store = controller.PanelBridgeController.ClipboardHistoryForVerify;
        store.Clear();
        store.AddText("Clipboard load fixture");
        await Task.Run(() =>
        {
            var random = new Random(4312);
            for (var n = 0; n < 6; n++)
            {
                var pixels = new byte[1024 * 640 * 4]; random.NextBytes(pixels);
                for (var i = 3; i < pixels.Length; i += 4) pixels[i] = 255;
                var image = BitmapSource.Create(1024, 640, 96, 96, PixelFormats.Bgra32, null, pixels, 1024 * 4);
                image.Freeze(); store.AddImage(image);
            }
        });
        var samples = new List<double>(); var stateBytes = 0;
        for (var i = 0; i < 3; i++)
        {
            var watch = Stopwatch.StartNew();
            stateBytes = JsonSerializer.SerializeToUtf8Bytes(store.BuildState(true, false, true)).Length;
            samples.Add(watch.Elapsed.TotalMilliseconds);
        }
        VerifyConsole.WriteLine("MEASURE clipboard snapshot: " + JsonSerializer.Serialize(new { imageCount = store.ImageItems.Count, originalBytes = store.ImageItems.Sum(item => new FileInfo(store.ImagePath(item)).Length), stateBytes, samplesMs = samples }));
        var web = controller.Panel.WebView!;
        await web.ExecuteScriptAsync("""
            window.__clipboardLoad={done:false};
            (async()=>{try{
              const {request}=await import('/js/bridge.js');
              const wait=ms=>new Promise(r=>setTimeout(r,ms));
              const until=async check=>{const end=performance.now()+15000;while(!check()){if(performance.now()>end)throw Error('clipboard UI timeout');await wait(5);}};
              const start=performance.now();
              await request('provider.select',{id:'clipboard'});
              await until(()=>document.querySelectorAll('.clipboard-image-item').length===6);
              const listMs=performance.now()-start;
              await until(()=>document.querySelector('.clipboard-image-item img')?.naturalWidth>0);
              const firstImageMs=performance.now()-start;
              const {runClipboardUiVerify}=await import('/providers/clipboard/clipboard.js');
              const checks=await runClipboardUiVerify(request);
              document.querySelector('.clipboard-image-item').click();
              await until(()=>document.querySelector('.clipboard-preview-image img')?.naturalWidth===1024);
              const fullResolutionOk=document.querySelector('.clipboard-preview-image img').naturalHeight===640;
              document.querySelector('[data-clipboard-action="close"]').click();
              window.__clipboardLoad={done:true,listMs,firstImageMs,checks,fullResolutionOk};
            }catch(error){window.__clipboardLoad={done:true,error:String(error)};}})();
            """);
        var deadline = DateTime.UtcNow.AddSeconds(45);
        while (DateTime.UtcNow < deadline && await web.ExecuteScriptAsync("window.__clipboardLoad.done") != "true") await Task.Delay(40);
        var raw = await web.ExecuteScriptAsync("window.__clipboardLoad");
        VerifyConsole.WriteLine("MEASURE clipboard first mount and image: " + raw);
        using var result = JsonDocument.Parse(raw);
        if (!result.RootElement.GetProperty("done").GetBoolean() || result.RootElement.TryGetProperty("error", out _)) return 1;
        var checks = result.RootElement.GetProperty("checks");
        return result.RootElement.GetProperty("fullResolutionOk").GetBoolean()
            && checks.EnumerateObject().Where(property => property.Name.EndsWith("Ok")).All(property => property.Value.GetBoolean()) ? 0 : 1;
    }
}
