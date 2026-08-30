import Darwin
import Foundation

enum CodexAppServerVerificationError: Error {
    case failed(String)
}

struct CodexAppServerVerificationResult {
    let installedCompatibility: CodexAppServerCompatibilityResult
    let managedLoginLifecycle: CodexManagedLoginLifecycleVerificationResult
}

struct CodexManagedLoginLifecycleVerificationResult {
    let scenarioCount: Int
    let processCount: Int
    let browserOpenCount: Int
    let credentialReuseVerified: Bool
    let processesClosed: Bool
}

struct CodexAppServerModelToolVerificationResult {
    let requestedModel: String
    let requestedEffort: String
    let toolName: String
    let approvalCount: Int
    let processClosed: Bool
}

private struct CodexManagedLoginVerificationFixture {
    let context: CodexVoiceManagedLoginContext
    let receiptURL: URL
}

private enum CodexManagedLoginPendingAction: String, CaseIterable {
    case cancel
    case deactivate
    case shutdown
}

@MainActor
private final class CodexManagedLoginVerificationRecorder {
    var browserURLs: [URL] = []
    var credentialChangeCount = 0
}

@MainActor
enum CodexAppServerVerificationCommand {
    private static let modelToolVerificationModel = "gpt-5.6-sol"
    private static let modelToolVerificationEffort = "medium"
    private static let modelToolVerificationTitle = "HoverPocket model verification"

    static func run() async throws -> CodexAppServerVerificationResult {
        try verifySchemaContract()
        try verifyChatGPTAccountPolicy()
        try verifyManagedChatGPTLoginContract()
        try verifyVoiceProfileAuthStorage()
        let managedLoginLifecycle = try await verifyManagedChatGPTLoginLifecycle()
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
            installedCompatibility: installedCompatibility,
            managedLoginLifecycle: managedLoginLifecycle
        )
    }

    static func runModelToolVerification() async throws
        -> CodexAppServerModelToolVerificationResult {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hoverpocket-codex-model-tool-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw CodexAppServerVerificationError.failed("model_tool_workspace_failed")
        }
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
        var approvalCount = 0
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
            approvalHandler: { _ in
                approvalCount += 1
                return true
            }
        )
        let bridge = CodexAppServerCapabilityBridge(runtime: runtime)
        let expectedToolName = OpenAIRealtimeMacOSCapabilityRuntime.timerStartTool
        guard bridge.dynamicTools.count == 1,
              bridge.dynamicTools.first?.objectValue?["name"]?.stringValue
                == expectedToolName else {
            try? FileManager.default.removeItem(at: root)
            throw CodexAppServerVerificationError.failed("model_tool_surface_invalid")
        }

        let compatibility = await CodexAppServerCompatibilityProbe.shared.probe(
            dynamicTools: bridge.dynamicTools
        )
        guard compatibility.gate.isReady,
              await CodexAppServerCompatibilityProbe.shared.isCurrent(compatibility),
              let executableURL = compatibility.executableURL,
              let profile = compatibility.appServerProfile else {
            try? FileManager.default.removeItem(at: root)
            throw CodexAppServerVerificationError.failed(
                compatibility.gate.safeErrorCode ?? "codex_app_server_not_ready"
            )
        }

        let client: CodexAppServerClient
        do {
            client = try await CodexAppServerClient.start(
                options: CodexAppServerClientOptions(
                    executableURL: executableURL,
                    launchArguments: CodexVoiceAppServerLaunchPolicy.arguments,
                    processEnvironment: profile.processEnvironment,
                    workingDirectoryURL: profile.codexHomeURL,
                    requestTimeout: 60,
                    clientName: "hover_pocket_model_tool_verifier",
                    clientTitle: "HoverPocket Model Tool Verifier",
                    clientVersion: "1",
                    experimentalAPI: true
                )
            )
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        let processID = await client.processIdentifier
        let toolCapture = CodexAppServerModelVerificationOneShot<
            CodexAppServerToolRouteProbeInvocationResult
        >()
        let turnCapture = CodexAppServerModelVerificationOneShot<
            CodexAppServerModelTurnCompletion
        >()
        let admission = CodexAppServerModelToolAdmission()

        do {
            let account = try await client.sendRequest(
                "account/read",
                params: .object(["refreshToken": .bool(false)])
            )
            guard CodexVoiceCoordinator.accountAdmissionCode(account) == nil else {
                throw CodexAppServerVerificationError.failed("model_tool_chatgpt_account_required")
            }

            let threadResponse = try await client.sendRequest(
                "thread/start",
                params: .object(CodexVoiceThreadContract.startParameters(
                    workspaceDirectory: root,
                    dynamicTools: bridge.dynamicTools,
                    ephemeral: true
                ))
            )
            guard let threadID = threadResponse.objectValue?["thread"]?
                    .objectValue?["id"]?.stringValue,
                  VoiceTextSafety.sanitizeIdentifier(threadID) == threadID else {
                throw CodexAppServerVerificationError.failed("model_tool_thread_invalid")
            }

            await client.setNotificationHandler { notification in
                guard notification.method == "turn/completed",
                      let params = notification.params?.objectValue,
                      let completedThreadID = params["threadId"]?.stringValue,
                      let turn = params["turn"]?.objectValue,
                      let turnID = turn["id"]?.stringValue,
                      let status = turn["status"]?.stringValue else { return }
                turnCapture.succeed(CodexAppServerModelTurnCompletion(
                    threadID: completedThreadID,
                    turnID: turnID,
                    status: status
                ))
            }
            await client.setServerRequestHandler { request in
                guard request.method == "item/tool/call",
                      request.params?.objectValue?["threadId"]?.stringValue == threadID,
                      request.params?.objectValue?["tool"]?.stringValue
                        == expectedToolName,
                      admission.admitToolCall() else {
                    admission.recordRejectedRequest()
                    return .failure(
                        code: -32600,
                        message: "HoverPocket model verification rejected an unexpected request."
                    )
                }
                let reply = await bridge.handle(
                    request: request,
                    context: CodexVoiceToolRequestContext(
                        rootThreadID: threadID,
                        clientGeneration: 1
                    )
                )
                return CodexAppServerReply(
                    result: reply.result,
                    error: reply.error,
                    afterWrite: {
                        if let afterWrite = reply.afterWrite {
                            await afterWrite()
                        }
                        toolCapture.succeed(CodexAppServerToolRouteProbeInvocationResult(
                            request: request,
                            reply: reply
                        ))
                    }
                )
            }

            async let capturedTool = toolCapture.wait(timeout: 60)
            async let completedTurn = turnCapture.wait(timeout: 60)
            let turnResponse = try await client.sendRequest(
                "turn/start",
                params: .object([
                    "threadId": .string(threadID),
                    "model": .string(modelToolVerificationModel),
                    "effort": .string(modelToolVerificationEffort),
                    "input": .array([
                        .object([
                            "type": .string("text"),
                            "text": .string(
                                "Call timer_countdown_start exactly once with "
                                    + "durationSeconds 60 and title \""
                                    + modelToolVerificationTitle
                                    + "\". Do not call any other tool. After the tool result, "
                                    + "reply with one short confirmation."
                            ),
                            "textElements": .array([])
                        ])
                    ])
                ])
            )
            guard let startedTurnID = turnResponse.objectValue?["turn"]?
                    .objectValue?["id"]?.stringValue,
                  VoiceTextSafety.sanitizeIdentifier(startedTurnID) == startedTurnID else {
                throw CodexAppServerVerificationError.failed("model_tool_turn_invalid")
            }

            let (toolResult, turnCompletion) = try await (capturedTool, completedTurn)
            let output = try toolOutput(toolResult.reply, expectedSuccess: true)
            let arguments = toolResult.request.params?.objectValue?["arguments"]?.objectValue
            let admissionSnapshot = admission.snapshot()
            let metrics = await client.metrics()
            guard toolResult.request.params?.objectValue?["threadId"]?.stringValue == threadID,
                  toolResult.request.params?.objectValue?["turnId"]?.stringValue == startedTurnID,
                  arguments?["durationSeconds"]?.integerValue == 60,
                  arguments?["title"]?.stringValue == modelToolVerificationTitle,
                  output["status"] as? String == "succeeded",
                  output["state"] as? String == "running",
                  output["readback"] as? String == "verified",
                  turnCompletion.threadID == threadID,
                  turnCompletion.turnID == startedTurnID,
                  turnCompletion.status == "completed",
                  approvalCount == 1,
                  calendar.createdCount == 0,
                  timerStore.runningTimers.count == 1,
                  timerStore.runningTimers.first?.title == modelToolVerificationTitle,
                  timerStore.runningTimers.first?.phaseDuration == 60,
                  admissionSnapshot.admitted == 1,
                  admissionSnapshot.rejected == 0,
                  metrics.malformedOutputLines == 0,
                  metrics.unknownResponses == 0,
                  metrics.unhandledServerRequests == 0 else {
                throw CodexAppServerVerificationError.failed("model_tool_readback_failed")
            }

            await client.setNotificationHandler(nil)
            await client.setServerRequestHandler(nil)
            await client.close()
            let processClosed = await waitForProcessExit(processID)
            guard processClosed else {
                throw CodexAppServerVerificationError.failed("model_tool_process_leaked")
            }
            try FileManager.default.removeItem(at: root)
            guard !FileManager.default.fileExists(atPath: root.path) else {
                throw CodexAppServerVerificationError.failed("model_tool_workspace_leaked")
            }
            return CodexAppServerModelToolVerificationResult(
                requestedModel: modelToolVerificationModel,
                requestedEffort: modelToolVerificationEffort,
                toolName: expectedToolName,
                approvalCount: approvalCount,
                processClosed: true
            )
        } catch {
            await client.setNotificationHandler(nil)
            await client.setServerRequestHandler(nil)
            await client.close()
            let processClosed = await waitForProcessExit(processID)
            try? FileManager.default.removeItem(at: root)
            guard processClosed else {
                throw CodexAppServerVerificationError.failed("model_tool_process_leaked")
            }
            guard !FileManager.default.fileExists(atPath: root.path) else {
                throw CodexAppServerVerificationError.failed("model_tool_workspace_leaked")
            }
            throw error
        }
    }

    private static func verifyManagedChatGPTLoginLifecycle() async throws
        -> CodexManagedLoginLifecycleVerificationResult {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "hoverpocket-managed-login-lifecycle-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(
                at: root,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw CodexAppServerVerificationError.failed(
                "managed_login_lifecycle_workspace"
            )
        }
        defer { try? fileManager.removeItem(at: root) }

        try await verifyManagedLoginSuccess(
            fixture: try makeManagedLoginFixture(root: root, name: "success", mode: "success")
        )
        for action in CodexManagedLoginPendingAction.allCases {
            try await verifyManagedLoginPendingCleanup(
                fixture: try makeManagedLoginFixture(
                    root: root,
                    name: action.rawValue,
                    mode: "pending"
                ),
                action: action
            )
        }
        return CodexManagedLoginLifecycleVerificationResult(
            scenarioCount: 1 + CodexManagedLoginPendingAction.allCases.count,
            processCount: 3 + CodexManagedLoginPendingAction.allCases.count,
            browserOpenCount: 1 + CodexManagedLoginPendingAction.allCases.count,
            credentialReuseVerified: true,
            processesClosed: true
        )
    }

    private static func verifyManagedLoginSuccess(
        fixture: CodexManagedLoginVerificationFixture
    ) async throws {
        let recorder = CodexManagedLoginVerificationRecorder()
        let controller = makeManagedLoginController(fixture: fixture, recorder: recorder)
        do {
            controller.refresh()
            guard await waitForManagedLoginCondition({
                controller.state == .signedOut(
                    managedLoginAvailable: true,
                    reasonCode: "signed_out"
                )
            }) else {
                throw CodexAppServerVerificationError.failed(
                    "managed_login_refresh_state"
                )
            }
            guard recorder.browserURLs.isEmpty,
                  recorder.credentialChangeCount == 0 else {
                throw CodexAppServerVerificationError.failed(
                    "managed_login_refresh_side_effect"
                )
            }

            controller.startLogin()
            guard await waitForManagedLoginCondition({ controller.state == .signedIn }) else {
                throw CodexAppServerVerificationError.failed(
                    "managed_login_success_state"
                )
            }
            guard recorder.browserURLs.count == 1,
                  recorder.browserURLs[0].absoluteString
                    == "https://auth.openai.com/hoverpocket-verification",
                  recorder.credentialChangeCount == 1,
                  fixture.context.profile.hasValidManagedCredentialFile else {
                throw CodexAppServerVerificationError.failed(
                    "managed_login_success_readback"
                )
            }

            controller.refresh()
            guard await waitForManagedLoginCondition({ controller.state == .signedIn }),
                  recorder.browserURLs.count == 1,
                  recorder.credentialChangeCount == 1 else {
                throw CodexAppServerVerificationError.failed(
                    "managed_login_credential_reuse"
                )
            }
            await controller.shutdown()
        } catch {
            await controller.shutdown()
            throw error
        }

        let events = try managedLoginReceiptEvents(fixture.receiptURL)
        guard events.filter({ $0.hasPrefix("process_started:") }).count == 3,
              events.filter({ $0 == "initialize" }).count == 3,
              events.filter({ $0 == "account_read:signed_out" }).count == 2,
              events.filter({ $0 == "account_read:chatgpt" }).count == 2,
              events.filter({ $0 == "login_start" }).count == 1,
              events.filter({ $0 == "credential_written" }).count == 1,
              events.filter({ $0 == "login_completed" }).count == 1,
              !events.contains("login_cancel"),
              !events.contains(where: { $0.hasPrefix("unexpected_request:") }),
              await managedLoginProcessesClosed(events) else {
            throw CodexAppServerVerificationError.failed(
                "managed_login_success_process_readback"
            )
        }
    }

    private static func verifyManagedLoginPendingCleanup(
        fixture: CodexManagedLoginVerificationFixture,
        action: CodexManagedLoginPendingAction
    ) async throws {
        let recorder = CodexManagedLoginVerificationRecorder()
        let controller = makeManagedLoginController(fixture: fixture, recorder: recorder)
        do {
            controller.startLogin()
            guard await waitForManagedLoginCondition({
                controller.state == .signingIn && recorder.browserURLs.count == 1
            }) else {
                throw CodexAppServerVerificationError.failed(
                    "managed_login_\(action.rawValue)_not_started"
                )
            }
            switch action {
            case .cancel:
                controller.cancelLogin()
                guard controller.state == .signedOut(
                    managedLoginAvailable: true,
                    reasonCode: "signed_out"
                ) else {
                    throw CodexAppServerVerificationError.failed(
                        "managed_login_cancel_state"
                    )
                }
                await controller.shutdown()
            case .deactivate:
                controller.deactivate()
                guard controller.state == .idle else {
                    throw CodexAppServerVerificationError.failed(
                        "managed_login_deactivate_state"
                    )
                }
                await controller.shutdown()
            case .shutdown:
                await controller.shutdown()
            }
            guard controller.state == .idle else {
                throw CodexAppServerVerificationError.failed(
                    "managed_login_\(action.rawValue)_shutdown_state"
                )
            }
        } catch {
            await controller.shutdown()
            throw error
        }

        let events = try managedLoginReceiptEvents(fixture.receiptURL)
        guard recorder.browserURLs.count == 1,
              recorder.credentialChangeCount == 0,
              !FileManager.default.fileExists(
                atPath: fixture.context.profile.codexHomeURL
                    .appendingPathComponent("auth.json").path
              ),
              events.filter({ $0.hasPrefix("process_started:") }).count == 1,
              events.filter({ $0 == "initialize" }).count == 1,
              events.filter({ $0 == "account_read:signed_out" }).count == 1,
              events.filter({ $0 == "login_start" }).count == 1,
              events.filter({ $0 == "login_cancel" }).count == 1,
              !events.contains(where: { $0.hasPrefix("unexpected_request:") }),
              await managedLoginProcessesClosed(events) else {
            throw CodexAppServerVerificationError.failed(
                "managed_login_\(action.rawValue)_process_readback"
            )
        }
    }

    private static func makeManagedLoginController(
        fixture: CodexManagedLoginVerificationFixture,
        recorder: CodexManagedLoginVerificationRecorder
    ) -> CodexVoiceAccountLoginController {
        CodexVoiceAccountLoginController(
            contextProvider: { [context = fixture.context] in [context] },
            browserOpener: { [weak recorder] url in
                recorder?.browserURLs.append(url)
                return true
            },
            credentialChangeHandler: { [weak recorder] in
                recorder?.credentialChangeCount += 1
            }
        )
    }

    private static func makeManagedLoginFixture(
        root: URL,
        name: String,
        mode: String
    ) throws -> CodexManagedLoginVerificationFixture {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        let codexHome = directory.appendingPathComponent("codex-home", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            at: codexHome,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let receiptURL = directory.appendingPathComponent("receipt.log")
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = codexHome.path
        environment[CodexManagedLoginVerificationHelper.modeEnvironmentKey] = mode
        environment[CodexManagedLoginVerificationHelper.receiptEnvironmentKey]
            = receiptURL.path
        let executableURL = try CodexExecutableResolver.validate(
            URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        )
        let profile = CodexVoiceAppServerProfile(
            codexHomeURL: codexHome,
            processEnvironment: environment,
            identity: "managed-login-verification-\(name)",
            authStorage: .managedFile
        )
        return CodexManagedLoginVerificationFixture(
            context: CodexVoiceManagedLoginContext(
                executableURL: executableURL,
                profile: profile,
                launchArguments: [CodexManagedLoginVerificationHelper.argument]
            ),
            receiptURL: receiptURL
        )
    }

    private static func managedLoginReceiptEvents(_ receiptURL: URL) throws -> [String] {
        let text: String
        do {
            text = try String(contentsOf: receiptURL, encoding: .utf8)
        } catch {
            throw CodexAppServerVerificationError.failed(
                "managed_login_receipt_missing"
            )
        }
        return text.split(whereSeparator: \.isNewline).map(String.init)
    }

    private static func managedLoginProcessesClosed(_ events: [String]) async -> Bool {
        let processIDs = events.compactMap { event -> Int32? in
            guard event.hasPrefix("process_started:"),
                  let value = Int32(event.dropFirst("process_started:".count)) else {
                return nil
            }
            return value
        }
        guard !processIDs.isEmpty else { return false }
        for processID in processIDs where !(await waitForProcessExit(processID)) {
            return false
        }
        return true
    }

    private static func waitForManagedLoginCondition(
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    private static func waitForProcessExit(_ processID: Int32?) async -> Bool {
        guard let processID else { return false }
        for _ in 0..<40 {
            if Darwin.kill(processID, 0) != 0, Darwin.errno == ESRCH {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return Darwin.kill(processID, 0) != 0 && Darwin.errno == ESRCH
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

    private static func verifyManagedChatGPTLoginContract() throws {
        let parameters = CodexVoiceAccountLoginController.loginStartParameters
        guard parameters["type"]?.stringValue == "chatgpt",
              parameters["useHostedLoginSuccessPage"]?.boolValue == true,
              parameters["appBrand"]?.stringValue == "chatgpt",
              parameters["apiKey"] == nil,
              parameters.count == 3 else {
            throw CodexAppServerVerificationError.failed("managed_login_parameters")
        }

        let valid = try CodexVoiceAccountLoginController.parseLoginStartResponse(.object([
            "type": .string("chatgpt"),
            "loginId": .string("login-123"),
            "authUrl": .string("https://auth.openai.com/oauth/authorize?client_id=test")
        ]))
        guard valid.loginID == "login-123",
              valid.authURL.host == "auth.openai.com" else {
            throw CodexAppServerVerificationError.failed("managed_login_response")
        }

        let rejectedResponses: [CodexJSONValue] = [
            .object(["type": .string("apiKey")]),
            .object([
                "type": .string("chatgpt"),
                "loginId": .string("login-123"),
                "authUrl": .string("http://auth.openai.com/oauth/authorize")
            ]),
            .object([
                "type": .string("chatgpt"),
                "loginId": .string("login-123"),
                "authUrl": .string("https://openai.com.example.test/oauth/authorize")
            ]),
            .object([
                "type": .string("chatgpt"),
                "loginId": .string("login id with spaces"),
                "authUrl": .string("https://auth.openai.com/oauth/authorize")
            ])
        ]
        for response in rejectedResponses {
            do {
                _ = try CodexVoiceAccountLoginController.parseLoginStartResponse(response)
                throw CodexAppServerVerificationError.failed("managed_login_rejection")
            } catch is CodexVoiceAccountLoginError {
                continue
            }
        }

        let matchingSuccess = CodexAppServerNotification(
            method: "account/login/completed",
            params: .object([
                "loginId": .string("login-123"),
                "success": .bool(true)
            ])
        )
        let legacySuccess = CodexAppServerNotification(
            method: "account/login/completed",
            params: .object([
                "loginId": .null,
                "success": .bool(true)
            ])
        )
        let mismatched = CodexAppServerNotification(
            method: "account/login/completed",
            params: .object([
                "loginId": .string("different-login"),
                "success": .bool(true)
            ])
        )
        let failed = CodexAppServerNotification(
            method: "account/login/completed",
            params: .object([
                "loginId": .string("login-123"),
                "success": .bool(false)
            ])
        )
        guard CodexVoiceAccountLoginController.parseLoginCompletion(
            matchingSuccess,
            expectedLoginID: "login-123"
        ) == .succeeded,
        CodexVoiceAccountLoginController.parseLoginCompletion(
            legacySuccess,
            expectedLoginID: "login-123"
        ) == .succeeded,
        CodexVoiceAccountLoginController.parseLoginCompletion(
            mismatched,
            expectedLoginID: "login-123"
        ) == .ignored,
        CodexVoiceAccountLoginController.parseLoginCompletion(
            failed,
            expectedLoginID: "login-123"
        ) == .failed,
        CodexVoiceAccountLoginController.loginCancelParameters(loginID: "login-123")
            == ["loginId": .string("login-123")] else {
            throw CodexAppServerVerificationError.failed("managed_login_lifecycle")
        }
    }

    private static func verifyVoiceProfileAuthStorage() throws {
        guard CodexVoiceAppServerProfile.configurationText.contains(
            "cli_auth_credentials_store = \"file\""
        ) else {
            throw CodexAppServerVerificationError.failed("managed_login_file_store")
        }

        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "hoverpocket-codex-auth-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }
        let sourceHome = root.appendingPathComponent("source", isDirectory: true)
        let managedHome = root.appendingPathComponent("managed", isDirectory: true)
        let linkedHome = root.appendingPathComponent("linked", isDirectory: true)
        let retainedHome = root.appendingPathComponent("retained", isDirectory: true)
        try fileManager.createDirectory(
            at: sourceHome,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        for directory in [managedHome, linkedHome, retainedHome] {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }

        guard try CodexVoiceAppServerProfile.prepareAuthStorage(
            in: managedHome,
            sourceHome: sourceHome,
            policy: .externalOrManaged,
            fileManager: fileManager
        ) == .managedFile else {
            throw CodexAppServerVerificationError.failed("managed_login_empty_profile")
        }

        let sourceCredential = sourceHome.appendingPathComponent("auth.json")
        try Data("{}".utf8).write(to: sourceCredential, options: .atomic)
        guard chmod(sourceCredential.path, 0o600) == 0 else {
            throw CodexAppServerVerificationError.failed("managed_login_source_mode")
        }
        guard try CodexVoiceAppServerProfile.prepareAuthStorage(
            in: linkedHome,
            sourceHome: sourceHome,
            policy: .externalOrManaged,
            fileManager: fileManager
        ) == .linkedExternalFile,
        (try fileManager.attributesOfItem(
            atPath: linkedHome.appendingPathComponent("auth.json").path
        )[.type] as? FileAttributeType) == .typeSymbolicLink else {
            throw CodexAppServerVerificationError.failed("managed_login_external_link")
        }

        let retainedCredential = retainedHome.appendingPathComponent("auth.json")
        try Data("{}".utf8).write(to: retainedCredential, options: .atomic)
        guard chmod(retainedCredential.path, 0o600) == 0,
              try CodexVoiceAppServerProfile.prepareAuthStorage(
                in: retainedHome,
                sourceHome: sourceHome,
                policy: .externalOrManaged,
                fileManager: fileManager
              ) == .managedFile,
              (try fileManager.attributesOfItem(atPath: retainedCredential.path)[.type]
                as? FileAttributeType) == .typeRegular else {
            throw CodexAppServerVerificationError.failed("managed_login_retained_profile")
        }

        guard try CodexVoiceAppServerProfile.prepareAuthStorage(
            in: linkedHome,
            sourceHome: sourceHome,
            policy: .disabled,
            fileManager: fileManager
        ) == .disabled,
        !fileManager.fileExists(
            atPath: linkedHome.appendingPathComponent("auth.json").path
        ) else {
            throw CodexAppServerVerificationError.failed("managed_login_disabled_profile")
        }

        let isolatedHome = root.appendingPathComponent("isolated", isDirectory: true)
        try fileManager.createDirectory(
            at: isolatedHome,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard try CodexVoiceAppServerProfile.prepareAuthStorage(
            in: isolatedHome,
            sourceHome: sourceHome,
            policy: .managedOnly,
            fileManager: fileManager
        ) == .managedFile,
        !fileManager.fileExists(
            atPath: isolatedHome.appendingPathComponent("auth.json").path
        ),
        (try? fileManager.destinationOfSymbolicLink(
            atPath: isolatedHome.appendingPathComponent("auth.json").path
        )) == nil else {
            throw CodexAppServerVerificationError.failed(
                "managed_login_isolated_profile"
            )
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

private struct CodexAppServerModelTurnCompletion: Sendable {
    let threadID: String
    let turnID: String
    let status: String
}

private final class CodexAppServerModelVerificationOneShot<Value: Sendable>:
    @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var pendingResult: Result<Value, Error>?
    private var completed = false

    func wait(timeout: TimeInterval) async throws -> Value {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let pendingResult {
                    self.pendingResult = nil
                    lock.unlock()
                    continuation.resume(with: pendingResult)
                    return
                }
                self.continuation = continuation
                lock.unlock()
                DispatchQueue.global(qos: .userInitiated).asyncAfter(
                    deadline: .now() + timeout
                ) { [weak self] in
                    self?.failIfPending()
                }
            }
        } onCancel: { [weak self] in
            self?.resolve(.failure(CancellationError()))
        }
    }

    func succeed(_ value: Value) {
        resolve(.success(value))
    }

    private func resolve(_ result: Result<Value, Error>) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let continuation = continuation
        self.continuation = nil
        if continuation == nil {
            pendingResult = result
        }
        lock.unlock()
        continuation?.resume(with: result)
    }

    private func failIfPending() {
        resolve(.failure(CodexAppServerVerificationError.failed(
            "model_tool_request_timed_out"
        )))
    }
}

private final class CodexAppServerModelToolAdmission: @unchecked Sendable {
    struct Snapshot {
        let admitted: Int
        let rejected: Int
    }

    private let lock = NSLock()
    private var admitted = 0
    private var rejected = 0

    func admitToolCall() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard admitted == 0 else { return false }
        admitted = 1
        return true
    }

    func recordRejectedRequest() {
        lock.lock()
        rejected += 1
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(admitted: admitted, rejected: rejected)
    }
}
