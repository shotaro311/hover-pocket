import Foundation

@MainActor
enum CodexAppServerMacOSRuntime {
    static let host = CodexVoiceRuntimeHost(voiceRuntime: .shared)
    static let driver = CodexVoiceWebRTCDriver(runtimeHost: host)
}

@MainActor
final class CodexVoiceRuntimeHost {
    private weak var voiceRuntime: VoiceLaneRuntime?
    private let workspaceDirectory: URL
    private let injectedClientFactory: CodexVoiceCoordinator.ClientFactory?
    private var configuredExecutableURL: URL?
    private var configuredExecutableIdentity: String?
    private var configuredProfile: CodexVoiceAppServerProfile?
    private var toolAdapter: (any CodexVoiceCapabilityToolAdapterProtocol)?
    private var coordinator: CodexVoiceCoordinator?
    private var desiredEnabled = false
    private var lifecycleGeneration: UInt64 = 0
    private var panelVisible = false
    private var sessionsVisible = false
    private var microphonePermissionArmedUntil: Date?
    private var publishedTranscript: [CodexVoiceTranscriptEntry] = []
    private var publishedSessions: [String: CodexVoiceThreadSummary] = [:]
    private var publishedRootThreadID: String?
    private var publishedErrorCode: String?

    private(set) var snapshot = CodexVoiceRuntimeHost.disabledSnapshot

    init(
        voiceRuntime: VoiceLaneRuntime,
        workspaceDirectory: URL? = nil,
        clientFactory: CodexVoiceCoordinator.ClientFactory? = nil
    ) {
        self.voiceRuntime = voiceRuntime
        self.workspaceDirectory = workspaceDirectory
            ?? HoverPocketRuntimeEnvironment.shared.storageDirectory("VoiceWorkspace")
        self.injectedClientFactory = clientFactory
    }

    func configureToolAdapter(_ adapter: any CodexVoiceCapabilityToolAdapterProtocol) {
        guard !desiredEnabled, coordinator == nil else { return }
        toolAdapter = adapter
    }

    func configureExecutable(
        _ executableURL: URL,
        expectedIdentity: String,
        profile: CodexVoiceAppServerProfile
    ) -> Bool {
        let resolved = executableURL.standardizedFileURL.resolvingSymlinksInPath()
        if desiredEnabled || coordinator != nil {
            return configuredExecutableURL == resolved
                && configuredExecutableIdentity == expectedIdentity
                && configuredProfile == profile
        }
        configuredExecutableURL = resolved
        configuredExecutableIdentity = expectedIdentity
        configuredProfile = profile
        return true
    }

    func setEnabled(_ enabled: Bool) async {
        desiredEnabled = enabled
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration

        guard enabled else {
            microphonePermissionArmedUntil = nil
            let previous = coordinator
            coordinator = nil
            previous?.snapshotHandler = nil
            if let rootThreadID = snapshot.rootThreadID {
                toolAdapter?.cancelSession(rootThreadID)
            }
            if let previous {
                await previous.close()
            }
            guard generation == lifecycleGeneration else { return }
            resetPublishedState()
            snapshot = Self.disabledSnapshot
            return
        }

        guard coordinator == nil, let toolAdapter else { return }
        let resolvedClientFactory: CodexVoiceCoordinator.ClientFactory?
        if let injectedClientFactory {
            resolvedClientFactory = injectedClientFactory
        } else if let executableURL = configuredExecutableURL,
                  let expectedIdentity = configuredExecutableIdentity,
                  let profile = configuredProfile {
            resolvedClientFactory = {
                guard CodexAppServerCompatibilityProbe.identityToken(executableURL)
                        == expectedIdentity else {
                    throw CodexVoiceRuntimeError.compatibility("codex_executable_changed")
                }
                return try await CodexAppServerClient.start(
                    options: CodexAppServerClientOptions(
                        executableURL: executableURL,
                        launchArguments: CodexVoiceAppServerLaunchPolicy.arguments,
                        processEnvironment: profile.processEnvironment,
                        workingDirectoryURL: profile.codexHomeURL,
                        clientTitle: "HoverPocket Voice Lane",
                        clientVersion: Bundle.main.object(
                            forInfoDictionaryKey: "CFBundleShortVersionString"
                        ) as? String ?? "0.0.0",
                        experimentalAPI: true
                    )
                )
            }
        } else {
            resolvedClientFactory = nil
        }
        guard let resolvedClientFactory else {
            snapshot = CodexVoiceSnapshot(
                featureEnabled: true,
                availability: .incompatible,
                sessionStatus: .blockedFailure,
                rootThreadID: nil,
                transportAttached: false,
                isMuted: true,
                transcript: [],
                sessions: [],
                lastErrorCode: "codex_executable_not_pinned",
                appServerProcessID: nil,
                restartAttempt: 0,
                voiceCount: 0
            )
            publish(snapshot)
            return
        }
        let candidate = CodexVoiceCoordinator(
            featureEnabled: true,
            workspaceDirectory: workspaceDirectory,
            clientFactory: resolvedClientFactory,
            toolAdapter: toolAdapter
        )
        candidate.snapshotHandler = { [weak self, weak candidate] (snapshot: CodexVoiceSnapshot) in
            guard let self, let candidate, self.coordinator === candidate else { return }
            self.publish(snapshot)
        }
        coordinator = candidate
        candidate.setSessionsVisible(sessionsVisible)
        publish(candidate.snapshot)
        await candidate.initialize()

        guard desiredEnabled,
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

    func resetRealtimeForCapabilityChange(alreadyStopped: Bool = false) async {
        guard desiredEnabled, let coordinator else { return }
        if let rootThreadID = snapshot.rootThreadID {
            toolAdapter?.cancelSession(rootThreadID)
        }
        await coordinator.resetRealtimeSession(alreadyStopped: alreadyStopped)
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

    func setSessionsVisible(_ visible: Bool) {
        sessionsVisible = visible
        coordinator?.setSessionsVisible(visible)
    }

    func beginMicrophoneRequest(now: Date = Date()) -> Bool {
        guard desiredEnabled,
              panelVisible,
              snapshot.availability == .ready else {
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
              now <= deadline else { return false }
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
        voiceRuntime?.reportTransportActivity(.listening)
    }

    func markTransportDetached(reconnectExpected: Bool) {
        guard let sourceCoordinator = coordinator else { return }
        let sourceGeneration = lifecycleGeneration
        sourceCoordinator.detachTransport(reconnectExpected: reconnectExpected)
        let errorCode = reconnectExpected
            ? "webrtc_transport_detached"
            : "webrtc_transport_closed"
        Task { @MainActor [weak self] in
            guard let self else { return }
            await sourceCoordinator.stopRealtime()
            guard self.desiredEnabled,
                  self.lifecycleGeneration == sourceGeneration,
                  self.coordinator === sourceCoordinator else { return }
            self.voiceRuntime?.reportTransportFailure(errorCode)
        }
    }

    func markSessionFailure(_ errorCode: String) {
        microphonePermissionArmedUntil = nil
        coordinator?.markSessionFailure(errorCode)
        voiceRuntime?.reportTransportFailure(errorCode)
    }

    func setMuted(_ muted: Bool) {
        coordinator?.setMuted(muted)
    }

    func stopRealtime() async {
        await coordinator?.stopRealtime()
    }

    private func publish(_ snapshot: CodexVoiceSnapshot) {
        self.snapshot = snapshot
        guard desiredEnabled, let voiceRuntime else { return }

        if snapshot.rootThreadID != publishedRootThreadID {
            publishedRootThreadID = snapshot.rootThreadID
            publishedTranscript = []
            publishedSessions = [:]
            voiceRuntime.setRootSessionID(snapshot.rootThreadID)
        }
        if let rootThreadID = snapshot.rootThreadID {
            for (index, entry) in snapshot.transcript.enumerated() {
                guard index >= publishedTranscript.count
                        || publishedTranscript[index] != entry else { continue }
                let role: VoiceTranscriptEvent.Role = switch entry.role.lowercased() {
                case "user": .user
                case "assistant", "agent": .assistant
                default: .system
                }
                voiceRuntime.appendTranscript(VoiceTranscriptEvent(
                    id: "codex.transcript.\(index)",
                    rootSessionID: rootThreadID,
                    role: role,
                    text: entry.text,
                    isFinal: entry.isComplete,
                    timestamp: entry.updatedAt
                ))
            }
            publishedTranscript = snapshot.transcript

            for session in snapshot.sessions where publishedSessions[session.threadID] != session {
                let status: VoiceSessionStatus = switch session.state {
                case .running: .running
                case .completed: .succeeded
                case .failed: .failed
                }
                voiceRuntime.upsertSession(VoiceSessionSummary(
                    sessionID: session.threadID,
                    rootSessionID: rootThreadID,
                    parentSessionID: session.isCurrentRoot ? nil : rootThreadID,
                    title: session.isCurrentRoot ? "この会話" : session.title,
                    status: status,
                    safeSummary: session.detail,
                    updatedAt: session.updatedAt
                ))
                publishedSessions[session.threadID] = session
            }
        }

        if let errorCode = snapshot.lastErrorCode,
           errorCode != publishedErrorCode,
           ([.incompatible, .signedOut, .unavailable, .faulted, .blocked]
            .contains(snapshot.availability)
            || [.blockedFailure, .recoverableFailure].contains(snapshot.sessionStatus)) {
            publishedErrorCode = errorCode
            voiceRuntime.reportTransportFailure(errorCode)
        } else if snapshot.lastErrorCode == nil {
            publishedErrorCode = nil
        }
    }

    private func resetPublishedState() {
        publishedTranscript = []
        publishedSessions = [:]
        publishedRootThreadID = nil
        publishedErrorCode = nil
    }

    private static let disabledSnapshot = CodexVoiceSnapshot(
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
}
