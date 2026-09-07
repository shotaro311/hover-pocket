import Foundation

struct CodexVoiceToolRequestContext: Equatable, Sendable {
    let rootThreadID: String
    let clientGeneration: UInt64
}

@MainActor
protocol CodexVoiceCapabilityToolAdapterProtocol: AnyObject {
    var dynamicTools: [CodexJSONValue] { get }

    func handle(
        request: CodexAppServerRequest,
        context: CodexVoiceToolRequestContext
    ) async -> CodexAppServerReply

    func cancelSession(_ sessionID: String)
    func noteUserInput(sessionID: String)
    func conversationDidDisconnect(sessionID: String)
}

extension CodexVoiceCapabilityToolAdapterProtocol {
    func noteUserInput(sessionID: String) {}
    func conversationDidDisconnect(sessionID: String) {}
}

@MainActor
final class CodexAppServerCapabilityBridge: CodexVoiceCapabilityToolAdapterProtocol {
    private static let maximumToolRequestBytes = 20 * 1_024
    private static let maximumToolOutputBytes = 64 * 1_024

    private let runtime: any OpenAIRealtimeCapabilityExecuting
    private let appController: PocketAppOSController?

    init(runtime: any OpenAIRealtimeCapabilityExecuting, appController: PocketAppOSController? = nil) {
        self.runtime = runtime
        self.appController = appController
    }

    var dynamicTools: [CodexJSONValue] {
        guard let tools = try? runtime.sessionTools() else { return [] }
        return (tools + (appController == nil ? [] : [PocketAppOSController.tool])).compactMap(Self.dynamicTool)
    }

    func handle(
        request: CodexAppServerRequest,
        context: CodexVoiceToolRequestContext
    ) async -> CodexAppServerReply {
        guard request.method == "item/tool/call" else {
            return .failure(code: -32601, message: "Unsupported app-server request")
        }
        guard context.clientGeneration > 0,
              VoiceTextSafety.sanitizeIdentifier(context.rootThreadID) == context.rootThreadID,
              let params = request.params?.objectValue,
              params["threadId"]?.stringValue == context.rootThreadID,
              let callID = params["callId"]?.stringValue,
              VoiceTextSafety.sanitizeIdentifier(callID) == callID,
              let turnID = params["turnId"]?.stringValue,
              VoiceTextSafety.sanitizeIdentifier(turnID) == turnID,
              let toolName = params["tool"]?.stringValue,
              VoiceTextSafety.sanitizeIdentifier(toolName) == toolName,
              let arguments = params["arguments"] else {
            return Self.toolFailure("invalid_request")
        }
        guard dynamicTools.contains(where: {
            $0.objectValue?["name"]?.stringValue == toolName
        }) else {
            return Self.toolFailure("tool_not_allowed")
        }

        let argumentsData: Data
        do {
            argumentsData = try JSONEncoder.sortedCodex.encode(arguments)
        } catch {
            return Self.toolFailure("invalid_arguments")
        }
        guard argumentsData.count <= Self.maximumToolRequestBytes,
              let argumentsJSON = String(data: argumentsData, encoding: .utf8) else {
            return Self.toolFailure("invalid_arguments")
        }

        let appConfirmationCancelled = toolName == "pending_action_cancel" && appController?.cancelPendingConfirmation(session: context.rootThreadID) == true
        var output: String
        if toolName == PocketAppOSController.toolName, let appController {
            output = await appController.execute(session: context.rootThreadID, callID: callID, arguments: arguments)
        } else {
            output = await runtime.execute(
            sessionID: context.rootThreadID,
            callID: callID,
            toolName: toolName,
            argumentsJSON: argumentsJSON
        )
        }
        if appConfirmationCancelled, let data = output.data(using: .utf8),
           var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            object["status"] = "succeeded"
            object["host_confirmation_cancelled"] = true
            if let updated = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), let text = String(data: updated, encoding: .utf8) { output = text }
        }
        guard output.utf8.count <= Self.maximumToolOutputBytes else {
            return Self.toolFailure("output_too_large")
        }
        let success = Self.outputSucceeded(output) || Self.outputAccepted(output)
        return .success(.object([
            "success": .bool(success),
            "contentItems": .array([
                .object([
                    "type": .string("inputText"),
                    "text": .string(output)
                ])
            ])
        ]))
    }

    func conversationDidDisconnect(sessionID: String) {
        _ = runtime.cancelPendingConfirmation(sessionID: sessionID)
        appController?.cancelSession(sessionID)
    }

    func noteUserInput(sessionID: String) {
        runtime.noteUserInput(sessionID: sessionID)
        appController?.noteUserInput(session: sessionID)
    }

    func cancelSession(_ sessionID: String) {
        runtime.cancelSession(sessionID)
        appController?.cancelSession(sessionID)
    }

    private static func dynamicTool(_ source: [String: Any]) -> CodexJSONValue? {
        guard source["type"] as? String == "function",
              let name = source["name"] as? String,
              VoiceTextSafety.sanitizeIdentifier(name) == name,
              let description = source["description"] as? String,
              let inputSchema = source["parameters"] else { return nil }
        let candidate: [String: Any] = [
            "type": "function",
            "name": name,
            "description": VoiceTextSafety.sanitizeVisibleText(description, limit: 512),
            "inputSchema": inputSchema,
            "deferLoading": false
        ]
        guard JSONSerialization.isValidJSONObject(candidate),
              let data = try? JSONSerialization.data(withJSONObject: candidate, options: [.sortedKeys]),
              data.count <= Self.maximumToolRequestBytes else { return nil }
        return try? JSONDecoder().decode(CodexJSONValue.self, from: data)
    }

    private static func outputAccepted(_ output: String) -> Bool {
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = object["status"] as? String else { return false }
        return ["accepted", "awaiting_confirmation"].contains(status)
    }

    private static func outputSucceeded(_ output: String) -> Bool {
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return object["status"] as? String == "succeeded"
    }

    private static func toolFailure(_ code: String) -> CodexAppServerReply {
        let safeCode = VoiceTextSafety.sanitizeErrorCode(code)
        return .success(.object([
            "success": .bool(false),
            "contentItems": .array([
                .object([
                    "type": .string("inputText"),
                    "text": .string("{\"code\":\"\(safeCode)\",\"status\":\"failed\"}")
                ])
            ])
        ]))
    }
}

private extension JSONEncoder {
    static var sortedCodex: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
