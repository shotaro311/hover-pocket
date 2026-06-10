import Foundation

enum GoogleCalendarToolError: LocalizedError {
    case notConnected

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Google Calendar is not connected."
        }
    }
}

@MainActor
final class GoogleCalendarStore: ObservableObject {
    static let shared = GoogleCalendarStore()

    @Published private(set) var connectionState: GoogleCalendarConnectionState
    @Published private(set) var loadState: GoogleCalendarLoadState = .idle
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var isMutatingEvent = false

    private let oauth: GoogleOAuthService
    private let apiClient: GoogleCalendarAPIClient
    private var refreshTask: Task<Void, Never>?
    private var lastLoadedMonth: Date?
    private var didCheckStoredCredential = false

    init(oauth: GoogleOAuthService = GoogleOAuthService()) {
        self.oauth = oauth
        self.apiClient = GoogleCalendarAPIClient(oauth: oauth)
        connectionState = oauth.isConfigured ? .signedOut : .missingConfiguration
    }

    var isConfigured: Bool {
        connectionState != .missingConfiguration
    }

    var isSignedIn: Bool {
        connectionState == .signedIn
    }

    func connect() {
        restoreConnectionIfNeeded()
        guard connectionState != .signedIn else { return }
        signIn()
    }

    func signIn() {
        guard connectionState != .signingIn else { return }
        guard oauth.isConfigured else {
            connectionState = .missingConfiguration
            return
        }

        connectionState = .signingIn
        lastErrorMessage = nil
        Task {
            do {
                try await oauth.signIn()
                await MainActor.run {
                    self.connectionState = .signedIn
                    self.refreshMonth(containing: Date(), force: true)
                }
            } catch {
                await MainActor.run {
                    self.updateConnectionStateFromStoredCredential()
                    self.lastErrorMessage = Self.safeErrorMessage(error)
                }
            }
        }
    }

    func signOut() {
        refreshTask?.cancel()
        refreshTask = nil
        oauth.signOut()
        connectionState = oauth.isConfigured ? .signedOut : .missingConfiguration
        loadState = .idle
        lastLoadedMonth = nil
        lastErrorMessage = nil
        isMutatingEvent = false
        didCheckStoredCredential = true
    }

    func restoreConnectionIfNeeded() {
        guard !didCheckStoredCredential else { return }
        didCheckStoredCredential = true
        updateConnectionStateFromStoredCredential()
    }

    func refreshMonth(containing month: Date, force: Bool = false) {
        guard connectionState == .signedIn else { return }

        let calendar = Calendar.current
        let monthStart = calendar.startOfMonth(for: month)
        if !force,
           let lastLoadedMonth,
           calendar.isDate(lastLoadedMonth, equalTo: monthStart, toGranularity: .month),
           case .loaded = loadState {
            return
        }

        refreshTask?.cancel()
        let previous = loadState.snapshot
        loadState = .loading(previous: previous)
        lastErrorMessage = nil

        refreshTask = Task {
            do {
                let snapshot = try await apiClient.fetchMonth(containing: monthStart, calendar: calendar)
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    self.lastLoadedMonth = monthStart
                    self.loadState = .loaded(snapshot)
                }
            } catch {
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    let message = Self.safeErrorMessage(error)
                    if case GoogleOAuthError.insufficientScopes = error {
                        self.connectionState = .needsReconnect
                    }
                    self.lastErrorMessage = message
                    self.loadState = .failed(message: message, previous: previous)
                }
            }
        }
    }

    func days(for month: Date, hoveredDate: Date?) -> [CalendarDayCell] {
        guard let snapshot = loadState.snapshot else {
            return Self.emptyMonthDays(for: month)
        }

        return snapshot.dayCells(for: month)
    }

    func events(for day: Date) -> [GoogleCalendarEventOccurrence] {
        guard let snapshot = loadState.snapshot else {
            return []
        }
        return snapshot.events(for: day)
    }

    func loadMonthForTool(containing month: Date, force: Bool = false) async throws -> GoogleCalendarSnapshot {
        restoreConnectionIfNeeded()
        guard connectionState == .signedIn else {
            throw GoogleCalendarToolError.notConnected
        }

        let calendar = Calendar.current
        let monthStart = calendar.startOfMonth(for: month)
        if !force,
           let lastLoadedMonth,
           calendar.isDate(lastLoadedMonth, equalTo: monthStart, toGranularity: .month),
           let snapshot = loadState.snapshot {
            return snapshot
        }

        let previous = loadState.snapshot
        refreshTask?.cancel()
        refreshTask = nil
        loadState = .loading(previous: previous)
        lastErrorMessage = nil

        do {
            let snapshot = try await apiClient.fetchMonth(containing: monthStart, calendar: calendar)
            lastLoadedMonth = monthStart
            loadState = .loaded(snapshot)
            return snapshot
        } catch {
            let message = Self.safeErrorMessage(error)
            if case GoogleOAuthError.insufficientScopes = error {
                connectionState = .needsReconnect
            }
            lastErrorMessage = message
            loadState = .failed(message: message, previous: previous)
            throw error
        }
    }

    func writableSources() -> [GoogleCalendarSource] {
        loadState.snapshot?.sources.filter(\.canWrite) ?? []
    }

    func saveEvent(_ draft: GoogleCalendarEventDraft, refreshing month: Date) async -> Bool {
        guard connectionState == .signedIn else { return false }
        guard !isMutatingEvent else { return false }

        isMutatingEvent = true
        lastErrorMessage = nil
        do {
            if draft.isNew {
                try await apiClient.createEvent(draft)
            } else {
                try await apiClient.updateEvent(draft)
            }
            isMutatingEvent = false
            refreshMonth(containing: month, force: true)
            return true
        } catch {
            isMutatingEvent = false
            if case GoogleOAuthError.insufficientScopes = error {
                connectionState = .needsReconnect
            }
            lastErrorMessage = Self.safeErrorMessage(error)
            return false
        }
    }

    func deleteEvent(_ event: GoogleCalendarEventOccurrence, refreshing month: Date) async -> Bool {
        guard connectionState == .signedIn else { return false }
        guard !isMutatingEvent else { return false }

        isMutatingEvent = true
        lastErrorMessage = nil
        do {
            try await apiClient.deleteEvent(calendarID: event.calendarID, eventID: event.googleEventID)
            isMutatingEvent = false
            refreshMonth(containing: month, force: true)
            return true
        } catch {
            isMutatingEvent = false
            if case GoogleOAuthError.insufficientScopes = error {
                connectionState = .needsReconnect
            }
            lastErrorMessage = Self.safeErrorMessage(error)
            return false
        }
    }

    private static func emptyMonthDays(for month: Date) -> [CalendarDayCell] {
        let calendar = Calendar.current
        let monthStart = calendar.startOfMonth(for: month)
        let weekday = calendar.component(.weekday, from: monthStart)
        let leadingDays = (weekday - calendar.firstWeekday + 7) % 7
        let gridStart = calendar.date(byAdding: .day, value: -leadingDays, to: monthStart) ?? monthStart

        return (0..<42).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: gridStart) else {
                return nil
            }
            return CalendarDayCell(
                id: dayIdentifier(for: date),
                date: date,
                dayNumber: calendar.component(.day, from: date),
                isInDisplayedMonth: calendar.isDate(date, equalTo: monthStart, toGranularity: .month),
                isToday: calendar.isDateInToday(date),
                events: []
            )
        }
    }

    private static func dayIdentifier(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func safeErrorMessage(_ error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty {
            return localized
        }
        return "Google Calendar could not be loaded."
    }

    private func updateConnectionStateFromStoredCredential() {
        guard oauth.isConfigured else {
            connectionState = .missingConfiguration
            return
        }

        switch oauth.storedCredentialStatus() {
        case .missing:
            connectionState = .signedOut
        case .needsReconnect:
            connectionState = .needsReconnect
        case .ready:
            connectionState = .signedIn
        }
    }
}
