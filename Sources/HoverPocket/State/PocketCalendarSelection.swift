import Combine
import Foundation

@MainActor
final class PocketCalendarSelection: ObservableObject {
    static let shared = PocketCalendarSelection()
    @Published var displayedMonth = Calendar.current.startOfMonth(for: Date())
    @Published var selectedDate = Date()
    @Published var lockedDate: Date?
    @Published var hoveredDate: Date?
    @Published var selectedEventID: String?
    @Published var draft: GoogleCalendarEventDraft?

    var visibleDate: Date { lockedDate ?? hoveredDate ?? selectedDate }

    func select(_ date: Date) -> Bool {
        guard draft == nil else { return false }
        displayedMonth = Calendar.current.startOfMonth(for: date)
        selectedDate = date
        lockedDate = date
        hoveredDate = nil
        selectedEventID = nil
        return true
    }
}
