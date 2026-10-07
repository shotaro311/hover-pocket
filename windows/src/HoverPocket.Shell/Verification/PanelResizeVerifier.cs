using System.Text.Json;
using System.Windows.Controls.Primitives;
using HoverPocket.Shell.Configuration;
using HoverPocket.Shell.Windows;
using Microsoft.Web.WebView2.Core;

namespace HoverPocket.Shell.Verification;

internal static class PanelResizeVerifier
{
    internal static async Task<int> RunAsync(HoverShellController controller)
    {
        var panel = controller.Panel;
        var web = panel.WebView!.CoreWebView2;
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(100));
        var token = timeout.Token;
        try
        {
            var layout = controller.Layouts[0];
            var limits = PanelSizeCatalog.ResizeLimits(layout.AccessSurface.DipRect.Height + controller.PanelBridgeController.ChatHeight);
            var grip = panel.ResizeGripForVerify;
            void Drag(double width, double height)
            {
                grip.RaiseEvent(new DragStartedEventArgs(0, 0) { RoutedEvent = Thumb.DragStartedEvent });
                grip.RaiseEvent(new DragDeltaEventArgs((width - panel.Width) / 2, height - panel.Height) { RoutedEvent = Thumb.DragDeltaEvent });
                grip.RaiseEvent(new DragCompletedEventArgs(0, 0, false) { RoutedEvent = Thumb.DragCompletedEvent });
            }
            var cases = new[] { ("minimum", 1d, 1d), ("wide-short", limits.MaxWidth, limits.MinHeight),
                ("narrow-tall", limits.MinWidth, limits.MaxHeight), ("middle", 640d, (limits.MinHeight + limits.MaxHeight) / 2), ("maximum", 90000d, 90000d) };
            var providers = new Dictionary<string, string> { ["calendar"] = ".hp-calendar", ["controls"] = ".hp-controls", ["calculator"] = ".hp-calc", ["clipboard"] = ".clipboard-root,.clipboard-loading", ["sticky"] = ".sticky-root", ["timer"] = ".hp-timer", ["assets"] = ".assets-root" };
            var evidence = Path.GetDirectoryName(Path.GetFullPath(Environment.GetEnvironmentVariable("HOVERPOCKET_VERIFY_LOG")!))!;
            var count = 0;
            await web.ExecuteScriptAsync("window.__resizeRequest=(method,params)=>import('./js/bridge.js').then(m=>m.request(method,params));");
            foreach (var (name, width, height) in cases)
            {
                Drag(width, height);
                await Task.Delay(120, token);
                var expected = limits.Clamp(new(width, height));
                expected.Width = Math.Min(expected.Width, layout.Monitor.WorkArea.Width / layout.Monitor.ScaleX);
                expected.Height = Math.Min(expected.Height, layout.Monitor.WorkArea.Bottom / layout.Monitor.ScaleY - panel.Top);
                if (Math.Abs(panel.Width - expected.Width) > 1 || Math.Abs(panel.Height - expected.Height) > 1)
                    throw new InvalidOperationException($"{name}: native bound {panel.Width}x{panel.Height} differs from {expected}");
                foreach (var (id, selector) in providers)
                {
                    await web.ExecuteScriptAsync($"window.__resizeDone=false;window.__resizeRequest('provider.select',{{id:{JsonSerializer.Serialize(id)}}}).then(()=>window.__resizeDone=true)");
                    await Until(async () => await web.ExecuteScriptAsync($"window.__resizeDone && !!document.querySelector({JsonSerializer.Serialize(selector)})") == "true", token);
                    await Task.Delay(100, token);
                    if (id == "calendar") await web.ExecuteScriptAsync("document.querySelector('[data-schedule]').hidden=false;document.querySelector('[data-connection]').hidden=true");
                    foreach (var text in new[] { "medium", "extraLarge" })
                    {
                        await web.ExecuteScriptAsync($"document.documentElement.dataset.textSize='{text}'");
                        await Task.Delay(40, token);
                        var result = await web.ExecuteScriptAsync("(()=>{const p=document.querySelector('[data-provider-container]'),r=p.getBoundingClientRect();return p.scrollWidth<=p.clientWidth+1&&r.bottom<=innerHeight+1&&r.width>400&&r.height>200;})()");
                        if (result != "true") throw new InvalidOperationException($"{id}/{name}/{text}: provider overflows viewport");
                        if (id == "controls")
                        {
                            var sections = await web.ExecuteScriptAsync("Array.from(document.querySelectorAll('.hp-controls-section')).every(section=>Array.from(section.querySelectorAll('button,input')).every(control=>control.getBoundingClientRect().bottom<=section.getBoundingClientRect().bottom+1))");
                            if (sections != "true") throw new InvalidOperationException($"controls/{name}/{text}: an interactive control is clipped inside its card");
                        }
                        if (id == "calendar")
                        {
                            var geometry = await web.ExecuteScriptAsync("(()=>{const c=document.querySelector('.hp-calendar'),day=c.querySelector('.hp-calendar-day').getBoundingClientRect(),left=c.querySelector('[data-month-pane]').getBoundingClientRect(),right=c.querySelector('[data-detail]').getBoundingClientRect(),root=c.getBoundingClientRect(),month=c.querySelector('[data-month-pane]');return day.width>=24&&Math.abs(day.height/day.width-.875)<.02&&right.width>=180&&left.right<right.left&&right.right<=root.right+1&&month.scrollWidth<=month.clientWidth+1;})()");
                            if (geometry != "true") throw new InvalidOperationException($"calendar/{name}: day ratio or balanced columns failed");
                        }
                        count++;
                    }
                    if (id == "calendar" || id == "calculator" || id == "controls")
                    {
                        using var stream = File.Create(Path.Combine(evidence, $"{id}-{name}.png"));
                        await web.CapturePreviewAsync(CoreWebView2CapturePreviewImageFormat.Png, stream);
                    }
                }
                VerifyConsole.WriteLine($"PASS manual resize {name}: actual={panel.Width:0}x{panel.Height:0}, provider bounds and calendar proportions");
            }
            VerifyConsole.WriteLine($"PASS manual resize: cases={count}, seven providers, text medium/extraLarge, native minimum/maximum, intermediate and mixed dimensions");
            return 0;
        }
        catch (Exception ex) { VerifyConsole.WriteLine("FAIL manual resize: " + ex); return 1; }
    }
    private static async Task Until(Func<Task<bool>> predicate, CancellationToken token)
    {
        while (!await predicate()) await Task.Delay(30, token);
    }
}
