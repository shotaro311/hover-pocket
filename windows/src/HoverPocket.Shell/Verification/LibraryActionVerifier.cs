using System.Text.Json;
using System.Windows.Threading;
using HoverPocket.Assets;
using HoverPocket.Shell.Capabilities;
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
            VerifyConsole.WriteLine("library_actions_verification=ok evidence=" + root);
            return 0;
        }
        catch (Exception error) { VerifyConsole.WriteLine("FAIL " + error); return 1; }
    }
    private sealed class UnavailableTools : ICodexVoiceDynamicToolRuntime
    {
        public JsonElement Definitions => JsonSerializer.SerializeToElement(Array.Empty<object>());
        public Task<CodexVoiceDynamicToolResponse> ExecuteAsync(JsonElement? p, string thread, CancellationToken token) => Task.FromResult(new CodexVoiceDynamicToolResponse(false, "unavailable"));
    }
}
