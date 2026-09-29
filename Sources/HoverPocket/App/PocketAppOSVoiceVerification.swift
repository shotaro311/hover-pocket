import Darwin
import Foundation

@MainActor
enum PocketAppOSVoiceVerification {
    private final class EmptyRuntime: OpenAIRealtimeCapabilityExecuting {
        func sessionTools() throws -> [[String: Any]] { [] }
        func execute(sessionID: String, callID: String, toolName: String, argumentsJSON: String) async -> String {
            "{\"status\":\"failed\",\"code\":\"unexpected_legacy_tool\"}"
        }
        func cancelSession(_ sessionID: String) {}
    }
    private actor Capture {
        var count = 0
        var success = false
        var done = false
        func record(_ reply: CodexAppServerReply) {
            count += 1
            success = reply.result?.objectValue?["success"] == .bool(true)
        }
        func receive(_ event: CodexAppServerNotification, threadID: String) {
            if event.method == "turn/completed", event.params?.objectValue?["threadId"]?.stringValue == threadID {
                success = success && event.params?.objectValue?["turn"]?.objectValue?["status"]?.stringValue == "completed"
                done = true
            }
        }
        func result() -> (Int, Bool, Bool) { (count, success, done) }
    }

    static func run(operation: String = "catalog") async throws {
        guard ["catalog", "weather"].contains(operation) else { throw PocketPreviewValidationError(code: "invalid_probe_operation") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PocketAppOSVoice-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = PocketAppOSController()
        let weatherSuite = "PocketAppOSWeatherLive-" + UUID().uuidString
        let weatherDefaults = UserDefaults(suiteName: weatherSuite)!
        defer { weatherDefaults.removePersistentDomain(forName: weatherSuite) }
        if operation == "weather" {
            let settings = AppSettings()
            let weather = WeatherForecastStore(defaults: weatherDefaults)
            host.readWeather = {
                try await WeatherVoiceReader.read(store: weather, location: settings.weatherLocation,
                    temperatureUnit: settings.weatherTemperatureUnit)
            }
        }
        let store = ProviderStore(registry: .builtIn, settings: AppSettings(defaults: EphemeralAppSettingsDefaults()))
        host.providerStore = store
        let bridge = CodexAppServerCapabilityBridge(runtime: EmptyRuntime(), appController: host)
        let compatibility = await CodexAppServerCompatibilityProbe.shared.probe(dynamicTools: bridge.dynamicTools)
        guard compatibility.gate.isReady,
              await CodexAppServerCompatibilityProbe.shared.isCurrent(compatibility),
              let executable = compatibility.executableURL, let profile = compatibility.appServerProfile else {
            throw PocketPreviewValidationError(code: "voice_compatibility")
        }
        let invocation = try await CodexAppServerToolRouteProbe.runInvocation(executableURL: executable, profile: profile,
            dynamicTools: bridge.dynamicTools, invocation: CodexAppServerToolRouteProbeInvocation(
                toolName: PocketAppOSController.toolName, arguments: .object(["operation": .string(operation)]),
                handler: { request, session in
                    await bridge.handle(request: request, context: CodexVoiceToolRequestContext(rootThreadID: session, clientGeneration: 1))
                }))
        guard invocation.reply.result?.objectValue?["success"] == .bool(true) else {
            throw PocketPreviewValidationError(code: "app_os_tool_route")
        }
        print("PASS App OS exact installed app-server tool route: " + operation)
        let client = try await CodexAppServerClient.start(options: CodexAppServerClientOptions(
            executableURL: executable, launchArguments: CodexVoiceAppServerLaunchPolicy.arguments,
            processEnvironment: profile.processEnvironment, workingDirectoryURL: profile.codexHomeURL,
            requestTimeout: 60, clientTitle: "HoverPocket App OS Verifier", clientVersion: "1", experimentalAPI: true))
        let processID = await client.processIdentifier
        do {
            let account = try await client.sendRequest("account/read", params: .object(["refreshToken": .bool(false)]))
            guard CodexVoiceCoordinator.accountAdmissionCode(account) == nil else { throw PocketPreviewValidationError(code: "chatgpt_account_required") }
            let started = try await client.sendRequest("thread/start", params: .object(CodexVoiceThreadContract.startParameters(workspaceDirectory: root, dynamicTools: bridge.dynamicTools, ephemeral: true)))
            guard let thread = started.objectValue?["thread"]?.objectValue?["id"]?.stringValue else { throw PocketPreviewValidationError(code: "thread_start") }
            let capture = Capture()
            await client.setNotificationHandler { await capture.receive($0, threadID: thread) }
            await client.setServerRequestHandler { request in
                guard request.method == "item/tool/call", request.params?.objectValue?["threadId"]?.stringValue == thread,
                      request.params?.objectValue?["tool"]?.stringValue == PocketAppOSController.toolName,
                      request.params?.objectValue?["arguments"]?.objectValue == ["operation": .string(operation)] else {
                    return .failure(code: -32600, message: "Only the read-only verification request is allowed")
                }
                let reply = await bridge.handle(request: request, context: CodexVoiceToolRequestContext(rootThreadID: thread, clientGeneration: 1))
                await capture.record(reply)
                return reply
            }
            _ = try await client.sendRequest("turn/start", params: .object([
                "threadId": .string(thread), "input": .array([.object(["type": .string("text"), "textElements": .array([]),
                    "text": .string("Call hoverpocket_control exactly once with operation \(operation) and no other fields. This is a read-only integration test. Then respond briefly. Do not call any other tool.")])])
            ]))
            let deadline = Date().addingTimeInterval(90)
            while !(await capture.result().2), Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
            let result = await capture.result()
            guard result.0 == 1, result.1, result.2 else { throw PocketPreviewValidationError(code: "live_model_" + operation) }
            await client.close()
            if let processID {
                let end = Date().addingTimeInterval(5)
                while kill(processID, 0) == 0, Date() < end { try await Task.sleep(for: .milliseconds(100)) }
                guard kill(processID, 0) != 0 else { throw PocketPreviewValidationError(code: "live_model_process_leaked") }
            }
            print("PASS App OS live ChatGPT model: \(operation) discovered and executed once; ephemeral session and process closed")
        } catch { await client.close(); throw error }
    }
}
