using System.Text.Json;
using System.Runtime.InteropServices;
using Point = System.Windows.Point;
using System.Windows.Threading;
using HoverPocket.Assets;
using HoverPocket.Shell.Capabilities;
using HoverPocket.Shell.Configuration;
using HoverPocket.Shell.Providers.Sticky;
using HoverPocket.Shell.Providers.Timer;
using HoverPocket.Shell.Voice;
using HoverPocket.Shell.Windows;

namespace HoverPocket.Shell.Verification;

internal static class LibraryActionVerifier
{
    public static async Task<int> RunAsync(HoverShellController controller)
    {
        var root = Path.Combine(Path.GetTempPath(), "HoverPocket-LibraryActions-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        using var store = new AssetStore(Path.Combine(root, "library"));
        await store.Ready;
        using var timers = new TimerStore(Path.Combine(root, "timer"), new ManualTimerClock(DateTimeOffset.UtcNow), new NullTimerAlertSound(), enableScheduler: false);
        var handlers = ProviderCapabilityCompositionRoot.Create(new FakeCalendarCapabilityDataSource(), timers, new StickyNotesStore(Path.Combine(root, "sticky")), new FakeControlsCapabilityDataSource());
        var library = new VoiceLibraryCapabilities(store, () => null, Dispatcher.CurrentDispatcher, (_, _) => Task.FromResult(true));
        library.Register(handlers);
        var registry = new CapabilityRegistry(handlers, PocketCapabilityDescriptors.BuiltIn.Concat(VoiceLibraryCapabilities.Descriptors));
        var broker = new CapabilityBroker(registry, new CapabilityBrokerLedger(Path.Combine(root, "broker")), new CapabilityBrokerAuditLog(Path.Combine(root, "broker")));
        var allow = false;
        Func<Task>? beforeApproval = null;
        var runtime = new CodexNativeCapabilityRuntime(new UnavailableTools(), registry, broker, async (_, _) => { if (beforeApproval is not null) await beforeApproval(); return allow; }, library);
        Task<CodexVoiceDynamicToolResponse> Call(string id, string tool, object args) => runtime.ExecuteAsync(JsonSerializer.SerializeToElement(new { threadId = "actions", callId = id, tool, arguments = args }), "actions", CancellationToken.None);
        void Check(bool value, string name) { if (!value) throw new InvalidOperationException(name); VerifyConsole.WriteLine("PASS " + name); }
        try
        {
            var settingsStore = new UserSettingsStore(Path.Combine(root, "settings"));
            var savedSettings = settingsStore.Load(["assets"]);
            Check(!savedSettings.CodexAllowAllAppActions, "automatic app actions default off");
            savedSettings.CodexAllowAllAppActions = true; savedSettings.ChatSplitRatio = .42;
            settingsStore.Save(savedSettings);
            var restoredSettings = settingsStore.Load(["assets"]);
            Check(restoredSettings.CodexAllowAllAppActions && restoredSettings.ChatSplitRatio == .42, "permission and boundary restore after restart");
            var file = Path.Combine(root, "keep.txt"); File.WriteAllText(file, "original to retain");
            var id = (await store.ImportAsync(file)).AssetId!;
            await store.UpdateAsync([id], "favoriteSet", "true");
            var original = store.ReadOriginalPath((await store.GetAsync(id))!);
            var bytes = File.ReadAllBytes(original);
            Check(!(await Call("denied", "library_trash_all", new { })).Success && !(await store.GetAsync(id))!.Trashed, "denied bulk trash writes nothing");
            allow = true;
            Check((await Call("trash", "library_asset_trash", new { assetId = id })).Success && (await store.GetAsync(id))!.Trashed, "single trash has verified readback");
            Check((await Call("search", "library_search", new { trash = true })).Success, "AI can search library trash");
            Check((await Call("restore", "library_asset_restore", new { assetId = id })).Success && (await store.GetAsync(id))!.Favorite, "restore retains favorite metadata");
            Check(!(await Call("inject", "library_trash_all", new { selectionToken = "injected" })).Success, "model cannot inject host selection token");
            var late = Path.Combine(root, "later.txt"); File.WriteAllText(late, "arrived after preparation");
            string? lateId = null;
            beforeApproval = async () => { lateId = (await store.ImportAsync(late)).AssetId!; };
            var snapshot = await Call("snapshot", "library_trash_all", new { }); beforeApproval = null;
            Check(snapshot.Success && !(await store.GetAsync(lateId!))!.Trashed, "bulk trash only affects prepared targets");
            Check(File.ReadAllBytes(original).SequenceEqual(bytes), "original bytes retained after trash and restore");
            var all = await Call("all-once", "library_trash_all", new { });
            Check(all.Success && (await store.QueryAsync(new())).Total == 0, "bulk trash includes remaining assets");
            Check((await Call("all-once", "library_trash_all", new { })).Text == all.Text, "bulk replay does not repeat writes");
            var web = controller.Panel.WebView!;
            await web.ExecuteScriptAsync("window.__splitBefore=document.querySelector('.hp-chat-lane').getBoundingClientRect().height;document.querySelector('.hp-chat-splitter').dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowUp',bubbles:true}));");
            await Task.Delay(200);
            var ui = await web.ExecuteScriptAsync("JSON.stringify({removed:!document.querySelector('[data-size-switch]'),split:document.querySelector('.hp-chat-lane').getBoundingClientRect().height>window.__splitBefore,settings:!!document.querySelector('.hp-chat-splitter')})");
            using var json = JsonDocument.Parse(JsonSerializer.Deserialize<string>(ui)!);
            Check(json.RootElement.GetProperty("removed").GetBoolean(), "obsolete size buttons removed");
            Check(json.RootElement.GetProperty("split").GetBoolean(), "chat boundary keyboard adjustment changes actual layout");
            var nativeBefore = JsonSerializer.Deserialize<double>(await web.ExecuteScriptAsync("document.querySelector('.hp-chat-lane').getBoundingClientRect().height"));
            using var bounds = JsonDocument.Parse(JsonSerializer.Deserialize<string>(await web.ExecuteScriptAsync("JSON.stringify(document.querySelector('.hp-chat-splitter').getBoundingClientRect().toJSON())"))!);
            var b = bounds.RootElement;
            var ratio = controller.Panel.WebView!.ActualWidth / JsonSerializer.Deserialize<double>(await web.ExecuteScriptAsync("innerWidth"));
            var position = controller.Panel.WebView.PointToScreen(new Point((b.GetProperty("x").GetDouble() + b.GetProperty("width").GetDouble()/2)*ratio, (b.GetProperty("y").GetDouble()+4)*ratio));
            GetCursorPos(out var previous);
            try
            {
                SetCursorPos((int)position.X, (int)position.Y); await Task.Delay(100);
                MouseEvent(2, 0, 0, 0, 0); await Task.Delay(100);
                for (var step = 1; step <= 6; step++) { SetCursorPos((int)position.X, (int)(position.Y-step*6*ratio)); await Task.Delay(50); }
                MouseEvent(4, 0, 0, 0, 0); await Task.Delay(250);
                Check(JsonSerializer.Deserialize<double>(await web.ExecuteScriptAsync("document.querySelector('.hp-chat-lane').getBoundingClientRect().height")) > nativeBefore + 20, "native boundary drag adjusts chat height");
            }
            finally { MouseEvent(4, 0, 0, 0, 0); SetCursorPos(previous.X, previous.Y); }
            await web.ExecuteScriptAsync("window.__actionsAssets=false;import('./js/bridge.js').then(m=>m.request('provider.select',{id:'assets'})).then(()=>window.__actionsAssets=true)");
            for (var attempt=0; attempt<100 && await web.ExecuteScriptAsync("window.__actionsAssets && !!document.querySelector('.assets-toolbar')")!="true"; attempt++) await Task.Delay(30);
            VerifyConsole.WriteLine("MEASURE toolbar " + await web.ExecuteScriptAsync("(()=>{const t=document.querySelector('.assets-toolbar'),s=document.querySelector('.assets-search-field');return {ready:window.__actionsAssets,toolbar:t?.getBoundingClientRect().toJSON(),wrap:t&&getComputedStyle(t).flexWrap,search:s?.getBoundingClientRect().toJSON(),controls:t&&Array.from(t.querySelectorAll('button,input,select')).map(e=>({class:e.className,rect:e.getBoundingClientRect().toJSON()}))};})()"));
            Check(await web.ExecuteScriptAsync("(()=>{const t=document.querySelector('.assets-toolbar'),s=document.querySelector('.assets-search-field');return t&&getComputedStyle(t).flexWrap==='nowrap'&&s.getBoundingClientRect().width<=201&&Array.from(t.querySelectorAll('button,input,select')).filter(e=>e.getBoundingClientRect().width>0).every(e=>Math.abs(e.getBoundingClientRect().y+e.getBoundingClientRect().height/2-t.querySelector('button').getBoundingClientRect().y-t.querySelector('button').getBoundingClientRect().height/2)<4);})()") == "true", "library controls occupy one row with compact search");
            await web.ExecuteScriptAsync("document.querySelector('.assets-root').style.width='480px'"); await Task.Delay(100);
            Check(await web.ExecuteScriptAsync("(()=>{const t=document.querySelector('.assets-toolbar');return t.scrollWidth>t.clientWidth&&getComputedStyle(t).overflowX==='auto'&&t.clientHeight<70;})()") == "true", "small library toolbar scrolls horizontally without wrapping");
            await web.ExecuteScriptAsync("document.querySelector('.assets-root').style.width=''");
            VerifyConsole.WriteLine("library_actions_verification=ok evidence=" + root);
            return 0;
        }
        catch (Exception error) { VerifyConsole.WriteLine("FAIL " + error); return 1; }
    }
    [StructLayout(LayoutKind.Sequential)] private struct NativePoint { public int X, Y; }
    [DllImport("user32.dll")] private static extern bool GetCursorPos(out NativePoint point);
    [DllImport("user32.dll")] private static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll", EntryPoint = "mouse_event")] private static extern void MouseEvent(uint flags, uint x, uint y, uint data, nuint extra);
    private sealed class UnavailableTools : ICodexVoiceDynamicToolRuntime
    {
        public JsonElement Definitions => JsonSerializer.SerializeToElement(Array.Empty<object>());
        public Task<CodexVoiceDynamicToolResponse> ExecuteAsync(JsonElement? p, string thread, CancellationToken token) => Task.FromResult(new CodexVoiceDynamicToolResponse(false, "unavailable"));
    }
}
