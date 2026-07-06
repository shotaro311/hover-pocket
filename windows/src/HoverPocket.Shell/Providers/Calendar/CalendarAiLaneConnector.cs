using System.Globalization;
using HoverPocket.Shell.Providers.AiLane;

namespace HoverPocket.Shell.Providers.Calendar;

internal sealed class CalendarAiLaneConnector : IAiLaneCalendarConnector
{
    private readonly CalendarStore _store;

    public CalendarAiLaneConnector(CalendarStore store)
    {
        _store = store;
    }

    public async Task<string> ReadCalendarAsync(DateTimeOffset day, CancellationToken cancellationToken)
    {
        return await _store.ReadDaySummaryAsync(day, cancellationToken);
    }

    public async Task<string> CreateCalendarEventAsync(AiLaneApprovalCard card, CancellationToken cancellationToken)
    {
        if (!DateTimeOffset.TryParseExact(
                card.Start,
                "yyyy-MM-dd HH:mm",
                CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeLocal,
                out var start))
        {
            throw new InvalidOperationException("Calendar start time could not be parsed.");
        }

        var end = DateTimeOffset.TryParseExact(
            card.End,
            "yyyy-MM-dd HH:mm",
            CultureInfo.InvariantCulture,
            DateTimeStyles.AssumeLocal,
            out var parsedEnd)
            ? parsedEnd
            : start.AddHours(1);

        return await _store.CreateFromAiLaneAsync(card.Title, start, end, cancellationToken);
    }
}
