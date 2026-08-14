import Foundation

private enum CapabilityIDs {
    static let calendarList = PocketCapabilityKey(id: "calendar.events.list", version: 1)
    static let calendarGet = PocketCapabilityKey(id: "calendar.event.get", version: 1)
    static let calendarCreate = PocketCapabilityKey(id: "calendar.event.create", version: 1)
    static let timerStart = PocketCapabilityKey(id: "timer.countdown.start", version: 1)
    static let timerGet = PocketCapabilityKey(id: "timer.countdown.get", version: 1)
    static let timerPause = PocketCapabilityKey(id: "timer.countdown.pause", version: 1)
    static let timerResume = PocketCapabilityKey(id: "timer.countdown.resume", version: 1)
    static let timerStop = PocketCapabilityKey(id: "timer.countdown.stop", version: 1)
    static let stickyUpsert = PocketCapabilityKey(id: "sticky.note.upsert", version: 1)
    static let stickyGet = PocketCapabilityKey(id: "sticky.note.get", version: 1)
}

struct CalendarCapabilityEvent: Equatable, Sendable {
    let eventRef: String
    let eventID: String
    let safeTitle: String
    let start: Date
    let end: Date
}

struct CalendarCapabilityCreateRequest: Equatable, Sendable {
    let calendarID: String?
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let allDayStart: CalendarCivilDate?
    let allDayEnd: CalendarCivilDate?
    let location: String?
    let notes: String?
}

struct CalendarCivilDate: Equatable, Sendable, Comparable {
    let year: Int
    let month: Int
    let day: Int

    init?(rfc3339 value: String) {
        let components = value.prefix(10).split(separator: "-", omittingEmptySubsequences: false)
        guard components.count == 3,
              let year = Int(components[0]),
              let month = Int(components[1]),
              let day = Int(components[2]) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let candidate = DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day
        )
        guard let date = calendar.date(from: candidate),
              calendar.dateComponents([.year, .month, .day], from: date)
                == DateComponents(year: year, month: month, day: day) else {
            return nil
        }
        self.year = year
        self.month = month
        self.day = day
    }

    func date(in calendar: Calendar) -> Date? {
        calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day
        ))
    }

    static func < (lhs: CalendarCivilDate, rhs: CalendarCivilDate) -> Bool {
        if lhs.year != rhs.year { return lhs.year < rhs.year }
        if lhs.month != rhs.month { return lhs.month < rhs.month }
        return lhs.day < rhs.day
    }
}

@MainActor
protocol CalendarCapabilityDataSource: AnyObject {
    func listEvents(from start: Date, to end: Date) async throws -> [CalendarCapabilityEvent]
    func getEvent(eventRef: String) async throws -> CalendarCapabilityEvent?
    func createEvent(
        _ request: CalendarCapabilityCreateRequest,
        idempotencyKey: String
    ) async throws -> CalendarCapabilityEvent
}

@MainActor
final class GoogleCalendarCapabilityDataSource: CalendarCapabilityDataSource {
    private let store: GoogleCalendarStore

    init(store: GoogleCalendarStore = .shared) {
        self.store = store
    }

    func listEvents(from start: Date, to end: Date) async throws -> [CalendarCapabilityEvent] {
        try await store.listEventsForCapability(from: start, to: end).map(Self.map)
    }

    func getEvent(eventRef: String) async throws -> CalendarCapabilityEvent? {
        try await store.eventForCapability(eventRef: eventRef).map(Self.map)
    }

    func createEvent(
        _ request: CalendarCapabilityCreateRequest,
        idempotencyKey: String
    ) async throws -> CalendarCapabilityEvent {
        Self.map(try await store.createEventForCapability(request, idempotencyKey: idempotencyKey))
    }

    private static func map(_ event: GoogleCalendarEventOccurrence) -> CalendarCapabilityEvent {
        CalendarCapabilityEvent(
            eventRef: event.id,
            eventID: event.googleEventID,
            safeTitle: event.title,
            start: event.start,
            end: event.end
        )
    }
}

@MainActor
final class CalendarListCapabilityHandler: PocketCapabilityHandler {
    let key = CapabilityIDs.calendarList
    private let dataSource: any CalendarCapabilityDataSource

    init(dataSource: any CalendarCapabilityDataSource) {
        self.dataSource = dataSource
    }

    func handle(arguments: CapabilityObject, context: CapabilityHandlerContext) async throws -> CapabilityObject {
        let range = try arguments.requiredString("range", maxLength: 16)
        guard range == "today" else {
            throw CapabilityHandlerError.invalidArgument("range")
        }
        let timeZoneID = try arguments.requiredString("timezone", maxLength: 64)
        guard let timeZone = TimeZone(identifier: timeZoneID) else {
            throw CapabilityHandlerError.invalidArgument("timezone")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = calendar.startOfDay(for: context.now)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else {
            throw CapabilityHandlerError.unavailable("calendar_range")
        }
        let events = try await dataSource.listEvents(from: start, to: end)
            .prefix(128)
            .map(Self.output)
        return ["events": .array(events.map(CapabilityValue.object))]
    }

    fileprivate static func output(_ event: CalendarCapabilityEvent) -> CapabilityObject {
        [
            "eventRef": .string(event.eventRef),
            "start": .string(CapabilityDateCodec.string(from: event.start)),
            "end": .string(CapabilityDateCodec.string(from: event.end)),
            "safeTitle": .string(event.safeTitle.prefixingUnicodeScalars(160))
        ]
    }
}

@MainActor
final class CalendarGetCapabilityHandler: PocketCapabilityHandler {
    let key = CapabilityIDs.calendarGet
    private let dataSource: any CalendarCapabilityDataSource

    init(dataSource: any CalendarCapabilityDataSource) {
        self.dataSource = dataSource
    }

    func handle(arguments: CapabilityObject, context: CapabilityHandlerContext) async throws -> CapabilityObject {
        _ = context
        let eventRef = try arguments.requiredString("eventRef", maxLength: 256)
        guard let event = try await dataSource.getEvent(eventRef: eventRef) else {
            throw CapabilityHandlerError.unavailable("calendar_event")
        }
        var output = CalendarListCapabilityHandler.output(event)
        output["eventId"] = .string(event.eventID)
        return output
    }
}

@MainActor
final class CalendarCreateCapabilityHandler: PocketCapabilityHandler {
    let key = CapabilityIDs.calendarCreate
    private let dataSource: any CalendarCapabilityDataSource

    init(dataSource: any CalendarCapabilityDataSource) {
        self.dataSource = dataSource
    }

    func handle(arguments: CapabilityObject, context: CapabilityHandlerContext) async throws -> CapabilityObject {
        let idempotencyKey = try context.requiredIdempotencyKey()
        let title = try arguments.requiredString("title", maxLength: 160)
        let startString = try arguments.requiredString("start", maxLength: 64)
        let endString = try arguments.requiredString("end", maxLength: 64)
        let isAllDay = try arguments.requiredBool("isAllDay")
        guard let start = CapabilityDateCodec.date(from: startString),
              let end = CapabilityDateCodec.date(from: endString) else {
            throw CapabilityHandlerError.invalidArgument("start_end")
        }
        let allDayStart = isAllDay ? CalendarCivilDate(rfc3339: startString) : nil
        let allDayEnd = isAllDay ? CalendarCivilDate(rfc3339: endString) : nil
        if isAllDay {
            guard let allDayStart, let allDayEnd, allDayEnd > allDayStart else {
                throw CapabilityHandlerError.invalidArgument("start_end")
            }
        } else if end <= start {
            throw CapabilityHandlerError.invalidArgument("start_end")
        }
        let request = CalendarCapabilityCreateRequest(
            calendarID: try arguments.optionalString("calendarId", maxLength: 256),
            title: title,
            start: start,
            end: end,
            isAllDay: isAllDay,
            allDayStart: allDayStart,
            allDayEnd: allDayEnd,
            location: try arguments.optionalString("location", maxLength: 500),
            notes: try arguments.optionalString("notes", maxLength: 10_000)
        )
        let created = try await dataSource.createEvent(request, idempotencyKey: idempotencyKey)
        guard let observed = try await dataSource.getEvent(eventRef: created.eventRef), observed == created else {
            throw CapabilityHandlerError.readbackMismatch("calendar.event.create")
        }
        return Self.output(observed)
    }

    private static func output(_ event: CalendarCapabilityEvent) -> CapabilityObject {
        var output = CalendarListCapabilityHandler.output(event)
        output["eventId"] = .string(event.eventID)
        return output
    }
}

@MainActor
final class TimerCapabilityHandler: PocketCapabilityHandler {
    enum Operation {
        case start
        case get
        case pause
        case resume
        case stop

        var key: PocketCapabilityKey {
            switch self {
            case .start: CapabilityIDs.timerStart
            case .get: CapabilityIDs.timerGet
            case .pause: CapabilityIDs.timerPause
            case .resume: CapabilityIDs.timerResume
            case .stop: CapabilityIDs.timerStop
            }
        }
    }

    let operation: Operation
    private let store: TimerStore
    private let idGenerator: @MainActor () -> UUID

    var key: PocketCapabilityKey { operation.key }

    init(operation: Operation, store: TimerStore, idGenerator: @escaping @MainActor () -> UUID = UUID.init) {
        self.operation = operation
        self.store = store
        self.idGenerator = idGenerator
    }

    func handle(arguments: CapabilityObject, context: CapabilityHandlerContext) async throws -> CapabilityObject {
        if operation != .get {
            _ = try context.requiredIdempotencyKey()
        }
        switch operation {
        case .start:
            return try await start(arguments: arguments, context: context)
        case .get:
            return try output(timerID: timerID(arguments), now: context.now)
        case .pause:
            let id = try timerID(arguments)
            guard store.runningTimer(id: id) != nil else {
                throw CapabilityHandlerError.unavailable("timer")
            }
            do {
                try await store.pauseForCapability(id: id, at: context.now)
            } catch {
                throw CapabilityHandlerError.unavailable("timer_storage")
            }
            return try output(timerID: id, now: context.now)
        case .resume:
            let id = try timerID(arguments)
            guard store.runningTimer(id: id) != nil else {
                throw CapabilityHandlerError.unavailable("timer")
            }
            do {
                try await store.resumeForCapability(id: id, at: context.now)
            } catch {
                throw CapabilityHandlerError.unavailable("timer_storage")
            }
            return try output(timerID: id, now: context.now)
        case .stop:
            let id = try timerID(arguments)
            do {
                try await store.stopForCapability(id: id)
            } catch {
                throw CapabilityHandlerError.unavailable("timer_storage")
            }
            return Self.stoppedOutput(id)
        }
    }

    private func start(arguments: CapabilityObject, context: CapabilityHandlerContext) async throws -> CapabilityObject {
        let duration = try arguments.requiredInteger("durationSeconds", range: 1...86_400)
        let title = try arguments.requiredString("title", maxLength: 80)
        _ = try arguments.optionalString("sourceRef", maxLength: 256)
        var preset = TimerPreset.defaultTimerDraft()
        preset.title = title
        preset.duration = TimeInterval(duration)
        let timer: RunningTimer?
        do {
            timer = try await store.startForCapability(preset: preset, id: idGenerator(), at: context.now)
        } catch {
            throw CapabilityHandlerError.unavailable("timer_storage")
        }
        guard let timer else {
            throw CapabilityHandlerError.unavailable("timer_capacity")
        }
        return Self.output(timer, now: context.now)
    }

    private func timerID(_ arguments: CapabilityObject) throws -> UUID {
        let value = try arguments.requiredString("timerId", maxLength: 36)
        guard let id = UUID(uuidString: value) else {
            throw CapabilityHandlerError.invalidArgument("timerId")
        }
        return id
    }

    private func output(timerID: UUID, now: Date) throws -> CapabilityObject {
        guard let timer = store.runningTimer(id: timerID) else {
            return Self.stoppedOutput(timerID)
        }
        return Self.output(timer, now: now)
    }

    private static func output(_ timer: RunningTimer, now: Date) -> CapabilityObject {
        [
            "timerId": .string(timer.id.uuidString.lowercased()),
            "state": .string(timer.isPaused ? "paused" : "running"),
            "endAt": .string(CapabilityDateCodec.string(from: timer.endDate))
        ]
    }

    private static func stoppedOutput(_ id: UUID) -> CapabilityObject {
        [
            "timerId": .string(id.uuidString.lowercased()),
            "state": .string("stopped"),
            "endAt": .null
        ]
    }
}

@MainActor
final class StickyCapabilityHandler: PocketCapabilityHandler {
    enum Operation {
        case upsert
        case get

        var key: PocketCapabilityKey {
            switch self {
            case .upsert: CapabilityIDs.stickyUpsert
            case .get: CapabilityIDs.stickyGet
            }
        }
    }

    let operation: Operation
    private let store: StickyNotesStore
    private let idGenerator: @MainActor () -> UUID

    var key: PocketCapabilityKey { operation.key }

    init(operation: Operation, store: StickyNotesStore, idGenerator: @escaping @MainActor () -> UUID = UUID.init) {
        self.operation = operation
        self.store = store
        self.idGenerator = idGenerator
    }

    func handle(arguments: CapabilityObject, context: CapabilityHandlerContext) async throws -> CapabilityObject {
        switch operation {
        case .upsert:
            _ = try context.requiredIdempotencyKey()
            let stableKey = try arguments.requiredString("stableKey", maxLength: 160)
            let title = try arguments.requiredString("title", maxLength: 120, allowEmpty: true)
            let body = try arguments.requiredString("body", maxLength: 10_000, allowEmpty: true)
            let color = try Self.color(try arguments.requiredString("color", maxLength: 16))
            let note: StickyNoteItem
            do {
                note = try store.upsertNote(
                    stableKey: stableKey,
                    title: title,
                    body: body,
                    color: color,
                    id: idGenerator(),
                    at: context.now
                )
            } catch {
                throw CapabilityHandlerError.unavailable("sticky_storage")
            }
            return Self.readOutput(note)
        case .get:
            let rawID = try arguments.requiredString("noteId", maxLength: 128)
            guard let id = UUID(uuidString: rawID), let note = store.note(id: id) else {
                throw CapabilityHandlerError.unavailable("sticky_note")
            }
            return Self.readOutput(note)
        }
    }

    private static func color(_ value: String) throws -> StickyNoteColor {
        switch value {
        case "yellow": .yellow
        case "blue": .blue
        case "green": .mint
        case "pink": .pink
        case "gray": .lavender
        default: throw CapabilityHandlerError.invalidArgument("color")
        }
    }

    private static func mutationOutput(_ note: StickyNoteItem) -> CapabilityObject {
        [
            "noteId": .string(note.id.uuidString.lowercased()),
            "updatedAt": .string(CapabilityDateCodec.string(from: note.updatedAt))
        ]
    }

    private static func readOutput(_ note: StickyNoteItem) -> CapabilityObject {
        var output = mutationOutput(note)
        output["title"] = .string(note.title)
        output["body"] = .string(note.body)
        return output
    }
}

@MainActor
enum ProviderCapabilityCompositionRoot {
    static func live(calendarDataSource: any CalendarCapabilityDataSource) throws -> PocketCapabilityHandlerSet {
        try PocketCapabilityHandlerSet(handlers: [
            CalendarListCapabilityHandler(dataSource: calendarDataSource),
            CalendarGetCapabilityHandler(dataSource: calendarDataSource),
            CalendarCreateCapabilityHandler(dataSource: calendarDataSource),
            TimerCapabilityHandler(operation: .start, store: .shared),
            TimerCapabilityHandler(operation: .get, store: .shared),
            TimerCapabilityHandler(operation: .pause, store: .shared),
            TimerCapabilityHandler(operation: .resume, store: .shared),
            TimerCapabilityHandler(operation: .stop, store: .shared),
            StickyCapabilityHandler(operation: .upsert, store: .shared),
            StickyCapabilityHandler(operation: .get, store: .shared)
        ])
    }
}
