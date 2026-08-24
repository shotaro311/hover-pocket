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
    static let macOSAudioTransportAvailable = false
}

protocol OpenAIRealtimeCredentialStoring: Sendable {
    func hasCredential() throws -> Bool
    func load() throws -> OpenAIRealtimeAPIKey?
    func save(_ apiKey: OpenAIRealtimeAPIKey) throws
    func delete() throws
}

enum OpenAIRealtimeMacOSTransportError: Error {
    case unavailableUntilAN3B3B
}

/// AN3-B3A intentionally stops before credential access. The provider/settings/keychain
/// seam is shared now; macOS capture/WebRTC transport remains the explicit AN3-B3B gate.
@MainActor
final class OpenAIRealtimeMacOSVoiceSessionAdapter: VoiceSessionAdapter {
    private let credentialStore: any OpenAIRealtimeCredentialStoring

    init(credentialStore: any OpenAIRealtimeCredentialStoring = OpenAIRealtimeKeychainStore()) {
        self.credentialStore = credentialStore
    }

    func probeCompatibility() async -> VoiceAdapterGate {
        _ = credentialStore // Keep the seam injected without reading the credential.
        guard OpenAIRealtimeFoundation.macOSAudioTransportAvailable else {
            return .blocked("openai_realtime_macos_transport_an3_b3b")
        }
        return .blocked("openai_realtime_macos_transport_an3_b3b")
    }

    func start() async throws {
        // Fail before any Keychain read or network request in AN3-B3A.
        throw OpenAIRealtimeMacOSTransportError.unavailableUntilAN3B3B
    }

    func setMuted(_ muted: Bool) async { _ = muted }
    func closeAudioSession() async { }
    func stop() async { }
}

@MainActor
final class FailClosedVoiceProviderAdapter: VoiceSessionAdapter {
    private let code: String

    init(code: String) {
        self.code = code
    }

    func probeCompatibility() async -> VoiceAdapterGate { .blocked(code) }
    func start() async throws { throw OpenAIRealtimeMacOSTransportError.unavailableUntilAN3B3B }
    func setMuted(_ muted: Bool) async { _ = muted }
    func closeAudioSession() async { }
    func stop() async { }
}

enum VoiceProviderAdapterFactory {
    @MainActor
    static func factory(
        providerID: VoiceProviderID,
        credentialStore: any OpenAIRealtimeCredentialStoring = OpenAIRealtimeKeychainStore()
    ) -> VoiceLaneRuntime.AdapterFactory? {
        switch providerID {
        case .off:
            nil
        case .openAIRealtimeBYOK:
            { OpenAIRealtimeMacOSVoiceSessionAdapter(credentialStore: credentialStore) }
        case .codexAppServer:
            { FailClosedVoiceProviderAdapter(code: "codex_voice_compatibility_blocked") }
        }
    }
}
