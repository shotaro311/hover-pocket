import Foundation

@MainActor
final class CodexVoiceRuntimeHost {
    private weak var viewModel: VoiceLaneViewModel?
    private let workspaceDirectory: URL
    private let clientFactory: CodexVoiceCoordinator.ClientFactory?
    private var coordinator: CodexVoiceCoordinator?
    private var desiredEnabled = false
    private var lifecycleGeneration: UInt64 = 0
    private var isDisposed = false
    private var panelVisible = false
    private var microphonePermissionArmedUntil: Date?

    private(set) var snapshot = CodexVoiceRuntimeHost.disabledSnapshot

    init(
        viewModel: VoiceLaneViewModel,
        workspaceDirectory: URL? = nil,
        clientFactory: CodexVoiceCoordinator.ClientFactory? = nil
    ) {
        self.viewModel = viewModel
        self.workspaceDirectory = workspaceDirectory ?? Self.defaultWorkspaceDirectory()
        self.clientFactory = clientFactory
        viewModel.applyVoiceSnapshot(Self.disabledSnapshot)
    }

    func setEnabled(_ enabled: Bool) async {
        guard !isDisposed else { return }
        desiredEnabled = enabled
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration

        guard enabled else {
            microphonePermissionArmedUntil = nil
            let previous = coordinator
            coordinator = nil
            previous?.snapshotHandler = nil
            if let previous {
                await previous.close()
            }
            guard !isDisposed, generation == lifecycleGeneration else { return }
            publish(Self.disabledSnapshot)
            return
        }

        guard coordinator == nil else { return }
        let candidate = CodexVoiceCoordinator(
            featureEnabled: true,
            workspaceDirectory: workspaceDirectory,
            clientFactory: clientFactory
        )
        candidate.snapshotHandler = { [weak self, weak candidate] snapshot in
            guard let self, let candidate, self.coordinator === candidate else { return }
            self.publish(snapshot)
        }
        coordinator = candidate
        publish(candidate.snapshot)
        await candidate.initialize()

        guard !isDisposed,
              desiredEnabled,
              generation == lifecycleGeneration,
              coordinator === candidate else {
            candidate.snapshotHandler = nil
            if coordinator === candidate {
                coordinator = nil
            }
            await candidate.close()
            return
        }
        publish(candidate.snapshot)
    }

    func clearTransientUIState() {
        panelVisible = false
        microphonePermissionArmedUntil = nil
        coordinator?.clearTransientUIState()
    }

    func setPanelVisible(_ visible: Bool) {
        panelVisible = visible
        if !visible {
            microphonePermissionArmedUntil = nil
        }
    }

    func beginMicrophoneRequest(now: Date = Date()) -> Bool {
        guard desiredEnabled,
              panelVisible,
              snapshot.availability == .ready,
              !isDisposed else {
            microphonePermissionArmedUntil = nil
            return false
        }
        microphonePermissionArmedUntil = now.addingTimeInterval(5)
        coordinator?.markSessionRequestingPermission()
        return true
    }

    func consumeMicrophonePermission(now: Date = Date()) -> Bool {
        defer { microphonePermissionArmedUntil = nil }
        guard desiredEnabled,
              panelVisible,
              snapshot.availability == .ready,
              let deadline = microphonePermissionArmedUntil,
              now <= deadline,
              !isDisposed else {
            return false
        }
        return true
    }

    func startWebRTC(sdpOffer: String) async throws -> CodexVoiceWebRTCAnswer {
        guard let coordinator else {
            throw CodexVoiceRuntimeError.compatibility("voice_not_enabled")
        }
        return try await coordinator.startWebRTC(sdpOffer: sdpOffer)
    }

    func markTransportAttached() {
        coordinator?.markTransportAttached()
    }

    func markTransportDetached(reconnectExpected: Bool) {
        coordinator?.detachTransport(reconnectExpected: reconnectExpected)
    }

    func markSessionFailure(_ errorCode: String) {
        coordinator?.markSessionFailure(errorCode)
    }

    func setMuted(_ muted: Bool) {
        coordinator?.setMuted(muted)
    }

    func stopRealtime() async {
        await coordinator?.stopRealtime()
    }

    func dispose() async {
        guard !isDisposed else { return }
        isDisposed = true
        desiredEnabled = false
        panelVisible = false
        microphonePermissionArmedUntil = nil
        lifecycleGeneration &+= 1
        let previous = coordinator
        coordinator = nil
        previous?.snapshotHandler = nil
        if let previous {
            await previous.close()
        }
        publish(Self.disabledSnapshot)
    }

    private func publish(_ snapshot: CodexVoiceSnapshot) {
        self.snapshot = snapshot
        viewModel?.applyVoiceSnapshot(snapshot)
    }

    private static let disabledSnapshot = CodexVoiceSnapshot(
        featureEnabled: false,
        availability: .disabled,
        sessionStatus: .idle,
        rootThreadID: nil,
        transportAttached: false,
        isMuted: true,
        transcript: [],
        lastErrorCode: nil,
        appServerProcessID: nil,
        restartAttempt: 0,
        voiceCount: 0
    )

    private static func defaultWorkspaceDirectory() -> URL {
        if let applicationSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            return applicationSupport
                .appendingPathComponent("HoverPocket", isDirectory: true)
                .appendingPathComponent("VoiceWorkspace", isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("HoverPocket", isDirectory: true)
            .appendingPathComponent("VoiceWorkspace", isDirectory: true)
    }
}
