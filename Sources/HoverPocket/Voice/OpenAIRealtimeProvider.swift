import Foundation

enum VoiceProviderID: String, CaseIterable, Codable, Identifiable, Sendable {
    case off
    case openAIRealtimeBYOK = "openai_realtime_byok"
    case codexAppServer = "codex_app_server"

    var id: String { rawValue }
}

enum OpenAIRealtimeFoundation {
    static let modelID = "gpt-realtime-2.1"
    static let callsEndpoint = URL(string: "https://api.openai.com/v1/realtime/calls")!
    static let macOSAudioTransportAvailable = true
}

protocol OpenAIRealtimeCredentialStoring: Sendable {
    func hasCredential() throws -> Bool
    func load() throws -> OpenAIRealtimeAPIKey?
    func save(_ apiKey: OpenAIRealtimeAPIKey) throws
    func delete() throws
}

final class OpenAIRealtimeEphemeralCredentialStore: OpenAIRealtimeCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Data?

    func hasCredential() throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return bytes != nil
    }

    func load() throws -> OpenAIRealtimeAPIKey? {
        let snapshot: Data?
        lock.lock()
        snapshot = bytes
        lock.unlock()
        guard let snapshot,
              let value = String(data: snapshot, encoding: .utf8) else {
            return nil
        }
        return try OpenAIRealtimeAPIKey(value)
    }

    func save(_ apiKey: OpenAIRealtimeAPIKey) throws {
        let replacement = apiKey.withUTF8Bytes { Data($0) }
        lock.lock()
        clearBytesLocked()
        bytes = replacement
        lock.unlock()
    }

    func delete() throws {
        lock.lock()
        clearBytesLocked()
        lock.unlock()
    }

    deinit {
        clearBytesLocked()
    }

    private func clearBytesLocked() {
        let count = bytes?.count ?? 0
        if count > 0 {
            bytes?.resetBytes(in: 0..<count)
        }
        bytes = nil
    }
}

enum OpenAIRealtimeCredentialStoreFactory {
    static let shared: any OpenAIRealtimeCredentialStoring =
        make(isolatedVoiceE2E: HoverPocketRuntimeEnvironment.shared.isIsolatedVoiceE2E)

    static func make(isolatedVoiceE2E: Bool) -> any OpenAIRealtimeCredentialStoring {
        isolatedVoiceE2E
            ? OpenAIRealtimeEphemeralCredentialStore()
            : OpenAIRealtimeKeychainStore()
    }
}

@MainActor
final class OpenAIRealtimeMacOSVoiceSessionAdapter: VoiceSessionAdapter {
    private let credentialStore: any OpenAIRealtimeCredentialStoring
    private let capabilityRuntime: OpenAIRealtimeMacOSCapabilityRuntime?
    private let transport: OpenAIRealtimeMacOSTransport
    private weak var voiceRuntime: VoiceLaneRuntime?

    var requiresExplicitStart: Bool { true }

    init(
        credentialStore: any OpenAIRealtimeCredentialStoring = OpenAIRealtimeCredentialStoreFactory.shared,
        context: VoiceCapabilityContext? = nil,
        calendarAccessGranted: @escaping () -> Bool = { false },
        actionConfirmationEnabled: @escaping @MainActor () -> Bool = { true },
        destructiveConfirmationEnabled: @escaping @MainActor () -> Bool = { true },
        voiceRuntime: VoiceLaneRuntime = .shared,
        transport: OpenAIRealtimeMacOSTransport = .shared
    ) {
        self.credentialStore = credentialStore
        self.capabilityRuntime = context.flatMap {
            try? OpenAIRealtimeMacOSCapabilityRuntime(
                context: $0,
                calendarAccessGranted: calendarAccessGranted,
                actionConfirmationEnabled: actionConfirmationEnabled,
                destructiveConfirmationEnabled: destructiveConfirmationEnabled
            )
        }
        self.voiceRuntime = voiceRuntime
        self.transport = transport
    }

    func probeCompatibility() async -> VoiceAdapterGate {
        guard OpenAIRealtimeFoundation.macOSAudioTransportAvailable,
              capabilityRuntime != nil else {
            return .blocked("openai_realtime_macos_transport_unavailable")
        }
        do {
            guard try credentialStore.hasCredential() else {
                return .blocked("openai_realtime_key_missing")
            }
        } catch {
            return .blocked("openai_realtime_key_unavailable")
        }
        return .ready
    }

    func start() async throws {
        guard let capabilityRuntime else {
            throw OpenAIRealtimeMacOSTransportError.unavailable
        }
        transport.onRootSession = { [weak voiceRuntime] sessionID in
            voiceRuntime?.setRootSessionID(sessionID)
        }
        transport.onTranscript = { [weak voiceRuntime] event in
            voiceRuntime?.appendTranscript(event)
        }
        transport.onActivity = { [weak voiceRuntime] activity in
            voiceRuntime?.reportTransportActivity(activity)
        }
        transport.onFailure = { [weak voiceRuntime] code in
            voiceRuntime?.reportTransportFailure(code)
        }
        _ = try await transport.start(
            credentialStore: credentialStore,
            capabilities: capabilityRuntime
        )
    }

    func setMuted(_ muted: Bool) async {
        await transport.setMuted(muted)
    }

    func closeAudioSession() async {
        await transport.close()
    }

    func capabilityGrantsDidChange() async {
        await transport.close()
    }

    func stop() async {
        await transport.close()
        transport.clearCallbacks()
    }
}

@MainActor
final class CodexAppServerMacOSVoiceSessionAdapter: VoiceSessionAdapter {
    private let compatibilityProbe: any CodexAppServerCompatibilityChecking
    private let capabilityBridge: CodexAppServerCapabilityBridge?
    private let runtimeHost: CodexVoiceRuntimeHost
    private let driver: CodexVoiceWebRTCDriver
    private weak var voiceRuntime: VoiceLaneRuntime?
    private var compatibilityResult: CodexAppServerCompatibilityResult?
    private var startGeneration: UInt64 = 0

    var requiresExplicitStart: Bool { true }

    init(
        context: VoiceCapabilityContext?,
        calendarAccessGranted: @escaping () -> Bool,
        actionConfirmationEnabled: @escaping @MainActor () -> Bool = { true },
        destructiveConfirmationEnabled: @escaping @MainActor () -> Bool = { true },
        voiceRuntime: VoiceLaneRuntime = .shared,
        compatibilityProbe: any CodexAppServerCompatibilityChecking = CodexAppServerCompatibilityProbe.shared,
        runtimeHost: CodexVoiceRuntimeHost = PocketCodexLibrary.host,
        driver: CodexVoiceWebRTCDriver = PocketCodexLibrary.driver,
        capabilityBridge: CodexAppServerCapabilityBridge? = nil
    ) {
        self.compatibilityProbe = compatibilityProbe
        self.capabilityBridge = capabilityBridge ?? context.flatMap {
            guard let runtime = try? OpenAIRealtimeMacOSCapabilityRuntime(
                context: $0,
                calendarAccessGranted: calendarAccessGranted,
                actionConfirmationEnabled: actionConfirmationEnabled,
                destructiveConfirmationEnabled: destructiveConfirmationEnabled
            ) else { return nil }
            return CodexAppServerCapabilityBridge(runtime: runtime, appController: .shared,
                endVoiceSession: { [weak voiceRuntime] sessionID in
                    voiceRuntime?.endAudioSession(expectedRootSessionID: sessionID) ?? false
                })
        }
        self.runtimeHost = runtimeHost
        self.driver = driver
        self.voiceRuntime = voiceRuntime
    }

    func probeCompatibility() async -> VoiceAdapterGate {
        guard capabilityBridge != nil else {
            return .blocked("codex_capability_runtime_unavailable")
        }
        let result = await compatibilityProbe.probe(
            explicitURL: nil,
            dynamicTools: capabilityBridge?.dynamicTools ?? []
        )
        compatibilityResult = result
        return result.gate
    }

    func start() async throws {
        startGeneration &+= 1
        let generation = startGeneration
        do {
            try checkStartCancellation(generation)
            guard let capabilityBridge else {
                throw CodexVoiceRuntimeError.compatibility("codex_capability_runtime_unavailable")
            }
            guard var compatibilityResult = self.compatibilityResult else {
                throw CodexVoiceRuntimeError.compatibility("codex_compatibility_not_ready")
            }

            if !compatibilityResult.gate.isReady {
                compatibilityResult = await compatibilityProbe.probe(
                    explicitURL: compatibilityResult.executableURL,
                    dynamicTools: capabilityBridge.dynamicTools
                )
                try checkStartCancellation(generation)
                self.compatibilityResult = compatibilityResult
            }
            guard compatibilityResult.gate.isReady else {
                throw CodexVoiceRuntimeError.compatibility(
                    compatibilityResult.gate.safeErrorCode ?? "codex_compatibility_not_ready"
                )
            }

            let revalidation = await compatibilityProbe.revalidateForStart(
                compatibilityResult,
                dynamicTools: capabilityBridge.dynamicTools
            )
            try checkStartCancellation(generation)
            guard let compatibilityResult = revalidation.result,
                  compatibilityResult.gate.isReady,
                  let executableURL = compatibilityResult.executableURL,
                  let executableIdentity = compatibilityResult.executableIdentity,
                  let profile = compatibilityResult.appServerProfile else {
                if !revalidation.refreshed {
                    self.compatibilityResult = revalidation.result
                }
                throw CodexVoiceRuntimeError.compatibility(
                    revalidation.result?.gate.safeErrorCode
                        ?? "codex_executable_changed"
                )
            }
            self.compatibilityResult = compatibilityResult
            guard await compatibilityProbe.isCurrent(compatibilityResult) else {
                throw CodexVoiceRuntimeError.compatibility("codex_executable_changed")
            }
            try checkStartCancellation(generation)

            let executableConfigured: Bool
            if revalidation.refreshed {
                executableConfigured = await runtimeHost.reconfigureExecutable(
                    executableURL,
                    expectedIdentity: executableIdentity,
                    profile: profile
                )
                try checkStartCancellation(generation)
            } else {
                executableConfigured = runtimeHost.configureExecutable(
                    executableURL,
                    expectedIdentity: executableIdentity,
                    profile: profile
                )
            }
            guard executableConfigured else {
                throw CodexVoiceRuntimeError.compatibility("codex_executable_configuration_conflict")
            }
            runtimeHost.configureToolAdapter(capabilityBridge)
            runtimeHost.setPanelVisible(voiceRuntime?.snapshot.uiAttached == true)
            runtimeHost.setSessionsVisible(voiceRuntime?.snapshot.mode == .expanded)
            await runtimeHost.setEnabled(true)
            try checkStartCancellation(generation)
            guard runtimeHost.snapshot.availability == .ready else {
                throw CodexVoiceRuntimeError.compatibility(
                    runtimeHost.snapshot.lastErrorCode ?? "codex_app_server_unavailable"
                )
            }
            try await driver.startSession()
            try checkStartCancellation(generation)
        } catch {
            if Task.isCancelled, generation == startGeneration {
                await driver.stopSession()
                if generation == startGeneration {
                    await runtimeHost.setEnabled(false)
                }
            }
            throw error
        }
    }

    private func checkStartCancellation(_ generation: UInt64) throws {
        try Task.checkCancellation()
        guard generation == startGeneration else { throw CancellationError() }
    }

    func setMuted(_ muted: Bool) async {
        driver.setMuted(muted)
    }

    func setPanelVisible(_ visible: Bool) {
        runtimeHost.setPanelVisible(visible)
    }

    func setPresentationMode(_ mode: VoiceLaneMode) async {
        runtimeHost.setSessionsVisible(mode == .expanded)
    }

    func capabilityGrantsDidChange() async {
        await driver.stopSession()
        await runtimeHost.resetRealtimeForCapabilityChange(alreadyStopped: true)
    }

    func closeAudioSession() async {
        await driver.stopSession()
    }

    func stop() async {
        startGeneration &+= 1
        await driver.stopSession()
        await runtimeHost.setEnabled(false)
    }
}

@MainActor
final class FailClosedVoiceProviderAdapter: VoiceSessionAdapter {
    private let code: String

    init(code: String) {
        self.code = code
    }

    func probeCompatibility() async -> VoiceAdapterGate { .blocked(code) }
    func start() async throws { throw OpenAIRealtimeMacOSTransportError.unavailable }
    func setMuted(_ muted: Bool) async { _ = muted }
    func closeAudioSession() async { }
    func stop() async { }
}

enum VoiceProviderAdapterFactory {
    @MainActor
    static func factory(
        providerID: VoiceProviderID,
        credentialStore: any OpenAIRealtimeCredentialStoring = OpenAIRealtimeCredentialStoreFactory.shared,
        settings: AppSettings,
        voiceRuntime: VoiceLaneRuntime = .shared
    ) -> VoiceLaneRuntime.AdapterFactory? {
        switch providerID {
        case .off:
            nil
        case .openAIRealtimeBYOK:
            {
                OpenAIRealtimeMacOSVoiceSessionAdapter(
                    credentialStore: credentialStore,
                    context: AINativeRuntime.shared.voiceCapabilityContext,
                    calendarAccessGranted: {
                        settings.voiceCalendarAccessEnabled
                            && HoverPocketRuntimeEnvironment.shared.externalIntegrationsEnabled
                    },
                    actionConfirmationEnabled: {
                        settings.voiceActionConfirmationEnabled
                    },
                    destructiveConfirmationEnabled: {
                        settings.voiceDestructiveConfirmationEnabled
                    },
                    voiceRuntime: voiceRuntime
                )
            }
        case .codexAppServer:
            {
                CodexAppServerMacOSVoiceSessionAdapter(
                    context: AINativeRuntime.shared.voiceCapabilityContext,
                    calendarAccessGranted: {
                        settings.voiceCalendarAccessEnabled
                            && HoverPocketRuntimeEnvironment.shared.externalIntegrationsEnabled
                    },
                    actionConfirmationEnabled: {
                        settings.voiceActionConfirmationEnabled
                    },
                    destructiveConfirmationEnabled: {
                        settings.voiceDestructiveConfirmationEnabled
                    },
                    voiceRuntime: voiceRuntime
                )
            }
        }
    }
}
