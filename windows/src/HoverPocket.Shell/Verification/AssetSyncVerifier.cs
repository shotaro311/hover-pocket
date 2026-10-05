using HoverPocket.Assets;
using HoverPocket.Shell.Settings;
using HoverPocket.Shell.Windows;
using Microsoft.Web.WebView2.Wpf;

namespace HoverPocket.Shell.Verification;

internal static class AssetSyncVerifier
{
    internal static async Task<int> RunAsync(HoverShellController controller)
    {
        var bridge=controller.PanelBridgeController;
        var store=bridge.AssetLibrary;
        var root=Path.Combine(Path.GetTempPath(),"HoverPocketSyncVerify-ui-"+Guid.NewGuid().ToString("N"));
        var transport=Path.Combine(root,"transport");
        var settings=new SettingsWindow(bridge,false,Path.Combine(root,"webview"),externalIntegrationsEnabled:false);
        try
        {
            bridge.AssetSyncFolderPickerForVerify=_=>transport;
            settings.Show();
            for(var i=0;i<200 && settings.WebViewForVerify?.CoreWebView2 is null;i++) await Task.Delay(50);
            var web=settings.WebViewForVerify ?? throw new Exception("settings unavailable");
            await Wait(web.CoreWebView2,"document.querySelector('[data-sync-create]') && !document.querySelector('[data-sync-create]').disabled");
            await web.ExecuteScriptAsync("document.querySelector('[data-asset-sync-settings]').scrollIntoView(); document.querySelector('[data-sync-create]').click()");
            await Wait(web.CoreWebView2,"document.querySelector('[data-sync-enabled]').checked && !document.querySelector('[data-sync-enabled]').disabled");
            if(!(await store.GetSyncStatusAsync()).Enabled) throw new Exception("create/enable bridge failed");
            await web.ExecuteScriptAsync("document.querySelector('[data-sync-enabled]').click()");
            await Wait(web.CoreWebView2,"document.querySelector('[data-sync-status]').textContent.includes('一時停止')");
            if((await store.GetSyncStatusAsync()).Enabled) throw new Exception("pause bridge failed");
            await web.ExecuteScriptAsync("document.querySelector('[data-sync-enabled]').click()");
            await Wait(web.CoreWebView2,"document.querySelector('[data-sync-enabled]').checked && !document.querySelector('[data-sync-enabled]').disabled");
            VerifyConsole.WriteLine("PASS sync settings: default-off, selected folder/create, persisted enable/pause/resume");

            Directory.CreateDirectory(root); var source=Path.Combine(root,"generated.txt");
            await File.WriteAllTextAsync(source,"Generated sync settings check");
            var id=(await store.ImportAsync(source)).AssetId!; await store.SyncOnceAsync();
            using var peer=new AssetStore(Path.Combine(root,"peer")); await peer.ConfigureSyncAsync(transport); await peer.SyncOnceAsync();
            await store.UpdateAsync([id],"rename","この端末の名前"); await peer.UpdateAsync([id],"rename","受信した名前");
            await store.SyncOnceAsync(); await peer.SyncOnceAsync(); await store.SyncOnceAsync();
            await Wait(web.CoreWebView2,"document.querySelectorAll('[data-sync-conflicts] button').length === 2 && !document.querySelector('[data-sync-conflicts] button').disabled");
            await web.ExecuteScriptAsync("document.querySelectorAll('[data-sync-conflicts] button')[1].click()");
            await Wait(web.CoreWebView2,"document.querySelectorAll('[data-sync-conflicts] button').length === 0");
            if((await store.GetAsync(id))!.Name!="受信した名前" || (await store.GetSyncStatusAsync()).Conflicts.Length!=0) throw new Exception("remote resolution failed");
            await peer.SyncOnceAsync();
            VerifyConsole.WriteLine("PASS sync settings: conflicting versions visible, received-version button resolves and converges");
            await web.ExecuteScriptAsync("""
                window.__syncEnglish=false;
                import('/js/bridge.js').then(async ({request}) => {
                    await request('settings.setLanguage',{language:'en'});
                    window.__syncEnglish=true;
                });
                """);
            await Wait(web.CoreWebView2,"window.__syncEnglish === true && document.querySelector('[data-sync-title]').textContent === 'Library sync'");
            await web.ExecuteScriptAsync("document.querySelector('[data-asset-sync-settings]').scrollIntoView()");
            await using(var image=File.Create(Path.Combine(root,"settings-sync.png")))
                await web.CoreWebView2.CapturePreviewAsync(Microsoft.Web.WebView2.Core.CoreWebView2CapturePreviewImageFormat.Png,image);
            await controller.Panel.WebView!.ExecuteScriptAsync("""
                window.__syncPanelDenied=null;
                import('/js/bridge.js').then(async ({request}) => {
                    try { await request('assetSync.enable',{enabled:false}); window.__syncPanelDenied=false; }
                    catch { window.__syncPanelDenied=true; }
                });
                """);
            await Wait(controller.Panel.WebView.CoreWebView2,"window.__syncPanelDenied === true");
            VerifyConsole.WriteLine("PASS sync settings: English labels and settings-only bridge boundary");
            VerifyConsole.WriteLine("PASS sync UI evidence: "+root);
            return 0;
        }
        catch(Exception ex) { VerifyConsole.WriteLine("FAIL sync UI: "+ex); return 1; }
        finally { bridge.AssetSyncFolderPickerForVerify=null; settings.Close(); }
    }
    private static async Task Wait(Microsoft.Web.WebView2.Core.CoreWebView2 web,string expression)
    {
        for(int i=0;i<240;i++)
        {
            if(await web.ExecuteScriptAsync(expression)=="true") return;
            await Task.Delay(50);
        }
        throw new TimeoutException(expression);
    }
}
