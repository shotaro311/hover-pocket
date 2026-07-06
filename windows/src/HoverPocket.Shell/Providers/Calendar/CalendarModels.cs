using System.Globalization;

namespace HoverPocket.Shell.Providers.Calendar;

internal sealed record CalendarSource(
    string Id,
    string Title,
    string? ColorHex,
    string? TimeZone,
    bool IsPrimary,
    string? AccessRole)
{
    public bool CanWrite => AccessRole is "owner" or "writer";
}

internal sealed record CalendarEventOccurrence(
    string Id,
    string GoogleEventId,
    string CalendarId,
    string CalendarTitle,
    string? CalendarColorHex,
    bool CalendarCanWrite,
    string Title,
    string? Location,
    string? Notes,
    DateTimeOffset Start,
    DateTimeOffset End,
    bool IsAllDay,
    string? HtmlLink)
{
    public bool Intersects(DateTimeOffset dayStart, DateTimeOffset dayEnd)
    {
        return Start < dayEnd && End > dayStart;
    }
}

internal sealed record CalendarEventDraft(
    string CalendarId,
    string? EventId,
    string Title,
    string? Location,
    string? Notes,
    DateTimeOffset Start,
    DateTimeOffset End,
    bool IsAllDay)
{
    public bool IsNew => string.IsNullOrWhiteSpace(EventId);

    public CalendarEventDraft Normalized()
    {
        var title = string.IsNullOrWhiteSpace(Title) ? "Untitled event" : Title.Trim();
        var start = Start;
        var end = End;
        if (IsAllDay)
        {
            var localStart = Start.LocalDateTime.Date;
            start = new DateTimeOffset(localStart);
            end = new DateTimeOffset(localStart.AddDays(1));
        }
        else if (end <= start)
        {
            end = start.AddHours(1);
        }

        return this with
        {
            Title = title,
            Location = string.IsNullOrWhiteSpace(Location) ? null : Location.Trim(),
            Notes = string.IsNullOrWhiteSpace(Notes) ? null : Notes.Trim(),
            Start = start,
            End = end
        };
    }
}

internal sealed record CalendarSnapshot(
    IReadOnlyList<CalendarSource> Sources,
    IReadOnlyList<CalendarEventOccurrence> Events,
    DateTimeOffset RangeStart,
    DateTimeOffset RangeEnd,
    DateTimeOffset MonthAnchor,
    DateTimeOffset UpdatedAt)
{
    public IReadOnlyList<CalendarDayCell> DayCells(
        DateTimeOffset month,
        DateTimeOffset selectedDate,
        DateTimeOffset? hoveredDate,
        DateTimeOffset? today = null)
    {
        var day = RangeStart;
        var cells = new List<CalendarDayCell>(42);
        var monthStart = CalendarDateMath.StartOfMonth(month.LocalDateTime);
        var selectedDay = selectedDate.LocalDateTime.Date;
        var hoveredDay = hoveredDate?.LocalDateTime.Date;
        var todayLocal = today?.LocalDateTime.Date ?? DateTime.Today;

        for (var index = 0; index < 42; index++)
        {
            var local = day.LocalDateTime.Date;
            cells.Add(new CalendarDayCell(
                CalendarDateMath.DayIdentifier(local),
                day,
                local.Day,
                local.Year == monthStart.Year && local.Month == monthStart.Month,
                local == todayLocal,
                local == selectedDay,
                hoveredDay is not null && local == hoveredDay,
                EventsForDay(day)));
            day = day.AddDays(1);
        }

        return cells;
    }

    public IReadOnlyList<CalendarEventOccurrence> EventsForDay(DateTimeOffset day)
    {
        var dayStart = new DateTimeOffset(day.LocalDateTime.Date);
        var dayEnd = dayStart.AddDays(1);
        return Events
            .Where(item => item.Intersects(dayStart, dayEnd))
            .OrderBy(item => item.Start)
            .ToArray();
    }
}

internal sealed record CalendarDayCell(
    string Id,
    DateTimeOffset Date,
    int DayNumber,
    bool IsInDisplayedMonth,
    bool IsToday,
    bool IsSelected,
    bool IsHovered,
    IReadOnlyList<CalendarEventOccurrence> Events);

internal sealed record CalendarSetupInstructions(
    string Path,
    IReadOnlyList<string> Ja,
    IReadOnlyList<string> En);

internal sealed record CalendarProviderState(
    string ConnectionStatus,
    string LoadStatus,
    string Message,
    DateTimeOffset MonthAnchor,
    DateTimeOffset SelectedDate,
    DateTimeOffset? HoveredDate,
    IReadOnlyList<CalendarSource> Sources,
    IReadOnlyList<CalendarDayCell> DayCells,
    IReadOnlyList<CalendarEventOccurrence> SelectedEvents,
    CalendarSetupInstructions Setup);

internal static class CalendarDateMath
{
    public static DateTime StartOfMonth(DateTime date)
    {
        return new DateTime(date.Year, date.Month, 1, 0, 0, 0, DateTimeKind.Local);
    }

    public static (DateTimeOffset Start, DateTimeOffset End) VisibleGridRange(
        DateTime date,
        DayOfWeek firstDayOfWeek)
    {
        var monthStart = StartOfMonth(date);
        var leadingDays = ((int)monthStart.DayOfWeek - (int)firstDayOfWeek + 7) % 7;
        var gridStart = monthStart.AddDays(-leadingDays);
        return (new DateTimeOffset(gridStart), new DateTimeOffset(gridStart.AddDays(42)));
    }

    public static string DayIdentifier(DateTime date)
    {
        return date.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
    }
}
