import Foundation

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

enum CodexVoiceThreadState: String, Equatable, Sendable {
    case running
    case completed
    case failed
}

struct CodexVoiceThreadSummary: Equatable, Sendable {
    let threadID: String
    let isCurrentRoot: Bool
    let title: String
    let detail: String
    let state: CodexVoiceThreadState
    let createdAt: Date
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
    let sessions: [CodexVoiceThreadSummary]
    let lastErrorCode: String?
    let appServerProcessID: Int32?
    let restartAttempt: Int
    let voiceCount: Int
}

struct CodexVoiceWebRTCAnswer: Equatable, Sendable {
    let rootThreadID: String
    let sdp: String
}
