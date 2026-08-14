using System.Globalization;
using System.Text.Json;
using HoverPocket.Shell.Providers.Calendar;
using HoverPocket.Shell.Providers.Sticky;
using HoverPocket.Shell.Providers.Timer;

namespace HoverPocket.Shell.Capabilities;

internal sealed class CapabilityVerifier
{
    private readonly List<string> _failures = [];

    public int Run()
    {
        try
        {
            VerifyAsync().GetAwaiter().GetResult();
        }
        catch (Exception ex)
        {
            _failures.Add($"unexpected:{ex.GetType().Name}:{ex.Message}");
        }

        if (_failures.Count > 0)
        {
            Console.Error.WriteLine("capability_verify=failed");
            foreach (var failure in _failures)
            {
                Console.Error.WriteLine($"failure={failure}");
            }
            return 1;
        }

        Console.WriteLine("capability_verify=ok");
        Console.WriteLine("capability_handlers=10");
        Console.WriteLine("capability_timer_lifecycle=ok");
        Console.WriteLine("capability_sticky_upsert=ok");
        Console.WriteLine("capability_calendar_readback=ok");
        return 0;
    }

    private async Task VerifyAsync()
    {
        var root = Path.Combine(Path.GetTempPath(), "HoverPocketCapabilityVerify", Guid.NewGuid().ToString("N"));
        try
        {
            var now = DateTimeOffset.FromUnixTimeSeconds(1_800_000_000);
            var clock = new ManualTimerClock(now);
            using var timerStore = new TimerStore(
                Path.Combine(root, "timer"),
                clock,
                new NullTimerAlertSound(),
                enableScheduler: false);
            var stickyRoot = Path.Combine(root, "sticky");
            var stickyStore = new StickyNotesStore(stickyRoot);
            var calendar = new FakeCalendarCapabilityDataSource();
            var handlers = ProviderCapabilityCompositionRoot.Create(calendar, timerStore, stickyStore);
            Require(handlers.Keys.Count == 10, "handler_count");

            await VerifyTimerAsync(handlers, clock, root);
            await VerifyStickyAsync(handlers, stickyRoot);
            await VerifyCalendarAsync(handlers, calendar, now);

            try
            {
                await handlers.InvokeAsync(CapabilityIds.TimerGet, Json(new[] { 1 }));
                _failures.Add("non_object_arguments_accepted");
            }
            catch (CapabilityHandlerException ex) when (ex.Code == "CAPABILITY_ARGUMENT_INVALID")
            {
            }

            try
            {
                await handlers.InvokeAsync(
                    new PocketCapabilityKey("timer.countdown.missing", 1),
                    Json(new { }));
                _failures.Add("unknown_capability_accepted");
            }
            catch (CapabilityHandlerException ex) when (ex.Code == "CAPABILITY_UNKNOWN")
            {
            }
        }
        finally
        {
            if (Directory.Exists(root))
            {
                Directory.Delete(root, recursive: true);
            }
        }
    }

    private async Task VerifyTimerAsync(
        PocketCapabilityHandlerSet handlers,
        ManualTimerClock clock,
        string root)
    {
        var started = await handlers.InvokeAsync(
            CapabilityIds.TimerStart,
            Json(new
            {
                durationSeconds = 86_400,
                title = "Focus",
                sourceRef = "calendar:test"
            }),
            new CapabilityHandlerContext("timer-verifier-key-0001", clock.UtcNow));
        var timerId = started.GetProperty("timerId").GetString() ?? string.Empty;
        Require(Guid.TryParse(timerId, out _), "timer_id");
        Require(started.GetProperty("state").GetString() == "running", "timer_start");
        Require(
            DateTimeOffset.Parse(started.GetProperty("endAt").GetString()!, CultureInfo.InvariantCulture)
                - clock.UtcNow == TimeSpan.FromHours(24),
            "timer_max_duration");

        var idArguments = Json(new { timerId });
        var read = await handlers.InvokeAsync(CapabilityIds.TimerGet, idArguments);
        Require(read.GetRawText() == started.GetRawText(), "timer_readback");

        try
        {
            await handlers.InvokeAsync(CapabilityIds.TimerPause, idArguments);
            _failures.Add("timer_missing_idempotency_accepted");
        }
        catch (CapabilityHandlerException ex) when (ex.Code == "CAPABILITY_ARGUMENT_INVALID" && ex.Field == "idempotencyKey")
        {
        }

        clock.Advance(TimeSpan.FromSeconds(30));
        var paused = await handlers.InvokeAsync(
            CapabilityIds.TimerPause,
            idArguments,
            new CapabilityHandlerContext("timer-verifier-key-0002", clock.UtcNow));
        Require(paused.GetProperty("state").GetString() == "paused", "timer_pause");

        clock.Advance(TimeSpan.FromSeconds(30));
        var resumed = await handlers.InvokeAsync(
            CapabilityIds.TimerResume,
            idArguments,
            new CapabilityHandlerContext("timer-verifier-key-0003", clock.UtcNow));
        Require(resumed.GetProperty("state").GetString() == "running", "timer_resume");

        var stopped = await handlers.InvokeAsync(
            CapabilityIds.TimerStop,
            idArguments,
            new CapabilityHandlerContext("timer-verifier-key-0004", clock.UtcNow));
        Require(stopped.GetProperty("state").GetString() == "stopped", "timer_stop_state");
        Require(stopped.GetProperty("endAt").ValueKind == JsonValueKind.Null, "timer_stop_end");

        var blockedRoot = Path.Combine(root, "blocked-timer");
        File.WriteAllText(blockedRoot, "blocked");
        using var blockedStore = new TimerStore(
            blockedRoot,
            clock,
            new NullTimerAlertSound(),
            enableScheduler: false);
        var blockedHandler = new TimerCapabilityHandler(TimerCapabilityOperation.Start, blockedStore);
        try
        {
            await blockedHandler.HandleAsync(
                Json(new
                {
                    durationSeconds = 60,
                    title = "Blocked",
                    sourceRef = (string?)null
                }),
                new CapabilityHandlerContext("timer-verifier-key-0005", clock.UtcNow));
            _failures.Add("timer_persistence_failure_accepted");
        }
        catch (CapabilityHandlerException ex) when (ex.Code == "CAPABILITY_UNAVAILABLE" && ex.Field == "timer_storage")
        {
        }
        Require(blockedStore.RunningTimers.Count == 0, "timer_persistence_failure_rollback");
    }

    private async Task VerifyStickyAsync(PocketCapabilityHandlerSet handlers, string root)
    {
        var longTitle = string.Concat(Enumerable.Repeat("🧑🏽‍💻", 20));
        Require(longTitle.EnumerateRunes().Count() == 80, "sticky_unicode_scalar_fixture");
        var first = await handlers.InvokeAsync(
            CapabilityIds.StickyUpsert,
            Json(new
            {
                stableKey = "today-focus:purpose",
                title = longTitle,
                body = "Write the note",
                color = "green"
            }),
            new CapabilityHandlerContext("sticky-verifier-key-001", DateTimeOffset.UtcNow));
        var noteId = first.GetProperty("noteId").GetString() ?? string.Empty;

        var second = await handlers.InvokeAsync(
            CapabilityIds.StickyUpsert,
            Json(new
            {
                stableKey = "today-focus:purpose",
                title = longTitle,
                body = "Finish the note",
                color = "blue"
            }),
            new CapabilityHandlerContext("sticky-verifier-key-002", DateTimeOffset.UtcNow));
        Require(second.GetProperty("noteId").GetString() == noteId, "sticky_atomic_upsert");
        Require(second.GetProperty("title").GetString() == longTitle, "sticky_upsert_title_readback");
        Require(second.GetProperty("body").GetString() == "Finish the note", "sticky_upsert_body_readback");

        var read = await handlers.InvokeAsync(CapabilityIds.StickyGet, Json(new { noteId }));
        Require(read.GetProperty("body").GetString() == "Finish the note", "sticky_readback");
        Require(read.GetProperty("title").GetString() == longTitle, "sticky_title_readback");
        var restored = new StickyNotesStore(root);
        Require(Guid.TryParse(noteId, out var parsed), "sticky_id");
        Require(restored.GetNote(parsed)?.StableKey == "today-focus:purpose", "sticky_persistence");
        Require(restored.GetNote(parsed)?.Title == longTitle, "sticky_title_persistence");

        var blockedRoot = Path.Combine(root, "blocked-store");
        File.WriteAllText(blockedRoot, "blocked");
        var blockedStore = new StickyNotesStore(blockedRoot);
        var blockedHandler = new StickyCapabilityHandler(StickyCapabilityOperation.Upsert, blockedStore);
        try
        {
            await blockedHandler.HandleAsync(
                Json(new
                {
                    stableKey = "blocked",
                    title = "Blocked",
                    body = "Must not remain in memory",
                    color = "yellow"
                }),
                new CapabilityHandlerContext("sticky-verifier-key-003", DateTimeOffset.UtcNow));
            _failures.Add("sticky_persistence_failure_accepted");
        }
        catch (CapabilityHandlerException ex) when (ex.Code == "CAPABILITY_UNAVAILABLE" && ex.Field == "sticky_storage")
        {
        }
        Require(blockedStore.Notes.Count == 0, "sticky_persistence_failure_rollback");

        var oversized = stickyStore.CreateNote();
        stickyStore.UpdateNote(
            oversized.Id,
            "Oversized",
            new string('B', 10_001),
            StickyNoteColor.Yellow);
        try
        {
            await handlers.InvokeAsync(CapabilityIds.StickyGet, Json(new { noteId = oversized.Id }));
            _failures.Add("sticky_oversized_readback_accepted");
        }
        catch (CapabilityHandlerException ex) when (ex.Code == "CAPABILITY_READBACK_MISMATCH" && ex.Field == "sticky.body")
        {
        }
    }

    private async Task VerifyCalendarAsync(
        PocketCapabilityHandlerSet handlers,
        FakeCalendarCapabilityDataSource calendar,
        DateTimeOffset now)
    {
        var allDayStart = new DateTimeOffset(2027, 1, 1, 0, 0, 0, TimeSpan.Zero);
        var normalizedAllDay = new CalendarEventDraft(
            "primary",
            null,
            "Multi-day",
            null,
            null,
            allDayStart,
            allDayStart.AddDays(3),
            IsAllDay: true).Normalized();
        Require(normalizedAllDay.End - normalizedAllDay.Start == TimeSpan.FromDays(3), "calendar_all_day_range");
        var offsetAllDay = new DateTimeOffset(2026, 8, 15, 0, 0, 0, TimeSpan.FromHours(9));
        Require(
            GoogleCalendarApiClient.AllDayString(offsetAllDay) == "2026-08-15",
            "calendar_all_day_offset_preserved");

        var longCalendarTitle = string.Concat(Enumerable.Repeat("👨‍👩‍👧‍👦", 40));
        calendar.Seed(new CalendarCapabilityEvent(
            "primary:event-existing",
            "event-existing",
            longCalendarTitle,
            now.AddMinutes(5),
            now.AddMinutes(15)));
        var list = await handlers.InvokeAsync(
            CapabilityIds.CalendarList,
            Json(new { range = "today", timezone = "UTC" }),
            new CapabilityHandlerContext(null, now));
        Require(list.GetProperty("events").GetArrayLength() == 1, "calendar_list");
        var safeTitle = list.GetProperty("events")[0].GetProperty("safeTitle").GetString() ?? string.Empty;
        Require(safeTitle.EnumerateRunes().Count() == 160, "calendar_title_scalar_limit");

        var dstNow = new DateTimeOffset(2026, 3, 8, 12, 0, 0, TimeSpan.Zero);
        await handlers.InvokeAsync(
            CapabilityIds.CalendarList,
            Json(new { range = "today", timezone = "America/New_York" }),
            new CapabilityHandlerContext(null, dstNow));
        Require(calendar.LastListEnd - calendar.LastListStart == TimeSpan.FromHours(23), "calendar_dst_day_range");

        var createArguments = Json(new
        {
            calendarId = "primary",
            title = "Created",
            start = now.AddMinutes(20).ToString("O", CultureInfo.InvariantCulture),
            end = now.AddMinutes(30).ToString("O", CultureInfo.InvariantCulture),
            isAllDay = false,
            location = (string?)null,
            notes = (string?)null
        });
        var created = await handlers.InvokeAsync(
            CapabilityIds.CalendarCreate,
            createArguments,
            new CapabilityHandlerContext("calendar-verifier-key-01", now));
        Require(created.GetProperty("eventId").GetString() == "created-1", "calendar_create_id");
        Require(calendar.IdempotencyKeys.SequenceEqual(["calendar-verifier-key-01"]), "calendar_idempotency_forward");
        Require(calendar.CreatedRequests.LastOrDefault()?.CalendarId == "primary", "calendar_target_forward");

        try
        {
            await handlers.InvokeAsync(CapabilityIds.CalendarCreate, createArguments);
            _failures.Add("calendar_missing_idempotency_accepted");
        }
        catch (CapabilityHandlerException ex) when (ex.Code == "CAPABILITY_ARGUMENT_INVALID" && ex.Field == "idempotencyKey")
        {
        }

        var read = await handlers.InvokeAsync(
            CapabilityIds.CalendarGet,
            Json(new { eventRef = created.GetProperty("eventRef").GetString() }));
        Require(read.GetProperty("safeTitle").GetString() == "Created", "calendar_get");

        calendar.MismatchNextReadback = true;
        try
        {
            await handlers.InvokeAsync(
                CapabilityIds.CalendarCreate,
                createArguments,
                new CapabilityHandlerContext("calendar-verifier-key-02", now));
            _failures.Add("calendar_mismatch_accepted");
        }
        catch (CapabilityHandlerException ex) when (ex.Code == "CAPABILITY_READBACK_MISMATCH")
        {
        }

        calendar.FailNextCreate = true;
        try
        {
            await handlers.InvokeAsync(
                CapabilityIds.CalendarCreate,
                createArguments,
                new CapabilityHandlerContext("calendar-verifier-key-03", now));
            _failures.Add("calendar_timeout_accepted");
        }
        catch (TaskCanceledException)
        {
        }

        calendar.Seed(new CalendarCapabilityEvent(
            new string('r', 257),
            "short",
            "Oversized ref",
            now.AddMinutes(40),
            now.AddMinutes(41)));
        try
        {
            await handlers.InvokeAsync(
                CapabilityIds.CalendarList,
                Json(new { range = "today", timezone = "UTC" }),
                new CapabilityHandlerContext(null, now));
            _failures.Add("calendar_oversized_event_ref_accepted");
        }
        catch (CapabilityHandlerException ex) when (ex.Code == "CAPABILITY_READBACK_MISMATCH" && ex.Field == "calendar.eventRef")
        {
        }

        calendar.Seed(new CalendarCapabilityEvent(
            "primary:oversized-event-id",
            new string('e', 257),
            "Oversized ID",
            now.AddMinutes(42),
            now.AddMinutes(43)));
        try
        {
            await handlers.InvokeAsync(
                CapabilityIds.CalendarGet,
                Json(new { eventRef = "primary:oversized-event-id" }));
            _failures.Add("calendar_oversized_event_id_accepted");
        }
        catch (CapabilityHandlerException ex) when (ex.Code == "CAPABILITY_READBACK_MISMATCH" && ex.Field == "calendar.eventId")
        {
        }
    }

    private void Require(bool condition, string name)
    {
        if (!condition)
        {
            _failures.Add(name);
        }
    }

    private static JsonElement Json<T>(T value)
    {
        return CapabilityJson.From(value);
    }
}

internal sealed class FakeCalendarCapabilityDataSource : ICalendarCapabilityDataSource
{
    private readonly Dictionary<string, CalendarCapabilityEvent> _events = new(StringComparer.Ordinal);
    private int _createCount;

    public List<string> IdempotencyKeys { get; } = [];

    public List<CalendarCapabilityCreateRequest> CreatedRequests { get; } = [];

    public bool MismatchNextReadback { get; set; }

    public bool FailNextCreate { get; set; }

    public DateTimeOffset LastListStart { get; private set; }

    public DateTimeOffset LastListEnd { get; private set; }

    public void Seed(CalendarCapabilityEvent item)
    {
        _events[item.EventRef] = item;
    }

    public Task<IReadOnlyList<CalendarCapabilityEvent>> ListEventsAsync(
        DateTimeOffset start,
        DateTimeOffset end,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        LastListStart = start;
        LastListEnd = end;
        IReadOnlyList<CalendarCapabilityEvent> result = _events.Values
            .Where(item => item.Start < end && item.End > start)
            .OrderBy(item => item.Start)
            .ToArray();
        return Task.FromResult(result);
    }

    public Task<CalendarCapabilityEvent?> GetEventAsync(
        string eventRef,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        _events.TryGetValue(eventRef, out var item);
        if (item is not null && MismatchNextReadback)
        {
            MismatchNextReadback = false;
            item = item with { SafeTitle = item.SafeTitle + " mismatch" };
        }
        return Task.FromResult(item);
    }

    public Task<CalendarCapabilityEvent> CreateEventAsync(
        CalendarCapabilityCreateRequest request,
        string idempotencyKey,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (FailNextCreate)
        {
            FailNextCreate = false;
            throw new TaskCanceledException("fake calendar timeout");
        }
        IdempotencyKeys.Add(idempotencyKey);
        CreatedRequests.Add(request);
        _createCount++;
        var eventId = $"created-{_createCount}";
        var calendarId = request.CalendarId ?? "primary";
        var item = new CalendarCapabilityEvent(
            $"{calendarId}:{eventId}",
            eventId,
            request.Title,
            request.Start,
            request.End);
        _events[item.EventRef] = item;
        return Task.FromResult(item);
    }
}
