import Foundation

enum GoogleCalendarAPIError: LocalizedError {
    case requestFailed(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .requestFailed(let message):
            return message
        case .invalidResponse:
            return "Google Calendar response could not be read."
        }
    }
}

final class GoogleCalendarAPIClient: @unchecked Sendable {
    private let oauth: GoogleOAuthService
    private let decoder = JSONDecoder()

    init(oauth: GoogleOAuthService) {
        self.oauth = oauth
    }

    func fetchMonth(containing monthAnchor: Date, calendar: Calendar = .current) async throws -> GoogleCalendarSnapshot {
        let visibleRange = Self.visibleGridRange(containing: monthAnchor, calendar: calendar)
        let accessToken = try await oauth.accessToken()
        let sources = try await fetchCalendarSources(accessToken: accessToken)
        let selectedSources = sources.filter { !$0.id.isEmpty }

        var allEvents: [GoogleCalendarEventOccurrence] = []
        for source in selectedSources {
            let events = try await fetchEvents(
                source: source,
                accessToken: accessToken,
                rangeStart: visibleRange.start,
                rangeEnd: visibleRange.end,
                timeZone: calendar.timeZone
            )
            allEvents.append(contentsOf: events)
        }

        return GoogleCalendarSnapshot(
            sources: selectedSources,
            events: allEvents.sorted { $0.start < $1.start },
            rangeStart: visibleRange.start,
            rangeEnd: visibleRange.end,
            monthAnchor: calendar.startOfMonth(for: monthAnchor),
            updatedAt: Date()
        )
    }

    func createEvent(_ draft: GoogleCalendarEventDraft, calendar: Calendar = .current) async throws {
        let accessToken = try await oauth.accessToken()
        let normalized = draft.normalized(calendar: calendar)
        var request = URLRequest(url: Self.eventsURL(calendarID: normalized.calendarID))
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Self.writeResource(from: normalized, calendar: calendar))
        _ = try await send(request)
    }

    func updateEvent(_ draft: GoogleCalendarEventDraft, calendar: Calendar = .current) async throws {
        guard let eventID = draft.eventID else {
            throw GoogleCalendarAPIError.requestFailed("Google Calendar event ID is missing.")
        }

        let accessToken = try await oauth.accessToken()
        let normalized = draft.normalized(calendar: calendar)
        var request = URLRequest(url: Self.eventURL(calendarID: normalized.calendarID, eventID: eventID))
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Self.writeResource(from: normalized, calendar: calendar))
        _ = try await send(request)
    }

    func deleteEvent(calendarID: String, eventID: String) async throws {
        let accessToken = try await oauth.accessToken()
        var request = URLRequest(url: Self.eventURL(calendarID: calendarID, eventID: eventID))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        _ = try await send(request)
    }

    private func fetchCalendarSources(accessToken: String) async throws -> [GoogleCalendarSource] {
        var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList")!
        components.queryItems = [
            URLQueryItem(name: "showHidden", value: "false"),
            URLQueryItem(name: "maxResults", value: "250")
        ]

        let response: CalendarListResponse = try await get(components.url!, accessToken: accessToken)
        let sources = response.items
            .filter { $0.selected != false && $0.deleted != true }
            .map {
                GoogleCalendarSource(
                    id: $0.id,
                    title: $0.summaryOverride ?? $0.summary,
                    colorHex: $0.backgroundColor,
                    timeZone: $0.timeZone,
                    isPrimary: $0.primary == true,
                    accessRole: $0.accessRole
                )
            }

        return sources.isEmpty ? response.items.prefix(1).map {
            GoogleCalendarSource(
                id: $0.id,
                title: $0.summaryOverride ?? $0.summary,
                colorHex: $0.backgroundColor,
                timeZone: $0.timeZone,
                isPrimary: $0.primary == true,
                accessRole: $0.accessRole
            )
        } : sources
    }

    private func fetchEvents(
        source: GoogleCalendarSource,
        accessToken: String,
        rangeStart: Date,
        rangeEnd: Date,
        timeZone: TimeZone
    ) async throws -> [GoogleCalendarEventOccurrence] {
        var events: [GoogleCalendarEventOccurrence] = []
        var pageToken: String?

        repeat {
            var components = URLComponents(url: Self.eventsURL(calendarID: source.id), resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "timeMin", value: Self.rfc3339String(from: rangeStart)),
                URLQueryItem(name: "timeMax", value: Self.rfc3339String(from: rangeEnd)),
                URLQueryItem(name: "singleEvents", value: "true"),
                URLQueryItem(name: "orderBy", value: "startTime"),
                URLQueryItem(name: "timeZone", value: timeZone.identifier),
                URLQueryItem(name: "maxResults", value: "2500")
            ]
            if let pageToken {
                components.queryItems?.append(URLQueryItem(name: "pageToken", value: pageToken))
            }

            let response: EventsListResponse = try await get(components.url!, accessToken: accessToken)
            events.append(
                contentsOf: response.items.compactMap {
                    Self.normalize(event: $0, source: source)
                }
            )
            pageToken = response.nextPageToken
        } while pageToken != nil

        return events
    }

    private func get<T: Decodable>(_ url: URL, accessToken: String) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let data = try await send(request)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw GoogleCalendarAPIError.invalidResponse
        }
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GoogleCalendarAPIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? decoder.decode(GoogleAPIErrorResponse.self, from: data))?.safeDescription
            throw GoogleCalendarAPIError.requestFailed(message ?? "Google Calendar request failed.")
        }
        return data
    }

    private static func normalize(
        event: GoogleCalendarEventResource,
        source: GoogleCalendarSource
    ) -> GoogleCalendarEventOccurrence? {
        guard event.status != "cancelled" else { return nil }
        guard let start = parseDateTime(event.start), let end = parseDateTime(event.end) else {
            return nil
        }
        let title = event.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeTitle = title?.isEmpty == false ? title! : "Busy"

        return GoogleCalendarEventOccurrence(
            id: "\(source.id):\(event.id)",
            googleEventID: event.id,
            calendarID: source.id,
            calendarTitle: source.title,
            calendarColorHex: source.colorHex,
            calendarCanWrite: source.canWrite,
            title: safeTitle,
            location: event.location,
            notes: event.description,
            start: start.date,
            end: end.date,
            isAllDay: start.isAllDay,
            htmlLink: event.htmlLink.flatMap(URL.init(string:))
        )
    }

    private static func parseDateTime(_ value: GoogleCalendarEventDateTime?) -> (date: Date, isAllDay: Bool)? {
        guard let value else { return nil }
        if let dateTime = value.dateTime, let date = parseInternetDate(dateTime) {
            return (date, false)
        }
        if let allDay = value.date, let date = parseAllDayDate(allDay) {
            return (date, true)
        }
        return nil
    }

    private static func visibleGridRange(containing date: Date, calendar: Calendar) -> (start: Date, end: Date) {
        let monthStart = calendar.startOfMonth(for: date)
        let weekday = calendar.component(.weekday, from: monthStart)
        let leadingDays = (weekday - calendar.firstWeekday + 7) % 7
        let gridStart = calendar.date(byAdding: .day, value: -leadingDays, to: monthStart) ?? monthStart
        let gridEnd = calendar.date(byAdding: .day, value: 42, to: gridStart) ?? monthStart
        return (gridStart, gridEnd)
    }

    private static func parseInternetDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }

        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func rfc3339String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func allDayString(from date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: calendar.startOfDay(for: date))
    }

    private static func writeResource(
        from draft: GoogleCalendarEventDraft,
        calendar: Calendar
    ) -> GoogleCalendarEventWriteResource {
        let timeZone = calendar.timeZone.identifier
        if draft.isAllDay {
            return GoogleCalendarEventWriteResource(
                summary: draft.normalizedTitle,
                location: draft.normalizedLocation,
                description: draft.normalizedNotes,
                start: GoogleCalendarEventDateTimeWrite(
                    date: allDayString(from: draft.start, calendar: calendar),
                    dateTime: nil,
                    timeZone: nil
                ),
                end: GoogleCalendarEventDateTimeWrite(
                    date: allDayString(from: draft.end, calendar: calendar),
                    dateTime: nil,
                    timeZone: nil
                )
            )
        }

        return GoogleCalendarEventWriteResource(
            summary: draft.normalizedTitle,
            location: draft.normalizedLocation,
            description: draft.normalizedNotes,
            start: GoogleCalendarEventDateTimeWrite(
                date: nil,
                dateTime: rfc3339String(from: draft.start),
                timeZone: timeZone
            ),
            end: GoogleCalendarEventDateTimeWrite(
                date: nil,
                dateTime: rfc3339String(from: draft.end),
                timeZone: timeZone
            )
        )
    }

    private static func eventsURL(calendarID: String) -> URL {
        URL(string: "https://www.googleapis.com/calendar/v3/calendars/\(pathComponent(calendarID))/events")!
    }

    private static func eventURL(calendarID: String, eventID: String) -> URL {
        URL(string: "https://www.googleapis.com/calendar/v3/calendars/\(pathComponent(calendarID))/events/\(pathComponent(eventID))")!
    }

    private static func pathComponent(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func parseAllDayDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }
}

private struct CalendarListResponse: Decodable {
    let items: [GoogleCalendarListEntry]
}

private struct GoogleCalendarListEntry: Decodable {
    let id: String
    let summary: String
    let summaryOverride: String?
    let backgroundColor: String?
    let timeZone: String?
    let primary: Bool?
    let selected: Bool?
    let deleted: Bool?
    let accessRole: String?
}

private struct EventsListResponse: Decodable {
    let items: [GoogleCalendarEventResource]
    let nextPageToken: String?
}

private struct GoogleCalendarEventResource: Decodable {
    let id: String
    let status: String?
    let summary: String?
    let location: String?
    let description: String?
    let start: GoogleCalendarEventDateTime?
    let end: GoogleCalendarEventDateTime?
    let htmlLink: String?
}

private struct GoogleCalendarEventDateTime: Decodable {
    let date: String?
    let dateTime: String?
}

private struct GoogleCalendarEventWriteResource: Encodable {
    let summary: String
    let location: String?
    let description: String?
    let start: GoogleCalendarEventDateTimeWrite
    let end: GoogleCalendarEventDateTimeWrite
}

private struct GoogleCalendarEventDateTimeWrite: Encodable {
    let date: String?
    let dateTime: String?
    let timeZone: String?
}

private struct GoogleAPIErrorResponse: Decodable {
    let error: GoogleAPIErrorBody?

    var safeDescription: String {
        error?.message ?? "Google Calendar request failed."
    }
}

private struct GoogleAPIErrorBody: Decodable {
    let message: String?
}

extension Calendar {
    func startOfMonth(for date: Date) -> Date {
        let components = dateComponents([.year, .month], from: date)
        return self.date(from: components) ?? startOfDay(for: date)
    }
}
