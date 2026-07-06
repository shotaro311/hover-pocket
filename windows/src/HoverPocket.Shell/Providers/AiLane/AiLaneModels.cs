namespace HoverPocket.Shell.Providers.AiLane;

internal enum AiLaneCommandKind
{
    ReadCalendar,
    CreateCalendarEvent,
    Unknown
}

internal sealed record AiLaneInterpretation(
    AiLaneCommandKind Kind,
    string Message,
    AiLaneApprovalCard? ApprovalCard,
    DateTimeOffset? ReadDate = null);

internal sealed record AiLaneApprovalCard(
    string ActionId,
    string ActionType,
    string Title,
    string Start,
    string End,
    bool AllDay,
    string Location,
    string Notes,
    string Calendar)
{
    public IReadOnlyList<AiLaneApprovalField> Fields { get; } =
    [
        new("title", "Title", Title),
        new("start", "Start", Start),
        new("end", "End", End),
        new("allDay", "All-day", AllDay ? "true" : "false"),
        new("location", "Location", string.IsNullOrWhiteSpace(Location) ? "-" : Location),
        new("notes", "Notes", string.IsNullOrWhiteSpace(Notes) ? "-" : Notes),
        new("calendar", "Calendar", Calendar)
    ];
}

internal sealed record AiLaneApprovalField(string Key, string Label, string Value);

internal sealed record AiLaneState(
    string Status,
    string Message,
    AiLaneApprovalCard? PendingApproval)
{
    public static AiLaneState Ready { get; } = new("ready", "Calendar に接続できます。", null);
}
