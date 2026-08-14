import Darwin
import Foundation

enum CodexAppServerLiveVerificationCommand {
    static func run() -> Never {
        Task {
            let exitCode = await verify()
            Darwin.exit(exitCode)
        }
        RunLoop.main.run()
        Darwin.exit(1)
    }

    private static func verify() async -> Int32 {
        var client: CodexAppServerClient?
        do {
            let connected = try await CodexAppServerClient.start(
                options: CodexAppServerClientOptions(
                    requestTimeout: 12,
                    clientTitle: "HoverPocket Live Voice Probe",
                    clientVersion: Bundle.main.object(
                        forInfoDictionaryKey: "CFBundleShortVersionString"
                    ) as? String ?? "0.0.0",
                    experimentalAPI: true
                )
            )
            client = connected

            let account = try await connected.sendRequest(
                "account/read",
                params: .object(["refreshToken": .bool(false)])
            )
            let rateLimits = try await connected.sendRequest(
                "account/rateLimits/read"
            )
            let voices = try await connected.sendRequest(
                "thread/realtime/listVoices",
                params: .object([:])
            )

            let accountReady = accountIsReady(account)
            let voiceSummary = summarizeVoices(voices)
            let rateLimitsReady = rateLimits.objectValue != nil
                || rateLimits.arrayValue != nil
            let metrics = await connected.metrics()
            let stderrCount = await connected.boundedErrorTail().count

            print("codex_live_initialize=ok")
            print("codex_live_account_ready=\(accountReady)")
            print("codex_live_rate_limits_ready=\(rateLimitsReady)")
            print("codex_live_voice_count=\(voiceSummary.count)")
            print("codex_live_default_voice_ready=\(voiceSummary.hasDefault)")
            print("codex_live_protocol_malformed=\(metrics.malformedOutputLines)")
            print("codex_live_protocol_unknown=\(metrics.unknownResponses)")
            print("codex_live_stderr_tail_count=\(stderrCount)")

            await connected.close()
            client = nil

            let passed = accountReady
                && rateLimitsReady
                && voiceSummary.count > 0
                && voiceSummary.hasDefault
                && metrics.malformedOutputLines == 0
                && metrics.unknownResponses == 0
            print(passed ? "PASS codex-app-server-live verify" : "FAIL codex-app-server-live verify")
            return passed ? 0 : 1
        } catch {
            if let client {
                await client.close()
            }
            print("codex_live_initialize=failed:\(String(describing: type(of: error)))")
            if let rpcError = error as? CodexAppServerRPCError {
                print("codex_live_rpc_code=\(rpcError.code)")
            }
            print("FAIL codex-app-server-live verify")
            return 1
        }
    }

    private static func accountIsReady(_ response: CodexJSONValue) -> Bool {
        guard let object = response.objectValue,
              let requiresAuth = object["requiresOpenaiAuth"]?.boolValue else {
            return false
        }
        return !requiresAuth || object["account"]?.objectValue != nil
    }

    private static func summarizeVoices(
        _ response: CodexJSONValue
    ) -> (count: Int, hasDefault: Bool) {
        guard let voices = response.objectValue?["voices"]?.objectValue else {
            return (0, false)
        }
        var unique = Set<String>()
        for value in voices.values {
            for item in value.arrayValue ?? [] {
                if let voice = item.stringValue, !voice.isEmpty {
                    unique.insert(voice)
                }
            }
        }
        let defaultVoice = voices["defaultV1"]?.stringValue
            ?? voices["defaultV2"]?.stringValue
        return (unique.count, !(defaultVoice?.isEmpty ?? true))
    }
}
