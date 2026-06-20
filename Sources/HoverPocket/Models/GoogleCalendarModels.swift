import Foundation

struct GoogleCalendarSource: Equatable, Codable, Sendable, Identifiable {
    let id: String
    let title: String
    let colorHex: String?
    let timeZone: String?
    let isPrimary: Bool
    let accessRole: String?

    var canWrite: Bool {
        accessRole == "owner" || accessRole == "writer"
    }
}

struct GoogleCalendarEventOccurrence: Equatable, Codable, Sendable, Identifiable {
    let id: String
    let googleEventID: String
    let calendarID: String
    let calendarTitle: String
    let calendarColorHex: String?
    let calendarCanWrite: Bool
    let title: String
    let location: String?
    let notes: String?
    let start: Date
    let end: Date
    let isAllDay: Bool
    let htmlLink: URL?

    func intersects(dayStart: Date, dayEnd: Date) -> Bool {
        start < dayEnd && end > dayStart
    }
}

struct GoogleCalendarEventDraft: Equatable, Sendable {
    var calendarID: String
    var eventID: String?
    var title: String
    var location: String
    var notes: String
    var start: Date
    var end: Date
    var isAllDay: Bool

    var isNew: Bool {
        eventID == nil
    }

    var normalizedTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled event" : trimmed
    }

    var normalizedLocation: String? {
        let trimmed = location.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var normalizedNotes: String? {
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func normalized(calendar: Calendar = .current) -> GoogleCalendarEventDraft {
        var copy = self
        if isAllDay {
            let dayStart = calendar.startOfDay(for: start)
            copy.start = dayStart
            copy.end = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        } else if end <= start {
            copy.end = calendar.date(byAdding: .hour, value: 1, to: start) ?? start.addingTimeInterval(3_600)
        }
        return copy
    }

    static func new(on day: Date, sources: [GoogleCalendarSource], calendar: Calendar = .current) -> GoogleCalendarEventDraft? {
        let writableSources = sources.filter(\.canWrite)
        guard let source = writableSources.first(where: \.isPrimary) ?? writableSources.first else {
            return nil
        }

        let dayStart = calendar.startOfDay(for: day)
        let start = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: dayStart) ?? dayStart
        let end = calendar.date(byAdding: .hour, value: 1, to: start) ?? start.addingTimeInterval(3_600)

        return GoogleCalendarEventDraft(
            calendarID: source.id,
            eventID: nil,
            title: "",
            location: "",
            notes: "",
            start: start,
            end: end,
            isAllDay: false
        )
    }

    static func editing(_ event: GoogleCalendarEventOccurrence) -> GoogleCalendarEventDraft {
        GoogleCalendarEventDraft(
            calendarID: event.calendarID,
            eventID: event.googleEventID,
            title: event.title,
            location: event.location ?? "",
            notes: event.notes ?? "",
            start: event.start,
            end: event.end,
            isAllDay: event.isAllDay
        )
    }
}

struct GoogleCalendarSnapshot: Equatable, Codable, Sendable {
    let sources: [GoogleCalendarSource]
    let events: [GoogleCalendarEventOccurrence]
    let rangeStart: Date
    let rangeEnd: Date
    let monthAnchor: Date
    let updatedAt: Date

    func dayCells(for month: Date, calendar: Calendar = .current) -> [CalendarDayCell] {
        let monthStart = calendar.startOfMonth(for: month)
        return (0..<42).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: rangeStart) else {
                return nil
            }

            return CalendarDayCell(
                id: Self.dayIdentifier(for: date, calendar: calendar),
                date: date,
                dayNumber: calendar.component(.day, from: date),
                isInDisplayedMonth: calendar.isDate(date, equalTo: monthStart, toGranularity: .month),
                isToday: calendar.isDateInToday(date),
                events: events(for: date, calendar: calendar)
            )
        }
    }

    func events(for day: Date, calendar: Calendar = .current) -> [GoogleCalendarEventOccurrence] {
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day)) else {
            return []
        }
        let dayStart = calendar.startOfDay(for: day)
        return events
            .filter { $0.intersects(dayStart: dayStart, dayEnd: dayEnd) }
            .sorted { $0.start < $1.start }
    }

    private static func dayIdentifier(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }
}

struct CalendarDayCell: Identifiable, Equatable {
    let id: String
    let date: Date
    let dayNumber: Int
    let isInDisplayedMonth: Bool
    let isToday: Bool
    let events: [GoogleCalendarEventOccurrence]
}

enum GoogleCalendarConnectionState: Equatable {
    case missingConfiguration
    case restoring
    case signedOut
    case needsReconnect
    case signingIn
    case signedIn
}

enum GoogleCalendarLoadState: Equatable {
    case idle
    case loading(previous: GoogleCalendarSnapshot?)
    case loaded(GoogleCalendarSnapshot)
    case failed(message: String, previous: GoogleCalendarSnapshot?)

    var snapshot: GoogleCalendarSnapshot? {
        switch self {
        case .idle:
            return nil
        case .loading(let previous):
            return previous
        case .loaded(let snapshot):
            return snapshot
        case .failed(_, let previous):
            return previous
        }
    }
}
