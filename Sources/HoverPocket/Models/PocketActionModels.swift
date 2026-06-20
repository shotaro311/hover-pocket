import Foundation

enum PocketActionKind: String, Codable, Sendable, Hashable {
    case calendarReadDay
    case calendarCreateEvent
}

struct PocketActionApprovalField: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let value: String
}

struct CalendarReadParameters: Codable, Equatable, Sendable {
    let date: Date
}

struct CalendarCreateEventParameters: Codable, Equatable, Sendable {
    let calendarID: String?
    let calendarTitle: String?
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let location: String?
    let notes: String?
}

struct PocketAction: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let kind: PocketActionKind
    let sourceText: String
    let readParameters: CalendarReadParameters?
    let createEventParameters: CalendarCreateEventParameters?

    init(
        id: UUID = UUID(),
        kind: PocketActionKind,
        sourceText: String,
        readParameters: CalendarReadParameters? = nil,
        createEventParameters: CalendarCreateEventParameters? = nil
    ) {
        self.id = id
        self.kind = kind
        self.sourceText = sourceText
        self.readParameters = readParameters
        self.createEventParameters = createEventParameters
    }

    var requiresApproval: Bool {
        switch kind {
        case .calendarReadDay:
            return false
        case .calendarCreateEvent:
            return true
        }
    }

    var displayTitle: String {
        switch kind {
        case .calendarReadDay:
            guard let date = readParameters?.date else { return "Read calendar" }
            return "\(Self.dayFormatter.string(from: date)) events"
        case .calendarCreateEvent:
            let title = createEventParameters?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return title.isEmpty ? "Create calendar event" : title
        }
    }

    var displaySubtitle: String {
        switch kind {
        case .calendarReadDay:
            return "Calendar read"
        case .calendarCreateEvent:
            guard let parameters = createEventParameters else { return "Calendar write" }
            if parameters.isAllDay {
                return "All day on \(Self.dayFormatter.string(from: parameters.start))"
            }
            return "\(Self.dateTimeFormatter.string(from: parameters.start)) - \(Self.timeFormatter.string(from: parameters.end))"
        }
    }

    var approvalTitle: String {
        switch kind {
        case .calendarReadDay:
            return "Read calendar"
        case .calendarCreateEvent:
            return "Create calendar event?"
        }
    }

    var approvalFields: [PocketActionApprovalField] {
        switch kind {
        case .calendarReadDay:
            guard let parameters = readParameters else { return [] }
            return [
                PocketActionApprovalField(id: "date", label: "Date", value: Self.dayFormatter.string(from: parameters.date))
            ]
        case .calendarCreateEvent:
            guard let parameters = createEventParameters else { return [] }
            var fields = [
                PocketActionApprovalField(id: "title", label: "Title", value: parameters.title),
                PocketActionApprovalField(id: "start", label: "Start", value: Self.dateTimeFormatter.string(from: parameters.start)),
                PocketActionApprovalField(id: "end", label: "End", value: Self.dateTimeFormatter.string(from: parameters.end))
            ]
            if parameters.isAllDay {
                fields[1] = PocketActionApprovalField(
                    id: "date",
                    label: "Date",
                    value: Self.dayFormatter.string(from: parameters.start)
                )
                fields.remove(at: 2)
            }
            if let location = parameters.location, !location.isEmpty {
                fields.append(PocketActionApprovalField(id: "location", label: "Location", value: location))
            }
            if let notes = parameters.notes, !notes.isEmpty {
                fields.append(PocketActionApprovalField(id: "notes", label: "Notes", value: notes))
            }
            if let calendarTitle = parameters.calendarTitle, !calendarTitle.isEmpty {
                fields.append(PocketActionApprovalField(id: "calendar", label: "Calendar", value: calendarTitle))
            }
            return fields
        }
    }

    func makeCalendarDraft(defaultCalendarID: String) -> GoogleCalendarEventDraft? {
        guard let parameters = createEventParameters else { return nil }
        return GoogleCalendarEventDraft(
            calendarID: parameters.calendarID ?? defaultCalendarID,
            eventID: nil,
            title: parameters.title,
            location: parameters.location ?? "",
            notes: parameters.notes ?? "",
            start: parameters.start,
            end: parameters.end,
            isAllDay: parameters.isAllDay
        ).normalized()
    }

    private static var dayFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }

    private static var dateTimeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }

    private static var timeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }
}

struct IntentPlan: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let sourceText: String
    let primaryAction: PocketAction?
    let candidates: [PocketAction]
    let confidence: Double
    let modelIdentifier: String
    let createdAt: Date

    init(
        id: UUID = UUID(),
        sourceText: String,
        primaryAction: PocketAction?,
        candidates: [PocketAction],
        confidence: Double,
        modelIdentifier: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sourceText = sourceText
        self.primaryAction = primaryAction
        self.candidates = candidates
        self.confidence = confidence
        self.modelIdentifier = modelIdentifier
        self.createdAt = createdAt
    }
}

struct ToolResult: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let actionID: UUID
    let title: String
    let message: String
    let succeeded: Bool
    let createdAt: Date

    init(
        id: UUID = UUID(),
        actionID: UUID,
        title: String,
        message: String,
        succeeded: Bool,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.actionID = actionID
        self.title = title
        self.message = message
        self.succeeded = succeeded
        self.createdAt = createdAt
    }
}
