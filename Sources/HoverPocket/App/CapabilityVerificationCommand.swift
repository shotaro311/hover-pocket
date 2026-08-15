import Darwin
import Foundation

enum CapabilityVerificationCommand {
    @MainActor
    static func run() -> Never {
        Task { @MainActor in
            do {
                try await verify()
                print("capability_verify=ok")
                print("capability_handlers=14")
                print("capability_calculator_evaluate=ok")
                print("capability_timer_lifecycle=ok")
                print("capability_sticky_upsert=ok")
                print("capability_sticky_lifecycle=ok")
                print("capability_calendar_readback=ok")
                Darwin.exit(0)
            } catch {
                fputs("capability_verify=failed\n", stderr)
                fputs("error=\(String(describing: error))\n", stderr)
                Darwin.exit(1)
            }
        }
        RunLoop.main.run()
        Darwin.exit(1)
    }

    @MainActor
    private static func verify() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hoverpocket-capability-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let timerStore = TimerStore(
            storageDirectory: root.appendingPathComponent("timer", isDirectory: true),
            observesWake: false,
            persistenceEnabled: true
        )
        let stickyRoot = root.appendingPathComponent("sticky", isDirectory: true)
        let stickyStore = StickyNotesStore(storageDirectory: stickyRoot)
        let calendar = FakeCalendarCapabilityDataSource()
        let timerID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let noteID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let handlers = try PocketCapabilityHandlerSet(handlers: [
            CalendarListCapabilityHandler(dataSource: calendar),
            CalendarGetCapabilityHandler(dataSource: calendar),
            CalendarCreateCapabilityHandler(dataSource: calendar),
            CalculatorEvaluateCapabilityHandler(),
            TimerCapabilityHandler(operation: .start, store: timerStore, idGenerator: { timerID }),
            TimerCapabilityHandler(operation: .get, store: timerStore),
            TimerCapabilityHandler(operation: .pause, store: timerStore),
            TimerCapabilityHandler(operation: .resume, store: timerStore),
            TimerCapabilityHandler(operation: .stop, store: timerStore),
            StickyCapabilityHandler(operation: .upsert, store: stickyStore, idGenerator: { noteID }),
            StickyCapabilityHandler(operation: .get, store: stickyStore),
            StickyCapabilityHandler(operation: .status, store: stickyStore),
            StickyCapabilityHandler(operation: .archive, store: stickyStore),
            StickyCapabilityHandler(operation: .delete, store: stickyStore)
        ])

        guard handlers.keys.count == 14 else {
            throw VerificationFailure("handler_count")
        }
        try await verifyCalculator(handlers: handlers)
        try await verifyTimer(handlers: handlers, timerID: timerID)
        try await verifyTimerPersistenceFailure(root: root)
        try await verifySticky(handlers: handlers, noteID: noteID, root: stickyRoot)
        try await verifyCalendar(handlers: handlers, dataSource: calendar)

        do {
            _ = try await handlers.invoke(
                PocketCapabilityKey(id: "timer.countdown.missing", version: 1),
                arguments: [:]
            )
            throw VerificationFailure("unknown_capability_accepted")
        } catch CapabilityHandlerError.unknownCapability {
        }
    }

    @MainActor
    private static func verifyCalculator(handlers: PocketCapabilityHandlerSet) async throws {
        let vectors: [(String, String, String)] = [
            ("1 + 2 * 3", "1 + 2 * 3", "7"),
            ("1 / 3", "1 / 3", "0.333333333333"),
            ("-5 + 2.5", "-5 + 2.5", "-2.5"),
            ("1,5 × 2", "1.5 * 2", "3")
        ]
        for (expression, normalized, result) in vectors {
            let output = try await handlers.invoke(
                PocketCapabilityKeys.calculatorEvaluate,
                arguments: ["expression": .string(expression)]
            )
            try require(output == [
                "normalizedExpression": .string(normalized),
                "result": .string(result)
            ], "calculator_\(expression)")
        }

        for invalid in ["1 / 0", "1 +", "2 ** 3", "999999999999999999 + 1"] {
            do {
                _ = try await handlers.invoke(
                    PocketCapabilityKeys.calculatorEvaluate,
                    arguments: ["expression": .string(invalid)]
                )
                throw VerificationFailure("calculator_invalid_accepted")
            } catch CapabilityHandlerError.invalidArgument(let field) where field == "expression" {
            }
        }
    }

    @MainActor
    private static func verifyTimer(
        handlers: PocketCapabilityHandlerSet,
        timerID: UUID
    ) async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let started = try await handlers.invoke(
            PocketCapabilityKey(id: "timer.countdown.start", version: 1),
            arguments: [
                "durationSeconds": .integer(86_400),
                "title": .string("Focus"),
                "sourceRef": .string("calendar:test")
            ],
            context: CapabilityHandlerContext(
                idempotencyKey: "timer-verifier-key-0001",
                now: now
            )
        )
        try require(started["timerId"] == .string(timerID.uuidString.lowercased()), "timer_id")
        try require(started["state"] == .string("running"), "timer_started")
        try require(
            started["endAt"] == .string(CapabilityDateCodec.string(from: now.addingTimeInterval(86_400))),
            "timer_max_duration"
        )

        let idArguments: CapabilityObject = ["timerId": .string(timerID.uuidString)]
        let read = try await handlers.invoke(
            PocketCapabilityKey(id: "timer.countdown.get", version: 1),
            arguments: idArguments,
            context: CapabilityHandlerContext(now: now)
        )
        try require(read == started, "timer_readback")

        do {
            _ = try await handlers.invoke(
                PocketCapabilityKey(id: "timer.countdown.pause", version: 1),
                arguments: idArguments,
                context: CapabilityHandlerContext(now: now)
            )
            throw VerificationFailure("timer_missing_idempotency_accepted")
        } catch CapabilityHandlerError.invalidArgument(let field) where field == "idempotencyKey" {
        }

        let paused = try await handlers.invoke(
            PocketCapabilityKey(id: "timer.countdown.pause", version: 1),
            arguments: idArguments,
            context: CapabilityHandlerContext(
                idempotencyKey: "timer-verifier-key-0002",
                now: now.addingTimeInterval(30)
            )
        )
        try require(paused["state"] == .string("paused"), "timer_pause")

        let resumed = try await handlers.invoke(
            PocketCapabilityKey(id: "timer.countdown.resume", version: 1),
            arguments: idArguments,
            context: CapabilityHandlerContext(
                idempotencyKey: "timer-verifier-key-0003",
                now: now.addingTimeInterval(60)
            )
        )
        try require(resumed["state"] == .string("running"), "timer_resume")

        let stopped = try await handlers.invoke(
            PocketCapabilityKey(id: "timer.countdown.stop", version: 1),
            arguments: idArguments,
            context: CapabilityHandlerContext(
                idempotencyKey: "timer-verifier-key-0004",
                now: now.addingTimeInterval(90)
            )
        )
        try require(stopped["state"] == .string("stopped") && stopped["endAt"] == .null, "timer_stop")
    }

    @MainActor
    private static func verifyTimerPersistenceFailure(root: URL) async throws {
        let blockedRoot = root.appendingPathComponent("blocked-timer", isDirectory: false)
        try Data("blocked".utf8).write(to: blockedRoot)
        let store = TimerStore(storageDirectory: blockedRoot, observesWake: false)
        let handler = TimerCapabilityHandler(operation: .start, store: store)
        do {
            _ = try await handler.handle(
                arguments: [
                    "durationSeconds": .integer(60),
                    "title": .string("Blocked"),
                    "sourceRef": .null
                ],
                context: CapabilityHandlerContext(idempotencyKey: "timer-verifier-key-0005")
            )
            throw VerificationFailure("timer_persistence_failure_accepted")
        } catch CapabilityHandlerError.unavailable(let field) where field == "timer_storage" {
        }
        try require(store.runningTimers.isEmpty, "timer_persistence_failure_rollback")
    }

    @MainActor
    private static func verifySticky(
        handlers: PocketCapabilityHandlerSet,
        noteID: UUID,
        root: URL
    ) async throws {
        let firstTime = Date(timeIntervalSince1970: 1_800_000_100)
        let longTitle = String(repeating: "🧑🏽‍💻", count: 20)
        try require(longTitle.unicodeScalars.count == 80, "sticky_unicode_scalar_fixture")
        let first = try await handlers.invoke(
            PocketCapabilityKey(id: "sticky.note.upsert", version: 1),
            arguments: [
                "stableKey": .string("today-focus:purpose"),
                "title": .string(longTitle),
                "body": .string("Write the note"),
                "color": .string("green")
            ],
            context: CapabilityHandlerContext(
                idempotencyKey: "sticky-verifier-key-001",
                now: firstTime
            )
        )
        try require(first["noteId"] == .string(noteID.uuidString.lowercased()), "sticky_id")

        let secondTime = firstTime.addingTimeInterval(1)
        let second = try await handlers.invoke(
            PocketCapabilityKey(id: "sticky.note.upsert", version: 1),
            arguments: [
                "stableKey": .string("today-focus:purpose"),
                "title": .string(longTitle),
                "body": .string("Finish the note"),
                "color": .string("blue")
            ],
            context: CapabilityHandlerContext(
                idempotencyKey: "sticky-verifier-key-002",
                now: secondTime
            )
        )
        try require(second["noteId"] == first["noteId"], "sticky_atomic_upsert")
        try require(second["title"] == .string(longTitle), "sticky_upsert_title_readback")
        try require(second["body"] == .string("Finish the note"), "sticky_upsert_body_readback")

        let read = try await handlers.invoke(
            PocketCapabilityKey(id: "sticky.note.get", version: 1),
            arguments: ["noteId": .string(noteID.uuidString)]
        )
        try require(read["body"] == .string("Finish the note"), "sticky_readback")
        try require(read["title"] == .string(longTitle), "sticky_title_readback")

        let restored = StickyNotesStore(storageDirectory: root)
        try require(restored.note(id: noteID)?.stableKey == "today-focus:purpose", "sticky_persistence")
        try require(restored.note(id: noteID)?.title == longTitle, "sticky_title_persistence")

        let archivedAt = secondTime.addingTimeInterval(1)
        let idArguments: CapabilityObject = ["noteId": .string(noteID.uuidString)]
        let archived = try await handlers.invoke(
            PocketCapabilityKeys.stickyArchive,
            arguments: idArguments,
            context: CapabilityHandlerContext(
                idempotencyKey: "sticky-verifier-key-003",
                now: archivedAt
            )
        )
        try require(archived["state"] == .string("archived"), "sticky_archive")
        try require(
            archived["updatedAt"] == .string(CapabilityDateCodec.string(from: archivedAt)),
            "sticky_archive_time"
        )
        let archivedStatus = try await handlers.invoke(PocketCapabilityKeys.stickyStatus, arguments: idArguments)
        try require(archivedStatus == archived, "sticky_archive_readback")
        let archivedRestored = StickyNotesStore(storageDirectory: root)
        try require(archivedRestored.note(id: noteID)?.archivedAt == archivedAt, "sticky_archive_persistence")

        let deleted = try await handlers.invoke(
            PocketCapabilityKeys.stickyDelete,
            arguments: idArguments,
            context: CapabilityHandlerContext(idempotencyKey: "sticky-verifier-key-004")
        )
        try require(deleted["state"] == .string("missing") && deleted["updatedAt"] == .null, "sticky_delete")
        let deletedStatus = try await handlers.invoke(PocketCapabilityKeys.stickyStatus, arguments: idArguments)
        try require(deletedStatus == deleted, "sticky_delete_readback")
        try require(StickyNotesStore(storageDirectory: root).note(id: noteID) == nil, "sticky_delete_persistence")

        do {
            _ = try await handlers.invoke(
                PocketCapabilityKeys.stickyStatus,
                arguments: ["noteId": .string("not-a-uuid")]
            )
            throw VerificationFailure("sticky_invalid_id_accepted")
        } catch CapabilityHandlerError.invalidArgument(let field) where field == "noteId" {
        }

        let blockedRoot = root.appendingPathComponent("blocked-store", isDirectory: false)
        try Data("blocked".utf8).write(to: blockedRoot)
        let blockedStore = StickyNotesStore(storageDirectory: blockedRoot)
        let blockedHandler = StickyCapabilityHandler(operation: .upsert, store: blockedStore)
        do {
            _ = try await blockedHandler.handle(
                arguments: [
                    "stableKey": .string("verify:blocked"),
                    "title": .string("Blocked"),
                    "body": .string("Must not remain in memory"),
                    "color": .string("yellow")
                ],
                context: CapabilityHandlerContext(idempotencyKey: "sticky-verifier-key-005")
            )
            throw VerificationFailure("sticky_persistence_failure_accepted")
        } catch CapabilityHandlerError.unavailable(let field) where field == "sticky_storage" {
        }
        try require(blockedStore.notes.isEmpty, "sticky_persistence_failure_rollback")

        try await verifyStickyLifecyclePersistenceFailure(
            root: root.appendingPathComponent("blocked-lifecycle", isDirectory: true)
        )

        let postDeleteStore = StickyNotesStore(storageDirectory: root)
        let oversized = postDeleteStore.createNote()
        _ = postDeleteStore.updateNote(
            id: oversized.id,
            title: String(repeating: "T", count: 121),
            body: String(repeating: "B", count: 10_001),
            color: .yellow
        )
        let oversizedHandler = StickyCapabilityHandler(operation: .get, store: postDeleteStore)
        do {
            _ = try await oversizedHandler.handle(
                arguments: ["noteId": .string(oversized.id.uuidString)],
                context: CapabilityHandlerContext()
            )
            throw VerificationFailure("sticky_oversized_readback_accepted")
        } catch CapabilityHandlerError.readbackMismatch(let field) where field == "sticky.note" {
        }
    }

    @MainActor
    private static func verifyStickyLifecyclePersistenceFailure(root: URL) async throws {
        let noteID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        let store = StickyNotesStore(storageDirectory: root)
        _ = try store.upsertNote(
            stableKey: "failure-fixture",
            title: "Failure fixture",
            body: "Must survive",
            color: .yellow,
            id: noteID,
            at: Date(timeIntervalSince1970: 1_800_000_200)
        )
        try FileManager.default.removeItem(at: root)
        try Data("blocked".utf8).write(to: root)

        let archive = StickyCapabilityHandler(operation: .archive, store: store)
        do {
            _ = try await archive.handle(
                arguments: ["noteId": .string(noteID.uuidString)],
                context: CapabilityHandlerContext(idempotencyKey: "sticky-verifier-key-006")
            )
            throw VerificationFailure("sticky_archive_failure_accepted")
        } catch CapabilityHandlerError.unavailable(let field) where field == "sticky_storage" {
        }
        try require(store.note(id: noteID)?.archivedAt == nil, "sticky_archive_failure_rollback")

        let delete = StickyCapabilityHandler(operation: .delete, store: store)
        do {
            _ = try await delete.handle(
                arguments: ["noteId": .string(noteID.uuidString)],
                context: CapabilityHandlerContext(idempotencyKey: "sticky-verifier-key-007")
            )
            throw VerificationFailure("sticky_delete_failure_accepted")
        } catch CapabilityHandlerError.unavailable(let field) where field == "sticky_storage" {
        }
        try require(store.note(id: noteID) != nil, "sticky_delete_failure_rollback")
    }

    @MainActor
    private static func verifyCalendar(
        handlers: PocketCapabilityHandlerSet,
        dataSource: FakeCalendarCapabilityDataSource
    ) async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let allDayStart = Date(timeIntervalSince1970: 1_799_712_000)
        let normalizedAllDay = GoogleCalendarEventDraft(
            calendarID: "primary",
            eventID: nil,
            title: "Multi-day",
            location: "",
            notes: "",
            start: allDayStart,
            end: allDayStart.addingTimeInterval(3 * 86_400),
            isAllDay: true
        ).normalized(calendar: utcCalendar)
        try require(
            normalizedAllDay.end.timeIntervalSince(normalizedAllDay.start) == 3 * 86_400,
            "calendar_all_day_range"
        )
        let longCalendarTitle = String(repeating: "👨‍👩‍👧‍👦", count: 40)
        dataSource.seed(
            CalendarCapabilityEvent(
                eventRef: "primary:event-existing",
                eventID: "event-existing",
                safeTitle: longCalendarTitle,
                start: now.addingTimeInterval(300),
                end: now.addingTimeInterval(900)
            )
        )
        let list = try await handlers.invoke(
            PocketCapabilityKey(id: "calendar.events.list", version: 1),
            arguments: ["range": .string("today"), "timezone": .string("UTC")],
            context: CapabilityHandlerContext(now: now)
        )
        guard case .array(let events)? = list["events"], events.count == 1,
              case .object(let firstEvent) = events[0],
              case .string(let safeTitle)? = firstEvent["safeTitle"] else {
            throw VerificationFailure("calendar_list")
        }
        try require(safeTitle.unicodeScalars.count == 160, "calendar_title_scalar_limit")

        guard let filterNow = CapabilityDateCodec.date(from: "2026-08-15T03:00:00Z"),
              let august14Start = CapabilityDateCodec.date(from: "2026-08-14T07:00:00Z"),
              let august14End = CapabilityDateCodec.date(from: "2026-08-15T07:00:00Z"),
              let august15Start = CapabilityDateCodec.date(from: "2026-08-15T07:00:00Z"),
              let august15End = CapabilityDateCodec.date(from: "2026-08-16T07:00:00Z"),
              let august14Civil = CalendarCivilDate(rfc3339: "2026-08-14"),
              let august15Civil = CalendarCivilDate(rfc3339: "2026-08-15"),
              let august16Civil = CalendarCivilDate(rfc3339: "2026-08-16") else {
            throw VerificationFailure("calendar_all_day_filter_fixture")
        }
        dataSource.seed(CalendarCapabilityEvent(
            eventRef: "primary:all-day-aug14",
            eventID: "all-day-aug14",
            safeTitle: "August 14",
            start: august14Start,
            end: august14End,
            isAllDay: true,
            allDayStart: august14Civil,
            allDayEnd: august15Civil
        ))
        dataSource.seed(CalendarCapabilityEvent(
            eventRef: "primary:all-day-aug15",
            eventID: "all-day-aug15",
            safeTitle: "August 15",
            start: august15Start,
            end: august15End,
            isAllDay: true,
            allDayStart: august15Civil,
            allDayEnd: august16Civil
        ))
        let civilList = try await handlers.invoke(
            PocketCapabilityKey(id: "calendar.events.list", version: 1),
            arguments: ["range": .string("today"), "timezone": .string("Asia/Tokyo")],
            context: CapabilityHandlerContext(now: filterNow)
        )
        guard case .array(let civilEvents)? = civilList["events"] else {
            throw VerificationFailure("calendar_all_day_civil_filter")
        }
        let civilRefs = civilEvents.compactMap { value -> String? in
            guard case .object(let event) = value,
                  case .string(let eventRef)? = event["eventRef"] else {
                return nil
            }
            return eventRef
        }
        try require(civilRefs == ["primary:all-day-aug15"], "calendar_all_day_civil_filter")

        let createArguments: CapabilityObject = [
            "calendarId": .string("primary"),
            "title": .string("Created"),
            "start": .string(CapabilityDateCodec.string(from: now.addingTimeInterval(1_200))),
            "end": .string(CapabilityDateCodec.string(from: now.addingTimeInterval(1_800))),
            "isAllDay": .bool(false),
            "location": .null,
            "notes": .null
        ]
        let created = try await handlers.invoke(
            PocketCapabilityKey(id: "calendar.event.create", version: 1),
            arguments: createArguments,
            context: CapabilityHandlerContext(
                idempotencyKey: "calendar-verifier-key-01",
                now: now
            )
        )
        try require(created["eventId"] == .string("created-1"), "calendar_create_id")
        try require(dataSource.idempotencyKeys == ["calendar-verifier-key-01"], "calendar_idempotency_forward")
        try require(dataSource.createdRequests.last?.calendarID == "primary", "calendar_target_forward")

        let allDayArguments: CapabilityObject = [
            "calendarId": .string("primary"),
            "title": .string("Offset all-day"),
            "start": .string("2026-08-15T00:00:00+09:00"),
            "end": .string("2026-08-18T00:00:00+09:00"),
            "isAllDay": .bool(true),
            "location": .null,
            "notes": .null
        ]
        _ = try await handlers.invoke(
            PocketCapabilityKey(id: "calendar.event.create", version: 1),
            arguments: allDayArguments,
            context: CapabilityHandlerContext(
                idempotencyKey: "calendar-verifier-all-day-01",
                now: now
            )
        )
        guard let allDayRequest = dataSource.createdRequests.last,
              let startCivil = allDayRequest.allDayStart,
              let endCivil = allDayRequest.allDayEnd else {
            throw VerificationFailure("calendar_all_day_civil_date_forward")
        }
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        guard let resolvedStart = startCivil.date(in: losAngeles),
              let resolvedEnd = endCivil.date(in: losAngeles) else {
            throw VerificationFailure("calendar_all_day_civil_date_resolution")
        }
        let resolvedStartParts = losAngeles.dateComponents([.year, .month, .day], from: resolvedStart)
        let resolvedEndParts = losAngeles.dateComponents([.year, .month, .day], from: resolvedEnd)
        try require(
            resolvedStartParts.year == 2026 && resolvedStartParts.month == 8 && resolvedStartParts.day == 15,
            "calendar_all_day_start_offset_preserved"
        )
        try require(
            resolvedEndParts.year == 2026 && resolvedEndParts.month == 8 && resolvedEndParts.day == 18,
            "calendar_all_day_end_offset_preserved"
        )

        do {
            _ = try await handlers.invoke(
                PocketCapabilityKey(id: "calendar.event.create", version: 1),
                arguments: createArguments,
                context: CapabilityHandlerContext(now: now)
            )
            throw VerificationFailure("calendar_missing_idempotency_accepted")
        } catch CapabilityHandlerError.invalidArgument(let field) where field == "idempotencyKey" {
        }

        let read = try await handlers.invoke(
            PocketCapabilityKey(id: "calendar.event.get", version: 1),
            arguments: ["eventRef": created["eventRef"]!]
        )
        try require(read["safeTitle"] == .string("Created"), "calendar_get")

        dataSource.mismatchNextReadback = true
        do {
            _ = try await handlers.invoke(
                PocketCapabilityKey(id: "calendar.event.create", version: 1),
                arguments: createArguments,
                context: CapabilityHandlerContext(
                    idempotencyKey: "calendar-verifier-key-02",
                    now: now
                )
            )
            throw VerificationFailure("calendar_mismatch_accepted")
        } catch CapabilityHandlerError.readbackMismatch {
        }

        dataSource.failNextCreate = true
        do {
            _ = try await handlers.invoke(
                PocketCapabilityKey(id: "calendar.event.create", version: 1),
                arguments: createArguments,
                context: CapabilityHandlerContext(
                    idempotencyKey: "calendar-verifier-key-03",
                    now: now
                )
            )
            throw VerificationFailure("calendar_timeout_accepted")
        } catch is CancellationError {
        }

        dataSource.seed(CalendarCapabilityEvent(
            eventRef: String(repeating: "r", count: 257),
            eventID: "short",
            safeTitle: "Oversized ref",
            start: now.addingTimeInterval(2_000),
            end: now.addingTimeInterval(2_100)
        ))
        do {
            _ = try await handlers.invoke(
                PocketCapabilityKey(id: "calendar.events.list", version: 1),
                arguments: ["range": .string("today"), "timezone": .string("UTC")],
                context: CapabilityHandlerContext(now: now)
            )
            throw VerificationFailure("calendar_oversized_event_ref_accepted")
        } catch CapabilityHandlerError.readbackMismatch(let field) where field == "calendar.eventRef" {
        }

        dataSource.seed(CalendarCapabilityEvent(
            eventRef: "primary:oversized-event-id",
            eventID: String(repeating: "e", count: 257),
            safeTitle: "Oversized ID",
            start: now.addingTimeInterval(2_200),
            end: now.addingTimeInterval(2_300)
        ))
        do {
            _ = try await handlers.invoke(
                PocketCapabilityKey(id: "calendar.event.get", version: 1),
                arguments: ["eventRef": .string("primary:oversized-event-id")]
            )
            throw VerificationFailure("calendar_oversized_event_id_accepted")
        } catch CapabilityHandlerError.readbackMismatch(let field) where field == "calendar.eventId" {
        }
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ name: String) throws {
        guard condition() else { throw VerificationFailure(name) }
    }
}

private struct VerificationFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

@MainActor
private final class FakeCalendarCapabilityDataSource: CalendarCapabilityDataSource {
    private var events: [String: CalendarCapabilityEvent] = [:]
    private var createCount = 0
    var idempotencyKeys: [String] = []
    var createdRequests: [CalendarCapabilityCreateRequest] = []
    var mismatchNextReadback = false
    var failNextCreate = false

    func seed(_ event: CalendarCapabilityEvent) {
        events[event.eventRef] = event
    }

    func listEvents(from start: Date, to end: Date) async throws -> [CalendarCapabilityEvent] {
        _ = start
        _ = end
        return events.values
            .sorted { $0.start < $1.start }
    }

    func getEvent(eventRef: String) async throws -> CalendarCapabilityEvent? {
        guard let event = events[eventRef] else { return nil }
        if mismatchNextReadback {
            mismatchNextReadback = false
            return CalendarCapabilityEvent(
                eventRef: event.eventRef,
                eventID: event.eventID,
                safeTitle: event.safeTitle + " mismatch",
                start: event.start,
                end: event.end,
                isAllDay: event.isAllDay,
                allDayStart: event.allDayStart,
                allDayEnd: event.allDayEnd
            )
        }
        return event
    }

    func createEvent(
        _ request: CalendarCapabilityCreateRequest,
        idempotencyKey: String
    ) async throws -> CalendarCapabilityEvent {
        if failNextCreate {
            failNextCreate = false
            throw CancellationError()
        }
        idempotencyKeys.append(idempotencyKey)
        createdRequests.append(request)
        createCount += 1
        let eventID = "created-\(createCount)"
        let calendarID = request.calendarID ?? "primary"
        let event = CalendarCapabilityEvent(
            eventRef: "\(calendarID):\(eventID)",
            eventID: eventID,
            safeTitle: request.title,
            start: request.start,
            end: request.end,
            isAllDay: request.isAllDay,
            allDayStart: request.allDayStart,
            allDayEnd: request.allDayEnd
        )
        events[event.eventRef] = event
        return event
    }
}
