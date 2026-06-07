import Foundation

struct PluginID: Hashable, Codable, Sendable, Identifiable {
    let rawValue: String

    var id: String {
        rawValue
    }
}

struct PluginManifest: Hashable, Codable, Sendable, Identifiable {
    let id: PluginID
    let title: String
    let symbolName: String
    let defaultEnabled: Bool
    let requestedPermissions: Set<PluginPermission>
    let refreshPolicy: RefreshPolicy
}

enum PluginPermission: Hashable, Codable, Sendable {
    case camera
    case clipboardRead
    case clipboardWrite
    case codexSessionsRead
    case calendarRead
    case calendarWrite
    case notificationsRead
    case systemStatsRead
    case processListRead
    case network(domain: String)
    case fileRead(scope: FileScope)
}

enum FileScope: Hashable, Codable, Sendable {
    case userSelected
    case container
    case path(String)
}

enum RefreshPolicy: Hashable, Codable, Sendable {
    case onPanelOpen
    case interval(seconds: TimeInterval)
    case eventDriven
    case manual
}

enum RefreshReason: Hashable, Sendable {
    case appLaunch
    case panelOpened
    case timer
    case userRequested
    case dependencyChanged
}

enum ProviderPhase: Equatable, Sendable {
    case idle
    case loading
    case ready
    case stale
    case failed(String)
    case disabled
}

struct ProviderState: Equatable, Sendable {
    var phase: ProviderPhase
    var snapshot: ProviderSnapshot?

    static let idle = ProviderState(phase: .idle, snapshot: nil)
}

struct ProviderSnapshot: Equatable, Codable, Sendable {
    let updatedAt: Date
    let staleAt: Date?
    let content: PreviewContent
    let errorDescription: String?

    static let empty = ProviderSnapshot(
        updatedAt: Date(),
        staleAt: nil,
        content: .empty,
        errorDescription: nil
    )
}

enum PreviewContent: Equatable, Codable, Sendable {
    case empty
    case list([PreviewListItem])
    case metrics([MetricItem])
    case timeline([TimelineItem])
    case markdown(String)
}

struct PreviewListItem: Equatable, Codable, Sendable, Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let accessory: String?
}

struct MetricItem: Equatable, Codable, Sendable, Identifiable {
    let id: String
    let title: String
    let value: String
    let detail: String?
}

struct TimelineItem: Equatable, Codable, Sendable, Identifiable {
    let id: String
    let title: String
    let time: Date
    let detail: String?
}
