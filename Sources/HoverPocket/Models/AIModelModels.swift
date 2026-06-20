import Foundation

enum AIModelRole: String, Codable, Sendable, Hashable {
    case singleToolSelection
    case structuredPlanner
    case agent
}

struct AIModelCapabilities: Codable, Equatable, Sendable {
    let supportsToolCalling: Bool
    let supportsStructuredOutput: Bool
    let maxContextTokens: Int?
    let roles: Set<AIModelRole>
}

struct AIModelDescriptor: Codable, Equatable, Sendable {
    let id: String
    let displayName: String
    let providerName: String
    let capabilities: AIModelCapabilities
}

enum AIModelAvailability: Equatable, Sendable {
    case available
    case unavailable(String)
}

struct CalendarToolCalendar: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    let isPrimary: Bool
}

struct AICommandContext: Sendable {
    let now: Date
    let timeZoneIdentifier: String
    let writableCalendars: [CalendarToolCalendar]
}

protocol AIModelProvider: Sendable {
    var descriptor: AIModelDescriptor { get }

    func availability() async -> AIModelAvailability
    func makeIntentPlan(for input: String, context: AICommandContext) async throws -> IntentPlan
}
