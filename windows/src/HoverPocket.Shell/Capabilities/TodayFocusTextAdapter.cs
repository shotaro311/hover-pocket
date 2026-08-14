using System.Text;
using System.Text.Json;
using System.Globalization;

namespace HoverPocket.Shell.Capabilities;

internal sealed record TodayFocusCalendarEvent(
    string EventRef,
    string SafeTitle,
    DateTimeOffset Start,
    DateTimeOffset End);

internal sealed record TodayFocusDraft(
    CapabilityExecutionPlan Plan,
    CapabilityBrokerPreparation Preparation);

internal static class TodayFocusApprovalText
{
    private static readonly HashSet<int> BidirectionalControls =
    [
        0x061C, 0x200E, 0x200F,
        0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
        0x2066, 0x2067, 0x2068, 0x2069
    ];

    public static string Sanitize(string value)
    {
        var builder = new StringBuilder();
        var pendingSpace = false;
        foreach (var rune in value.EnumerateRunes())
        {
            var category = Rune.GetUnicodeCategory(rune);
            var disallowed = category is UnicodeCategory.Control
                or UnicodeCategory.Format
                or UnicodeCategory.LineSeparator
                or UnicodeCategory.ParagraphSeparator
                || BidirectionalControls.Contains(rune.Value);
            if (disallowed || Rune.IsWhiteSpace(rune))
            {
                pendingSpace = builder.Length > 0;
                continue;
            }
            if (pendingSpace)
            {
                builder.Append(' ');
                pendingSpace = false;
            }
            builder.Append(rune.ToString());
        }
        var normalized = builder.ToString().Trim();
        return string.IsNullOrEmpty(normalized)
            ? "予定名なし"
            : CapabilityJson.TruncateString(normalized, 120);
    }
}

internal sealed class TodayFocusTextAdapter(CapabilityBroker broker)
{
    private readonly CapabilityBroker _broker = broker;

    public async Task<IReadOnlyList<TodayFocusCalendarEvent>> ListTodayAsync(
        string timezoneId,
        CapabilityPrincipal principal,
        CapabilityPermissionSet permissions,
        DateTimeOffset now,
        CancellationToken cancellationToken = default)
    {
        var nonce = Guid.NewGuid().ToString("D");
        var plan = new CapabilityExecutionPlan(
            $"today-focus-read:{nonce}",
            now,
            CapabilityOrigin.Text,
            principal,
            null,
            [
                new CapabilityPlanStep(
                    "listCalendar",
                    CapabilityIds.CalendarList,
                    CapabilityJson.From(new { range = "today", timezone = timezoneId }),
                    $"today-focus-read.{nonce}",
                    [])
            ],
            new HashSet<string>(["calendar.events.read"], StringComparer.Ordinal));
        var preparation = _broker.Prepare(plan, permissions, now);
        if (preparation.ApprovalRequest is not null)
        {
            throw new CapabilityBrokerException("CAPABILITY_PLAN_INVALID", "read_approval");
        }
        var receipt = await _broker.ExecuteAsync(plan, permissions, null, now, cancellationToken);
        if (receipt.Status != CapabilityReceiptStatus.Succeeded
            || receipt.Steps.FirstOrDefault()?.Output is not { } output
            || !output.TryGetProperty("events", out var events)
            || events.ValueKind != JsonValueKind.Array)
        {
            throw new CapabilityBrokerException("CAPABILITY_UNAVAILABLE", CapabilityIds.CalendarList.Id);
        }
        return events.EnumerateArray().Select(item =>
        {
            if (!item.TryGetProperty("eventRef", out var eventRef)
                || !item.TryGetProperty("safeTitle", out var safeTitle)
                || !item.TryGetProperty("start", out var start)
                || !item.TryGetProperty("end", out var end)
                || !DateTimeOffset.TryParse(start.GetString(), out var startDate)
                || !DateTimeOffset.TryParse(end.GetString(), out var endDate))
            {
                throw new CapabilityBrokerException("CAPABILITY_READBACK_MISMATCH", "calendar.events");
            }
            return new TodayFocusCalendarEvent(
                eventRef.GetString() ?? string.Empty,
                safeTitle.GetString() ?? string.Empty,
                startDate,
                endDate);
        }).ToArray();
    }

    public TodayFocusDraft PrepareFocus(
        TodayFocusCalendarEvent selectedEvent,
        int durationSeconds,
        string purpose,
        CapabilityPrincipal principal,
        CapabilityPermissionSet permissions,
        DateTimeOffset now,
        TimeZoneInfo? timeZone = null)
    {
        if (durationSeconds is < 1 or > 86_400
            || string.IsNullOrEmpty(purpose)
            || purpose.EnumerateRunes().Count() > 10_000)
        {
            throw new CapabilityBrokerException("CAPABILITY_PLAN_INVALID", "today_focus_input");
        }
        var nonce = Guid.NewGuid().ToString("D");
        var plan = new CapabilityExecutionPlan(
            $"today-focus-write:{nonce}",
            now,
            CapabilityOrigin.Text,
            principal,
            null,
            [
                new CapabilityPlanStep(
                    "startTimer",
                    CapabilityIds.TimerStart,
                    CapabilityJson.From(new
                    {
                        durationSeconds,
                        title = CapabilityJson.TruncateString(selectedEvent.SafeTitle, 80),
                        sourceRef = selectedEvent.EventRef
                    }),
                    $"today-focus-timer.{nonce}",
                    []),
                new CapabilityPlanStep(
                    "savePurpose",
                    CapabilityIds.StickyUpsert,
                    CapabilityJson.From(new
                    {
                        stableKey = $"today-focus:{TimeZoneInfo.ConvertTime(now, timeZone ?? TimeZoneInfo.Local):yyyy-MM-dd}",
                        title = "今日の目的",
                        body = purpose,
                        color = "yellow"
                    }),
                    $"today-focus-sticky.{nonce}",
                    ["startTimer"])
            ],
            new HashSet<string>(["sticky.write", "timer.write"], StringComparer.Ordinal));
        return new TodayFocusDraft(plan, _broker.Prepare(plan, permissions, now));
    }

    public async Task<CapabilityWorkflowReceipt> ApproveAndExecuteAsync(
        TodayFocusDraft draft,
        CapabilityPermissionSet permissions,
        DateTimeOffset now,
        CancellationToken cancellationToken = default)
    {
        var request = draft.Preparation.ApprovalRequest
            ?? throw new CapabilityBrokerException("CAPABILITY_APPROVAL_REQUIRED", draft.Plan.Id);
        var grant = _broker.DecideApproval(
            request.Id,
            draft.Preparation.PlanDigest,
            CapabilityApprovalDecision.Approve,
            now);
        return await _broker.ExecuteAsync(draft.Plan, permissions, grant, now, cancellationToken);
    }
}
