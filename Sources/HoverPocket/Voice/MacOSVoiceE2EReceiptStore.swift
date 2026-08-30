import AppKit
import Foundation

enum MacOSVoiceE2EMediaEvent: String, CaseIterable, Sendable {
    case microphoneAcquired
    case microphoneStopped
    case remoteAudioTrackReceived
    case remoteAudioTrackStopped
    case remoteAudioPlaybackSucceeded
    case remoteAudioPlaybackFailed
    case remoteAudioPlaybackStopped
}

struct MacOSVoiceE2EReceipt: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let providerId: String
    let featureEnabled: Bool
    let connection: String
    let rootSessionPresent: Bool
    let microphoneAcquired: Bool
    let microphoneCurrent: Bool
    let remoteAudioTrackEver: Bool
    let remoteAudioTrackCurrent: Bool
    let remoteAudioPlaybackEver: Bool
    let remoteAudioPlaybackCurrent: Bool
    let userTranscriptCount: Int
    let assistantTranscriptCount: Int
    let timerCapabilityReadbackVerified: Bool
    let physicalMediaUserConfirmed: Bool
    let credentialCurrent: Bool
    let lastSafeEvent: String
}

@MainActor
final class MacOSVoiceE2EReceiptStore {
    static let expectedPhysicalProviderID = VoiceProviderID.codexAppServer.rawValue

    static let allowedKeys: Set<String> = [
        "schemaVersion",
        "providerId",
        "featureEnabled",
        "connection",
        "rootSessionPresent",
        "microphoneAcquired",
        "microphoneCurrent",
        "remoteAudioTrackEver",
        "remoteAudioTrackCurrent",
        "remoteAudioPlaybackEver",
        "remoteAudioPlaybackCurrent",
        "userTranscriptCount",
        "assistantTranscriptCount",
        "timerCapabilityReadbackVerified",
        "physicalMediaUserConfirmed",
        "credentialCurrent",
        "lastSafeEvent"
    ]

    static let shared: MacOSVoiceE2EReceiptStore? = {
        guard HoverPocketRuntimeEnvironment.shared.isIsolatedVoiceE2E else { return nil }
        return try? MacOSVoiceE2EReceiptStore(
            receiptURL: HoverPocketRuntimeEnvironment.shared.voiceE2EReceiptURL
        )
    }()

    private let receiptURL: URL
    private var providerID = VoiceProviderID.codexAppServer.rawValue
    private var featureEnabled = false
    private var connection = VoiceLaneConnection.disconnected.rawValue
    private var rootSessionPresent = false
    private var microphoneAcquired = false
    private var microphoneCurrent = false
    private var remoteAudioTrackEver = false
    private var remoteAudioTrackCurrent = false
    private var remoteAudioPlaybackEver = false
    private var remoteAudioPlaybackCurrent = false
    private var userTranscriptCount = 0
    private var assistantTranscriptCount = 0
    private var timerCapabilityReadbackVerified = false
    private var physicalMediaUserConfirmed = false
    private var physicalConfirmationRequested = false
    private var mediaAttemptID: UInt64 = 0
    private var mediaAttemptProviderID = VoiceProviderID.off.rawValue
    private var credentialCurrent = false
    private var lastSafeEvent = "initialized"

    init(receiptURL: URL) throws {
        self.receiptURL = receiptURL
        try write()
    }

    func recordVoiceSnapshot(_ snapshot: VoiceLaneSnapshot, credentialCurrent: Bool) {
        MacOSVoiceE2EPerformanceStore.shared?.recordSnapshotPublish()
        let previousUserTranscriptCount = userTranscriptCount
        let previousAssistantTranscriptCount = assistantTranscriptCount
        let nextProviderID = snapshot.providerID.rawValue
        if providerID != nextProviderID {
            invalidateProviderBoundEvidence()
        }
        providerID = nextProviderID
        featureEnabled = snapshot.mode != .disabled
        connection = snapshot.connection.rawValue
        rootSessionPresent = snapshot.rootSessionID != nil
        if providerID == Self.expectedPhysicalProviderID,
           mediaAttemptProviderID == Self.expectedPhysicalProviderID {
            userTranscriptCount = snapshot.transcript.filter {
                $0.role == .user && $0.isFinal
            }.count
            assistantTranscriptCount = snapshot.transcript.filter {
                $0.role == .assistant && $0.isFinal
            }.count
        } else {
            userTranscriptCount = 0
            assistantTranscriptCount = 0
        }
        self.credentialCurrent = credentialCurrent
        lastSafeEvent = "voice_snapshot"
        try? write()
        if userTranscriptCount != previousUserTranscriptCount
            || assistantTranscriptCount != previousAssistantTranscriptCount {
            MacOSVoiceE2EPerformanceStore.shared?.flush(event: "transcript_final")
        }
    }

    @discardableResult
    func beginMediaSession() -> UInt64 {
        MacOSVoiceE2EPerformanceStore.shared?.beginMediaAttempt()
        mediaAttemptID &+= 1
        mediaAttemptProviderID = providerID
        microphoneAcquired = false
        microphoneCurrent = false
        remoteAudioTrackEver = false
        remoteAudioTrackCurrent = false
        remoteAudioPlaybackEver = false
        remoteAudioPlaybackCurrent = false
        userTranscriptCount = 0
        assistantTranscriptCount = 0
        timerCapabilityReadbackVerified = false
        physicalMediaUserConfirmed = false
        physicalConfirmationRequested = false
        lastSafeEvent = "media_session_started"
        try? write()
        return mediaAttemptID
    }

    func recordMediaEvent(_ event: MacOSVoiceE2EMediaEvent) {
        switch event {
        case .microphoneAcquired:
            microphoneAcquired = true
            microphoneCurrent = true
        case .microphoneStopped:
            microphoneCurrent = false
        case .remoteAudioTrackReceived:
            remoteAudioTrackEver = true
            remoteAudioTrackCurrent = true
        case .remoteAudioTrackStopped:
            remoteAudioTrackCurrent = false
        case .remoteAudioPlaybackSucceeded:
            remoteAudioPlaybackEver = true
            remoteAudioPlaybackCurrent = true
        case .remoteAudioPlaybackFailed:
            remoteAudioPlaybackCurrent = false
        case .remoteAudioPlaybackStopped:
            remoteAudioPlaybackCurrent = false
        }
        lastSafeEvent = event.rawValue
        try? write()
    }

    func recordSafeClose(performanceFlushSynchronously: Bool = false) {
        microphoneCurrent = false
        remoteAudioTrackCurrent = false
        remoteAudioPlaybackCurrent = false
        lastSafeEvent = "safe_close"
        try? write()
        if performanceFlushSynchronously {
            try? MacOSVoiceE2EPerformanceStore.shared?.flushSynchronously(
                event: "safe_close"
            )
        } else {
            MacOSVoiceE2EPerformanceStore.shared?.flush(event: "safe_close")
        }
    }

    func recordTimerCapabilityReadbackVerified() {
        guard providerID == Self.expectedPhysicalProviderID,
              mediaAttemptProviderID == Self.expectedPhysicalProviderID else {
            return
        }
        timerCapabilityReadbackVerified = true
        lastSafeEvent = "timer_readback_verified"
        try? write()
        MacOSVoiceE2EPerformanceStore.shared?.flush(event: "timer_readback_verified")
    }

    func claimPhysicalConfirmationRequest() -> UInt64? {
        guard providerID == Self.expectedPhysicalProviderID,
              mediaAttemptProviderID == Self.expectedPhysicalProviderID,
              featureEnabled,
              connection == VoiceLaneConnection.connected.rawValue,
              microphoneAcquired,
              microphoneCurrent,
              remoteAudioTrackCurrent,
              remoteAudioPlaybackEver,
              remoteAudioPlaybackCurrent,
              credentialCurrent,
              !physicalMediaUserConfirmed,
              !physicalConfirmationRequested else { return nil }
        physicalConfirmationRequested = true
        lastSafeEvent = "physical_confirmation_requested"
        try? write()
        return mediaAttemptID
    }

    @discardableResult
    func recordPhysicalMediaUserConfirmation(
        _ confirmed: Bool,
        attemptID: UInt64
    ) -> Bool {
        guard attemptID == mediaAttemptID,
              providerID == Self.expectedPhysicalProviderID,
              mediaAttemptProviderID == Self.expectedPhysicalProviderID,
              featureEnabled,
              connection == VoiceLaneConnection.connected.rawValue,
              microphoneCurrent,
              remoteAudioTrackCurrent,
              remoteAudioPlaybackCurrent,
              credentialCurrent,
              physicalConfirmationRequested else { return false }
        if confirmed {
            physicalMediaUserConfirmed = true
            lastSafeEvent = "physical_media_user_confirmed"
        } else {
            lastSafeEvent = "physical_media_user_not_confirmed"
        }
        try? write()
        MacOSVoiceE2EPerformanceStore.shared?.flush(
            event: confirmed
                ? "physical_media_user_confirmed"
                : "physical_media_user_not_confirmed"
        )
        return true
    }

    func recordCredentialCurrent(_ current: Bool) {
        credentialCurrent = current
        lastSafeEvent = current ? "credential_available" : "credential_cleared"
        try? write()
    }

    func readback() throws -> MacOSVoiceE2EReceipt {
        let data = try Data(contentsOf: receiptURL)
        return try JSONDecoder().decode(MacOSVoiceE2EReceipt.self, from: data)
    }

    private func snapshot() -> MacOSVoiceE2EReceipt {
        MacOSVoiceE2EReceipt(
            schemaVersion: 1,
            providerId: providerID,
            featureEnabled: featureEnabled,
            connection: connection,
            rootSessionPresent: rootSessionPresent,
            microphoneAcquired: microphoneAcquired,
            microphoneCurrent: microphoneCurrent,
            remoteAudioTrackEver: remoteAudioTrackEver,
            remoteAudioTrackCurrent: remoteAudioTrackCurrent,
            remoteAudioPlaybackEver: remoteAudioPlaybackEver,
            remoteAudioPlaybackCurrent: remoteAudioPlaybackCurrent,
            userTranscriptCount: userTranscriptCount,
            assistantTranscriptCount: assistantTranscriptCount,
            timerCapabilityReadbackVerified: timerCapabilityReadbackVerified,
            physicalMediaUserConfirmed: physicalMediaUserConfirmed,
            credentialCurrent: credentialCurrent,
            lastSafeEvent: lastSafeEvent
        )
    }

    private func invalidateProviderBoundEvidence() {
        mediaAttemptID &+= 1
        mediaAttemptProviderID = VoiceProviderID.off.rawValue
        microphoneAcquired = false
        microphoneCurrent = false
        remoteAudioTrackEver = false
        remoteAudioTrackCurrent = false
        remoteAudioPlaybackEver = false
        remoteAudioPlaybackCurrent = false
        userTranscriptCount = 0
        assistantTranscriptCount = 0
        timerCapabilityReadbackVerified = false
        physicalMediaUserConfirmed = false
        physicalConfirmationRequested = false
    }

    private func write() throws {
        let data = try JSONEncoder.sorted.encode(snapshot())
        try FileManager.default.createDirectory(
            at: receiptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: receiptURL, options: .atomic)
    }
}

@MainActor
enum MacOSVoiceE2EPhysicalMediaConfirmation {
    static func present() async -> Bool {
        guard let hostWindow = NSApp.keyWindow
            ?? NSApp.mainWindow
            ?? NSApp.windows.first(where: { $0.isVisible }) else {
            return false
        }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "実音声E2Eを確認"
        alert.informativeText = "マイクで話した内容が認識され、Codexの音声が実際に聞こえた場合だけ確認してください。"
        alert.addButton(withTitle: "話せた・聞こえた")
        alert.addButton(withTitle: "未確認")
        NSApp.activate(ignoringOtherApps: true)
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: hostWindow) { response in
                continuation.resume(returning: response == .alertFirstButtonReturn)
            }
        }
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
