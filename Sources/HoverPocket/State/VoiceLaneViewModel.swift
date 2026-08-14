import Combine
import Foundation

@MainActor
final class VoiceLaneViewModel: ObservableObject {
    @Published private(set) var effectiveDisplayMode: VoiceLaneDisplayMode = .disabled
    @Published private(set) var expansionBlocked = false
    @Published private(set) var isSessionActive = false
    @Published private(set) var isMuted = true
    @Published private(set) var statusText: String?
    @Published private(set) var transcript: [VoiceLaneTranscriptLine] = []
    @Published private(set) var sessions: [VoiceLaneSessionCard] = []
    @Published private(set) var availability: CodexVoiceAvailability = .disabled
    @Published private(set) var sessionStatus: CodexVoiceSessionStatus = .idle

    private var setMutedHandler: ((Bool) -> Void)?
    private var endSessionHandler: (() -> Void)?
    private var startSessionHandler: (() -> Void)?

    func applyLayout(
        requested: VoiceLaneDisplayMode,
        resolved: VoiceLaneDisplayMode
    ) {
        effectiveDisplayMode = resolved
        expansionBlocked = requested == .expanded && resolved == .compact
    }

    func setMuted(_ muted: Bool) {
        guard isSessionActive else { return }
        isMuted = muted
        setMutedHandler?(muted)
    }

    func endSession() {
        guard isSessionActive else { return }
        sessionStatus = .stopping
        statusText = "stopping"
        endSessionHandler?()
    }

    func startSession() {
        guard availability == .ready, !isSessionActive else { return }
        startSessionHandler?()
    }

    func bindRuntimeActions(
        startSession: @escaping () -> Void,
        setMuted: @escaping (Bool) -> Void,
        endSession: @escaping () -> Void
    ) {
        startSessionHandler = startSession
        setMutedHandler = setMuted
        endSessionHandler = endSession
    }

    func applyVoiceSnapshot(_ snapshot: CodexVoiceSnapshot) {
        availability = snapshot.availability
        sessionStatus = snapshot.sessionStatus
        isMuted = snapshot.isMuted
        isSessionActive = snapshot.transportAttached || [
            .requestingPermission,
            .negotiating,
            .connecting,
            .connected,
            .muted,
            .stopping
        ].contains(snapshot.sessionStatus)
        statusText = Self.statusCode(snapshot)
        transcript = snapshot.transcript.enumerated().map { index, entry in
            VoiceLaneTranscriptLine(
                id: "\(entry.threadID):\(index):\(entry.updatedAt.timeIntervalSince1970)",
                speaker: entry.role == "user" ? .user : .assistant,
                text: entry.text,
                timestamp: entry.updatedAt
            )
        }
        if snapshot.rootThreadID == nil {
            sessions = []
        } else {
            sessions = [
                VoiceLaneSessionCard(
                    id: "current-root",
                    title: "current",
                    detail: snapshot.sessionStatus.rawValue,
                    state: Self.sessionCardState(snapshot.sessionStatus),
                    elapsedSeconds: 0
                )
            ]
        }
    }

    private static func statusCode(_ snapshot: CodexVoiceSnapshot) -> String? {
        if let error = snapshot.lastErrorCode {
            return "error:\(error)"
        }
        switch (snapshot.availability, snapshot.sessionStatus) {
        case (.disabled, _): return nil
        case (.starting, _): return "starting"
        case (.signedOut, _): return "signed_out"
        case (.unavailable, _): return "unavailable"
        case (.incompatible, _): return "incompatible"
        case (.faulted, _), (.blocked, _): return "faulted"
        case (.ready, .requestingPermission): return "requesting_permission"
        case (.ready, .negotiating): return "negotiating"
        case (.ready, .connecting): return "connecting"
        case (.ready, .connected): return "connected"
        case (.ready, .muted): return "muted"
        case (.ready, .reconnecting): return "reconnecting"
        case (.ready, .stopping): return "stopping"
        case (.ready, .closed): return "closed"
        case (.ready, .recoverableFailure): return "recoverable_failure"
        case (.ready, .blockedFailure): return "blocked_failure"
        case (.ready, .idle): return "ready"
        }
    }

    private static func sessionCardState(
        _ status: CodexVoiceSessionStatus
    ) -> VoiceLaneSessionState {
        switch status {
        case .closed:
            return .completed
        case .recoverableFailure, .blockedFailure:
            return .failed
        default:
            return .running
        }
    }
}
