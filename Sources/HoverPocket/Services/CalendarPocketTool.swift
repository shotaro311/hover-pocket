import Foundation

@MainActor
final class CalendarPocketTool {
    private let store: GoogleCalendarStore

    init(store: GoogleCalendarStore = .shared) {
        self.store = store
    }

    func run(_ action: PocketAction, approved: Bool = false) async -> ToolResult {
        switch action.kind {
        case .calendarReadDay:
            return await readDay(action)
        case .calendarCreateEvent:
            guard approved else {
                return ToolResult(
                    actionID: action.id,
                    title: "Approval required",
                    message: "Calendar writes must be approved before they run.",
                    succeeded: false
                )
            }
            return await createEvent(action)
        }
    }

    private func readDay(_ action: PocketAction) async -> ToolResult {
        guard let date = action.readParameters?.date else {
            return ToolResult(
                actionID: action.id,
                title: "Calendar read failed",
                message: "The calendar read action did not include a date.",
                succeeded: false
            )
        }

        do {
            let snapshot = try await store.loadMonthForTool(containing: date)
            let events = snapshot.events(for: date)
            let message: String
            if events.isEmpty {
                message = "No events on \(Self.dayFormatter.string(from: date))."
            } else {
                let shown = events.prefix(3).map(Self.eventLine).joined(separator: "\n")
                let remaining = events.count > 3 ? "\n+\(events.count - 3) more" : ""
                message = shown + remaining
            }
            return ToolResult(
                actionID: action.id,
                title: "\(Self.dayFormatter.string(from: date)) events",
                message: message,
                succeeded: true
            )
        } catch {
            return ToolResult(
                actionID: action.id,
                title: "Calendar read failed",
                message: Self.safeErrorMessage(error),
                succeeded: false
            )
        }
    }

    private func createEvent(_ action: PocketAction) async -> ToolResult {
        let writableSources = store.writableSources()
        guard let defaultCalendarID = writableSources.first(where: \.isPrimary)?.id ?? writableSources.first?.id else {
            return ToolResult(
                actionID: action.id,
                title: "Calendar write failed",
                message: "No writable Google Calendar is available.",
                succeeded: false
            )
        }

        guard let draft = action.makeCalendarDraft(defaultCalendarID: defaultCalendarID) else {
            return ToolResult(
                actionID: action.id,
                title: "Calendar write failed",
                message: "The calendar write action was incomplete.",
                succeeded: false
            )
        }

        let didSave = await store.saveEvent(draft, refreshing: draft.start)
        if didSave {
            return ToolResult(
                actionID: action.id,
                title: "Event created",
                message: "\(draft.normalizedTitle) was added to Google Calendar.",
                succeeded: true
            )
        }

        return ToolResult(
            actionID: action.id,
            title: "Calendar write failed",
            message: store.lastErrorMessage ?? "Google Calendar could not save the event.",
            succeeded: false
        )
    }

    private static func eventLine(_ event: GoogleCalendarEventOccurrence) -> String {
        if event.isAllDay {
            return "All day - \(event.title)"
        }
        return "\(timeFormatter.string(from: event.start)) - \(event.title)"
    }

    private static func safeErrorMessage(_ error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty {
            return localized
        }
        return "Google Calendar could not be loaded."
    }

    private static var dayFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }

    private static var timeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }
}
