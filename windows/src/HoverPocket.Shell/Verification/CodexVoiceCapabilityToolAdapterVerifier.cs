using System.Text.Json;
using HoverPocket.Shell.Capabilities;
using HoverPocket.Shell.Providers.CodexVoice;
using HoverPocket.Shell.Providers.Sticky;
using HoverPocket.Shell.Providers.Timer;

namespace HoverPocket.Shell.Verification;

internal sealed class CodexVoiceCapabilityToolAdapterVerifier
{
    private readonly List<string> _failures;

    public CodexVoiceCapabilityToolAdapterVerifier(List<string> failures)
    {
        _failures = failures;
    }

    public async Task VerifyAsync(CancellationToken cancellationToken)
    {
        var root = Path.Combine(
            Path.GetTempPath(),
            "HoverPocketVoiceToolVerify",
            Guid.NewGuid().ToString("N"));
        try
        {
            var now = DateTimeOffset.Now;
            var calendar = new FakeCalendarCapabilityDataSource();
            calendar.Seed(new CalendarCapabilityEvent(
                "primary:focus-event",
                "focus-event",
                "設計会議\n確認\u202E偽装",
                now.AddMinutes(10),
                now.AddHours(1)));
            using var timerStore = new TimerStore(
                Path.Combine(root, "timer"),
                alertSound: new NullTimerAlertSound(),
                enableScheduler: false);
            var stickyStore = new StickyNotesStore(Path.Combine(root, "sticky"));
            var handlers = ProviderCapabilityCompositionRoot.Create(calendar, timerStore, stickyStore);
            var brokerRoot = Path.Combine(root, "broker");
            var broker = new CapabilityBroker(
                new CapabilityRegistry(handlers),
                new CapabilityBrokerLedger(brokerRoot),
                new CapabilityBrokerAuditLog(brokerRoot));
            var approvalDecisions = new Queue<bool>();
            var approvals = new List<CodexVoiceCapabilityApproval>();
            var adapter = new CodexVoiceCapabilityToolAdapter(
                broker,
                new TodayFocusTextAdapter(broker),
                (approval, _) =>
                {
                    approvals.Add(approval);
                    return Task.FromResult(approvalDecisions.Count == 0 || approvalDecisions.Dequeue());
                });

            VerifyToolSpecs(adapter);
            var unsupported = await adapter.HandleAsync(
                new CodexAppServerRequest(
                    JsonSerializer.SerializeToElement(1),
                    "fake/approval",
                    JsonSerializer.SerializeToElement(new { })),
                "root-thread",
                cancellationToken);
            Require(unsupported.Error?.Code == -32601, "voice_tool_unsupported_request_fail_closed");

            var wrongThread = await adapter.HandleAsync(
                Request(
                    CodexVoiceCapabilityToolAdapter.CalendarTodayTool,
                    new { },
                    "wrong-thread",
                    "read-wrong"),
                "root-thread",
                cancellationToken);
            _ = Payload(wrongThread, expectedSuccess: false, "voice_tool_cross_thread_denied");

            var today = await adapter.HandleAsync(
                Request(
                    CodexVoiceCapabilityToolAdapter.CalendarTodayTool,
                    new { },
                    "root-thread",
                    "read-today"),
                "root-thread",
                cancellationToken);
            var todayPayload = Payload(today, expectedSuccess: true, "voice_tool_calendar_today");
            Require(
                todayPayload is { } todayValue
                && todayValue.GetProperty("events").EnumerateArray().Any(item =>
                    item.GetProperty("eventRef").GetString() == "primary:focus-event"),
                "voice_tool_calendar_event_ref");
            Require(approvals.Count == 0, "voice_tool_read_without_per_call_approval");

            approvalDecisions.Enqueue(false);
            var rejectedTimer = await adapter.HandleAsync(
                Request(
                    CodexVoiceCapabilityToolAdapter.TimerStartTool,
                    new { durationSeconds = 600, title = "拒否するTimer" },
                    "root-thread",
                    "timer-rejected"),
                "root-thread",
                cancellationToken);
            _ = Payload(rejectedTimer, expectedSuccess: false, "voice_tool_timer_rejected");
            Require(timerStore.RunningTimers.Count == 0, "voice_tool_reject_no_timer_write");

            var timerRequest = Request(
                CodexVoiceCapabilityToolAdapter.TimerStartTool,
                new { durationSeconds = 600, title = "会議\n確認\u202E偽装" },
                "root-thread",
                "timer-approved");
            var approvedTimer = await adapter.HandleAsync(
                timerRequest,
                "root-thread",
                cancellationToken);
            var timerPayload = Payload(approvedTimer, expectedSuccess: true, "voice_tool_timer_approved");
            Require(
                timerPayload is { } timerValue
                && timerValue.GetProperty("readbackVerified").GetBoolean(),
                "voice_tool_timer_readback");
            Require(
                timerStore.RunningTimers.Count == 1
                && timerStore.RunningTimers[0].Title == "会議 確認 偽装",
                "voice_tool_timer_exact_canonical_title");
            var timerApproval = approvals.LastOrDefault(item =>
                item.ToolName == CodexVoiceCapabilityToolAdapter.TimerStartTool);
            Require(
                timerApproval?.Fields.FirstOrDefault(field => field.Key == "title")?.Value
                    == timerStore.RunningTimers[0].Title,
                "voice_tool_timer_approval_execution_binding");

            var replayedTimer = await adapter.HandleAsync(
                timerRequest,
                "root-thread",
                cancellationToken);
            _ = Payload(replayedTimer, expectedSuccess: true, "voice_tool_timer_duplicate_reply");
            Require(timerStore.RunningTimers.Count == 1, "voice_tool_timer_duplicate_no_second_write");
            var changedDuplicate = await adapter.HandleAsync(
                Request(
                    CodexVoiceCapabilityToolAdapter.TimerStartTool,
                    new { durationSeconds = 601, title = "会議 確認 偽装" },
                    "root-thread",
                    "timer-approved"),
                "root-thread",
                cancellationToken);
            var changedPayload = Payload(
                changedDuplicate,
                expectedSuccess: false,
                "voice_tool_timer_changed_duplicate_rejected");
            Require(
                changedPayload is { } changedValue
                && changedValue.GetProperty("code").GetString() == "CAPABILITY_IDEMPOTENCY_CONFLICT",
                "voice_tool_timer_changed_duplicate_code");
            Require(timerStore.RunningTimers.Count == 1, "voice_tool_timer_changed_duplicate_no_write");

            var calendarCreate = await adapter.HandleAsync(
                Request(
                    CodexVoiceCapabilityToolAdapter.CalendarCreateTool,
                    new
                    {
                        title = "新しい予定\n承認",
                        start = now.AddHours(2).ToString("O"),
                        end = now.AddHours(3).ToString("O"),
                        isAllDay = false
                    },
                    "root-thread",
                    "calendar-create"),
                "root-thread",
                cancellationToken);
            var calendarPayload = Payload(
                calendarCreate,
                expectedSuccess: true,
                "voice_tool_calendar_create");
            Require(
                calendarPayload is { } calendarValue
                && calendarValue.GetProperty("readbackVerified").GetBoolean(),
                "voice_tool_calendar_create_readback");
            Require(
                calendar.CreatedRequests.Count == 1
                && calendar.CreatedRequests[0].Title == "新しい予定 承認",
                "voice_tool_calendar_create_exact_title");

            var todayFocus = await adapter.HandleAsync(
                Request(
                    CodexVoiceCapabilityToolAdapter.TodayFocusTool,
                    new
                    {
                        eventRef = "primary:focus-event",
                        durationSeconds = 1_500,
                        purpose = "設計を完了\nする"
                    },
                    "root-thread",
                    "today-focus"),
                "root-thread",
                cancellationToken);
            var focusPayload = Payload(todayFocus, expectedSuccess: true, "voice_tool_today_focus");
            Require(
                focusPayload is { } focusValue
                && focusValue.GetProperty("readbackVerified").GetBoolean(),
                "voice_tool_today_focus_readback");
            Require(timerStore.RunningTimers.Count == 2, "voice_tool_today_focus_timer_write");
            Require(
                stickyStore.Notes.Any(note => note.Body == "設計を完了 する"),
                "voice_tool_today_focus_sticky_write");
            var focusApproval = approvals.LastOrDefault(item =>
                item.ToolName == CodexVoiceCapabilityToolAdapter.TodayFocusTool);
            Require(
                focusApproval?.Fields.FirstOrDefault(field => field.Key == "purpose")?.Value
                    == "設計を完了 する",
                "voice_tool_today_focus_approval_execution_binding");
        }
        finally
        {
            if (Directory.Exists(root))
            {
                Directory.Delete(root, recursive: true);
            }
        }
    }

    private void VerifyToolSpecs(CodexVoiceCapabilityToolAdapter adapter)
    {
        var specs = JsonSerializer.SerializeToElement(adapter.DynamicTools);
        var names = specs.EnumerateArray()
            .Select(item => item.GetProperty("name").GetString())
            .ToHashSet(StringComparer.Ordinal);
        Require(
            names.SetEquals(
            [
                CodexVoiceCapabilityToolAdapter.CalendarTodayTool,
                CodexVoiceCapabilityToolAdapter.TimerStartTool,
                CodexVoiceCapabilityToolAdapter.CalendarCreateTool,
                CodexVoiceCapabilityToolAdapter.TodayFocusTool
            ]),
            "voice_tool_specs_allowlist");
        Require(
            specs.EnumerateArray().All(item =>
                item.GetProperty("type").GetString() == "function"
                && item.GetProperty("inputSchema").GetProperty("additionalProperties").ValueKind == JsonValueKind.False),
            "voice_tool_specs_closed_schema");
    }

    private static CodexAppServerRequest Request(
        string tool,
        object arguments,
        string threadId,
        string callId)
    {
        return new CodexAppServerRequest(
            JsonSerializer.SerializeToElement(callId),
            "item/tool/call",
            JsonSerializer.SerializeToElement(new
            {
                arguments,
                callId,
                @namespace = (string?)null,
                threadId,
                tool,
                turnId = "turn-verify"
            }));
    }

    private JsonElement? Payload(
        CodexAppServerReply reply,
        bool expectedSuccess,
        string label)
    {
        if (reply.Error is not null || reply.Result is null)
        {
            _failures.Add(label);
            return null;
        }
        var result = JsonSerializer.SerializeToElement(reply.Result);
        if (!result.TryGetProperty("success", out var success)
            || success.ValueKind is not (JsonValueKind.True or JsonValueKind.False)
            || success.GetBoolean() != expectedSuccess
            || !result.TryGetProperty("contentItems", out var contentItems)
            || contentItems.ValueKind != JsonValueKind.Array
            || contentItems.GetArrayLength() != 1
            || contentItems[0].GetProperty("type").GetString() != "inputText")
        {
            _failures.Add(label);
            return null;
        }
        using var document = JsonDocument.Parse(contentItems[0].GetProperty("text").GetString() ?? "{}");
        return document.RootElement.Clone();
    }

    private void Require(bool condition, string label)
    {
        if (!condition)
        {
            _failures.Add(label);
        }
    }
}
