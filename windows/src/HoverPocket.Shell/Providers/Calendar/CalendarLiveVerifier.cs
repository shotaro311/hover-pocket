using HoverPocket.Shell.Verification;

namespace HoverPocket.Shell.Providers.Calendar;

internal sealed class CalendarLiveVerifier
{
    public async Task<int> RunAsync(CancellationToken cancellationToken = default)
    {
        var state = await new CalendarStore().LoadMonthAsync(
            new DateTimeOffset(DateTime.Today),
            cancellationToken);
        var eventCount = state.DayCells
            .SelectMany(cell => cell.Events)
            .Select(calendarEvent => calendarEvent.Id)
            .Distinct(StringComparer.Ordinal)
            .Count();

        VerifyConsole.WriteLine($"calendar_live_source_count={state.Sources.Count}");
        VerifyConsole.WriteLine($"calendar_live_event_count={eventCount}");

        if (!string.Equals(state.ConnectionStatus, "signed_in", StringComparison.Ordinal)
            || !string.Equals(state.LoadStatus, "loaded", StringComparison.Ordinal))
        {
            VerifyConsole.WriteLine("FAIL calendar-live verify");
            return 1;
        }

        VerifyConsole.WriteLine("PASS calendar-live verify");
        return 0;
    }
}
