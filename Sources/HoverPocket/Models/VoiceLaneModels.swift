import Foundation

enum VoiceLaneLayoutMode: String, CaseIterable, Identifiable {
    case compact
    case expanded

    var id: String { rawValue }

    func title(language: AppLanguage) -> String {
        switch (self, language) {
        case (.compact, .japanese):
            return "コンパクト"
        case (.compact, .english):
            return "Compact"
        case (.expanded, .japanese):
            return "拡張"
        case (.expanded, .english):
            return "Expanded"
        }
    }
}

enum VoiceLaneDisplayMode: String, CaseIterable {
    case disabled
    case compact
    case expanded
}

enum VoiceLaneSpeaker: String {
    case user
    case assistant
}

struct VoiceLaneTranscriptLine: Identifiable, Equatable {
    let id: String
    let speaker: VoiceLaneSpeaker
    let text: String
    let timestamp: Date
}

enum VoiceLaneSessionState: String {
    case running
    case completed
    case failed
}

struct VoiceLaneSessionCard: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let state: VoiceLaneSessionState
    let elapsedSeconds: Int
}

enum CodexVoiceAvailability: String, Equatable, Sendable {
    case disabled
    case starting
    case ready
    case signedOut
    case unavailable
    case incompatible
    case faulted
    case blocked
}

enum CodexVoiceSessionStatus: String, Equatable, Sendable {
    case idle
    case requestingPermission
    case negotiating
    case connecting
    case connected
    case muted
    case reconnecting
    case stopping
    case closed
    case recoverableFailure
    case blockedFailure
}

struct CodexVoiceTranscriptEntry: Equatable, Sendable {
    let threadID: String
    let role: String
    let text: String
    let isComplete: Bool
    let updatedAt: Date
}

struct CodexVoiceSnapshot: Equatable, Sendable {
    let featureEnabled: Bool
    let availability: CodexVoiceAvailability
    let sessionStatus: CodexVoiceSessionStatus
    let rootThreadID: String?
    let transportAttached: Bool
    let isMuted: Bool
    let transcript: [CodexVoiceTranscriptEntry]
    let lastErrorCode: String?
    let appServerProcessID: Int32?
    let restartAttempt: Int
    let voiceCount: Int
}

struct CodexVoiceWebRTCAnswer: Equatable, Sendable {
    let rootThreadID: String
    let sdp: String
}
