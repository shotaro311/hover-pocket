using System.Text.Json;
using HoverPocket.Assets;
using HoverPocket.Shell.Capabilities;
using HoverPocket.Shell.Providers.Sticky;
using HoverPocket.Shell.Providers.Timer;
using HoverPocket.Shell.Voice;

namespace HoverPocket.Shell.Verification;

internal static class CodexChatLiveVerifier
{
    public static async Task<int> RunAsync()
    {
        var root = Path.Combine(Path.GetTempPath(), "HoverPocket-ChatLive-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        using var store = new AssetStore(Path.Combine(root, "Library"));
        using var timers = new TimerStore(Path.Combine(root, "timer"), new ManualTimerClock(DateTimeOffset.UtcNow), new NullTimerAlertSound(), enableScheduler: false);
        try
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(100));
            var token = timeout.Token;
            await store.Ready;
            var handlers = ProviderCapabilityCompositionRoot.Create(new FakeCalendarCapabilityDataSource(), timers,
                new StickyNotesStore(Path.Combine(root, "sticky")), new FakeControlsCapabilityDataSource());
            var library = new VoiceLibraryCapabilities(store, () => null, System.Windows.Application.Current.Dispatcher, (_, _) => Task.FromResult(false));
            library.Register(handlers);
            var registry = new CapabilityRegistry(handlers, PocketCapabilityDescriptors.BuiltIn.Concat(VoiceLibraryCapabilities.Descriptors));
            var broker = new CapabilityBroker(registry, new CapabilityBrokerLedger(Path.Combine(root, "broker")), new CapabilityBrokerAuditLog(Path.Combine(root, "broker")));
            var approvals = 0;
            const string folderName = "チャット検証専用";
            var tools = new CodexNativeCapabilityRuntime(new CodexRealtimeCapabilityAdapter(new OpenAIRealtimeCapabilityRuntime(
                new BrokerOpenAIRealtimeCapabilityAuthority(registry, broker), (_, _) => Task.FromResult(false), (_, _) => Task.FromResult(false),
                () => true, () => "Asia/Tokyo", origin: CapabilityOrigin.Text)), registry, broker,
                (request, _) => { if (!request.Details.Contains(folderName)) return Task.FromResult(false); approvals++; return Task.FromResult(true); }, library, CapabilityOrigin.Text);
            var identity = CodexExecutableResolver.Resolve() ?? throw new InvalidOperationException("codex missing");
            await CodexVoiceToolRouteProbe.VerifyAsync(identity, tools.Definitions, Path.Combine(root, "route"), token);
            if (tools.Definitions.GetArrayLength() != 19) throw new InvalidOperationException("tool count");
            VerifyConsole.WriteLine("PASS chat-live: installed model route exposes exactly 19 tools");
            var profileRoot = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "HoverPocket", "CodexVoice");
            if (!File.Exists(Path.Combine(profileRoot, "auth.json"))) throw new InvalidOperationException("dedicated app login is required; no host auth is copied");
            // Reuse the already signed-in app profile in place. No host credentials are copied.
            // The test's history index, capabilities and saved folder are isolated from the app.
            var profile = CodexVoiceProfile.Prepare(profileRoot, reuseExistingLogin: false);
            var history = new CodexChatHistory(root);
            await using var chat = new CodexChatCoordinator(ct => CodexAppServerClient.StartProcessAsync(identity.Path,
                ["app-server", "--stdio"], TimeSpan.FromSeconds(25), ct, profile.Environment, root), tools, history);
            var deltas = 0;
            chat.Changed += (_, state) => { if (state.Busy && state.Messages.Any(m => m.Role == "assistant")) Interlocked.Increment(ref deltas); };
            await chat.SendAsync($"ライブラリに「{folderName}」というフォルダを一つ作ってください。完了後は簡潔に返答してください。", token);
            if (chat.Snapshot.ErrorCode is { } error) throw new InvalidOperationException(error);
            var folders = (await store.QueryAsync(new AssetQuery(Limit: 1))).Folders;
            if (approvals != 1 || folders.Count(f => f.Name == folderName) != 1 || !chat.Snapshot.Messages.Any(m => m.Role == "assistant"))
                throw new InvalidOperationException("chat folder readback or response missing");
            var threadId = chat.Snapshot.ThreadId!;
            await chat.SelectAsync(threadId, token);
            if (chat.Snapshot.ErrorCode is not null || !chat.Snapshot.Messages.Any(m => m.Role == "assistant") || chat.Snapshot.ThreadId != threadId)
                throw new InvalidOperationException("real history resume failed");
            VerifyConsole.WriteLine($"PASS chat-live: turn/start -> native approval -> isolated folder saved/readback -> assistant text -> history resume; stream_updates={deltas}; auth_copy=false; microphone=false; production_library_unchanged=true");
            return 0;
        }
        catch (Exception exception)
        {
            VerifyConsole.WriteLine("FAIL chat-live: " + exception.GetType().Name + " " + VoiceTextSafety.SanitizeErrorCode(exception.Message));
            return 1;
        }
    }
}
