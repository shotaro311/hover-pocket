import Darwin
import Foundation

enum CapabilityVerificationCommand {
    @MainActor
    static func run() -> Never {
        Task { @MainActor in
            do {
                try await verify()
                print("capability_verify=ok")
                print("capability_handlers=10")
                print("capability_timer_lifecycle=ok")
                print("capability_sticky_upsert=ok")
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
            persistenceEnabled: false
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
            TimerCapabilityHandler(operation: .start, store: timerStore, idGenerator: { timerID }),
            TimerCapabilityHandler(operation: .get, store: timerStore),
            TimerCapabilityHandler(operation: .pause, store: timerStore),
            TimerCapabilityHandler(operation: .resume, store: timerStore),
            TimerCapabilityHandler(operation: .stop, store: timerStore),
            StickyCapabilityHandler(operation: .upsert, store: stickyStore, idGenerator: { noteID }),
            StickyCapabilityHandler(operation: .get, store: stickyStore)
        ])

        guard handlers.keys.count == 10 else {
            throw VerificationFailure("handler_count")
        }
        try await verifyTimer(handlers: handlers, timerID: timerID)
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
    private static func verifyTimer(
        handlers: PocketCapabilityHandlerSet,
        timerID: UUID
    ) async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let started = try await handlers.invoke(
            PocketCapabilityKey(id: "timer.countdown.start", version: 1),
            arguments: [
                "durationSeconds": .integer(600),
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
    private static func verifySticky(
        handlers: PocketCapabilityHandlerSet,
        noteID: UUID,
        root: URL
    ) async throws {
        let firstTime = Date(timeIntervalSince1970: 1_800_000_100)
        let longTitle = String(repeating: "T", count: 80)
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

        let read = try await handlers.invoke(
            PocketCapabilityKey(id: "sticky.note.get", version: 1),
            arguments: ["noteId": .string(noteID.uuidString)]
        )
        try require(read["body"] == .string("Finish the note"), "sticky_readback")
        try require(read["title"] == .string(longTitle), "sticky_title_readback")

        let restored = StickyNotesStore(storageDirectory: root)
        try require(restored.note(id: noteID)?.stableKey == "today-focus:purpose", "sticky_persistence")
        try require(restored.note(id: noteID)?.title == longTitle, "sticky_title_persistence")
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
        dataSource.seed(
            CalendarCapabilityEvent(
                eventRef: "primary:event-existing",
                eventID: "event-existing",
                safeTitle: "Existing",
                start: now.addingTimeInterval(300),
                end: now.addingTimeInterval(900)
            )
        )
        let list = try await handlers.invoke(
            PocketCapabilityKey(id: "calendar.events.list", version: 1),
            arguments: ["range": .string("today"), "timezone": .string("UTC")],
            context: CapabilityHandlerContext(now: now)
        )
        guard case .array(let events)? = list["events"], events.count == 1 else {
            throw VerificationFailure("calendar_list")
        }

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
        events.values
            .filter { $0.start < end && $0.end > start }
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
                end: event.end
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
            end: request.end
        )
        events[event.eventRef] = event
        return event
    }
}
