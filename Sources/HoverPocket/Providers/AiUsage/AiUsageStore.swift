import Combine
import Foundation

enum AiUsageService: String, CaseIterable, Identifiable, Sendable {
    case codex, claude, claudeAPI = "claude-api", gemini, colab, muse

    var id: String { rawValue }
    var title: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .claudeAPI: "Claude API"
        case .gemini: "Gemini"
        case .colab: "Colab"
        case .muse: "Muse"
        }
    }

    var accountOwner: Self { self == .colab ? .gemini : self }
    var sharedServices: [Self] { accountOwner == .gemini ? [.gemini, .colab] : [self] }
    var hasWebSignIn: Bool { self != .codex && self != .colab }
}

struct AiUsageWindow: Equatable, Sendable {
    let kind: Kind
    let model: String?
    let percent: Double?
    let resetsAt: Date?
    let minutes: Int

    enum Kind: Sendable {
        case session, weekly, window
    }

    init(model: String? = nil, percent: Double?, resetsAt: Date? = nil, minutes: Int) {
        self.kind = switch minutes {
        case 300: .session
        case 10_080: .weekly
        default: .window
        }
        self.model = model
        self.percent = percent
        self.resetsAt = resetsAt
        self.minutes = minutes
    }
}

struct AiUsageBalance: Equatable, Sendable {
    enum Kind: Sendable { case planCredit, purchasedCredit, codexCredits, computeUnits }
    enum Value: Equatable, Sendable {
        case amount(Decimal), units(Double), unlimited, unreadable
    }

    let kind: Kind
    let value: Value
    var label: String? = nil
    var expiresAt: Date? = nil
    var perHour: Double? = nil
}

struct AiUsageReading: Equatable, Sendable {
    var plan: String? = nil
    var windows: [AiUsageWindow] = []
    var balances: [AiUsageBalance] = []
}

enum AiUsageFailure: Error, Equatable, Sendable {
    case network, changed, timeout, codexMissing, blocked, unavailable, noAccess, ambiguous
}

enum AiUsageResult: Equatable, Sendable {
    case success(AiUsageReading), signedOut, failure(AiUsageFailure)
}

struct AiUsageSnapshot: Equatable, Sendable {
    enum Status: Equatable, Sendable { case idle, ready, signedOut, failure(AiUsageFailure) }

    var status = Status.idle
    var reading: AiUsageReading?
    var fetchedAt: Date?
    var checkedAt: Date?
    var refreshing = false

    var stale: Bool {
        if case .failure = status { return reading != nil }
        return false
    }

    mutating func apply(_ result: AiUsageResult, at now: Date) {
        checkedAt = now
        refreshing = false
        switch result {
        case .success(let reading):
            status = .ready
            self.reading = reading
            fetchedAt = now
        case .signedOut:
            status = .signedOut
            reading = nil
            fetchedAt = nil
        case .failure(let error):
            status = .failure(error)
        }
    }
}

@MainActor
final class AiUsageStore: ObservableObject {
    typealias Reader = @MainActor (AiUsageService) async -> AiUsageResult
    static let shared = AiUsageStore(reader: readLive)

    private static func readLive(_ service: AiUsageService) async -> AiUsageResult {
        guard HoverPocketRuntimeEnvironment.shared.externalIntegrationsEnabled else {
            return .failure(.unavailable)
        }
        if service == .codex { return await AiUsageCodexReader.read() }
        return await AiUsageWebReader.shared.read(service)
    }

    @Published private(set) var snapshots: [AiUsageService: AiUsageSnapshot] = [:]
    private var accountChanges: [AiUsageService: Int] = [:]
    private var generations: [AiUsageService: UInt64] = [:]
    private var running: [AiUsageService: Task<Void, Never>] = [:]
    private let reader: Reader
    private let now: () -> Date

    convenience init(reader: @escaping Reader) {
        self.init(reader: reader, now: { Date() })
    }

    init(reader: @escaping Reader, now: @escaping () -> Date) {
        self.reader = reader
        self.now = now
    }

    func snapshot(_ service: AiUsageService) -> AiUsageSnapshot {
        snapshots[service] ?? AiUsageSnapshot()
    }

    func isChangingAccount(_ service: AiUsageService) -> Bool {
        accountChanges[service.accountOwner, default: 0] > 0
    }

    func refresh(_ services: [AiUsageService], force: Bool = false) {
        schedule(services, force: force, startingWith: snapshots)
    }

    private func schedule(
        _ services: [AiUsageService], force: Bool, startingWith initial: [AiUsageService: AiUsageSnapshot], notify: Bool = false
    ) {
        var next = initial
        for service in services {
            guard accountChanges[service.accountOwner, default: 0] == 0, running[service] == nil else { continue }
            var state = next[service] ?? AiUsageSnapshot()
            let reuse: TimeInterval = state.status == .signedOut ? 30 * 60 : 2 * 60
            if !force, let checkedAt = state.checkedAt, now().timeIntervalSince(checkedAt) < reuse { continue }

            state.refreshing = true
            next[service] = state
            let generation = generations[service, default: 0]
            running[service] = Task { [weak self, reader] in
                guard !Task.isCancelled else { return }
                let result = await reader(service)
                self?.finish(service, generation: generation, result: result)
            }
        }
        if notify || next != snapshots { snapshots = next }
    }

    private func finish(_ service: AiUsageService, generation: UInt64, result: AiUsageResult) {
        guard generations[service, default: 0] == generation,
              accountChanges[service.accountOwner, default: 0] == 0 else { return }
        running[service] = nil
        var state = snapshot(service)
        state.apply(result, at: now())
        snapshots[service] = state
    }

    private func invalidated(_ service: AiUsageService) -> [AiUsageService: AiUsageSnapshot] {
        var next = snapshots
        for member in service.sharedServices {
            generations[member, default: 0] &+= 1
            running.removeValue(forKey: member)?.cancel()
            next[member] = nil
        }
        return next
    }

    func beginAccountChange(_ service: AiUsageService) {
        let owner = service.accountOwner
        let next = invalidated(owner)
        accountChanges[owner, default: 0] += 1
        snapshots = next
    }

    func endAccountChange(_ service: AiUsageService) {
        let owner = service.accountOwner
        let next = invalidated(owner)
        if let count = accountChanges[owner] {
            accountChanges[owner] = count > 1 ? count - 1 : nil
        }
        schedule(owner.sharedServices, force: true, startingWith: next, notify: true)
    }

    func signOut(_ service: AiUsageService, clear: @MainActor () async throws -> Void) async throws {
        guard service.hasWebSignIn else { throw AiUsageFailure.unavailable }
        beginAccountChange(service)
        defer { endAccountChange(service) }
        try await clear()
    }
}
