import Foundation

/// Host-only AI module. Generation creates ephemeral threads; voice owns its
/// existing coordinator. Generated tools receive neither controller nor credentials.
@MainActor
enum PocketCodexLibrary {
    static let id = "pocket.codex"
    static let host = CodexVoiceRuntimeHost(voiceRuntime: .shared)
    static let driver = CodexVoiceWebRTCDriver(runtimeHost: host)

    static func makeGenerator(workspaceRoot: URL) throws -> CodexAppServerPocketGenerator {
        try CodexAppServerPocketGenerator(workspaceRoot: workspaceRoot)
    }
}
