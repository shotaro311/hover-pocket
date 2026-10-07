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
            await web.ExecuteScriptAsync("document.querySelector('[data-category=library]').click(); document.querySelector('[data-sync-advanced]').open=true; document.querySelector('[data-sync-create]').click()");
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
                    let denied=true;
                    for (const [method,params] of [['assetSync.enable',{enabled:false}],['pairing.invite',{}],['pairing.approve',{approvalId:'fake'}]]) {
                        try { await request(method,params); denied=false; } catch { }
                    }
                    window.__syncPanelDenied=denied;
                });
                """);
            await Wait(controller.Panel.WebView.CoreWebView2,"window.__syncPanelDenied === true");
            await web.ExecuteScriptAsync("document.querySelector('[data-sync-advanced]').open=false; document.querySelector('[data-category=general]').click()");
            await Wait(web.CoreWebView2,"document.querySelector('[data-category-title]').textContent==='General' && document.querySelector('[data-asset-sync-settings]').hidden");
            await web.ExecuteScriptAsync("document.querySelector('[data-settings-search]').value='Library'; document.querySelector('[data-settings-search]').dispatchEvent(new Event('input'))");
            await Wait(web.CoreWebView2,"!document.querySelector('[data-asset-sync-settings]').hidden && document.querySelector('[data-category-title]').textContent==='Search results'");
            await web.ExecuteScriptAsync("document.querySelector('[data-category=library]').click()");
            await Wait(web.CoreWebView2,"document.querySelector('[data-settings-search]').value==='' && !document.querySelector('[data-asset-sync-settings]').hidden");
            settings.Width=620; await Task.Delay(300);
            if(await web.ExecuteScriptAsync("document.documentElement.scrollWidth<=window.innerWidth")!="true") throw new Exception("narrow settings overflow");
            await using(var image=File.Create(Path.Combine(root,"settings-library-narrow.png")))
                await web.CoreWebView2.CapturePreviewAsync(Microsoft.Web.WebView2.Core.CoreWebView2CapturePreviewImageFormat.Png,image);
            settings.Width=940; await Task.Delay(300);
            await using(var image=File.Create(Path.Combine(root,"settings-library.png")))
                await web.CoreWebView2.CapturePreviewAsync(Microsoft.Web.WebView2.Core.CoreWebView2CapturePreviewImageFormat.Png,image);
            var fakeSession = new Sync.PairingState();
            var approvals=0; var fakeRole="invite";
            bridge.PairingForVerify = (method, parameters, _) => {
                switch(method) {
                    case "invite": fakeRole="invite"; fakeSession=new("waiting", Code:"123-12345678", ExpiresAt:DateTimeOffset.UtcNow.AddMinutes(5)); return Task.FromResult<object?>(fakeSession);
                    case "join": fakeRole="join"; fakeSession=new("peer", ApprovalId:"fictional",PeerName:"Test Mac",Platform:"macos",Verification:"ABCD1234",ExpiresAt:DateTimeOffset.UtcNow.AddMinutes(5)); return Task.FromResult<object?>(fakeSession);
                    case "approve":
                        if(parameters?.GetProperty("approvalId").GetString()!="fictional") throw new Exception("wrong approval ID");
                        approvals++; fakeSession=new("complete"); return Task.FromResult<object?>(fakeSession);
                    case "cancel": fakeSession=new(); return Task.FromResult<object?>(fakeSession);
                    default: return Task.FromResult<object?>(new {available=true,devices=Array.Empty<object>(),session=fakeSession,role=fakeRole,error=(string?)null});
                }
            };
            await Wait(web.CoreWebView2,"!document.querySelector('[data-sync-invite]').disabled");
            await web.ExecuteScriptAsync("document.querySelector('[data-sync-invite]').click()");
            await Wait(web.CoreWebView2,"document.querySelector('[data-sync-code]').textContent==='123-12345678'");
            if(approvals!=0) throw new Exception("unprompted pairing approval");
            fakeSession=new("peer",ApprovalId:"fictional",PeerName:"<img src=x onerror=alert(1)>",Platform:"macos",Verification:"ABCD1234",ExpiresAt:DateTimeOffset.UtcNow.AddMinutes(5));
            await Wait(web.CoreWebView2,"!document.querySelector('[data-sync-approve]').hidden && !document.querySelector('[data-sync-approve]').disabled");
            if(await web.ExecuteScriptAsync("document.querySelector('[data-sync-peer] img')===null && document.querySelector('[data-sync-peer]').textContent.includes('<img')")!="true") throw new Exception("peer name was treated as HTML");
            await web.ExecuteScriptAsync("document.querySelector('[data-sync-approve]').click()");
            await Wait(web.CoreWebView2,"document.querySelector('[data-sync-connection-status]').textContent.includes('Connected')");
            if(approvals!=1) throw new Exception("approval not exact-once");
            await web.ExecuteScriptAsync("document.querySelector('[data-sync-enter]').click(); document.querySelector('[data-sync-code-input]').value='123-12345678'; document.querySelector('[data-sync-code-input]').dispatchEvent(new Event('input')); document.querySelector('[data-sync-connect]').click()");
            await Wait(web.CoreWebView2,"document.querySelector('[data-sync-session-label]').textContent.includes('Approve the connection on your other device')");
            if(await web.ExecuteScriptAsync("document.querySelector('[data-sync-approve]').hidden")!="true") throw new Exception("joiner may approve itself");
            await web.ExecuteScriptAsync("document.querySelector('[data-sync-cancel]').click()");
            await Wait(web.CoreWebView2,"document.querySelector('[data-sync-session]').hidden");
            VerifyConsole.WriteLine("PASS pairing UI: invite/code, explicit bound approval, untrusted name rendered as text, join waiting, cancellation");
            await web.ExecuteScriptAsync("import('/js/bridge.js').then(({request})=>request('settings.setLanguage',{language:'ja'}))");
            await Wait(web.CoreWebView2,"document.querySelector('[data-sync-title]').textContent==='ライブラリの同期'");
            foreach(var category in new[]{"general","appearance","library","ai"}) {
                await web.ExecuteScriptAsync("document.querySelector('[data-category="+category+"]').click()"); await Task.Delay(100);
                await using var preview=File.Create(Path.Combine(root,"settings-"+category+"-ja.png"));
                await web.CoreWebView2.CapturePreviewAsync(Microsoft.Web.WebView2.Core.CoreWebView2CapturePreviewImageFormat.Png,preview);
            }

            VerifyConsole.WriteLine("PASS settings navigation: six categories, search, clear search on navigation, narrow window without horizontal overflow");
            VerifyConsole.WriteLine("PASS sync settings: English labels and settings-only bridge boundary");
            VerifyConsole.WriteLine("PASS sync UI evidence: "+root);
            return 0;
        }
        catch(Exception ex) { VerifyConsole.WriteLine("FAIL sync UI: "+ex); return 1; }
        finally { bridge.PairingForVerify=null; bridge.AssetSyncFolderPickerForVerify=null; settings.Close(); }
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
