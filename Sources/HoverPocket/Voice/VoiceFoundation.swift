import Combine
import Foundation

enum VoiceLaneLayoutPreference: String, CaseIterable, Codable, Identifiable, Sendable {
    case compact
    case expanded

    var id: String { rawValue }
}

enum VoiceLaneMode: String, Codable, Sendable {
    case disabled
    case compact
    case expanded
}

enum VoiceLaneConnection: String, Codable, Sendable {
    case disconnected
    case connecting
    case connected
    case recovering
}

enum VoiceLaneActivity: String, Codable, Sendable {
    case idle
    case listening
    case thinking
    case speaking
    case waitingForApproval = "waiting_for_approval"
    case reconnecting
    case failed
}

enum VoiceSessionStatus: String, Codable, Sendable {
    case queued
    case running
    case waitingForUser = "waiting_for_user"
    case succeeded
    case failed
    case cancelled
}

struct VoiceSessionProgress: Equatable, Codable, Sendable {
    let completed: Int
    let total: Int
}

struct VoiceSessionSummary: Identifiable, Equatable, Codable, Sendable {
    let sessionID: String
    let rootSessionID: String
    let parentSessionID: String?
    let title: String
    let status: VoiceSessionStatus
    let safeSummary: String?
    let progress: VoiceSessionProgress?
    let updatedAt: Date

    var id: String { sessionID }

    init(
        sessionID: String,
        rootSessionID: String,
        parentSessionID: String? = nil,
        title: String,
        status: VoiceSessionStatus,
        safeSummary: String? = nil,
        progress: VoiceSessionProgress? = nil,
        updatedAt: Date
    ) {
        self.sessionID = VoiceTextSafety.sanitizeIdentifier(sessionID)
        self.rootSessionID = VoiceTextSafety.sanitizeIdentifier(rootSessionID)
        self.parentSessionID = parentSessionID.map(VoiceTextSafety.sanitizeIdentifier)
        self.title = VoiceTextSafety.sanitizeVisibleText(title, limit: 120)
        self.status = status
        self.safeSummary = safeSummary.map { VoiceTextSafety.sanitizeVisibleText($0, limit: 320) }
        self.progress = progress.flatMap { value in
            guard value.total > 0, value.completed >= 0, value.completed <= value.total else { return nil }
            return value
        }
        self.updatedAt = updatedAt
    }
}

struct VoiceTranscriptEvent: Identifiable, Equatable, Codable, Sendable {
    enum Role: String, Codable, Sendable {
        case user
        case assistant
        case system
    }

    let id: String
    let role: Role
    let text: String
    let isFinal: Bool
    let timestamp: Date

    init(id: String, role: Role, text: String, isFinal: Bool, timestamp: Date) {
        self.id = VoiceTextSafety.sanitizeIdentifier(id)
        self.role = role
        self.text = VoiceTextSafety.sanitizeVisibleText(text, limit: 1_024)
        self.isFinal = isFinal
        self.timestamp = timestamp
    }
}

struct VoiceAdapterGate: Equatable, Sendable {
    let installedSchemaCompatible: Bool
    let accountReady: Bool
    let capabilityReady: Bool
    let safeErrorCode: String?

    static let ready = VoiceAdapterGate(
        installedSchemaCompatible: true,
        accountReady: true,
        capabilityReady: true,
        safeErrorCode: nil
    )

    static func blocked(_ code: String) -> VoiceAdapterGate {
        VoiceAdapterGate(
            installedSchemaCompatible: false,
            accountReady: false,
            capabilityReady: false,
            safeErrorCode: VoiceTextSafety.sanitizeErrorCode(code)
        )
    }

    var isReady: Bool {
        installedSchemaCompatible && accountReady && capabilityReady
    }
}

@MainActor
protocol VoiceSessionAdapter: AnyObject {
    func probeCompatibility() async -> VoiceAdapterGate
    func start() async throws
    func setMuted(_ muted: Bool) async
    func closeAudioSession() async
    func stop() async
}

struct VoiceLaneSnapshot: Equatable, Sendable {
    let mode: VoiceLaneMode
    let connection: VoiceLaneConnection
    let activity: VoiceLaneActivity
    let muted: Bool
    let transcript: [VoiceTranscriptEvent]
    let transcriptPreview: String?
    let rootSessionID: String?
    let sessions: [VoiceSessionSummary]
    let visibleSessionCount: Int
    let safeErrorCode: String?
    let layoutBlockedReason: String?
    let uiAttached: Bool
    let restartAttempt: Int

    static let disabled = VoiceLaneSnapshot(
        mode: .disabled,
        connection: .disconnected,
        activity: .idle,
        muted: true,
        transcript: [],
        transcriptPreview: nil,
        rootSessionID: nil,
        sessions: [],
        visibleSessionCount: 0,
        safeErrorCode: nil,
        layoutBlockedReason: nil,
        uiAttached: false,
        restartAttempt: 0
    )
}

enum VoiceTextSafety {
    private static let sensitiveMarkers = ["authorization:", "token=", "api_key=", "apikey="]
    private static let absolutePathPattern = #"(?i)(?:^|[\s\"'(=])(?:file://|/(?:[^/\s]+/)*[^/\s]+|[a-z]:\\[^\s]+|\\\\[^\s]+)"#

    static func sanitizeVisibleText(_ value: String, limit: Int) -> String {
        let collapsed = value.unicodeScalars.map { scalar -> Unicode.Scalar in
            if scalar.value < 0x20 && scalar != "\n" && scalar != "\t" {
                return Unicode.Scalar(0x20)!
            }
            return scalar
        }
        var text = String(String.UnicodeScalarView(collapsed))
        let lowered = text.lowercased()
        if text.range(of: absolutePathPattern, options: .regularExpression) != nil
            || sensitiveMarkers.contains(where: { lowered.contains($0) }) {
            text = "[redacted]"
        }
        return String(text.unicodeScalars.prefix(max(0, limit)))
    }

    static func sanitizeIdentifier(_ value: String) -> String {
        let allowed = value.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || "-_.:".unicodeScalars.contains($0)
        }
        return String(String.UnicodeScalarView(allowed).prefix(160))
    }

    static func sanitizeErrorCode(_ value: String) -> String {
        let safeValue = sanitizeVisibleText(value, limit: 80)
        let normalized = safeValue.lowercased().map { character -> Character in
            character.isLetter || character.isNumber || character == "_" ? character : "_"
        }
        let result = String(normalized.prefix(80))
        return result.isEmpty ? "voice_unavailable" : result
    }
}

struct VoiceTranscriptBuffer: Sendable {
    static let maxEvents = 64
    static let maxUnicodeScalars = 8_192

    private(set) var events: [VoiceTranscriptEvent] = []

    mutating func append(_ event: VoiceTranscriptEvent) {
        events.append(event)
        if events.count > Self.maxEvents {
            events.removeFirst(events.count - Self.maxEvents)
        }
        trimToScalarBudget()
    }

    private mutating func trimToScalarBudget() {
        var total = events.reduce(0) { $0 + $1.text.unicodeScalars.count }
        while total > Self.maxUnicodeScalars, events.count > 1 {
            total -= events.removeFirst().text.unicodeScalars.count
        }
    }
}

enum VoiceSessionScope {
    static func visibleSessions(
        rootSessionID: String?,
        sessions: [VoiceSessionSummary]
    ) -> [VoiceSessionSummary] {
        guard let rootSessionID, !rootSessionID.isEmpty else { return [] }
        return sessions
            .filter { $0.rootSessionID == rootSessionID }
            .sorted {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.sessionID < $1.sessionID
            }
    }
}

enum VoiceLaneGeometry {
    static let compactHeight = 64.0

    static func expandedHeight(panelSizeRawValue: String) -> Double {
        switch panelSizeRawValue.lowercased() {
        case let value where value.contains("extra"):
            return 280
        case let value where value.contains("large"):
            return 250
        case let value where value.contains("small"):
            return 190
        default:
            return 220
        }
    }

    static func height(
        enabled: Bool,
        preference: VoiceLaneLayoutPreference,
        panelSizeRawValue: String
    ) -> Double {
        guard enabled else { return 0 }
        return preference == .compact ? compactHeight : expandedHeight(panelSizeRawValue: panelSizeRawValue)
    }

    static func height(panelSizeRawValue: String, mode: VoiceLaneMode) -> Double {
        switch mode {
        case .disabled:
            return 0
        case .compact:
            return compactHeight
        case .expanded:
            return expandedHeight(panelSizeRawValue: panelSizeRawValue)
        }
    }

    static func resolvedPreference(
        requested: VoiceLaneLayoutPreference,
        availableExtraHeight: Double,
        panelSizeRawValue: String
    ) -> VoiceLaneLayoutPreference {
        guard requested == .expanded else { return .compact }
        return availableExtraHeight >= expandedHeight(panelSizeRawValue: panelSizeRawValue)
            ? .expanded
            : .compact
    }
}

@MainActor
final class VoiceLaneRuntime: ObservableObject {
    static let shared = VoiceLaneRuntime()
    static let maxRetainedSessions = 64

    typealias AdapterFactory = @MainActor () -> any VoiceSessionAdapter

    @Published private(set) var snapshot: VoiceLaneSnapshot = .disabled

    private var featureEnabled = false
    private var preferredLayout: VoiceLaneLayoutPreference = .compact
    private var adapterFactory: AdapterFactory?
    private var adapter: (any VoiceSessionAdapter)?
    private var transcriptBuffer = VoiceTranscriptBuffer()
    private var allSessions: [String: VoiceSessionSummary] = [:]
    private var rootSessionID: String?
    private var configurationTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var restartGeneration = 0
    private var restartAttempt = 0
    private let restartDelaysNanoseconds: [UInt64]

    init(restartDelaysNanoseconds: [UInt64] = [0, 250_000_000, 1_000_000_000]) {
        self.restartDelaysNanoseconds = restartDelaysNanoseconds
    }

    @discardableResult
    func configure(
        featureEnabled: Bool,
        preferredLayout: VoiceLaneLayoutPreference,
        adapterFactory: AdapterFactory?
    ) -> Task<Void, Never> {
        let previousTask = configurationTask
        let task = Task { @MainActor [weak self] in
            await previousTask?.value
            guard let self else { return }
            await self.applyConfiguration(
                featureEnabled: featureEnabled,
                preferredLayout: preferredLayout,
                adapterFactory: adapterFactory
            )
        }
        configurationTask = task
        return task
    }

    private func applyConfiguration(
        featureEnabled: Bool,
        preferredLayout: VoiceLaneLayoutPreference,
        adapterFactory: AdapterFactory?
    ) async {
        let wasEnabled = self.featureEnabled
        self.preferredLayout = preferredLayout
        self.adapterFactory = adapterFactory
        if wasEnabled, featureEnabled {
            setPreferredLayout(preferredLayout)
            return
        }
        restartGeneration &+= 1
        let pendingRestart = restartTask
        pendingRestart?.cancel()
        restartTask = nil
        restartAttempt = 0

        guard featureEnabled else {
            if wasEnabled {
                publish(connection: .recovering, activity: .reconnecting, muted: true)
            }
            self.featureEnabled = false
            let previousAdapter = adapter
            adapter = nil
            transcriptBuffer = VoiceTranscriptBuffer()
            allSessions.removeAll()
            rootSessionID = nil
            if let previousAdapter {
                await previousAdapter.stop()
            }
            await pendingRestart?.value
            snapshot = .disabled
            return
        }

        self.featureEnabled = true
        publish(
            mode: preferredLayout == .expanded ? .expanded : .compact,
            connection: .disconnected,
            activity: .failed,
            muted: true,
            safeErrorCode: adapterFactory == nil ? "voice_adapter_unavailable" : nil
        )
        guard adapterFactory != nil else { return }
        scheduleStart(afterNanoseconds: 0)
    }

    func setPreferredLayout(_ preference: VoiceLaneLayoutPreference) {
        preferredLayout = preference
        guard featureEnabled else { return }
        publish(
            mode: preference == .expanded ? .expanded : .compact,
            clearLayoutBlockedReason: true
        )
    }

    func setResolvedLayout(
        requested: VoiceLaneLayoutPreference,
        resolved: VoiceLaneLayoutPreference
    ) {
        preferredLayout = requested
        guard featureEnabled else { return }
        publish(
            mode: resolved == .expanded ? .expanded : .compact,
            layoutBlockedReason: requested == .expanded && resolved == .compact
                ? "Expanded表示には画面の高さが足りません"
                : nil,
            clearLayoutBlockedReason: requested != .expanded || resolved == .expanded
        )
    }

    func attachPanel() {
        guard featureEnabled else { return }
        publish(uiAttached: true)
    }

    func detachPanel() {
        guard featureEnabled else { return }
        publish(muted: true, uiAttached: false)
        if let adapter {
            Task { await adapter.setMuted(true) }
        }
    }

    func setMuted(_ muted: Bool) {
        guard featureEnabled else { return }
        guard muted || (adapter != nil && snapshot.connection == .connected) else {
            publish(muted: true)
            return
        }
        publish(muted: muted)
        if let adapter {
            Task { await adapter.setMuted(muted) }
        }
    }

    func endAudioSession() {
        guard featureEnabled else { return }
        publish(
            activity: .idle,
            muted: true
        )
        if let adapter {
            Task { await adapter.closeAudioSession() }
        }
    }

    func recoverAfterSystemTransition() {
        guard featureEnabled else { return }
        restartGeneration &+= 1
        let recoveryGeneration = restartGeneration
        restartTask?.cancel()
        restartTask = nil
        let previousAdapter = adapter
        adapter = nil
        guard adapterFactory != nil else {
            publish(
                connection: .disconnected,
                activity: .failed,
                muted: true,
                safeErrorCode: "voice_adapter_unavailable"
            )
            if let previousAdapter {
                Task { await previousAdapter.stop() }
            }
            return
        }
        publish(connection: .recovering, activity: .reconnecting, muted: true)
        restartAfterStopping(previousAdapter, generation: recoveryGeneration, bounded: false)
    }

    func markAdapterCrashed() {
        guard featureEnabled else { return }
        restartGeneration &+= 1
        let crashGeneration = restartGeneration
        restartTask?.cancel()
        restartTask = nil
        let previousAdapter = adapter
        adapter = nil
        publish(
            connection: .recovering,
            activity: .reconnecting,
            muted: true,
            safeErrorCode: "voice_transport_crashed"
        )
        restartAfterStopping(previousAdapter, generation: crashGeneration, bounded: true)
    }

    func handleUnexpectedServerRequest(method: String) {
        guard featureEnabled else { return }
        _ = method
        let previousAdapter = adapter
        adapter = nil
        restartGeneration &+= 1
        restartTask?.cancel()
        publish(
            connection: .disconnected,
            activity: .failed,
            muted: true,
            safeErrorCode: "unexpected_server_request"
        )
        if let previousAdapter {
            Task { await previousAdapter.stop() }
        }
    }

    func appendTranscript(_ event: VoiceTranscriptEvent) {
        guard featureEnabled else { return }
        transcriptBuffer.append(event)
        publish()
    }

    func setRootSessionID(_ sessionID: String?) {
        let next = sessionID.map(VoiceTextSafety.sanitizeIdentifier)
        if next != rootSessionID {
            transcriptBuffer = VoiceTranscriptBuffer()
            allSessions.removeAll()
        }
        rootSessionID = next
        publish()
    }

    func upsertSession(_ summary: VoiceSessionSummary) {
        guard featureEnabled else { return }
        if let rootSessionID, summary.rootSessionID != rootSessionID {
            return
        }
        allSessions[summary.sessionID] = summary
        if allSessions.count > Self.maxRetainedSessions {
            let overflow = allSessions.values
                .sorted {
                    if $0.updatedAt != $1.updatedAt { return $0.updatedAt < $1.updatedAt }
                    return $0.sessionID < $1.sessionID
                }
                .prefix(allSessions.count - Self.maxRetainedSessions)
            overflow.forEach { allSessions.removeValue(forKey: $0.sessionID) }
        }
        publish()
    }

    func shutdown() async {
        let pendingConfiguration = configurationTask
        configurationTask = nil
        await pendingConfiguration?.value
        featureEnabled = false
        restartGeneration &+= 1
        let pendingRestart = restartTask
        pendingRestart?.cancel()
        restartTask = nil
        let currentAdapter = adapter
        adapter = nil
        if let currentAdapter {
            await currentAdapter.stop()
        }
        await pendingRestart?.value
        snapshot = .disabled
    }

    private func scheduleBoundedRestart() {
        guard restartAttempt < restartDelaysNanoseconds.count else {
            publish(
                connection: .disconnected,
                activity: .failed,
                muted: true,
                safeErrorCode: "voice_restart_exhausted"
            )
            return
        }
        let delay = restartDelaysNanoseconds[restartAttempt]
        restartAttempt += 1
        publish(restartAttempt: restartAttempt)
        scheduleStart(afterNanoseconds: delay)
    }

    private func scheduleStart(afterNanoseconds delay: UInt64) {
        guard featureEnabled, adapterFactory != nil else { return }
        restartGeneration &+= 1
        let generation = restartGeneration
        restartTask?.cancel()
        restartTask = Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard let self, !Task.isCancelled, generation == self.restartGeneration else { return }
            await self.startAdapter(generation: generation)
        }
    }

    private func startAdapter(generation: Int) async {
        guard featureEnabled,
              generation == restartGeneration,
              let adapterFactory else { return }

        publish(connection: .connecting, activity: .reconnecting, muted: true, clearSafeError: true)
        let candidate = adapterFactory()
        let gate = await candidate.probeCompatibility()
        guard featureEnabled, generation == restartGeneration else {
            await candidate.stop()
            return
        }
        guard gate.isReady else {
            await candidate.stop()
            adapter = nil
            let safeErrorCode = VoiceTextSafety.sanitizeErrorCode(
                gate.safeErrorCode ?? "voice_compatibility_blocked"
            )
            publish(
                connection: .disconnected,
                activity: .failed,
                muted: true,
                safeErrorCode: safeErrorCode
            )
            return
        }

        do {
            try await candidate.start()
            guard featureEnabled, generation == restartGeneration else {
                await candidate.stop()
                return
            }
            adapter = candidate
            restartAttempt = 0
            publish(
                connection: .connected,
                activity: .idle,
                muted: true,
                clearSafeError: true,
                restartAttempt: 0
            )
        } catch {
            await candidate.stop()
            guard featureEnabled, generation == restartGeneration else { return }
            adapter = nil
            publish(
                connection: .recovering,
                activity: .reconnecting,
                muted: true,
                safeErrorCode: "voice_start_failed"
            )
            scheduleBoundedRestart()
        }
    }

    private func restartAfterStopping(
        _ previousAdapter: (any VoiceSessionAdapter)?,
        generation: Int,
        bounded: Bool
    ) {
        Task { @MainActor [weak self] in
            if let previousAdapter {
                await previousAdapter.stop()
            }
            guard let self,
                  self.featureEnabled,
                  generation == self.restartGeneration else { return }
            if bounded {
                self.scheduleBoundedRestart()
            } else {
                self.scheduleStart(afterNanoseconds: self.restartDelaysNanoseconds.first ?? 0)
            }
        }
    }

    private func publish(
        mode: VoiceLaneMode? = nil,
        connection: VoiceLaneConnection? = nil,
        activity: VoiceLaneActivity? = nil,
        muted: Bool? = nil,
        safeErrorCode: String? = nil,
        clearSafeError: Bool = false,
        layoutBlockedReason: String? = nil,
        clearLayoutBlockedReason: Bool = false,
        uiAttached: Bool? = nil,
        restartAttempt: Int? = nil
    ) {
        guard featureEnabled else {
            snapshot = .disabled
            return
        }

        let scoped = VoiceSessionScope.visibleSessions(
            rootSessionID: rootSessionID,
            sessions: Array(allSessions.values)
        )
        let transcript = transcriptBuffer.events
        let preview = transcript.last.map { VoiceTextSafety.sanitizeVisibleText($0.text, limit: 240) }
        snapshot = VoiceLaneSnapshot(
            mode: mode ?? (snapshot.mode == .disabled
                ? (preferredLayout == .expanded ? .expanded : .compact)
                : snapshot.mode),
            connection: connection ?? snapshot.connection,
            activity: activity ?? snapshot.activity,
            muted: muted ?? snapshot.muted,
            transcript: transcript,
            transcriptPreview: preview,
            rootSessionID: rootSessionID,
            sessions: scoped,
            visibleSessionCount: scoped.count,
            safeErrorCode: clearSafeError ? nil : (safeErrorCode ?? snapshot.safeErrorCode),
            layoutBlockedReason: clearLayoutBlockedReason
                ? nil
                : (layoutBlockedReason ?? snapshot.layoutBlockedReason),
            uiAttached: uiAttached ?? snapshot.uiAttached,
            restartAttempt: restartAttempt ?? snapshot.restartAttempt
        )
    }
}

@MainActor
final class FakeVoiceSessionAdapter: VoiceSessionAdapter {
    var gate: VoiceAdapterGate
    var startFailuresRemaining: Int
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var closeAudioSessionCount = 0
    private(set) var muted = true

    init(gate: VoiceAdapterGate = .ready, startFailuresRemaining: Int = 0) {
        self.gate = gate
        self.startFailuresRemaining = startFailuresRemaining
    }

    func probeCompatibility() async -> VoiceAdapterGate {
        gate
    }

    func start() async throws {
        startCount += 1
        if startFailuresRemaining > 0 {
            startFailuresRemaining -= 1
            throw FakeVoiceSessionAdapterError.startFailed
        }
    }

    func setMuted(_ muted: Bool) async {
        self.muted = muted
    }

    func closeAudioSession() async {
        closeAudioSessionCount += 1
        muted = true
    }

    func stop() async {
        stopCount += 1
        muted = true
    }
}

enum FakeVoiceSessionAdapterError: Error {
    case startFailed
}
