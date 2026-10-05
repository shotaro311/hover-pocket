using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using HoverPocket.Shell.Capabilities;

namespace HoverPocket.Shell.Voice;

internal sealed record VoiceNativeApproval(string Title, string Details);

internal sealed class CodexNativeCapabilityRuntime(
    ICodexVoiceDynamicToolRuntime conversationTools,
    CapabilityRegistry registry,
    CapabilityBroker broker,
    Func<VoiceNativeApproval, CancellationToken, Task<bool>> approve,
    VoiceLibraryCapabilities? library = null,
    CapabilityOrigin origin = CapabilityOrigin.Voice) : ICodexVoiceDynamicToolRuntime
{
    private readonly object _sync = new();
    private readonly Dictionary<string, (string Digest, Lazy<Task<CodexVoiceDynamicToolResponse>> Result)> _calls = [];
    private static readonly IReadOnlyDictionary<string, PocketCapabilityKey> NativeTools = new Dictionary<string, PocketCapabilityKey>
    {
        ["calculator_evaluate"] = CapabilityIds.CalculatorEvaluate,
        ["sticky_note_create"] = CapabilityIds.StickyUpsert,
        ["controls_volume_get"] = CapabilityIds.ControlsVolumeGet,
        ["controls_volume_set"] = CapabilityIds.ControlsVolumeSet,
        ["controls_mute_set"] = CapabilityIds.ControlsMuteSet
    };

    public JsonElement Definitions
    {
        get
        {
            foreach (var key in NativeTools.Values) _ = registry.Resolve(key);
            using var extra = JsonDocument.Parse("""
                [
                  {"type":"function","name":"calculator_evaluate","description":"Calculate a mathematical expression using HoverPocket's calculator.","inputSchema":{"type":"object","properties":{"expression":{"type":"string","minLength":1,"maxLength":256}},"required":["expression"],"additionalProperties":false}},
                  {"type":"function","name":"sticky_note_create","description":"Create a new sticky note after the user confirms its exact text. Never edits an existing note.","inputSchema":{"type":"object","properties":{"title":{"type":"string","maxLength":120},"body":{"type":"string","minLength":1,"maxLength":10000},"color":{"type":"string","enum":["yellow","blue","green","pink","gray"]}},"required":["body"],"additionalProperties":false}},
                  {"type":"function","name":"controls_volume_get","description":"Read the current PC volume and mute state. Volume level is a fraction between 0 and 1.","inputSchema":{"type":"object","properties":{},"additionalProperties":false}},
                  {"type":"function","name":"controls_volume_set","description":"Set the PC volume after user confirmation. Use level 0.5 for 50 percent. For relative changes, first read the current volume.","inputSchema":{"type":"object","properties":{"level":{"type":"number","minimum":0,"maximum":1}},"required":["level"],"additionalProperties":false}},
                  {"type":"function","name":"controls_mute_set","description":"Mute or unmute PC audio after user confirmation. This is separate from the conversation microphone.","inputSchema":{"type":"object","properties":{"muted":{"type":"boolean"}},"required":["muted"],"additionalProperties":false}}
                ]
                """);
            var native = extra.RootElement.EnumerateArray().Select(tool => JsonSerializer.SerializeToElement(new {
                type = "function", name = tool.GetProperty("name").GetString(), description = tool.GetProperty("description").GetString(),
                inputSchema = CodexRealtimeCapabilityAdapter.ModelSchema(tool.GetProperty("inputSchema"))
            }));
            return JsonSerializer.SerializeToElement(conversationTools.Definitions.EnumerateArray().Concat(native)
                .Concat(library is null ? [] : VoiceLibraryCapabilities.Definitions.EnumerateArray()).ToArray());
        }
    }

    public async Task<CodexVoiceDynamicToolResponse> ExecuteAsync(JsonElement? parameters, string expectedThreadId, CancellationToken cancellationToken)
    {
        if (parameters is not { ValueKind: JsonValueKind.Object } value
            || !value.TryGetProperty("threadId", out var thread) || thread.ValueKind != JsonValueKind.String || thread.GetString() != expectedThreadId
            || !value.TryGetProperty("callId", out var call) || call.ValueKind != JsonValueKind.String || string.IsNullOrWhiteSpace(call.GetString()) || call.GetString()!.Length > 160
            || !value.TryGetProperty("tool", out var tool) || tool.ValueKind != JsonValueKind.String
            || !value.TryGetProperty("arguments", out var args) || args.ValueKind != JsonValueKind.Object
            || (value.TryGetProperty("namespace", out var ns) && ns.ValueKind != JsonValueKind.Null)) return Failure("invalid_request");
        if (Encoding.UTF8.GetByteCount(args.GetRawText()) > 16384) return Failure("invalid_arguments");
        var correlation = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(expectedThreadId + ":" + call.GetString())))[..32].ToLowerInvariant();
        var digest = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(tool.GetString() + ":" + args.GetRawText())));
        Lazy<Task<CodexVoiceDynamicToolResponse>> execution;
        lock (_sync)
        {
            if (_calls.TryGetValue(correlation, out var prior))
            {
                if (prior.Digest != digest) return Failure("idempotency_conflict");
                execution = prior.Result;
            }
            else
            {
                if (_calls.Count >= 512) return Failure("overloaded");
                execution = new(() => (NativeTools.TryGetValue(tool.GetString()!, out var key)
                    || (library is not null && VoiceLibraryCapabilities.Tools.TryGetValue(tool.GetString()!, out key)))
                    ? ExecuteNativeAsync(key, args, correlation, expectedThreadId, cancellationToken)
                    : conversationTools.ExecuteAsync(value, expectedThreadId, cancellationToken));
                _calls.Add(correlation, (digest, execution));
            }
        }
        return await execution.Value;
    }

    private async Task<CodexVoiceDynamicToolResponse> ExecuteNativeAsync(PocketCapabilityKey key, JsonElement arguments,
        string correlation, string sessionId, CancellationToken cancellationToken)
    {
        CapabilityApprovalRequest? approval = null;
        string? planDigest = null;
        try
        {
            cancellationToken.ThrowIfCancellationRequested();
            PreparedLibraryCall? preparedLibrary = null;
            if (library is not null && VoiceLibraryCapabilities.Tools.Values.Contains(key))
            {
                preparedLibrary = await library.PrepareAsync(key, arguments, cancellationToken);
                arguments = preparedLibrary.Arguments;
            }
            if (key == CapabilityIds.StickyUpsert)
            {
                var keys = arguments.EnumerateObject().Select(p => p.Name).ToArray();
                if (keys.Length != keys.Distinct().Count() || keys.Any(k => k is not ("title" or "body" or "color"))) return Failure("invalid_arguments");
                arguments = JsonSerializer.SerializeToElement(new {
                    stableKey = "voice:" + correlation,
                    title = arguments.TryGetProperty("title", out var title) ? title.GetString() : "",
                    body = arguments.GetProperty("body").GetString(),
                    color = arguments.TryGetProperty("color", out var color) ? color.GetString() : "yellow"
                });
            }
            var descriptor = registry.Resolve(key);
            descriptor.ValidateInput(arguments);
            var principal = new CapabilityPrincipal("local-user", AgentSessionId: sessionId);
            var permissions = new CapabilityPermissionSet(principal, descriptor.Permissions);
            var plan = new CapabilityExecutionPlan("voice-native:" + correlation, DateTimeOffset.UtcNow,
                origin, principal, null,
                [new CapabilityPlanStep("operation", key, arguments, "voice.native." + correlation, [])], descriptor.Permissions);
            var preparation = broker.Prepare(plan, permissions, DateTimeOffset.UtcNow);
            approval = preparation.ApprovalRequest;
            planDigest = preparation.PlanDigest;
            CapabilityApprovalGrant? grant = null;
            if (approval is not null)
            {
                var request = preparedLibrary?.Approval ?? (key == CapabilityIds.StickyUpsert
                    ? new VoiceNativeApproval("付箋を追加 / Create note", arguments.GetProperty("title").GetString() + "\n\n" + arguments.GetProperty("body").GetString() + "\n\n" + arguments.GetProperty("color").GetString())
                    : key == CapabilityIds.ControlsVolumeSet
                        ? new VoiceNativeApproval("音量を変更 / Change volume", $"{arguments.GetProperty("level").GetDouble() * 100:0.##}%")
                        : new VoiceNativeApproval("音声出力 / PC audio", arguments.GetProperty("muted").GetBoolean() ? "ミュート / Mute" : "ミュート解除 / Unmute"));
                if (!await approve(request, cancellationToken)) return Failure("user_rejected");
                cancellationToken.ThrowIfCancellationRequested();
                grant = broker.DecideApproval(approval.Id, planDigest, CapabilityApprovalDecision.Approve, DateTimeOffset.UtcNow);
                approval = null;
            }
            var receipt = await broker.ExecuteAsync(plan, permissions, grant, DateTimeOffset.UtcNow, cancellationToken);
            if (receipt.Status != CapabilityReceiptStatus.Succeeded || receipt.Steps.Count != 1
                || receipt.Steps[0].Output is not { } output
                || (descriptor.Effect.IsWrite() && receipt.Steps[0].Readback?.Status != CapabilityReadbackStatus.Verified)) return Failure("readback_failed");
            return new(true, JsonSerializer.Serialize(new { status = "succeeded", output, readback = descriptor.Effect.IsWrite() ? "verified" : "read" }));
        }
        catch (OperationCanceledException) { return Failure("cancelled"); }
        catch (VoiceLibraryException exception) { return Failure(exception.Message); }
        catch (InvalidOperationException exception) when (exception.Message is "window_not_found" or "window_ambiguous_use_windows_list" or "window_title_required" or "capture_target_expired" or "capture_target_changed" or "current_window_unavailable" or "capture_busy")
        { return Failure(exception.Message); }
        catch (Exception exception) when (exception is CapabilityBrokerException or CapabilityHandlerException or JsonException or KeyNotFoundException or InvalidOperationException or ArgumentException or IOException or UnauthorizedAccessException)
        { return Failure("operation_failed"); }
        finally
        {
            if (approval is not null && planDigest is not null)
                try { broker.DecideApproval(approval.Id, planDigest, CapabilityApprovalDecision.Reject, DateTimeOffset.UtcNow); }
                catch (CapabilityBrokerException) { }
        }
    }

    private static CodexVoiceDynamicToolResponse Failure(string code) => new(false, JsonSerializer.Serialize(new { status = "failed", code }));
}
