using System.Globalization;
using System.Text.Json;
using HoverPocket.Shell.Providers.Calendar;
using HoverPocket.Shell.Providers.Controls;
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
        Console.WriteLine("capability_handlers=21");
        Console.WriteLine("capability_calculator_evaluate=ok");
        Console.WriteLine("capability_controls_readback=ok");
        Console.WriteLine("capability_timer_lifecycle=ok");
        Console.WriteLine("capability_sticky_upsert=ok");
        Console.WriteLine("capability_sticky_lifecycle=ok");
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
            var alertSound = new NullTimerAlertSound();
            using var timerStore = new TimerStore(
                Path.Combine(root, "timer"),
                clock,
                alertSound,
                enableScheduler: false);
            var stickyRoot = Path.Combine(root, "sticky");
            var stickyStore = new StickyNotesStore(stickyRoot);
            var calendar = new FakeCalendarCapabilityDataSource();
            var controls = new FakeControlsCapabilityDataSource();
            var handlers = ProviderCapabilityCompositionRoot.Create(calendar, timerStore, stickyStore, controls);
            Require(handlers.Keys.Count == 21, "handler_count");
            await VerifyCalculatorAsync(handlers);
            await VerifyControlsAsync(handlers, controls);

            await VerifyTimerAsync(handlers, timerStore, alertSound, clock, root);
            await VerifyStickyAsync(handlers, stickyStore, stickyRoot);
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

    private async Task VerifyCalculatorAsync(PocketCapabilityHandlerSet handlers)
    {
        var vectors = new[]
        {
            (Expression: "1 + 2 * 3", Normalized: "1 + 2 * 3", Result: "7"),
            (Expression: "1 / 3", Normalized: "1 / 3", Result: "0.333333333333"),
            (Expression: "-5 + 2.5", Normalized: "-5 + 2.5", Result: "-2.5"),
            (Expression: "1,5 × 2", Normalized: "1.5 * 2", Result: "3")
        };
        foreach (var vector in vectors)
        {
            var output = await handlers.InvokeAsync(
                CapabilityIds.CalculatorEvaluate,
                Json(new { expression = vector.Expression }));
            Require(output.GetProperty("normalizedExpression").GetString() == vector.Normalized, $"calculator_normalized_{vector.Expression}");
            Require(output.GetProperty("result").GetString() == vector.Result, $"calculator_result_{vector.Expression}");
        }

        foreach (var invalid in new[] { "1 / 0", "1 +", "2 ** 3", "999999999999999999 + 1" })
        {
            try
            {
                _ = await handlers.InvokeAsync(
                    CapabilityIds.CalculatorEvaluate,
                    Json(new { expression = invalid }));
                _failures.Add("calculator_invalid_accepted");
            }
            catch (CapabilityHandlerException ex) when (ex.Code == "CAPABILITY_ARGUMENT_INVALID")
            {
            }
        }
    }

    private async Task VerifyControlsAsync(
        PocketCapabilityHandlerSet handlers,
        FakeControlsCapabilityDataSource controls)
    {
        var available = await handlers.InvokeAsync(CapabilityIds.ControlsAvailability, Json(new { }));
        Require(available.GetProperty("volumeAvailable").GetBoolean(), "controls_volume_available");
        Require(available.GetProperty("brightnessAvailable").GetBoolean(), "controls_brightness_available");
        Require(available.GetProperty("mediaAvailable").GetBoolean(), "controls_media_available");
        Require(
            available.GetProperty("displayIds").EnumerateArray().Select(item => item.GetString()).SequenceEqual(["display-1"]),
            "controls_display_ids");

        var initial = await handlers.InvokeAsync(CapabilityIds.ControlsVolumeGet, Json(new { }));
        Require(Math.Abs(initial.GetProperty("level").GetDouble() - 0.3) < 0.001, "controls_volume_get");
        Require(!initial.GetProperty("muted").GetBoolean(), "controls_mute_get");

        var volume = await handlers.InvokeAsync(
            CapabilityIds.ControlsVolumeSet,
            Json(new { level = 0.7 }),
            new CapabilityHandlerContext("controls-verifier-key-0001", DateTimeOffset.UtcNow));
        Require(Math.Abs(volume.GetProperty("level").GetDouble() - 0.7) < 0.001, "controls_volume_set");

        var muted = await handlers.InvokeAsync(
            CapabilityIds.ControlsMuteSet,
            Json(new { muted = true }),
            new CapabilityHandlerContext("controls-verifier-key-0002", DateTimeOffset.UtcNow));
        Require(muted.GetProperty("muted").GetBoolean(), "controls_mute_set");

        var mutedVolume = await handlers.InvokeAsync(
            CapabilityIds.ControlsVolumeSet,
            Json(new { level = 0.4 }),
            new CapabilityHandlerContext("controls-verifier-key-0002b", DateTimeOffset.UtcNow));
        Require(mutedVolume.GetProperty("muted").GetBoolean(), "controls_volume_preserves_mute");

        var brightness = await handlers.InvokeAsync(
            CapabilityIds.ControlsBrightnessSet,
            Json(new { displayId = "display-1", level = 0.6 }),
            new CapabilityHandlerContext("controls-verifier-key-0003", DateTimeOffset.UtcNow));
        Require(brightness.GetProperty("displayId").GetString() == "display-1", "controls_brightness_id");
        Require(Math.Abs(brightness.GetProperty("level").GetDouble() - 0.6) < 0.001, "controls_brightness_set");

        var brightnessReadback = await handlers.InvokeAsync(
            CapabilityIds.ControlsBrightnessGet,
            Json(new { displayId = "display-1" }));
        Require(brightnessReadback.GetProperty("displayId").GetString() == "display-1", "controls_brightness_get_id");
        Require(Math.Abs(brightnessReadback.GetProperty("level").GetDouble() - 0.6) < 0.001, "controls_brightness_get");

        var media = await handlers.InvokeAsync(
            CapabilityIds.ControlsMediaCommand,
            Json(new { command = "play_pause" }),
            new CapabilityHandlerContext("controls-verifier-key-0004", DateTimeOffset.UtcNow));
        Require(media.GetProperty("available").GetBoolean(), "controls_media_available_output");
        Require(media.GetProperty("isPlaying").GetBoolean(), "controls_media_play_pause");
        Require(media.GetProperty("safeTitle").GetString() == "Track A", "controls_media_safe_title");

        try
        {
            await handlers.InvokeAsync(CapabilityIds.ControlsVolumeSet, Json(new { level = 0.5 }));
            _failures.Add("controls_missing_idempotency_accepted");
        }
        catch (CapabilityHandlerException ex) when (ex.Code == "CAPABILITY_ARGUMENT_INVALID" && ex.Field == "idempotencyKey")
        {
        }

        controls.MismatchNextVolume = true;
        try
        {
            await handlers.InvokeAsync(
                CapabilityIds.ControlsVolumeSet,
                Json(new { level = 0.2 }),
                new CapabilityHandlerContext("controls-verifier-key-0005", DateTimeOffset.UtcNow));
            _failures.Add("controls_volume_mismatch_accepted");
        }
        catch (CapabilityHandlerException ex) when (ex.Code == "CAPABILITY_READBACK_MISMATCH" && ex.Field == "controls.volume")
        {
        }

        controls.ChangeMuteOnNextVolume = true;
        try
        {
            await handlers.InvokeAsync(
                CapabilityIds.ControlsVolumeSet,
                Json(new { level = 0.25 }),
                new CapabilityHandlerContext("controls-verifier-key-0006", DateTimeOffset.UtcNow));
            _failures.Add("controls_hidden_mute_change_accepted");
        }
        catch (CapabilityHandlerException ex) when (ex.Code == "CAPABILITY_READBACK_MISMATCH" && ex.Field == "controls.volume")
        {
        }

        controls.ProgressOnlyNextMediaChange = true;
        try
        {
            await handlers.InvokeAsync(
                CapabilityIds.ControlsMediaCommand,
                Json(new { command = "next" }),
                new CapabilityHandlerContext("controls-verifier-key-0007", DateTimeOffset.UtcNow));
            _failures.Add("controls_progress_only_media_change_accepted");
        }
        catch (CapabilityHandlerException ex) when (ex.Code == "CAPABILITY_READBACK_MISMATCH" && ex.Field == "controls.media")
        {
        }

        controls.LongMetadataNextMediaChange = true;
        var boundedMedia = await handlers.InvokeAsync(
            CapabilityIds.ControlsMediaCommand,
            Json(new { command = "next" }),
            new CapabilityHandlerContext("controls-verifier-key-0008", DateTimeOffset.UtcNow));
        Require(boundedMedia.GetProperty("safeTitle").GetString()?.Length == 160, "controls_media_title_bounded");
        Require(boundedMedia.GetProperty("safeSource").GetString()?.Length == 120, "controls_media_source_bounded");

        controls.UnsafeMetadataNextMediaChange = true;
        var sanitizedMedia = await handlers.InvokeAsync(
            CapabilityIds.ControlsMediaCommand,
            Json(new { command = "next" }),
            new CapabilityHandlerContext("controls-verifier-key-0009", DateTimeOffset.UtcNow));
        Require(sanitizedMedia.GetProperty("safeTitle").GetString() == "Track spoof", "controls_media_title_sanitized");
        Require(sanitizedMedia.GetProperty("safeSource").GetString() == "Source name", "controls_media_source_sanitized");
    }

    private async Task VerifyTimerAsync(
        PocketCapabilityHandlerSet handlers,
        TimerStore timerStore,
        NullTimerAlertSound alertSound,
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

        var expiring = await handlers.InvokeAsync(
            CapabilityIds.TimerStart,
            Json(new
            {
                durationSeconds = 1,
                title = "Expiring",
                sourceRef = (string?)null
            }),
            new CapabilityHandlerContext("timer-verifier-key-0005", clock.UtcNow));
        var expiringId = Guid.Parse(expiring.GetProperty("timerId").GetString()!);
        clock.Advance(TimeSpan.FromSeconds(2));
        timerStore.CheckExpired();
        Require(timerStore.GetSnapshot().ActiveAlert?.Id == expiringId, "timer_expired_alert_fixture");
        var stopCountBefore = alertSound.StopCount;
        var expiredStopped = await handlers.InvokeAsync(
            CapabilityIds.TimerStop,
            Json(new { timerId = expiringId }),
            new CapabilityHandlerContext("timer-verifier-key-0006", clock.UtcNow));
        Require(expiredStopped.GetProperty("state").GetString() == "stopped", "timer_expired_stop_state");
        Require(timerStore.GetSnapshot().ActiveAlert is null, "timer_expired_alert_cleared");
        Require(alertSound.StopCount == stopCountBefore + 1, "timer_expired_sound_stopped");

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
                new CapabilityHandlerContext("timer-verifier-key-0007", clock.UtcNow));
            _failures.Add("timer_persistence_failure_accepted");
        }
        catch (CapabilityHandlerException ex) when (ex.Code == "CAPABILITY_UNAVAILABLE" && ex.Field == "timer_storage")
        {
        }
        Require(blockedStore.RunningTimers.Count == 0, "timer_persistence_failure_rollback");
    }

    private async Task VerifyStickyAsync(
        PocketCapabilityHandlerSet handlers,
        StickyNotesStore stickyStore,
        string root)
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

        var archiveTime = DateTimeOffset.FromUnixTimeSeconds(1_800_000_200);
        var idArguments = Json(new { noteId });
        var archived = await handlers.InvokeAsync(
            CapabilityIds.StickyArchive,
            idArguments,
            new CapabilityHandlerContext("sticky-verifier-key-003", archiveTime));
        Require(archived.GetProperty("state").GetString() == "archived", "sticky_archive");
        Require(
            DateTimeOffset.Parse(archived.GetProperty("updatedAt").GetString()!, CultureInfo.InvariantCulture) == archiveTime,
            "sticky_archive_time");
        var archivedStatus = await handlers.InvokeAsync(CapabilityIds.StickyStatus, idArguments);
        Require(archivedStatus.GetRawText() == archived.GetRawText(), "sticky_archive_readback");
        Require(new StickyNotesStore(root).GetNote(parsed)?.ArchivedAt == archiveTime, "sticky_archive_persistence");

        var deleted = await handlers.InvokeAsync(
            CapabilityIds.StickyDelete,
            idArguments,
            new CapabilityHandlerContext("sticky-verifier-key-004", archiveTime.AddSeconds(1)));
        Require(deleted.GetProperty("state").GetString() == "missing", "sticky_delete");
        Require(deleted.GetProperty("updatedAt").ValueKind == JsonValueKind.Null, "sticky_delete_time");
        var deletedStatus = await handlers.InvokeAsync(CapabilityIds.StickyStatus, idArguments);
        Require(deletedStatus.GetRawText() == deleted.GetRawText(), "sticky_delete_readback");
        Require(new StickyNotesStore(root).GetNote(parsed) is null, "sticky_delete_persistence");

        try
        {
            await handlers.InvokeAsync(CapabilityIds.StickyStatus, Json(new { noteId = "not-a-uuid" }));
            _failures.Add("sticky_invalid_id_accepted");
        }
        catch (CapabilityHandlerException ex) when (ex.Code == "CAPABILITY_ARGUMENT_INVALID" && ex.Field == "noteId")
        {
        }

        var blockedRoot = Path.Combine(root, "blocked-store");
        File.WriteAllText(blockedRoot, "blocked");
        var blockedStore = new StickyNotesStore(blockedRoot);
        var blockedHandler = new StickyCapabilityHandler(StickyCapabilityOperation.Upsert, blockedStore);
        try
        {
            await blockedHandler.HandleAsync(
                Json(new
                {
                    stableKey = "verify:blocked",
                    title = "Blocked",
                    body = "Must not remain in memory",
                    color = "yellow"
                }),
                new CapabilityHandlerContext("sticky-verifier-key-005", DateTimeOffset.UtcNow));
            _failures.Add("sticky_persistence_failure_accepted");
        }
        catch (CapabilityHandlerException ex) when (ex.Code == "CAPABILITY_UNAVAILABLE" && ex.Field == "sticky_storage")
        {
        }
        Require(blockedStore.Notes.Count == 0, "sticky_persistence_failure_rollback");

        await VerifyStickyLifecyclePersistenceFailureAsync(Path.Combine(root, "blocked-lifecycle"));

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

    private async Task VerifyStickyLifecyclePersistenceFailureAsync(string root)
    {
        var store = new StickyNotesStore(root);
        var note = store.UpsertNote("failure-fixture", "Failure fixture", "Must survive", StickyNoteColor.Yellow);
        Directory.Delete(root, recursive: true);
        File.WriteAllText(root, "blocked");

        var archive = new StickyCapabilityHandler(StickyCapabilityOperation.Archive, store);
        try
        {
            await archive.HandleAsync(
                Json(new { noteId = note.Id }),
                new CapabilityHandlerContext("sticky-verifier-key-006", DateTimeOffset.UtcNow));
            _failures.Add("sticky_archive_failure_accepted");
        }
        catch (CapabilityHandlerException ex) when (ex.Code == "CAPABILITY_UNAVAILABLE" && ex.Field == "sticky_storage")
        {
        }
        Require(store.GetNote(note.Id)?.ArchivedAt is null, "sticky_archive_failure_rollback");

        var delete = new StickyCapabilityHandler(StickyCapabilityOperation.Delete, store);
        try
        {
            await delete.HandleAsync(
                Json(new { noteId = note.Id }),
                new CapabilityHandlerContext("sticky-verifier-key-007", DateTimeOffset.UtcNow));
            _failures.Add("sticky_delete_failure_accepted");
        }
        catch (CapabilityHandlerException ex) when (ex.Code == "CAPABILITY_UNAVAILABLE" && ex.Field == "sticky_storage")
        {
        }
        Require(store.GetNote(note.Id) is not null, "sticky_delete_failure_rollback");
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
        var writableSources = new[]
        {
            new CalendarSource("primary", "Primary", null, "UTC", IsPrimary: true, AccessRole: "owner")
        };
        Require(
            CalendarStore.SelectWritableSourceForCapability(writableSources, null).Id == "primary",
            "calendar_implicit_target_fallback");
        try
        {
            CalendarStore.SelectWritableSourceForCapability(writableSources, string.Empty);
            _failures.Add("calendar_empty_explicit_target_accepted");
        }
        catch (GoogleCalendarApiException ex) when (ex.Code == "calendar_read_only")
        {
        }

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

        calendar.Seed(new CalendarCapabilityEvent(
            "primary:all-day-aug14",
            "all-day-aug14",
            "August 14",
            new DateTimeOffset(2026, 8, 14, 7, 0, 0, TimeSpan.Zero),
            new DateTimeOffset(2026, 8, 15, 7, 0, 0, TimeSpan.Zero),
            IsAllDay: true,
            AllDayStart: new DateOnly(2026, 8, 14),
            AllDayEnd: new DateOnly(2026, 8, 15)));
        calendar.Seed(new CalendarCapabilityEvent(
            "primary:all-day-aug15",
            "all-day-aug15",
            "August 15",
            new DateTimeOffset(2026, 8, 15, 7, 0, 0, TimeSpan.Zero),
            new DateTimeOffset(2026, 8, 16, 7, 0, 0, TimeSpan.Zero),
            IsAllDay: true,
            AllDayStart: new DateOnly(2026, 8, 15),
            AllDayEnd: new DateOnly(2026, 8, 16)));
        var civilList = await handlers.InvokeAsync(
            CapabilityIds.CalendarList,
            Json(new { range = "today", timezone = "Asia/Tokyo" }),
            new CapabilityHandlerContext(
                null,
                new DateTimeOffset(2026, 8, 15, 3, 0, 0, TimeSpan.Zero)));
        var civilRefs = civilList.GetProperty("events")
            .EnumerateArray()
            .Select(item => item.GetProperty("eventRef").GetString())
            .ToArray();
        Require(civilRefs.SequenceEqual(["primary:all-day-aug15"]), "calendar_all_day_civil_filter");

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

        var crossOffsetAllDay = await handlers.InvokeAsync(
            CapabilityIds.CalendarCreate,
            Json(new
            {
                calendarId = "primary",
                title = "Civil date range",
                start = "2026-08-15T00:00:00-12:00",
                end = "2026-08-16T00:00:00+14:00",
                isAllDay = true,
                location = (string?)null,
                notes = (string?)null
            }),
            new CapabilityHandlerContext("calendar-verifier-key-civil-date", now));
        Require(
            crossOffsetAllDay.GetProperty("eventId").GetString() == "created-2",
            "calendar_all_day_civil_range");
        Require(
            calendar.CreatedRequests.Last().Start.Date == new DateTime(2026, 8, 15)
                && calendar.CreatedRequests.Last().End.Date == new DateTime(2026, 8, 16),
            "calendar_all_day_civil_dates_preserved");

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
            request.End,
            request.IsAllDay,
            request.IsAllDay ? DateOnly.FromDateTime(request.Start.Date) : null,
            request.IsAllDay ? DateOnly.FromDateTime(request.End.Date) : null);
        _events[item.EventRef] = item;
        return Task.FromResult(item);
    }
}

internal sealed class FakeControlsCapabilityDataSource : IControlsCapabilityDataSource
{
    private int _volume = 30;
    private bool _muted;
    private int _brightness = 40;
    private MediaSessionState _media = Media(
        title: "Track A",
        isPlaying: false,
        positionSeconds: 10);

    public bool MismatchNextVolume { get; set; }
    public bool ChangeMuteOnNextVolume { get; set; }
    public bool ProgressOnlyNextMediaChange { get; set; }
    public bool LongMetadataNextMediaChange { get; set; }
    public bool UnsafeMetadataNextMediaChange { get; set; }

    public Task<ControlsSnapshot> GetSnapshotAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return Task.FromResult(Snapshot());
    }

    public Task<ControlsSnapshot> SetVolumeAsync(int value, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (MismatchNextVolume)
        {
            MismatchNextVolume = false;
            _volume = Math.Clamp(value + 20, 0, 100);
        }
        else
        {
            _volume = value;
        }
        if (ChangeMuteOnNextVolume)
        {
            ChangeMuteOnNextVolume = false;
            _muted = !_muted;
        }
        return Task.FromResult(Snapshot());
    }

    public Task<ControlsSnapshot> SetMutedAsync(bool muted, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        _muted = muted;
        return Task.FromResult(Snapshot());
    }

    public Task<ControlsSnapshot> SetBrightnessAsync(
        string displayId,
        int value,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!string.Equals(displayId, "display-1", StringComparison.Ordinal))
        {
            return Task.FromResult(Snapshot());
        }
        _brightness = value;
        return Task.FromResult(Snapshot());
    }

    public Task<ControlsSnapshot> ExecuteMediaCommandAsync(string command, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (ProgressOnlyNextMediaChange && command is "next" or "previous")
        {
            ProgressOnlyNextMediaChange = false;
            _media = _media with { PositionSeconds = _media.PositionSeconds + 2 };
        }
        else if (LongMetadataNextMediaChange && command is "next" or "previous")
        {
            LongMetadataNextMediaChange = false;
            _media = _media with
            {
                Title = new string('T', 200),
                Source = new string('S', 140),
                PositionSeconds = 0
            };
        }
        else if (UnsafeMetadataNextMediaChange && command is "next" or "previous")
        {
            UnsafeMetadataNextMediaChange = false;
            _media = _media with
            {
                Title = "Track\u202Espoof",
                Source = "Source\nname",
                PositionSeconds = 0
            };
        }
        else
        {
            _media = command switch
            {
                "play_pause" => _media with { IsPlaying = !_media.IsPlaying },
                "next" => _media with { Title = "Track B", PositionSeconds = 0 },
                "previous" => _media with { Title = "Track Previous", PositionSeconds = 0 },
                _ => _media
            };
        }
        return Task.FromResult(Snapshot());
    }

    private ControlsSnapshot Snapshot() => new(
        [new DisplayBrightnessState("display-1", "Display", true, _brightness, WriteVerified: true)],
        new VolumeState(true, _volume, _muted),
        _media,
        MediaPreviewState.Inactive,
        DateTimeOffset.UtcNow);

    private static MediaSessionState Media(string title, bool isPlaying, double positionSeconds) => new(
        true,
        title,
        "Artist",
        "Music",
        null,
        positionSeconds,
        180,
        isPlaying,
        1,
        true,
        true,
        false,
        true,
        true,
        "music",
        null);
}
