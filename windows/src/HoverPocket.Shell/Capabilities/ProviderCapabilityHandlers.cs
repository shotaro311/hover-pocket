using System.Globalization;
using System.Text.Json;
using HoverPocket.Shell.Providers.Calendar;
using HoverPocket.Shell.Providers.Sticky;
using HoverPocket.Shell.Providers.Timer;

namespace HoverPocket.Shell.Capabilities;

internal static class CapabilityIds
{
    public static readonly PocketCapabilityKey CalendarList = new("calendar.events.list", 1);
    public static readonly PocketCapabilityKey CalendarGet = new("calendar.event.get", 1);
    public static readonly PocketCapabilityKey CalendarCreate = new("calendar.event.create", 1);
    public static readonly PocketCapabilityKey TimerStart = new("timer.countdown.start", 1);
    public static readonly PocketCapabilityKey TimerGet = new("timer.countdown.get", 1);
    public static readonly PocketCapabilityKey TimerPause = new("timer.countdown.pause", 1);
    public static readonly PocketCapabilityKey TimerResume = new("timer.countdown.resume", 1);
    public static readonly PocketCapabilityKey TimerStop = new("timer.countdown.stop", 1);
    public static readonly PocketCapabilityKey StickyUpsert = new("sticky.note.upsert", 1);
    public static readonly PocketCapabilityKey StickyGet = new("sticky.note.get", 1);
}

internal sealed record CalendarCapabilityEvent(
    string EventRef,
    string EventId,
    string SafeTitle,
    DateTimeOffset Start,
    DateTimeOffset End);

internal sealed record CalendarCapabilityCreateRequest(
    string? CalendarId,
    string Title,
    DateTimeOffset Start,
    DateTimeOffset End,
    bool IsAllDay,
    string? Location,
    string? Notes);

internal interface ICalendarCapabilityDataSource
{
    Task<IReadOnlyList<CalendarCapabilityEvent>> ListEventsAsync(
        DateTimeOffset start,
        DateTimeOffset end,
        CancellationToken cancellationToken);

    Task<CalendarCapabilityEvent?> GetEventAsync(
        string eventRef,
        CancellationToken cancellationToken);

    Task<CalendarCapabilityEvent> CreateEventAsync(
        CalendarCapabilityCreateRequest request,
        string idempotencyKey,
        CancellationToken cancellationToken);
}

internal sealed class GoogleCalendarCapabilityDataSource : ICalendarCapabilityDataSource
{
    private readonly CalendarStore _store;

    public GoogleCalendarCapabilityDataSource(CalendarStore store)
    {
        _store = store;
    }

    public async Task<IReadOnlyList<CalendarCapabilityEvent>> ListEventsAsync(
        DateTimeOffset start,
        DateTimeOffset end,
        CancellationToken cancellationToken)
    {
        var events = await _store.ListEventsForCapabilityAsync(start, end, cancellationToken);
        return events.Select(Map).ToArray();
    }

    public async Task<CalendarCapabilityEvent?> GetEventAsync(
        string eventRef,
        CancellationToken cancellationToken)
    {
        var item = await _store.GetEventForCapabilityAsync(eventRef, cancellationToken);
        return item is null ? null : Map(item);
    }

    public async Task<CalendarCapabilityEvent> CreateEventAsync(
        CalendarCapabilityCreateRequest request,
        string idempotencyKey,
        CancellationToken cancellationToken)
    {
        return Map(await _store.CreateEventForCapabilityAsync(
            request,
            idempotencyKey,
            cancellationToken));
    }

    private static CalendarCapabilityEvent Map(CalendarEventOccurrence item)
    {
        return new CalendarCapabilityEvent(
            item.Id,
            item.GoogleEventId,
            item.Title,
            item.Start,
            item.End);
    }
}

internal sealed class CalendarListCapabilityHandler : IPocketCapabilityHandler
{
    private readonly ICalendarCapabilityDataSource _dataSource;

    public CalendarListCapabilityHandler(ICalendarCapabilityDataSource dataSource)
    {
        _dataSource = dataSource;
    }

    public PocketCapabilityKey Key => CapabilityIds.CalendarList;

    public async Task<JsonElement> HandleAsync(
        JsonElement arguments,
        CapabilityHandlerContext context,
        CancellationToken cancellationToken = default)
    {
        if (CapabilityJson.RequiredString(arguments, "range", 16) != "today")
        {
            throw CapabilityJson.Invalid("range");
        }
        var timeZoneId = CapabilityJson.RequiredString(arguments, "timezone", 64);
        TimeZoneInfo timeZone;
        try
        {
            timeZone = TimeZoneInfo.FindSystemTimeZoneById(timeZoneId);
        }
        catch (TimeZoneNotFoundException)
        {
            throw CapabilityJson.Invalid("timezone");
        }
        catch (InvalidTimeZoneException)
        {
            throw CapabilityJson.Invalid("timezone");
        }

        var localNow = TimeZoneInfo.ConvertTime(context.Now, timeZone);
        var localDate = DateOnly.FromDateTime(localNow.DateTime);
        var localStart = StartOfDay(localDate, timeZone);
        var localEnd = StartOfDay(localDate.AddDays(1), timeZone);
        var events = await _dataSource.ListEventsAsync(localStart, localEnd, cancellationToken);
        return CapabilityJson.From(new
        {
            events = events.Take(128).Select(Output).ToArray()
        });
    }

    internal static object Output(CalendarCapabilityEvent item)
    {
        return new
        {
            EventRef = CapabilityJson.OutputString(item.EventRef, 256, "calendar.eventRef"),
            start = item.Start.ToString("O", CultureInfo.InvariantCulture),
            end = item.End.ToString("O", CultureInfo.InvariantCulture),
            safeTitle = CapabilityJson.TruncateString(item.SafeTitle, 160)
        };
    }

    private static DateTimeOffset StartOfDay(DateOnly date, TimeZoneInfo timeZone)
    {
        var local = DateTime.SpecifyKind(date.ToDateTime(TimeOnly.MinValue), DateTimeKind.Unspecified);
        return new DateTimeOffset(local, timeZone.GetUtcOffset(local));
    }
}

internal sealed class CalendarGetCapabilityHandler : IPocketCapabilityHandler
{
    private readonly ICalendarCapabilityDataSource _dataSource;

    public CalendarGetCapabilityHandler(ICalendarCapabilityDataSource dataSource)
    {
        _dataSource = dataSource;
    }

    public PocketCapabilityKey Key => CapabilityIds.CalendarGet;

    public async Task<JsonElement> HandleAsync(
        JsonElement arguments,
        CapabilityHandlerContext context,
        CancellationToken cancellationToken = default)
    {
        _ = context;
        var eventRef = CapabilityJson.RequiredString(arguments, "eventRef", 256);
        var item = await _dataSource.GetEventAsync(eventRef, cancellationToken)
            ?? throw new CapabilityHandlerException("CAPABILITY_UNAVAILABLE", "calendar_event");
        return CapabilityJson.From(new
        {
            EventRef = CapabilityJson.OutputString(item.EventRef, 256, "calendar.eventRef"),
            EventId = CapabilityJson.OutputString(item.EventId, 256, "calendar.eventId"),
            start = item.Start.ToString("O", CultureInfo.InvariantCulture),
            end = item.End.ToString("O", CultureInfo.InvariantCulture),
            safeTitle = CapabilityJson.TruncateString(item.SafeTitle, 160)
        });
    }
}

internal sealed class CalendarCreateCapabilityHandler : IPocketCapabilityHandler
{
    private readonly ICalendarCapabilityDataSource _dataSource;

    public CalendarCreateCapabilityHandler(ICalendarCapabilityDataSource dataSource)
    {
        _dataSource = dataSource;
    }

    public PocketCapabilityKey Key => CapabilityIds.CalendarCreate;

    public async Task<JsonElement> HandleAsync(
        JsonElement arguments,
        CapabilityHandlerContext context,
        CancellationToken cancellationToken = default)
    {
        var idempotencyKey = context.RequireIdempotencyKey();
        var title = CapabilityJson.RequiredString(arguments, "title", 160);
        var start = RequiredDate(arguments, "start");
        var end = RequiredDate(arguments, "end");
        var isAllDay = CapabilityJson.RequiredBool(arguments, "isAllDay");
        if (isAllDay)
        {
            var startDate = DateOnly.FromDateTime(start.Date);
            var endDate = DateOnly.FromDateTime(end.Date);
            if (endDate <= startDate)
            {
                throw CapabilityJson.Invalid("start_end");
            }
        }
        else if (end <= start)
        {
            throw CapabilityJson.Invalid("start_end");
        }
        var request = new CalendarCapabilityCreateRequest(
            CapabilityJson.OptionalString(arguments, "calendarId", 256),
            title,
            start,
            end,
            isAllDay,
            CapabilityJson.OptionalString(arguments, "location", 500),
            CapabilityJson.OptionalString(arguments, "notes", 10_000));
        var created = await _dataSource.CreateEventAsync(
            request,
            idempotencyKey,
            cancellationToken);
        var observed = await _dataSource.GetEventAsync(created.EventRef, cancellationToken);
        if (observed != created)
        {
            throw new CapabilityHandlerException("CAPABILITY_READBACK_MISMATCH", "calendar.event.create");
        }
        return CapabilityJson.From(new
        {
            EventRef = CapabilityJson.OutputString(created.EventRef, 256, "calendar.eventRef"),
            EventId = CapabilityJson.OutputString(created.EventId, 256, "calendar.eventId"),
            start = created.Start.ToString("O", CultureInfo.InvariantCulture),
            end = created.End.ToString("O", CultureInfo.InvariantCulture),
            safeTitle = CapabilityJson.TruncateString(created.SafeTitle, 160)
        });
    }

    private static DateTimeOffset RequiredDate(JsonElement arguments, string name)
    {
        var value = CapabilityJson.RequiredString(arguments, name, 64);
        if (!DateTimeOffset.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var parsed))
        {
            throw CapabilityJson.Invalid(name);
        }
        return parsed;
    }
}

internal enum TimerCapabilityOperation
{
    Start,
    Get,
    Pause,
    Resume,
    Stop
}

internal sealed class TimerCapabilityHandler : IPocketCapabilityHandler
{
    private readonly TimerCapabilityOperation _operation;
    private readonly TimerStore _store;

    public TimerCapabilityHandler(TimerCapabilityOperation operation, TimerStore store)
    {
        _operation = operation;
        _store = store;
    }

    public PocketCapabilityKey Key => _operation switch
    {
        TimerCapabilityOperation.Start => CapabilityIds.TimerStart,
        TimerCapabilityOperation.Get => CapabilityIds.TimerGet,
        TimerCapabilityOperation.Pause => CapabilityIds.TimerPause,
        TimerCapabilityOperation.Resume => CapabilityIds.TimerResume,
        TimerCapabilityOperation.Stop => CapabilityIds.TimerStop,
        _ => throw new ArgumentOutOfRangeException()
    };

    public Task<JsonElement> HandleAsync(
        JsonElement arguments,
        CapabilityHandlerContext context,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (_operation != TimerCapabilityOperation.Get)
        {
            _ = context.RequireIdempotencyKey();
        }
        try
        {
            return Task.FromResult(_operation switch
            {
                TimerCapabilityOperation.Start => Start(arguments),
                TimerCapabilityOperation.Get => Output(TimerId(arguments)),
                TimerCapabilityOperation.Pause => Pause(TimerId(arguments)),
                TimerCapabilityOperation.Resume => Resume(TimerId(arguments)),
                TimerCapabilityOperation.Stop => Stop(TimerId(arguments)),
                _ => throw new ArgumentOutOfRangeException()
            });
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            throw new CapabilityHandlerException("CAPABILITY_UNAVAILABLE", "timer_storage");
        }
    }

    private JsonElement Start(JsonElement arguments)
    {
        var duration = CapabilityJson.RequiredInt(arguments, "durationSeconds", 1, 86_400);
        var title = CapabilityJson.RequiredString(arguments, "title", 80);
        _ = CapabilityJson.OptionalString(arguments, "sourceRef", 256);
        var before = _store.GetSnapshot().RunningTimers.Select(timer => timer.Id).ToHashSet();
        var preset = TimerPreset.DefaultTimerDraft() with
        {
            Title = title,
            DurationSeconds = duration
        };
        var snapshot = _store.Start(preset);
        var created = snapshot.RunningTimers.SingleOrDefault(timer => !before.Contains(timer.Id))
            ?? throw new CapabilityHandlerException("CAPABILITY_UNAVAILABLE", "timer_capacity");
        return Output(created);
    }

    private JsonElement Pause(Guid id)
    {
        if (_store.GetRunningTimer(id) is null)
        {
            throw new CapabilityHandlerException("CAPABILITY_UNAVAILABLE", "timer");
        }
        _store.Pause(id);
        return Output(id);
    }

    private JsonElement Resume(Guid id)
    {
        if (_store.GetRunningTimer(id) is null)
        {
            throw new CapabilityHandlerException("CAPABILITY_UNAVAILABLE", "timer");
        }
        _store.Resume(id);
        return Output(id);
    }

    private JsonElement Stop(Guid id)
    {
        _store.Stop(id);
        return Stopped(id);
    }

    private JsonElement Output(Guid id)
    {
        var timer = _store.GetSnapshot().RunningTimers.FirstOrDefault(item => item.Id == id);
        return timer is null ? Stopped(id) : Output(timer);
    }

    private static JsonElement Output(RunningTimerSnapshot timer)
    {
        return CapabilityJson.From(new
        {
            timerId = timer.Id.ToString("D").ToLowerInvariant(),
            state = timer.IsPaused ? "paused" : "running",
            endAt = timer.EndAtUtc.ToString("O", CultureInfo.InvariantCulture)
        });
    }

    private static JsonElement Stopped(Guid id)
    {
        return CapabilityJson.From(new
        {
            timerId = id.ToString("D").ToLowerInvariant(),
            state = "stopped",
            endAt = (string?)null
        });
    }

    private static Guid TimerId(JsonElement arguments)
    {
        var value = CapabilityJson.RequiredString(arguments, "timerId", 36);
        return Guid.TryParse(value, out var id) ? id : throw CapabilityJson.Invalid("timerId");
    }
}

internal enum StickyCapabilityOperation
{
    Upsert,
    Get
}

internal sealed class StickyCapabilityHandler : IPocketCapabilityHandler
{
    private readonly StickyCapabilityOperation _operation;
    private readonly StickyNotesStore _store;

    public StickyCapabilityHandler(StickyCapabilityOperation operation, StickyNotesStore store)
    {
        _operation = operation;
        _store = store;
    }

    public PocketCapabilityKey Key => _operation == StickyCapabilityOperation.Upsert
        ? CapabilityIds.StickyUpsert
        : CapabilityIds.StickyGet;

    public Task<JsonElement> HandleAsync(
        JsonElement arguments,
        CapabilityHandlerContext context,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (_operation == StickyCapabilityOperation.Upsert)
        {
            _ = context.RequireIdempotencyKey();
        }
        return Task.FromResult(_operation == StickyCapabilityOperation.Upsert
            ? Upsert(arguments)
            : Get(arguments));
    }

    private JsonElement Upsert(JsonElement arguments)
    {
        StickyNoteItem note;
        try
        {
            note = _store.UpsertNote(
                CapabilityJson.RequiredString(arguments, "stableKey", 160),
                CapabilityJson.RequiredString(arguments, "title", 120, allowEmpty: true),
                CapabilityJson.RequiredString(arguments, "body", 10_000, allowEmpty: true),
                Color(CapabilityJson.RequiredString(arguments, "color", 16)));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            throw new CapabilityHandlerException("CAPABILITY_UNAVAILABLE", "sticky_storage");
        }
        return MutationOutput(note);
    }

    private JsonElement Get(JsonElement arguments)
    {
        var rawId = CapabilityJson.RequiredString(arguments, "noteId", 128);
        if (!Guid.TryParse(rawId, out var id) || _store.GetNote(id) is not { } note)
        {
            throw new CapabilityHandlerException("CAPABILITY_UNAVAILABLE", "sticky_note");
        }
        return CapabilityJson.From(new
        {
            noteId = note.Id.ToString("D").ToLowerInvariant(),
            Title = CapabilityJson.OutputString(note.Title, 120, "sticky.title", allowEmpty: true),
            Body = CapabilityJson.OutputString(note.Body, 10_000, "sticky.body", allowEmpty: true),
            updatedAt = note.UpdatedAt.ToString("O", CultureInfo.InvariantCulture)
        });
    }

    private static JsonElement MutationOutput(StickyNoteItem note)
    {
        return CapabilityJson.From(new
        {
            noteId = note.Id.ToString("D").ToLowerInvariant(),
            Title = CapabilityJson.OutputString(note.Title, 120, "sticky.title", allowEmpty: true),
            Body = CapabilityJson.OutputString(note.Body, 10_000, "sticky.body", allowEmpty: true),
            updatedAt = note.UpdatedAt.ToString("O", CultureInfo.InvariantCulture)
        });
    }

    private static StickyNoteColor Color(string value)
    {
        return value switch
        {
            "yellow" => StickyNoteColor.Yellow,
            "blue" => StickyNoteColor.Blue,
            "green" => StickyNoteColor.Mint,
            "pink" => StickyNoteColor.Pink,
            "gray" => StickyNoteColor.Lavender,
            _ => throw CapabilityJson.Invalid("color")
        };
    }
}

internal static class ProviderCapabilityCompositionRoot
{
    public static PocketCapabilityHandlerSet Create(
        ICalendarCapabilityDataSource calendarDataSource,
        TimerStore timerStore,
        StickyNotesStore stickyStore)
    {
        return new PocketCapabilityHandlerSet([
            new CalendarListCapabilityHandler(calendarDataSource),
            new CalendarGetCapabilityHandler(calendarDataSource),
            new CalendarCreateCapabilityHandler(calendarDataSource),
            new TimerCapabilityHandler(TimerCapabilityOperation.Start, timerStore),
            new TimerCapabilityHandler(TimerCapabilityOperation.Get, timerStore),
            new TimerCapabilityHandler(TimerCapabilityOperation.Pause, timerStore),
            new TimerCapabilityHandler(TimerCapabilityOperation.Resume, timerStore),
            new TimerCapabilityHandler(TimerCapabilityOperation.Stop, timerStore),
            new StickyCapabilityHandler(StickyCapabilityOperation.Upsert, stickyStore),
            new StickyCapabilityHandler(StickyCapabilityOperation.Get, stickyStore)
        ]);
    }
}
