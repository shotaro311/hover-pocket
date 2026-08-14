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
    }

    func endSession() {
        guard isSessionActive else { return }
        isSessionActive = false
        isMuted = true
        statusText = nil
    }
}
