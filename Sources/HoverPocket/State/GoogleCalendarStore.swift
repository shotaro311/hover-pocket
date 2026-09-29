import CryptoKit
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
    private var emptyMonthDaysCache: [String: [CalendarDayCell]] = [:]

    init(oauth: GoogleOAuthService = GoogleOAuthService()) {
        self.oauth = oauth
        self.apiClient = GoogleCalendarAPIClient(oauth: oauth)
        connectionState = oauth.isConfigured ? .restoring : .missingConfiguration
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
        guard connectionState != .restoring else { return }
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
                    self.handleLoadFailure(error, previous: previous)
                }
            }
        }
    }

    func days(for month: Date, hoveredDate: Date?) -> [CalendarDayCell] {
        let calendar = Calendar.current
        let monthStart = calendar.startOfMonth(for: month)

        guard let snapshot = loadState.snapshot,
              calendar.isDate(snapshot.monthAnchor, equalTo: monthStart, toGranularity: .month)
        else {
            return emptyMonthDays(for: monthStart, calendar: calendar)
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
            handleLoadFailure(error, previous: previous)
            if Self.requiresReconnect(error) {
                throw GoogleCalendarToolError.notConnected
            } else {
                throw error
            }
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
                _ = try await apiClient.createEvent(draft)
            } else {
                try await apiClient.updateEvent(draft)
            }
            isMutatingEvent = false
            refreshMonth(containing: month, force: true)
            return true
        } catch {
            isMutatingEvent = false
            handleMutationFailure(error)
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
            handleMutationFailure(error)
            return false
        }
    }

    private var personalApprovalTargets: [String: (revision: CapabilityValue, label: String)] = [:]

    func personalApprovalLabel(_ target: String, revision: CapabilityValue?) -> String? {
        guard let stored = personalApprovalTargets[target], stored.revision == revision else { return nil }
        return stored.label
    }

    func personalTool(_ operation: PersonalToolOperation, arguments: CapabilityObject) async throws -> CapabilityObject {
        guard connectionState == .signedIn else { throw GoogleCalendarToolError.notConnected }
        if operation == .calendarSearch {
            let start = try PersonalToolDate.parse( arguments.requiredString("start", maxLength: 64))
            let end = try PersonalToolDate.parse( arguments.requiredString("end", maxLength: 64))
            guard end > start, end.timeIntervalSince(start) <= 31 * 86400 else { throw CapabilityHandlerError.invalidArgument("date_range") }
            var month = Calendar.current.dateInterval(of: .month, for: start)!.start
            var events: [GoogleCalendarEventOccurrence] = []
            var ids: Set<String> = []
            while month < end {
                try Task.checkCancellation()
                let snapshot = try await loadMonthForTool(containing: month)
                for event in snapshot.events where ids.insert(event.id).inserted { events.append(event) }
                guard let next = Calendar.current.date(byAdding: .month, value: 1, to: month), next > month else { throw CapabilityHandlerError.invalidArgument("date_range") }
                month = next
            }
            let matching = events.filter { $0.start < end && $0.end > start }.sorted { $0.start < $1.start }
            return ["items": .array(matching.prefix(100).map { .object([
                "targetId": .string($0.id), "title": .string(String($0.title.prefix(160))),
                "start": .string($0.allDayStartDate ?? CapabilityDateCodec.string(from: $0.start)),
                "end": .string($0.allDayEndDate ?? CapabilityDateCodec.string(from: $0.end)), "isAllDay": .bool($0.isAllDay)
            ]) }), "truncated": .bool(matching.count > 100)]
        }
        let target = try arguments.requiredString("targetId", maxLength: 512)
        guard let separator = target.lastIndex(of: ":") else { throw CapabilityHandlerError.invalidArgument("targetId") }
        let calendarID = String(target[..<separator]); let eventID = String(target[target.index(after: separator)...])
        guard !calendarID.isEmpty, !eventID.isEmpty else { throw CapabilityHandlerError.invalidArgument("targetId") }
        guard let before = try await apiClient.personalEventResource(calendarID: calendarID, eventID: eventID), before["status"] != .string("cancelled") else { throw CapabilityHandlerError.unavailable("event_not_found") }
        if operation.isWrite {
            let snapshot = try await loadMonthForTool(containing: Date())
            guard snapshot.sources.contains(where: { $0.id == calendarID && $0.canWrite }) else { throw CapabilityHandlerError.unavailable("calendar_read_only") }
            let revision = try before.requiredString("etag", maxLength: 256)
            guard arguments["expectedRevision"] == .string(revision) else { throw CapabilityHandlerError.unavailable("event_changed") }
            let patch = try PersonalCalendarEditing.patch(arguments: arguments, before: before)
            try Task.checkCancellation()
            try await apiClient.modifyPersonalEvent(calendarID: calendarID, eventID: eventID, revision: revision, patch: operation == .calendarDelete ? nil : patch)
            let observed = try await apiClient.personalEventResource(calendarID: calendarID, eventID: eventID)
            if operation == .calendarDelete {
                guard observed == nil || observed?["status"] == .string("cancelled") else { throw CapabilityHandlerError.readbackMismatch("event_delete") }
                refreshMonth(containing: lastLoadedMonth ?? Date(), force: true)
                return ["targetId": .string(target), "state": .string("deleted")]
            }
            guard let observed else { throw CapabilityHandlerError.readbackMismatch("event_edit") }
            try PersonalCalendarEditing.verify(patch: patch, observed: observed)
            refreshMonth(containing: lastLoadedMonth ?? Date(), force: true)
            return try personalEventSnapshot(observed, target: target, calendarID: calendarID)
        }
        return try personalEventSnapshot(before, target: target, calendarID: calendarID)
    }

    private func personalEventSnapshot(_ event: CapabilityObject, target: String, calendarID: String) throws -> CapabilityObject {
        guard case .object(let start)? = event["start"], case .object(let end)? = event["end"] else { throw GoogleCalendarAPIError.invalidResponse }
        var result: CapabilityObject = ["targetId": .string(target), "title": event["summary"] ?? .string(""),
            "start": start["date"] ?? start["dateTime"] ?? .null, "end": end["date"] ?? end["dateTime"] ?? .null,
            "isAllDay": .bool(start["date"] != nil), "location": event["location"] ?? .string(""), "notes": event["description"] ?? .string(""),
            "revision": .string(try event.requiredString("etag", maxLength: 256)), "isRecurringSeries": .bool(event["recurrence"] != nil)]
        if case .string(let series)? = event["recurringEventId"] { result["seriesTargetId"] = .string(calendarID + ":" + series) }
        if case .array(let attendees)? = event["attendees"] { result["attendeeCount"] = .integer(attendees.count) }
        if personalApprovalTargets.count > 256 { personalApprovalTargets.removeAll() }
        if case .string(let title)? = result["title"], let revision = result["revision"] {
            personalApprovalTargets[target] = (revision, title.isEmpty ? "予定（タイトルなし）" : title)
        }
        return result
    }

    func listEventsForCapability(from start: Date, to end: Date) async throws -> [GoogleCalendarEventOccurrence] {
        let snapshot = try await loadMonthForTool(containing: start)
        return snapshot.events
            .sorted { $0.start < $1.start }
    }

    func eventForCapability(eventRef: String) async throws -> GoogleCalendarEventOccurrence? {
        if let cached = loadState.snapshot?.events.first(where: { $0.id == eventRef }) {
            return cached
        }
        guard let separator = eventRef.lastIndex(of: ":") else {
            return nil
        }
        let calendarID = String(eventRef[..<separator])
        let eventID = String(eventRef[eventRef.index(after: separator)...])
        guard !calendarID.isEmpty, !eventID.isEmpty else { return nil }
        restoreConnectionIfNeeded()
        guard connectionState == .signedIn else {
            throw GoogleCalendarToolError.notConnected
        }
        let source = loadState.snapshot?.sources.first { $0.id == calendarID }
        return try await apiClient.fetchEvent(
            calendarID: calendarID,
            eventID: eventID,
            source: source
        )
    }

    func createEventForCapability(
        _ request: CalendarCapabilityCreateRequest,
        idempotencyKey: String
    ) async throws -> GoogleCalendarEventOccurrence {
        let externalEventID = Self.capabilityEventID(idempotencyKey)
        var draftStart = request.start
        var draftEnd = request.end
        if request.isAllDay {
            let calendar = Calendar.current
            guard let start = request.allDayStart?.date(in: calendar),
                  let end = request.allDayEnd?.date(in: calendar),
                  end > start else {
                throw CapabilityHandlerError.invalidArgument("start_end")
            }
            draftStart = start
            draftEnd = end
        }
        let snapshot = try await loadMonthForTool(containing: draftStart)
        let source: GoogleCalendarSource
        if let requested = request.calendarID {
            guard let requestedSource = snapshot.sources.first(where: { $0.id == requested && $0.canWrite }) else {
                throw CapabilityHandlerError.unavailable("writable_calendar")
            }
            source = requestedSource
        } else if let defaultSource = snapshot.sources.first(where: { $0.canWrite && $0.isPrimary })
            ?? snapshot.sources.first(where: \.canWrite) {
            source = defaultSource
        } else {
            throw CapabilityHandlerError.unavailable("writable_calendar")
        }
        let draft = GoogleCalendarEventDraft(
            calendarID: source.id,
            eventID: nil,
            title: request.title,
            location: request.location ?? "",
            notes: request.notes ?? "",
            start: draftStart,
            end: draftEnd,
            isAllDay: request.isAllDay
        ).normalized()
        let created: GoogleCalendarEventOccurrence
        do {
            created = try await apiClient.createEvent(draft, source: source, eventID: externalEventID)
        } catch GoogleCalendarAPIError.conflict {
            created = try await apiClient.fetchEvent(
                calendarID: source.id,
                eventID: externalEventID,
                source: source
            )
        }
        let observed = try await apiClient.fetchEvent(
            calendarID: source.id,
            eventID: created.googleEventID,
            source: source
        )
        guard Self.capabilityEventMatches(observed, draft: draft) else {
            throw CapabilityHandlerError.readbackMismatch("calendar.idempotency")
        }
        if let refreshed = try? await apiClient.fetchMonth(containing: draftStart) {
            lastLoadedMonth = Calendar.current.startOfMonth(for: draftStart)
            loadState = .loaded(refreshed)
        }
        return observed
    }

    static func capabilityEventMatches(
        _ observed: GoogleCalendarEventOccurrence,
        draft: GoogleCalendarEventDraft
    ) -> Bool {
        let timeMatches: Bool
        if draft.isAllDay {
            timeMatches = observed.isAllDay
                && observed.allDayStartDate == capabilityAllDayString(draft.start)
                && observed.allDayEndDate == capabilityAllDayString(draft.end)
        } else {
            timeMatches = !observed.isAllDay
                && capabilityWholeSecond(observed.start) == capabilityWholeSecond(draft.start)
                && capabilityWholeSecond(observed.end) == capabilityWholeSecond(draft.end)
        }
        return observed.title == draft.normalizedTitle
            && observed.location == draft.normalizedLocation
            && observed.notes == draft.normalizedNotes
            && timeMatches
    }

    private static func capabilityWholeSecond(_ date: Date) -> Int64 {
        Int64(floor(date.timeIntervalSince1970))
    }

    private static func capabilityAllDayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = Calendar.current.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func capabilityEventID(_ idempotencyKey: String) -> String {
        let digest = SHA256.hash(data: Data(idempotencyKey.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "hp\(digest)"
    }

    private func emptyMonthDays(for monthStart: Date, calendar: Calendar) -> [CalendarDayCell] {
        let cacheKey = Self.monthCacheKey(for: monthStart, calendar: calendar)
        if let cached = emptyMonthDaysCache[cacheKey] {
            return cached
        }

        let weekday = calendar.component(.weekday, from: monthStart)
        let leadingDays = (weekday - calendar.firstWeekday + 7) % 7
        let gridStart = calendar.date(byAdding: .day, value: -leadingDays, to: monthStart) ?? monthStart

        let days: [CalendarDayCell] = (0..<42).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: gridStart) else {
                return nil
            }
            return CalendarDayCell(
                id: Self.dayIdentifier(for: date, calendar: calendar),
                date: date,
                dayNumber: calendar.component(.day, from: date),
                isInDisplayedMonth: calendar.isDate(date, equalTo: monthStart, toGranularity: .month),
                isToday: calendar.isDateInToday(date),
                events: []
            )
        }
        emptyMonthDaysCache[cacheKey] = days
        return days
    }

    private static func dayIdentifier(for date: Date) -> String {
        dayIdentifier(for: date, calendar: .current)
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

    private static func monthCacheKey(for monthStart: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month], from: monthStart)
        return String(format: "%04d-%02d", components.year ?? 0, components.month ?? 0)
    }

    private static func safeErrorMessage(_ error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty {
            return localized
        }
        return "Google Calendar could not be loaded."
    }

    private static func requiresReconnect(_ error: Error) -> Bool {
        if let oauthError = error as? GoogleOAuthError {
            return oauthError.requiresReconnect
        }
        if let apiError = error as? GoogleCalendarAPIError {
            return apiError.requiresReconnect
        }
        return false
    }

    private static func reconnectErrorMessage(_ error: Error) -> String {
        if case GoogleOAuthError.insufficientScopes = error {
            return safeErrorMessage(error)
        }
        return "Reconnect Google Calendar to continue."
    }

    private func handleLoadFailure(_ error: Error, previous: GoogleCalendarSnapshot?) {
        if Self.requiresReconnect(error) {
            oauth.removeStoredCredential()
            connectionState = oauth.isConfigured ? .needsReconnect : .missingConfiguration
            let message = Self.reconnectErrorMessage(error)
            lastErrorMessage = message
            loadState = .failed(message: message, previous: previous)
            return
        }
        let message = Self.safeErrorMessage(error)
        lastErrorMessage = message
        loadState = .failed(message: message, previous: previous)
    }

    private func handleMutationFailure(_ error: Error) {
        if Self.requiresReconnect(error) {
            oauth.removeStoredCredential()
            connectionState = oauth.isConfigured ? .needsReconnect : .missingConfiguration
            lastErrorMessage = Self.reconnectErrorMessage(error)
            return
        }
        lastErrorMessage = Self.safeErrorMessage(error)
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
