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
        displayTitle(language: .english)
    }

    func displayTitle(language: AppLanguage) -> String {
        switch kind {
        case .calendarReadDay:
            guard let date = readParameters?.date else { return AppText.text(.readCalendar, language: language) }
            let day = Self.dayString(date, language: language)
            return language == .japanese ? "\(day)の予定" : "\(day) \(AppText.text(.calendarEvents, language: language))"
        case .calendarCreateEvent:
            let title = createEventParameters?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return title.isEmpty ? AppText.text(.addEvent, language: language) : title
        }
    }

    var displaySubtitle: String {
        displaySubtitle(language: .english)
    }

    func displaySubtitle(language: AppLanguage) -> String {
        switch kind {
        case .calendarReadDay:
            return AppText.text(.calendarRead, language: language)
        case .calendarCreateEvent:
            guard let parameters = createEventParameters else { return AppText.text(.calendarWrite, language: language) }
            if parameters.isAllDay {
                let day = Self.dayString(parameters.start, language: language)
                return language == .japanese ? "\(day) \(AppText.text(.allDay, language: language))" : "\(AppText.text(.allDay, language: language)) on \(day)"
            }
            return "\(Self.dateTimeString(parameters.start, language: language)) - \(Self.timeString(parameters.end, language: language))"
        }
    }

    var approvalTitle: String {
        approvalTitle(language: .english)
    }

    func approvalTitle(language: AppLanguage) -> String {
        switch kind {
        case .calendarReadDay:
            return AppText.text(.readCalendar, language: language)
        case .calendarCreateEvent:
            return language == .japanese ? "予定を作成しますか？" : "Create calendar event?"
        }
    }

    var approvalFields: [PocketActionApprovalField] {
        approvalFields(language: .english)
    }

    func approvalFields(language: AppLanguage) -> [PocketActionApprovalField] {
        switch kind {
        case .calendarReadDay:
            guard let parameters = readParameters else { return [] }
            return [
                PocketActionApprovalField(id: "date", label: AppText.text(.date, language: language), value: Self.dayString(parameters.date, language: language))
            ]
        case .calendarCreateEvent:
            guard let parameters = createEventParameters else { return [] }
            var fields = [
                PocketActionApprovalField(id: "title", label: AppText.text(.title, language: language), value: parameters.title),
                PocketActionApprovalField(id: "start", label: AppText.text(.start, language: language), value: Self.dateTimeString(parameters.start, language: language)),
                PocketActionApprovalField(id: "end", label: AppText.text(.end, language: language), value: Self.dateTimeString(parameters.end, language: language))
            ]
            if parameters.isAllDay {
                fields[1] = PocketActionApprovalField(
                    id: "date",
                    label: AppText.text(.date, language: language),
                    value: Self.dayString(parameters.start, language: language)
                )
                fields.remove(at: 2)
            }
            if let location = parameters.location, !location.isEmpty {
                fields.append(PocketActionApprovalField(id: "location", label: AppText.text(.location, language: language), value: location))
            }
            if let notes = parameters.notes, !notes.isEmpty {
                fields.append(PocketActionApprovalField(id: "notes", label: AppText.text(.notes, language: language), value: notes))
            }
            if let calendarTitle = parameters.calendarTitle, !calendarTitle.isEmpty {
                fields.append(PocketActionApprovalField(id: "calendar", label: AppText.text(.calendar, language: language), value: calendarTitle))
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

    private static func dayString(_ date: Date, language: AppLanguage) -> String {
        language.formattedDate(date, template: "yMMMd")
    }

    private static func dateTimeString(_ date: Date, language: AppLanguage) -> String {
        language.formattedDate(date, template: "yMMMdHm")
    }

    private static func timeString(_ date: Date, language: AppLanguage) -> String {
        language.formattedDate(date, template: "Hm")
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
