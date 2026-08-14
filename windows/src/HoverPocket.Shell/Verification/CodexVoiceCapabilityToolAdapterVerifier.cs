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
            var authorizationAllowed = true;
            var authorizationEpoch = 1L;
            var invalidateDuringApproval = false;
            var adapter = new CodexVoiceCapabilityToolAdapter(
                broker,
                new TodayFocusTextAdapter(broker),
                (approval, _) =>
                {
                    approvals.Add(approval);
                    if (invalidateDuringApproval)
                    {
                        invalidateDuringApproval = false;
                        authorizationAllowed = false;
                        authorizationEpoch++;
                    }
                    return Task.FromResult(approvalDecisions.Count == 0 || approvalDecisions.Dequeue());
                },
                () => new CodexVoiceToolAuthorization(authorizationAllowed, authorizationEpoch));
            var context = new CodexVoiceToolRequestContext("root-thread", 1);

            VerifyToolSpecs(adapter);
            var unsupported = await adapter.HandleAsync(
                new CodexAppServerRequest(
                    JsonSerializer.SerializeToElement(1),
                    "fake/approval",
                    JsonSerializer.SerializeToElement(new { })),
                context,
                cancellationToken);
            Require(unsupported.Error?.Code == -32601, "voice_tool_unsupported_request_fail_closed");

            var wrongThread = await adapter.HandleAsync(
                Request(
                    CodexVoiceCapabilityToolAdapter.CalendarTodayTool,
                    new { },
                    "wrong-thread",
                    "read-wrong"),
                context,
                cancellationToken);
            _ = Payload(wrongThread, expectedSuccess: false, "voice_tool_cross_thread_denied");

            var today = await adapter.HandleAsync(
                Request(
                    CodexVoiceCapabilityToolAdapter.CalendarTodayTool,
                    new { },
                    "root-thread",
                    "read-today"),
                context,
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
                context,
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
                context,
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
                context,
                cancellationToken);
            _ = Payload(replayedTimer, expectedSuccess: true, "voice_tool_timer_duplicate_reply");
            Require(timerStore.RunningTimers.Count == 1, "voice_tool_timer_duplicate_no_second_write");
            var changedDuplicate = await adapter.HandleAsync(
                Request(
                    CodexVoiceCapabilityToolAdapter.TimerStartTool,
                    new { durationSeconds = 601, title = "会議 確認 偽装" },
                    "root-thread",
                    "timer-approved"),
                context,
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
                context,
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
                context,
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

            var substitutionRead = Request(
                CodexVoiceCapabilityToolAdapter.CalendarTodayTool,
                new { },
                "root-thread",
                "tool-substitution");
            _ = Payload(
                await adapter.HandleAsync(substitutionRead, context, cancellationToken),
                expectedSuccess: true,
                "voice_tool_substitution_seed");
            var timerCountBeforeSubstitution = timerStore.RunningTimers.Count;
            var substitutionWrite = await adapter.HandleAsync(
                Request(
                    CodexVoiceCapabilityToolAdapter.TimerStartTool,
                    new { durationSeconds = 60, title = "置換拒否" },
                    "root-thread",
                    "tool-substitution"),
                context,
                cancellationToken);
            var substitutionPayload = Payload(
                substitutionWrite,
                expectedSuccess: false,
                "voice_tool_substitution_rejected");
            Require(
                substitutionPayload is { } substitutionValue
                && substitutionValue.GetProperty("code").GetString() == "CAPABILITY_IDEMPOTENCY_CONFLICT",
                "voice_tool_substitution_conflict_code");
            Require(
                timerStore.RunningTimers.Count == timerCountBeforeSubstitution,
                "voice_tool_substitution_no_write");

            var timerCountBeforeStaleApproval = timerStore.RunningTimers.Count;
            invalidateDuringApproval = true;
            var staleApprovalReply = await adapter.HandleAsync(
                Request(
                    CodexVoiceCapabilityToolAdapter.TimerStartTool,
                    new { durationSeconds = 60, title = "期限切れ承認" },
                    "root-thread",
                    "stale-approval"),
                context,
                cancellationToken);
            var staleApprovalPayload = Payload(
                staleApprovalReply,
                expectedSuccess: false,
                "voice_tool_stale_approval_rejected");
            Require(
                staleApprovalPayload is { } staleApprovalValue
                && staleApprovalValue.GetProperty("code").GetString() == "CAPABILITY_APPROVAL_REJECTED",
                "voice_tool_stale_approval_code");
            Require(
                timerStore.RunningTimers.Count == timerCountBeforeStaleApproval,
                "voice_tool_stale_approval_no_write");

            var listCountBeforeDisabledRequest = calendar.ListRequestCount;
            var disabledRead = await adapter.HandleAsync(
                Request(
                    CodexVoiceCapabilityToolAdapter.CalendarTodayTool,
                    new { },
                    "root-thread",
                    "read-today"),
                context,
                cancellationToken);
            _ = Payload(disabledRead, expectedSuccess: false, "voice_tool_disabled_cache_denied");
            Require(
                calendar.ListRequestCount == listCountBeforeDisabledRequest,
                "voice_tool_disabled_no_calendar_read");

            authorizationAllowed = true;
            authorizationEpoch++;
            var reauthorizedRead = await adapter.HandleAsync(
                Request(
                    CodexVoiceCapabilityToolAdapter.CalendarTodayTool,
                    new { },
                    "root-thread",
                    "read-today"),
                context,
                cancellationToken);
            _ = Payload(reauthorizedRead, expectedSuccess: true, "voice_tool_reauthorized_read");
            Require(
                calendar.ListRequestCount == listCountBeforeDisabledRequest + 1,
                "voice_tool_authorization_epoch_invalidates_cache");

            var oversized = await adapter.HandleAsync(
                Request(
                    CodexVoiceCapabilityToolAdapter.TodayFocusTool,
                    new
                    {
                        eventRef = "primary:focus-event",
                        durationSeconds = 1_500,
                        purpose = new string('x', 17_000)
                    },
                    "root-thread",
                    "oversized"),
                context,
                cancellationToken);
            var oversizedPayload = Payload(
                oversized,
                expectedSuccess: false,
                "voice_tool_oversized_rejected");
            Require(
                oversizedPayload is { } oversizedValue
                && oversizedValue.GetProperty("code").GetString() == "CAPABILITY_PAYLOAD_TOO_LARGE",
                "voice_tool_oversized_code");

            var pendingApproval = new TaskCompletionSource<bool>(
                TaskCreationOptions.RunContinuationsAsynchronously);
            var approvalEntered = new TaskCompletionSource<bool>(
                TaskCreationOptions.RunContinuationsAsynchronously);
            var boundedAdapter = new CodexVoiceCapabilityToolAdapter(
                broker,
                new TodayFocusTextAdapter(broker),
                async (_, token) =>
                {
                    approvalEntered.TrySetResult(true);
                    return await pendingApproval.Task.WaitAsync(token);
                });
            var pendingTasks = Enumerable.Range(0, 8)
                .Select(index => boundedAdapter.HandleAsync(
                    Request(
                        CodexVoiceCapabilityToolAdapter.TimerStartTool,
                        new { durationSeconds = 60, title = $"pending-{index}" },
                        "root-thread",
                        $"pending-{index}"),
                    context,
                    cancellationToken))
                .ToArray();
            _ = await approvalEntered.Task.WaitAsync(TimeSpan.FromSeconds(2), cancellationToken);
            for (var attempt = 0;
                attempt < 100 && boundedAdapter.PendingCallCountForVerify < 8;
                attempt++)
            {
                await Task.Delay(5, cancellationToken);
            }
            if (boundedAdapter.PendingCallCountForVerify == 8)
            {
                var overloaded = await boundedAdapter.HandleAsync(
                    Request(
                        CodexVoiceCapabilityToolAdapter.TimerStartTool,
                        new { durationSeconds = 60, title = "overloaded" },
                        "root-thread",
                        "pending-overloaded"),
                    context,
                    cancellationToken);
                var overloadedPayload = Payload(
                    overloaded,
                    expectedSuccess: false,
                    "voice_tool_pending_overload_rejected");
                Require(
                    overloadedPayload is { } overloadedValue
                    && overloadedValue.GetProperty("code").GetString() == "CAPABILITY_OVERLOADED",
                    "voice_tool_pending_overload_code");
            }
            else
            {
                _failures.Add("voice_tool_pending_bound_fixture");
            }
            pendingApproval.TrySetResult(false);
            _ = await Task.WhenAll(pendingTasks);
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
