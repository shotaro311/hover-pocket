import Foundation

enum GoogleCalendarVerificationCommand {
    static func run() -> Never {
        let arguments = Set(CommandLine.arguments.dropFirst())
        Task {
            let exitCode: Int32
            do {
                try await verify(arguments: arguments)
                exitCode = 0
            } catch {
                fputs("google_calendar_verify=failed\n", stderr)
                fputs("error=\(safeErrorMessage(error))\n", stderr)
                exitCode = 1
            }
            Darwin.exit(exitCode)
        }
        RunLoop.main.run()
        Darwin.exit(1)
    }

    private static func verify(arguments: Set<String>) async throws {
        let oauth = GoogleOAuthService()
        guard oauth.isConfigured else {
            throw GoogleOAuthError.missingConfiguration
        }

        let forceSignIn = arguments.contains("--force-google-sign-in")
        if forceSignIn {
            oauth.signOut()
        }

        let shouldSignIn = forceSignIn || !oauth.hasRequiredCalendarCredential()
        if shouldSignIn {
            print("google_calendar_auth=browser_opened")
            try await oauth.signIn()
        }

        let calendar = Calendar.current
        let snapshot = try await GoogleCalendarAPIClient(oauth: oauth)
            .fetchMonth(containing: Date(), calendar: calendar)
        let occupiedDays = snapshot.dayCells(for: snapshot.monthAnchor, calendar: calendar)
            .filter { !$0.events.isEmpty }
        let todayEvents = snapshot.events(for: Date(), calendar: calendar)

        print("google_calendar_verify=ok")
        print("used_login_flow=\(shouldSignIn)")
        print("calendar_sources=\(snapshot.sources.count)")
        print("events_in_visible_grid=\(snapshot.events.count)")
        print("days_with_events=\(occupiedDays.count)")
        print("today_events=\(todayEvents.count)")
        print("range_start=\(dateString(snapshot.rangeStart, calendar: calendar))")
        print("range_end=\(dateString(snapshot.rangeEnd, calendar: calendar))")
    }

    private static func dateString(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func safeErrorMessage(_ error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty {
            return localized
        }
        let description = String(describing: error)
        if !description.isEmpty {
            return "\(type(of: error)): \(description)"
        }
        return "Google Calendar verification failed."
    }
}
