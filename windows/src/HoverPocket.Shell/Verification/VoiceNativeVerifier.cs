using System.Text.Json;
using HoverPocket.Shell.Capabilities;
using HoverPocket.Shell.Providers.Sticky;
using HoverPocket.Shell.Providers.Timer;
using HoverPocket.Shell.Voice;

namespace HoverPocket.Shell.Verification;

internal static class VoiceNativeVerifier
{
    public static int Run()
    {
        try { Task.Run(VerifyAsync).GetAwaiter().GetResult(); VerifyConsole.WriteLine("PASS voice-native: calculator, note approval/denial/deduplication, volume readback, invalid inputs, root isolation, shared Calendar/Timer adapter"); return 0; }
        catch (Exception exception) { VerifyConsole.WriteLine("FAIL voice-native: " + exception.Message); return 1; }
    }

    private static async Task VerifyAsync()
    {
        var root = Path.Combine(Path.GetTempPath(), "HoverPocket-VoiceNative-" + Guid.NewGuid().ToString("N"));
        var sticky = new StickyNotesStore(Path.Combine(root, "sticky"));
        using var timers = new TimerStore(Path.Combine(root, "timer"), new ManualTimerClock(DateTimeOffset.UtcNow), new NullTimerAlertSound(), enableScheduler: false);
        var controls = new FakeControlsCapabilityDataSource();
        var registry = new CapabilityRegistry(ProviderCapabilityCompositionRoot.Create(new FakeCalendarCapabilityDataSource(), timers, sticky, controls));
        var broker = new CapabilityBroker(registry, new CapabilityBrokerLedger(Path.Combine(root, "broker")), new CapabilityBrokerAuditLog(Path.Combine(root, "broker")));
        var approved = false;
        var approvals = 0;
        var native = new CodexNativeCapabilityRuntime(new CodexRealtimeCapabilityAdapter(new OpenAIRealtimeCapabilityRuntime(
            new BrokerOpenAIRealtimeCapabilityAuthority(registry, broker), (_, _) => Task.FromResult(true), (_, _) => Task.FromResult(true), () => true, () => "Asia/Tokyo")),
            registry, broker, (_, _) => { approvals++; return Task.FromResult(approved); });
        Require(native.Definitions.GetArrayLength() == 8, "tool definitions");
        Task<CodexVoiceDynamicToolResponse> Call(string id, string tool, object args, string thread = "voice-native") => native.ExecuteAsync(
            JsonSerializer.SerializeToElement(new { threadId = thread, turnId = "turn-1", callId = id, tool, arguments = args }), "voice-native", CancellationToken.None);
        var calc = await Call("calc", "calculator_evaluate", new { expression = "6*7" });
        Require(calc.Success && calc.Text.Contains("42") && approvals == 0, "calculator result");
        var denied = await Call("denied", "sticky_note_create", new { body = "verifier note" });
        Require(!denied.Success && sticky.Notes.Count == 0 && approvals == 1, "denied note unchanged");
        approved = true;
        var note = await Call("note", "sticky_note_create", new { title = "確認", body = "保存確認", color = "blue" });
        var repeated = await Call("note", "sticky_note_create", new { title = "確認", body = "保存確認", color = "blue" });
        Require(note.Success && repeated == note && sticky.Notes.Count == 1 && approvals == 2, "note readback and duplicate");
        Require(!(await Call("note", "sticky_note_create", new { body = "different" })).Success && sticky.Notes.Count == 1, "changed arguments rejected");
        Require(!(await Call("wrong-root", "sticky_note_create", new { body = "never saved" }, "other-root")).Success, "foreign root rejected");
        var volume = await Call("volume", "controls_volume_set", new { level = 0.45 });
        Require(volume.Success && volume.Text.Contains("verified"), "volume readback");
        controls.MismatchNextVolume = true;
        Require(!(await Call("volume-mismatch", "controls_volume_set", new { level = 0.5 })).Success, "OS mismatch not success");
        Require(!(await Call("volume-invalid", "controls_volume_set", new { level = 5.0 })).Success, "volume range");
        Require(!(await Call("unknown", "shell", new { command = "ignored" })).Success, "unknown tool rejected");
        var timer = await Call("timer", "timer_countdown_start", new { durationSeconds = 60, title = "verify" });
        Require(timer.Success && timer.Text.Contains("verified"), "Codex uses shared timer approval and readback");
        var textAudit = new CapabilityBrokerAuditLog(Path.Combine(root, "text-broker"));
        var textBroker = new CapabilityBroker(registry, new CapabilityBrokerLedger(Path.Combine(root, "text-broker")), textAudit);
        var textNative = new CodexNativeCapabilityRuntime(new CodexRealtimeCapabilityAdapter(new OpenAIRealtimeCapabilityRuntime(
            new BrokerOpenAIRealtimeCapabilityAuthority(registry, textBroker), (_, _) => Task.FromResult(true), (_, _) => Task.FromResult(true),
            () => true, () => "Asia/Tokyo", origin: CapabilityOrigin.Text)), registry, textBroker, (_, _) => Task.FromResult(true), origin: CapabilityOrigin.Text);
        foreach (var name in new[] { "calculator_evaluate", "timer_countdown_start" })
        {
            var args = name == "calculator_evaluate" ? JsonSerializer.SerializeToElement(new { expression = "6*7" })
                : JsonSerializer.SerializeToElement(new { durationSeconds = 90, title = "typed chat" });
            Require((await textNative.ExecuteAsync(JsonSerializer.SerializeToElement(new { threadId = "chat-text", turnId = "turn-1", callId = name, tool = name, arguments = args }), "chat-text", CancellationToken.None)).Success, "typed capability");
        }
        var audit = System.Text.Encoding.UTF8.GetString(textAudit.CombinedData());
        Require(audit.Contains("\"origin\":\"text\"") && !audit.Contains("\"origin\":\"voice\""), "typed tools retain text origin in the shared broker");
        using var request = JsonDocument.Parse("""{"tools":[{"type":"function","name":"unexpected","parameters":{}}]}""");
        Require(!CodexVoiceToolRouteProbe.MatchesTools(request.RootElement, native.Definitions), "extra tool gate");
    }

    private static void Require(bool valid, string name) { if (!valid) throw new InvalidOperationException(name); }
}
