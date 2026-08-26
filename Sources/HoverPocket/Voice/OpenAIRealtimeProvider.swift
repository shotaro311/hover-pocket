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

@MainActor
final class OpenAIRealtimeMacOSVoiceSessionAdapter: VoiceSessionAdapter {
    private let credentialStore: any OpenAIRealtimeCredentialStoring
    private let capabilityRuntime: OpenAIRealtimeMacOSCapabilityRuntime?
    private let transport: OpenAIRealtimeMacOSTransport
    private weak var voiceRuntime: VoiceLaneRuntime?

    var requiresExplicitStart: Bool { true }

    init(
        credentialStore: any OpenAIRealtimeCredentialStoring = OpenAIRealtimeKeychainStore(),
        context: VoiceCapabilityContext? = nil,
        calendarAccessGranted: @escaping () -> Bool = { false },
        voiceRuntime: VoiceLaneRuntime = .shared,
        transport: OpenAIRealtimeMacOSTransport = .shared
    ) {
        self.credentialStore = credentialStore
        self.capabilityRuntime = context.flatMap {
            try? OpenAIRealtimeMacOSCapabilityRuntime(
                context: $0,
                calendarAccessGranted: calendarAccessGranted
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

    func stop() async {
        await transport.close()
        transport.clearCallbacks()
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
        credentialStore: any OpenAIRealtimeCredentialStoring = OpenAIRealtimeKeychainStore(),
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
                    calendarAccessGranted: { settings.voiceCalendarAccessEnabled },
                    voiceRuntime: voiceRuntime
                )
            }
        case .codexAppServer:
            { FailClosedVoiceProviderAdapter(code: "codex_voice_compatibility_blocked") }
        }
    }
}
