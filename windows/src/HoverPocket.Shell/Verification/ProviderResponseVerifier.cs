using System.Text.Json;
using Microsoft.Web.WebView2.Wpf;

namespace HoverPocket.Shell.Verification;

internal static class ProviderResponseVerifier
{
    public static async Task<int> RunAsync(WebView2CompositionControl web)
    {
        await web.ExecuteScriptAsync("""
            window.__responseProbe = {done:false};
            (async () => {
              try {
                const samples = []; let headerMutations = 0;
                const headerObserver = new MutationObserver(records => { headerMutations += records.filter(record => record.type === 'childList').length; });
                for (const selector of ['[data-provider-icons]','[data-size-switch]']) {
                  const header = document.querySelector(selector); if (header) headerObserver.observe(header,{childList:true,subtree:true});
                }
                const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
                const paint = () => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
                const order = ['calculator','controls','timer','clipboard','assets'];
                for (let round = 0; round < 6; round++) for (const id of order) {
                  await wait(220);
                  const button = document.querySelector(`[data-provider-id="${id}"]`);
                  if (!button) throw Error(`Missing provider ${id}`);
                  const start = performance.now();
                  button.dispatchEvent(new MouseEvent('mouseenter'));
                  button.click();
                  while (button.getAttribute('aria-pressed') !== 'true') {
                    if (performance.now() - start > 10000) throw Error(`Switch timed out: ${id}`);
                    await wait(1);
                  }
                  await paint();
                  const paintMs = performance.now()-start;
                  const animations = document.querySelector('.hp-provider').getAnimations().filter(animation => animation.animationName === 'hp-provider-enter');
                  await Promise.all(animations.map(animation => animation.finished));
                  samples.push({id,round,paintMs,settledMs:performance.now()-start});
                }
                headerObserver.disconnect();
                window.__responseProbe = {done:true,samples,headerMutations};
              } catch(error) { window.__responseProbe = {done:true,error:error.message}; }
            })();
            """);
        var deadline = DateTime.UtcNow.AddSeconds(90);
        while (DateTime.UtcNow < deadline && await web.ExecuteScriptAsync("window.__responseProbe.done") != "true") await Task.Delay(50);
        var raw = await web.ExecuteScriptAsync("window.__responseProbe");
        VerifyConsole.WriteLine("MEASURE provider response (input to selected UI and two animation frames): " + raw);
        using var result = JsonDocument.Parse(raw);
        return result.RootElement.GetProperty("done").GetBoolean() && !result.RootElement.TryGetProperty("error", out _) ? 0 : 1;
    }
}
