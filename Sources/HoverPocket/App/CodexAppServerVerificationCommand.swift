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
        try await verifyBrokerCapabilityBridge()
        guard CodexVoiceCoordinator.verifyRealtimeLifecyclePolicy() else {
            throw CodexAppServerVerificationError.failed("realtime_lifecycle_policy")
        }
        guard await CodexVoiceCoordinator.verifyOneShotResolutionPolicy() else {
            throw CodexAppServerVerificationError.failed("realtime_one_shot_policy")
        }
        let installedCompatibility = try await verifyInstalledSchemaCache()
        try await verifyInstalledAppServerBrokerInvocation(installedCompatibility)
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

    private static func verifyBrokerCapabilityBridge() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hoverpocket-codex-broker-bridge-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let calendar = CodexAppServerVerificationCalendarDataSource(now: now)
        let timerStore = TimerStore(
            storageDirectory: root.appendingPathComponent("timer", isDirectory: true),
            observesWake: false,
            persistenceEnabled: true
        )
        let handlers = try PocketCapabilityHandlerSet(handlers: [
            CalendarListCapabilityHandler(dataSource: calendar),
            CalendarGetCapabilityHandler(dataSource: calendar),
            CalendarCreateCapabilityHandler(dataSource: calendar),
            TimerCapabilityHandler(operation: .start, store: timerStore),
            TimerCapabilityHandler(operation: .get, store: timerStore),
            TimerCapabilityHandler(operation: .stop, store: timerStore)
        ])
        let registry = try CapabilityRegistry(handlers: handlers)
        let brokerRoot = root.appendingPathComponent("broker", isDirectory: true)
        let context = VoiceCapabilityContext(
            registry: registry,
            broker: CapabilityBroker(
                registry: registry,
                ledger: try CapabilityBrokerLedger(rootDirectory: brokerRoot),
                auditLog: try CapabilityBrokerAuditLog(rootDirectory: brokerRoot)
            )
        )
        var approvalCount = 0
        let runtime = try OpenAIRealtimeMacOSCapabilityRuntime(
            context: context,
            calendarAccessGranted: { true },
            timeZoneID: { "Asia/Tokyo" },
            now: { now },
            approvalHandler: { _ in
                approvalCount += 1
                return true
            }
        )
        let bridge = CodexAppServerCapabilityBridge(runtime: runtime)
        let toolNames = Set(bridge.dynamicTools.compactMap {
            $0.objectValue?["name"]?.stringValue
        })
        guard toolNames == [
            OpenAIRealtimeMacOSCapabilityRuntime.calendarListTool,
            OpenAIRealtimeMacOSCapabilityRuntime.calendarCreateTool,
            OpenAIRealtimeMacOSCapabilityRuntime.timerStartTool
        ] else {
            throw CodexAppServerVerificationError.failed("broker_tool_surface")
        }

        let listed = await bridge.handle(
            request: toolRequest(
                id: 10,
                threadID: "broker-thread",
                callID: "calendar-list",
                tool: OpenAIRealtimeMacOSCapabilityRuntime.calendarListTool,
                arguments: .object([:])
            ),
            context: CodexVoiceToolRequestContext(
                rootThreadID: "broker-thread",
                clientGeneration: 1
            )
        )
        let listedOutput = try toolOutput(listed, expectedSuccess: true)
        guard listedOutput["status"] as? String == "succeeded",
              listedOutput["readback"] as? String == "verified",
              (listedOutput["events"] as? [[String: Any]])?.count == 1 else {
            throw CodexAppServerVerificationError.failed("broker_calendar_list_readback")
        }

        let created = await bridge.handle(
            request: toolRequest(
                id: 11,
                threadID: "broker-thread",
                callID: "calendar-create",
                tool: OpenAIRealtimeMacOSCapabilityRuntime.calendarCreateTool,
                arguments: .object([
                    "title": .string("確認予定"),
                    "start": .string("2027-01-15T09:00:00+09:00"),
                    "end": .string("2027-01-15T10:00:00+09:00"),
                    "isAllDay": .bool(false)
                ])
            ),
            context: CodexVoiceToolRequestContext(
                rootThreadID: "broker-thread",
                clientGeneration: 1
            )
        )
        let createdOutput = try toolOutput(created, expectedSuccess: true)
        guard createdOutput["status"] as? String == "succeeded",
              createdOutput["readback"] as? String == "verified",
              calendar.createdCount == 1 else {
            throw CodexAppServerVerificationError.failed("broker_calendar_create_readback")
        }

        let timerRequest = toolRequest(
            id: 12,
            threadID: "broker-thread",
            callID: "timer-start",
            tool: OpenAIRealtimeMacOSCapabilityRuntime.timerStartTool,
            arguments: .object([
                "durationSeconds": .integer(600),
                "title": .string("集中")
            ])
        )
        let timer = await bridge.handle(
            request: timerRequest,
            context: CodexVoiceToolRequestContext(
                rootThreadID: "broker-thread",
                clientGeneration: 1
            )
        )
        let timerOutput = try toolOutput(timer, expectedSuccess: true)
        guard timerOutput["status"] as? String == "succeeded",
              timerOutput["state"] as? String == "running",
              timerOutput["readback"] as? String == "verified",
              timerStore.runningTimers.count == 1,
              approvalCount == 2 else {
            throw CodexAppServerVerificationError.failed("broker_timer_start_readback")
        }
        let replay = await bridge.handle(
            request: timerRequest,
            context: CodexVoiceToolRequestContext(
                rootThreadID: "broker-thread",
                clientGeneration: 1
            )
        )
        guard replay.result == timer.result,
              timerStore.runningTimers.count == 1,
              approvalCount == 2 else {
            throw CodexAppServerVerificationError.failed("broker_tool_replay")
        }

        let rejectedRuntime = try OpenAIRealtimeMacOSCapabilityRuntime(
            context: context,
            calendarAccessGranted: { false },
            timeZoneID: { "Asia/Tokyo" },
            now: { now },
            approvalHandler: { _ in false }
        )
        let rejectedBridge = CodexAppServerCapabilityBridge(runtime: rejectedRuntime)
        let rejected = await rejectedBridge.handle(
            request: toolRequest(
                id: 13,
                threadID: "rejected-thread",
                callID: "timer-rejected",
                tool: OpenAIRealtimeMacOSCapabilityRuntime.timerStartTool,
                arguments: .object(["durationSeconds": .integer(60)])
            ),
            context: CodexVoiceToolRequestContext(
                rootThreadID: "rejected-thread",
                clientGeneration: 2
            )
        )
        let rejectedOutput = try toolOutput(rejected, expectedSuccess: false)
        guard rejectedOutput["code"] as? String == "user_rejected",
              timerStore.runningTimers.count == 1 else {
            throw CodexAppServerVerificationError.failed("broker_tool_rejection")
        }
    }

    private static func toolRequest(
        id: Int64,
        threadID: String,
        callID: String,
        tool: String,
        arguments: CodexJSONValue
    ) -> CodexAppServerRequest {
        CodexAppServerRequest(
            id: .integer(id),
            method: "item/tool/call",
            params: .object([
                "arguments": arguments,
                "callId": .string(callID),
                "threadId": .string(threadID),
                "tool": .string(tool),
                "turnId": .string("turn-\(id)")
            ])
        )
    }

    private static func toolOutput(
        _ reply: CodexAppServerReply,
        expectedSuccess: Bool
    ) throws -> [String: Any] {
        guard reply.error == nil,
              let result = reply.result?.objectValue,
              result["success"]?.boolValue == expectedSuccess,
              let content = result["contentItems"]?.arrayValue?.first?.objectValue,
              content["type"]?.stringValue == "inputText",
              let text = content["text"]?.stringValue,
              let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        else {
            throw CodexAppServerVerificationError.failed("broker_tool_output")
        }
        return object
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
        let firstCount = await probe.schemaProbeExecutionCountForVerification()
        let second = await probe.probe(dynamicTools: tools)
        let secondCount = await probe.schemaProbeExecutionCountForVerification()
        guard first == second,
              firstCount > 0,
              secondCount == firstCount else {
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
        print("codex_app_server_schema_probe_executions=\(secondCount)")
        return first
    }

    private static func verifyInstalledAppServerBrokerInvocation(
        _ compatibility: CodexAppServerCompatibilityResult
    ) async throws {
        guard compatibility.gate.isReady,
              let executableURL = compatibility.executableURL,
              let profile = compatibility.appServerProfile else {
            print("codex_app_server_broker_invocation=skipped_not_ready")
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hoverpocket-codex-live-broker-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let calendar = CodexAppServerVerificationCalendarDataSource(now: now)
        let timerStore = TimerStore(
            storageDirectory: root.appendingPathComponent("timer", isDirectory: true),
            observesWake: false,
            persistenceEnabled: true
        )
        let handlers = try PocketCapabilityHandlerSet(handlers: [
            CalendarListCapabilityHandler(dataSource: calendar),
            CalendarGetCapabilityHandler(dataSource: calendar),
            CalendarCreateCapabilityHandler(dataSource: calendar),
            TimerCapabilityHandler(operation: .start, store: timerStore),
            TimerCapabilityHandler(operation: .get, store: timerStore),
            TimerCapabilityHandler(operation: .stop, store: timerStore)
        ])
        let registry = try CapabilityRegistry(handlers: handlers)
        let brokerRoot = root.appendingPathComponent("broker", isDirectory: true)
        let runtime = try OpenAIRealtimeMacOSCapabilityRuntime(
            context: VoiceCapabilityContext(
                registry: registry,
                broker: CapabilityBroker(
                    registry: registry,
                    ledger: try CapabilityBrokerLedger(rootDirectory: brokerRoot),
                    auditLog: try CapabilityBrokerAuditLog(rootDirectory: brokerRoot)
                )
            ),
            calendarAccessGranted: { false },
            timeZoneID: { "Asia/Tokyo" },
            now: { now },
            approvalHandler: { _ in true }
        )
        let bridge = CodexAppServerCapabilityBridge(runtime: runtime)
        let result = try await CodexAppServerToolRouteProbe.runInvocation(
            executableURL: executableURL,
            profile: profile,
            dynamicTools: bridge.dynamicTools,
            invocation: CodexAppServerToolRouteProbeInvocation(
                toolName: OpenAIRealtimeMacOSCapabilityRuntime.timerStartTool,
                arguments: .object([
                    "durationSeconds": .integer(60),
                    "title": .string("app-server検証")
                ]),
                handler: { request, threadID in
                    await bridge.handle(
                        request: request,
                        context: CodexVoiceToolRequestContext(
                            rootThreadID: threadID,
                            clientGeneration: 1
                        )
                    )
                }
            )
        )
        let output = try toolOutput(result.reply, expectedSuccess: true)
        guard result.request.method == "item/tool/call",
              result.request.params?.objectValue?["tool"]?.stringValue
                == OpenAIRealtimeMacOSCapabilityRuntime.timerStartTool,
              output["status"] as? String == "succeeded",
              output["state"] as? String == "running",
              output["readback"] as? String == "verified",
              timerStore.runningTimers.count == 1 else {
            throw CodexAppServerVerificationError.failed("installed_broker_tool_invocation")
        }
        print("codex_app_server_broker_invocation=verified")
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

@MainActor
private final class CodexAppServerVerificationCalendarDataSource: CalendarCapabilityDataSource {
    private var events: [String: CalendarCapabilityEvent]
    private(set) var createdCount = 0

    init(now: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let startOfDay = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .hour, value: 10, to: startOfDay)!
        let end = calendar.date(byAdding: .hour, value: 1, to: start)!
        let event = CalendarCapabilityEvent(
            eventRef: "event-existing",
            eventID: "google-existing",
            safeTitle: "既存予定",
            start: start,
            end: end
        )
        events = [event.eventRef: event]
    }

    func listEvents(from start: Date, to end: Date) async throws -> [CalendarCapabilityEvent] {
        events.values.filter { $0.start < end && $0.end > start }
    }

    func getEvent(eventRef: String) async throws -> CalendarCapabilityEvent? {
        events[eventRef]
    }

    func createEvent(
        _ request: CalendarCapabilityCreateRequest,
        idempotencyKey: String
    ) async throws -> CalendarCapabilityEvent {
        createdCount += 1
        let event = CalendarCapabilityEvent(
            eventRef: "event-created-\(createdCount)",
            eventID: "google-created-\(createdCount)",
            safeTitle: request.title,
            start: request.start,
            end: request.end,
            isAllDay: request.isAllDay,
            allDayStart: request.allDayStart,
            allDayEnd: request.allDayEnd
        )
        events[event.eventRef] = event
        _ = idempotencyKey
        return event
    }
}
