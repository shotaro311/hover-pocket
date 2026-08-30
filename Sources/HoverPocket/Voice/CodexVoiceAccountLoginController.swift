import AppKit
import Combine
import Foundation

enum CodexVoiceAccountLoginState: Equatable, Sendable {
    case idle
    case checking
    case signedOut(managedLoginAvailable: Bool, reasonCode: String)
    case signingIn
    case signedIn
    case failed(String)
}

enum CodexVoiceLoginCompletion: Equatable, Sendable {
    case ignored
    case succeeded
    case failed
}

enum CodexVoiceAccountLoginError: Error, Equatable, Sendable {
    case compatibility(String)
    case managedLoginUnavailable
    case loginResponseInvalid
    case loginURLInvalid
    case browserOpenFailed
    case loginFailed
    case loginTimedOut
    case loginTransportEnded
    case accountReadFailed
    case accountSelectionTimedOut
    case credentialReadbackFailed
}

struct CodexVoiceManagedLoginContext: Equatable, Sendable {
    let executableURL: URL
    let profile: CodexVoiceAppServerProfile
}

actor CodexVoiceAccountContextResolver {
    static let shared = CodexVoiceAccountContextResolver()

    func contexts() throws -> [CodexVoiceManagedLoginContext] {
        let candidates: [URL]
        do {
            candidates = try CodexExecutableResolver.candidates(
                nil,
                includePathLookupWhenFixedCandidatesExist: false
            )
        } catch {
            throw CodexVoiceAccountLoginError.compatibility("codex_not_found")
        }
        var contexts: [CodexVoiceManagedLoginContext] = []
        for executableURL in candidates {
            try Task.checkCancellation()
            if let profile = try? CodexVoiceAppServerProfile.prepare(
                executableURL: executableURL
            ) {
                contexts.append(CodexVoiceManagedLoginContext(
                    executableURL: executableURL,
                    profile: profile
                ))
            }
        }
        guard !contexts.isEmpty else {
            throw CodexVoiceAccountLoginError.compatibility(
                candidates.isEmpty ? "codex_not_found" : "codex_voice_profile_invalid"
            )
        }
        return contexts
    }
}

private struct CodexVoiceAccountClientSelection: Sendable {
    let context: CodexVoiceManagedLoginContext
    let client: CodexAppServerClient
    let account: CodexJSONValue
    let requestTimeout: TimeInterval
}

@MainActor
final class CodexVoiceAccountLoginController: ObservableObject {
    static let shared = CodexVoiceAccountLoginController()

    @Published private(set) var state: CodexVoiceAccountLoginState = .idle

    private static let loginTimeoutNanoseconds: UInt64 = 10 * 60 * 1_000_000_000
    private static let cancelGraceNanoseconds: UInt64 = 500_000_000
    private static let accountSelectionTimeout: TimeInterval = 20
    private static let accountRequestTimeout: TimeInterval = 8
    private var operationTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var operationGeneration: UInt64 = 0
    private var activeClient: CodexAppServerClient?
    private var activeLoginID: String?
    private var lastManagedLoginAvailable = false
    private var isShuttingDown = false

    func refresh() {
        guard !isShuttingDown,
              operationTask == nil,
              cleanupTask == nil,
              state != .signingIn else { return }
        let generation = beginOperation(state: .checking)
        operationTask = Task { [weak self] in
            await self?.performRefresh(generation: generation)
        }
    }

    func startLogin() {
        guard !isShuttingDown,
              operationTask == nil,
              cleanupTask == nil,
              state != .signingIn else { return }
        let generation = beginOperation(state: .signingIn)
        operationTask = Task { [weak self] in
            await self?.performLogin(generation: generation)
        }
    }

    func cancelLogin() {
        stopCurrentOperation(nextState: .signedOut(
            managedLoginAvailable: lastManagedLoginAvailable,
            reasonCode: "signed_out"
        ))
    }

    func deactivate() {
        stopCurrentOperation(nextState: .idle)
    }

    func shutdown() async {
        isShuttingDown = true
        operationGeneration &+= 1
        let task = operationTask
        operationTask = nil
        task?.cancel()
        let pendingCleanup = cleanupTask
        cleanupTask = nil
        let client = activeClient
        let loginID = activeLoginID
        activeClient = nil
        activeLoginID = nil
        await pendingCleanup?.value
        await Self.cancelLoginAndClose(client: client, loginID: loginID)
        await task?.value
        state = .idle
    }

    nonisolated static var loginStartParameters: [String: CodexJSONValue] {
        [
            "type": .string("chatgpt"),
            "useHostedLoginSuccessPage": .bool(true),
            "appBrand": .string("chatgpt")
        ]
    }

    nonisolated static func loginCancelParameters(loginID: String)
        -> [String: CodexJSONValue] {
        ["loginId": .string(loginID)]
    }

    nonisolated static func parseLoginStartResponse(
        _ response: CodexJSONValue
    ) throws -> (loginID: String, authURL: URL) {
        guard let object = response.objectValue,
              object["type"]?.stringValue == "chatgpt",
              let loginID = object["loginId"]?.stringValue,
              isValidLoginID(loginID),
              let authURLText = object["authUrl"]?.stringValue,
              let authURL = URL(string: authURLText),
              isAllowedAuthURL(authURL) else {
            throw CodexVoiceAccountLoginError.loginResponseInvalid
        }
        return (loginID, authURL)
    }

    nonisolated static func parseLoginCompletion(
        _ notification: CodexAppServerNotification,
        expectedLoginID: String
    ) -> CodexVoiceLoginCompletion {
        guard notification.method == "account/login/completed",
              let params = notification.params?.objectValue,
              let success = params["success"]?.boolValue else {
            return .ignored
        }
        if let loginIDValue = params["loginId"] {
            switch loginIDValue {
            case .null:
                break
            case .string(let loginID) where loginID == expectedLoginID:
                break
            default:
                return .ignored
            }
        }
        return success ? .succeeded : .failed
    }

    nonisolated static func isAllowedAuthURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              url.port == nil || url.port == 443,
              let host = url.host?.lowercased() else {
            return false
        }
        return host == "openai.com"
            || host.hasSuffix(".openai.com")
            || host == "chatgpt.com"
            || host.hasSuffix(".chatgpt.com")
    }

    private func performRefresh(generation: UInt64) async {
        do {
            let selection = try await selectAccountClient(generation: generation)
            lastManagedLoginAvailable = selection.context.profile.authStorage.allowsManagedLogin
            await selection.client.close()
            clearActiveClient(selection.client, generation: generation)
            guard isCurrent(generation) else { return }
            state = Self.state(
                for: selection.account,
                managedLoginAvailable: selection.context.profile.authStorage.allowsManagedLogin
            )
            finishOperation(generation)
        } catch {
            guard generation == operationGeneration else { return }
            publishFailure(error, generation: generation)
        }
    }

    private func performLogin(generation: UInt64) async {
        var client: CodexAppServerClient?
        var loginID: String?
        var streamContinuation: AsyncStream<CodexAppServerNotification>.Continuation?
        do {
            let selection = try await selectAccountClient(generation: generation)
            client = selection.client
            guard selection.context.profile.authStorage.allowsManagedLogin else {
                throw CodexVoiceAccountLoginError.managedLoginUnavailable
            }
            guard isCurrent(generation) else { return }
            lastManagedLoginAvailable = true
            let startedClient: CodexAppServerClient
            if selection.requestTimeout < Self.accountRequestTimeout {
                await selection.client.close()
                clearActiveClient(selection.client, generation: generation)
                let replacement = try await Self.startClient(
                    selection.context,
                    requestTimeout: Self.accountRequestTimeout
                )
                guard installActiveClient(replacement, generation: generation) else {
                    await replacement.close()
                    throw CancellationError()
                }
                startedClient = replacement
            } else {
                startedClient = selection.client
            }
            client = startedClient

            let stream = AsyncStream<CodexAppServerNotification> { continuation in
                streamContinuation = continuation
            }
            guard let streamContinuation else {
                throw CodexVoiceAccountLoginError.loginTransportEnded
            }
            await startedClient.setNotificationHandler { notification in
                streamContinuation.yield(notification)
            }
            let response = try await startedClient.sendRequest(
                "account/login/start",
                params: .object(Self.loginStartParameters)
            )
            let login = try Self.parseLoginStartResponse(response)
            guard isCurrent(generation) else { return }
            loginID = login.loginID
            activeLoginID = login.loginID
            guard NSWorkspace.shared.open(login.authURL) else {
                throw CodexVoiceAccountLoginError.browserOpenFailed
            }

            let completion = try await Self.waitForLoginCompletion(
                stream: stream,
                expectedLoginID: login.loginID
            )
            guard completion == .succeeded else {
                throw CodexVoiceAccountLoginError.loginFailed
            }
            let account = try await startedClient.sendRequest(
                "account/read",
                params: .object(["refreshToken": .bool(false)])
            )
            guard CodexVoiceCoordinator.accountAdmissionCode(account) == nil else {
                throw CodexVoiceAccountLoginError.accountReadFailed
            }
            guard selection.context.profile.hasValidManagedCredentialFile else {
                throw CodexVoiceAccountLoginError.credentialReadbackFailed
            }

            streamContinuation.finish()
            await startedClient.close()
            clearActiveClient(startedClient, generation: generation)
            guard isCurrent(generation) else { return }
            state = .signedIn
            finishOperation(generation)
            VoiceLaneRuntime.shared.credentialsDidChange()
        } catch is CancellationError {
            streamContinuation?.finish()
            if generation == operationGeneration {
                await Self.cancelLoginAndClose(client: client, loginID: loginID)
                clearActiveClient(client, generation: generation)
            }
        } catch {
            streamContinuation?.finish()
            guard generation == operationGeneration else { return }
            await Self.cancelLoginAndClose(client: client, loginID: loginID)
            clearActiveClient(client, generation: generation)
            publishFailure(error, generation: generation)
        }
    }

    private func selectAccountClient(
        generation: UInt64
    ) async throws -> CodexVoiceAccountClientSelection {
        let contexts = try await CodexVoiceAccountContextResolver.shared.contexts()
        let deadline = ProcessInfo.processInfo.systemUptime
            + Self.accountSelectionTimeout
        var lastError: Error = CodexVoiceAccountLoginError.accountReadFailed
        for context in contexts {
            try Task.checkCancellation()
            guard isCurrent(generation) else { throw CancellationError() }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else {
                throw CodexVoiceAccountLoginError.accountSelectionTimedOut
            }
            let requestTimeout = min(
                Self.accountRequestTimeout,
                max(1, remaining / 2)
            )
            var candidate: CodexAppServerClient?
            do {
                let startedClient = try await Self.startClient(
                    context,
                    requestTimeout: requestTimeout
                )
                candidate = startedClient
                guard installActiveClient(startedClient, generation: generation) else {
                    await startedClient.close()
                    throw CancellationError()
                }
                let account = try await startedClient.sendRequest(
                    "account/read",
                    params: .object(["refreshToken": .bool(false)])
                )
                guard CodexVoiceCoordinator.accountAdmissionCode(account)
                    != "account_response_invalid" else {
                    throw CodexVoiceAccountLoginError.accountReadFailed
                }
                guard ProcessInfo.processInfo.systemUptime <= deadline else {
                    throw CodexVoiceAccountLoginError.accountSelectionTimedOut
                }
                return CodexVoiceAccountClientSelection(
                    context: context,
                    client: startedClient,
                    account: account,
                    requestTimeout: requestTimeout
                )
            } catch is CancellationError {
                if generation == operationGeneration {
                    await candidate?.close()
                    clearActiveClient(candidate, generation: generation)
                }
                throw CancellationError()
            } catch {
                guard generation == operationGeneration else {
                    throw CancellationError()
                }
                await candidate?.close()
                clearActiveClient(candidate, generation: generation)
                lastError = error
            }
        }
        throw lastError
    }

    private nonisolated static func startClient(
        _ context: CodexVoiceManagedLoginContext,
        requestTimeout: TimeInterval
    ) async throws -> CodexAppServerClient {
        try await CodexAppServerClient.start(
            options: CodexAppServerClientOptions(
                executableURL: context.executableURL,
                launchArguments: ["app-server", "--stdio"],
                processEnvironment: context.profile.processEnvironment,
                workingDirectoryURL: context.profile.codexHomeURL,
                requestTimeout: requestTimeout,
                clientName: "hover_pocket_account",
                clientTitle: "HoverPocket Account",
                clientVersion: "1",
                experimentalAPI: true
            )
        )
    }

    private nonisolated static func waitForLoginCompletion(
        stream: AsyncStream<CodexAppServerNotification>,
        expectedLoginID: String
    ) async throws -> CodexVoiceLoginCompletion {
        try await withThrowingTaskGroup(of: CodexVoiceLoginCompletion.self) { group in
            group.addTask {
                for await notification in stream {
                    try Task.checkCancellation()
                    let completion = parseLoginCompletion(
                        notification,
                        expectedLoginID: expectedLoginID
                    )
                    if completion != .ignored {
                        return completion
                    }
                }
                throw CodexVoiceAccountLoginError.loginTransportEnded
            }
            group.addTask {
                try await Task.sleep(nanoseconds: loginTimeoutNanoseconds)
                throw CodexVoiceAccountLoginError.loginTimedOut
            }
            guard let result = try await group.next() else {
                throw CodexVoiceAccountLoginError.loginTransportEnded
            }
            group.cancelAll()
            return result
        }
    }

    private nonisolated static func cancelLoginAndClose(
        client: CodexAppServerClient?,
        loginID: String?
    ) async {
        guard let client else { return }
        guard let loginID else {
            await client.close()
            return
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = try? await client.sendRequest(
                    "account/login/cancel",
                    params: .object(loginCancelParameters(loginID: loginID))
                )
            }
            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: cancelGraceNanoseconds)
                } catch {
                    return
                }
            }
            _ = await group.next()
            await client.close()
            group.cancelAll()
        }
    }

    private nonisolated static func state(
        for account: CodexJSONValue,
        managedLoginAvailable: Bool
    ) -> CodexVoiceAccountLoginState {
        if CodexVoiceCoordinator.accountAdmissionCode(account) == nil {
            return .signedIn
        }
        return .signedOut(
            managedLoginAvailable: managedLoginAvailable,
            reasonCode: CodexVoiceCoordinator.accountAdmissionCode(account)
                ?? "account_response_invalid"
        )
    }

    private nonisolated static func isValidLoginID(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 256 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII
                && (CharacterSet.alphanumerics.contains(scalar)
                    || scalar == "-"
                    || scalar == "_"
                    || scalar == ".")
        }
    }

    private func beginOperation(state: CodexVoiceAccountLoginState) -> UInt64 {
        operationGeneration &+= 1
        self.state = state
        return operationGeneration
    }

    private func stopCurrentOperation(nextState: CodexVoiceAccountLoginState) {
        guard !isShuttingDown else { return }
        guard cleanupTask == nil else {
            state = nextState
            return
        }
        operationGeneration &+= 1
        let task = operationTask
        task?.cancel()
        operationTask = nil
        let client = activeClient
        let loginID = activeLoginID
        activeClient = nil
        activeLoginID = nil
        state = nextState
        cleanupTask = Task { [weak self] in
            await Self.cancelLoginAndClose(client: client, loginID: loginID)
            await task?.value
            self?.cleanupTask = nil
        }
    }

    private func installActiveClient(
        _ client: CodexAppServerClient,
        generation: UInt64
    ) -> Bool {
        guard isCurrent(generation) else { return false }
        activeClient = client
        return true
    }

    private func clearActiveClient(
        _ client: CodexAppServerClient?,
        generation: UInt64
    ) {
        guard isCurrent(generation), activeClient === client else { return }
        activeClient = nil
        activeLoginID = nil
    }

    private func finishOperation(_ generation: UInt64) {
        guard isCurrent(generation) else { return }
        operationTask = nil
    }

    private func publishFailure(_ error: Error, generation: UInt64) {
        guard isCurrent(generation) else { return }
        state = .failed(Self.safeErrorCode(error))
        operationTask = nil
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        generation == operationGeneration && !Task.isCancelled
    }

    private nonisolated static func safeErrorCode(_ error: Error) -> String {
        switch error {
        case CodexVoiceAccountLoginError.compatibility(let code):
            code
        case CodexVoiceAccountLoginError.managedLoginUnavailable:
            "codex_managed_login_unavailable"
        case CodexVoiceAccountLoginError.loginResponseInvalid,
             CodexVoiceAccountLoginError.loginURLInvalid:
            "codex_login_response_invalid"
        case CodexVoiceAccountLoginError.browserOpenFailed:
            "codex_login_browser_failed"
        case CodexVoiceAccountLoginError.loginFailed:
            "codex_login_failed"
        case CodexVoiceAccountLoginError.loginTimedOut:
            "codex_login_timed_out"
        case CodexVoiceAccountLoginError.loginTransportEnded:
            "codex_login_transport_ended"
        case CodexVoiceAccountLoginError.accountReadFailed:
            "codex_login_account_readback_failed"
        case CodexVoiceAccountLoginError.accountSelectionTimedOut:
            "codex_login_account_selection_timed_out"
        case CodexVoiceAccountLoginError.credentialReadbackFailed:
            "codex_login_credential_readback_failed"
        default:
            "codex_login_unavailable"
        }
    }
}
