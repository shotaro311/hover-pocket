import Foundation

@MainActor
enum CodexVoiceE2EReceipt {
    private struct Receipt: Codable {
        let schemaVersion: Int
        let updatedAt: String
        let availability: String
        let sessionStatus: String
        let featureEnabled: Bool
        let rootThreadPresent: Bool
        let transportAttached: Bool
        let muted: Bool
        let transcriptEntryCount: Int
        let userTranscriptEntryCount: Int
        let assistantTranscriptEntryCount: Int
        let completeTranscriptEntryCount: Int
        let sessionCount: Int
        let appServerProcessPresent: Bool
        let voiceCount: Int
        let lastErrorCode: String?
        let microphoneAcquiredEver: Bool
        let remoteAudioTrackReceivedEver: Bool
        let remoteAudioPlaybackStartedEver: Bool
        let currentMicrophoneActive: Bool
        let currentRemoteAudioActive: Bool
        let lastTransportEvent: String
    }

    private static var latestSnapshot = CodexVoiceSnapshot(
        featureEnabled: false,
        availability: .disabled,
        sessionStatus: .idle,
        rootThreadID: nil,
        transportAttached: false,
        isMuted: true,
        transcript: [],
        sessions: [],
        lastErrorCode: nil,
        appServerProcessID: nil,
        restartAttempt: 0,
        voiceCount: 0
    )
    private static var microphoneAcquiredEver = false
    private static var remoteAudioTrackReceivedEver = false
    private static var remoteAudioPlaybackStartedEver = false
    private static var currentMicrophoneActive = false
    private static var currentRemoteAudioActive = false
    private static var lastTransportEvent = "idle"

    static func record(snapshot: CodexVoiceSnapshot) {
        guard HoverPocketApplicationData.usesIsolatedE2ERoot() else { return }
        latestSnapshot = snapshot
        write()
    }

    static func startSession() {
        guard HoverPocketApplicationData.usesIsolatedE2ERoot() else { return }
        currentMicrophoneActive = false
        currentRemoteAudioActive = false
        lastTransportEvent = "session_start_requested"
        write()
    }

    static func microphoneAcquired() {
        guard HoverPocketApplicationData.usesIsolatedE2ERoot() else { return }
        microphoneAcquiredEver = true
        currentMicrophoneActive = true
        lastTransportEvent = "microphone_acquired"
        write()
    }

    static func remoteAudioTrackReceived() {
        guard HoverPocketApplicationData.usesIsolatedE2ERoot() else { return }
        remoteAudioTrackReceivedEver = true
        currentRemoteAudioActive = true
        lastTransportEvent = "remote_audio_track"
        write()
    }

    static func remoteAudioPlaybackStarted() {
        guard HoverPocketApplicationData.usesIsolatedE2ERoot() else { return }
        remoteAudioPlaybackStartedEver = true
        currentRemoteAudioActive = true
        lastTransportEvent = "remote_audio_playing"
        write()
    }

    static func transportClosed(event: String) {
        guard HoverPocketApplicationData.usesIsolatedE2ERoot() else { return }
        currentMicrophoneActive = false
        currentRemoteAudioActive = false
        lastTransportEvent = event
        write()
    }

    static func transportEvent(_ event: String) {
        guard HoverPocketApplicationData.usesIsolatedE2ERoot() else { return }
        lastTransportEvent = event
        write()
    }

    private static func write() {
        let transcript = latestSnapshot.transcript
        let receipt = Receipt(
            schemaVersion: 1,
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            availability: latestSnapshot.availability.rawValue,
            sessionStatus: latestSnapshot.sessionStatus.rawValue,
            featureEnabled: latestSnapshot.featureEnabled,
            rootThreadPresent: latestSnapshot.rootThreadID != nil,
            transportAttached: latestSnapshot.transportAttached,
            muted: latestSnapshot.isMuted,
            transcriptEntryCount: transcript.count,
            userTranscriptEntryCount: transcript.count(where: { $0.role == "user" }),
            assistantTranscriptEntryCount: transcript.count(where: { $0.role == "assistant" }),
            completeTranscriptEntryCount: transcript.count(where: \.isComplete),
            sessionCount: latestSnapshot.sessions.count,
            appServerProcessPresent: latestSnapshot.appServerProcessID != nil,
            voiceCount: latestSnapshot.voiceCount,
            lastErrorCode: latestSnapshot.lastErrorCode,
            microphoneAcquiredEver: microphoneAcquiredEver,
            remoteAudioTrackReceivedEver: remoteAudioTrackReceivedEver,
            remoteAudioPlaybackStartedEver: remoteAudioPlaybackStartedEver,
            currentMicrophoneActive: currentMicrophoneActive,
            currentRemoteAudioActive: currentRemoteAudioActive,
            lastTransportEvent: lastTransportEvent
        )

        do {
            let root = HoverPocketApplicationData.rootDirectory()
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(receipt).write(
                to: root.appendingPathComponent("voice-e2e-receipt.json"),
                options: .atomic
            )
        } catch {
            NSLog("HoverPocket isolated Voice E2E receipt write failed")
        }
    }
}
