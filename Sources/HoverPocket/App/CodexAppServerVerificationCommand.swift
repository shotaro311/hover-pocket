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
        try verifyChatGPTAccountPolicy()
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

    private static func verifyChatGPTAccountPolicy() throws {
        let chatGPT: CodexJSONValue = .object([
            "requiresOpenaiAuth": .bool(true),
            "account": .object(["type": .string("chatgpt")])
        ])
        let apiKey: CodexJSONValue = .object([
            "requiresOpenaiAuth": .bool(true),
            "account": .object(["type": .string("apiKey")])
        ])
        let signedOut: CodexJSONValue = .object([
            "requiresOpenaiAuth": .bool(true),
            "account": .null
        ])
        guard CodexVoiceCoordinator.accountAdmissionCode(chatGPT) == nil,
              CodexVoiceCoordinator.accountAdmissionCode(apiKey)
                == "codex_chatgpt_account_required",
              CodexVoiceCoordinator.accountAdmissionCode(signedOut) == "signed_out" else {
            throw CodexAppServerVerificationError.failed("chatgpt_account_policy")
        }
    }

    private static func verifySchemaContract() throws {
        let base = CodexAppServerSchemaContract.requiredMarkers.joined(separator: "\n")
        let missingPolicy = CodexAppServerSchemaContract.gate(
            schemaText: base,
            threadStartSchema: Data("{\"properties\":{}}".utf8)
        )
        guard !missingPolicy.isReady,
              missingPolicy.safeErrorCode == "codex_thread_tool_contract_missing" else {
            throw CodexAppServerVerificationError.failed("thread_tool_contract_missing")
        }
        let ready = CodexAppServerSchemaContract.gate(
            schemaText: base,
            threadStartSchema: Data(
                """
                {"properties":{
                  "dynamicTools":{},
                  "environments":{},
                  "runtimeWorkspaceRoots":{},
                  "selectedCapabilityRoots":{}
                }}
                """.utf8
            )
        )
        guard ready.isReady else {
            throw CodexAppServerVerificationError.failed("thread_tool_contract_ready")
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
        let tools: [CodexJSONValue] = [
            .object([
                "type": .string("function"),
                "name": .string("hoverpocket_verification_read"),
                "description": .string("Verify the delegated HoverPocket tool route."),
                "inputSchema": .object([
                    "type": .string("object"),
                    "properties": .object([:]),
                    "additionalProperties": .bool(false)
                ]),
                "deferLoading": .bool(false)
            ])
        ]
        let first = await probe.probe(dynamicTools: tools)
        let second = await probe.probe(dynamicTools: tools)
        let count = await probe.schemaProbeExecutionCountForVerification()
        guard first == second, count == 1 else {
            throw CodexAppServerVerificationError.failed("schema_probe_cache")
        }
        if first.executableIdentity != nil,
           !(await probe.isCurrent(first)) {
            throw CodexAppServerVerificationError.failed("schema_probe_identity")
        }
        let acceptedInstalledBlocks: Set<String> = [
            "codex_realtime_schema_missing",
            "codex_thread_tool_contract_missing",
            "codex_broker_only_tool_route_mismatch",
            "codex_tool_route_probe_timed_out",
            "codex_tool_route_probe_response_invalid",
            "codex_tool_route_probe_loopback_failed",
            "codex_tool_route_probe_executable_invalid",
            "codex_tool_route_probe_launch_failed",
            "codex_tool_route_probe_transport_ended",
            "codex_tool_route_probe_closed",
            "codex_tool_route_probe_rpc_failed",
            "codex_tool_route_probe_failed"
        ]
        guard first.gate.isReady
                || acceptedInstalledBlocks.contains(first.gate.safeErrorCode ?? "") else {
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
