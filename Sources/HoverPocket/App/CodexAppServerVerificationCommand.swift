import Foundation

enum CodexAppServerVerificationError: Error {
    case failed(String)
}

struct CodexAppServerVerificationResult {
    let installedCompatibility: CodexAppServerCompatibilityResult
}

@MainActor
enum CodexAppServerVerificationCommand {
    static func run() async throws -> CodexAppServerVerificationResult {
        try verifySchemaContract()
        try await verifyCapabilityBridge()
        guard CodexVoiceCoordinator.verifyRealtimeLifecyclePolicy() else {
            throw CodexAppServerVerificationError.failed("realtime_lifecycle_policy")
        }
        let installedCompatibility = try await verifyInstalledSchemaCache()
        guard CodexVoiceWebRTCEmbeddedContract.verifyOperationEpoch() else {
            throw CodexAppServerVerificationError.failed("webrtc_contract")
        }
        return CodexAppServerVerificationResult(
            installedCompatibility: installedCompatibility
        )
    }

    private static func verifySchemaContract() throws {
        let base = CodexAppServerSchemaContract.requiredMarkers.joined(separator: "\n")
        let missingPolicy = CodexAppServerSchemaContract.gate(
            schemaText: base,
            threadStartSchema: Data("{\"properties\":{}}".utf8)
        )
        guard !missingPolicy.isReady,
              missingPolicy.safeErrorCode == "codex_broker_only_tool_policy_missing" else {
            throw CodexAppServerVerificationError.failed("positive_tool_policy_missing")
        }
        let ready = CodexAppServerSchemaContract.gate(
            schemaText: base,
            threadStartSchema: Data(
                "{\"properties\":{\"dynamicToolsOnly\":{\"type\":\"boolean\"}}}".utf8
            )
        )
        guard ready.isReady else {
            throw CodexAppServerVerificationError.failed("positive_tool_policy_ready")
        }
    }

    private static func verifyCapabilityBridge() async throws {
        let runtime = CodexAppServerVerificationCapabilityRuntime()
        let bridge = CodexAppServerCapabilityBridge(runtime: runtime)
        guard bridge.dynamicTools.count == 1,
              bridge.dynamicTools[0].objectValue?["inputSchema"] != nil,
              bridge.dynamicTools[0].objectValue?["parameters"] == nil else {
            throw CodexAppServerVerificationError.failed("dynamic_tool_mapping")
        }
        let request = CodexAppServerRequest(
            id: .integer(1),
            method: "item/tool/call",
            params: .object([
                "arguments": .object(["durationSeconds": .integer(60)]),
                "callId": .string("call-1"),
                "threadId": .string("thread-1"),
                "tool": .string("timer_countdown_start"),
                "turnId": .string("turn-1")
            ])
        )
        let reply = await bridge.handle(
            request: request,
            context: CodexVoiceToolRequestContext(
                rootThreadID: "thread-1",
                clientGeneration: 1
            )
        )
        guard reply.error == nil,
              reply.result?.objectValue?["success"]?.boolValue == true,
              runtime.executionCount == 1 else {
            throw CodexAppServerVerificationError.failed("tool_bridge_execution")
        }

        let stale = await bridge.handle(
            request: request,
            context: CodexVoiceToolRequestContext(
                rootThreadID: "thread-stale",
                clientGeneration: 1
            )
        )
        guard stale.result?.objectValue?["success"]?.boolValue == false,
              runtime.executionCount == 1 else {
            throw CodexAppServerVerificationError.failed("tool_bridge_root_scope")
        }
    }

    private static func verifyInstalledSchemaCache() async throws
        -> CodexAppServerCompatibilityResult {
        let probe = CodexAppServerCompatibilityProbe.shared
        await probe.resetCacheForVerification()
        let first = await probe.probe()
        let second = await probe.probe()
        let count = await probe.schemaProbeExecutionCountForVerification()
        guard first == second, count == 1 else {
            throw CodexAppServerVerificationError.failed("schema_probe_cache")
        }
        if first.executableIdentity != nil,
           !(await probe.isCurrent(first)) {
            throw CodexAppServerVerificationError.failed("schema_probe_identity")
        }
        guard first.gate.isReady
                || first.gate.safeErrorCode == "codex_broker_only_tool_policy_missing" else {
            throw CodexAppServerVerificationError.failed(
                first.gate.safeErrorCode ?? "installed_schema_unknown"
            )
        }
        print("codex_app_server_installed_gate=\(first.gate.safeErrorCode ?? "ready")")
        print("codex_app_server_schema_probe_executions=\(count)")
        return first
    }
}

@MainActor
private final class CodexAppServerVerificationCapabilityRuntime: OpenAIRealtimeCapabilityExecuting {
    private(set) var executionCount = 0

    func sessionTools() throws -> [[String: Any]] {
        [[
            "type": "function",
            "name": "timer_countdown_start",
            "description": "Start a timer",
            "parameters": [
                "type": "object",
                "additionalProperties": false,
                "properties": ["durationSeconds": ["type": "integer"]],
                "required": ["durationSeconds"]
            ]
        ]]
    }

    func execute(
        sessionID: String,
        callID: String,
        toolName: String,
        argumentsJSON: String
    ) async -> String {
        _ = sessionID
        _ = callID
        _ = toolName
        _ = argumentsJSON
        executionCount += 1
        return "{\"status\":\"succeeded\"}"
    }

    func cancelSession(_ sessionID: String) {
        _ = sessionID
    }
}
