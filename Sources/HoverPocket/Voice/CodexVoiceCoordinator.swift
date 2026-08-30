import Foundation

enum CodexVoiceRuntimeError: Error, Equatable, Sendable {
    case signedOut
    case compatibility(String)
    case sdpTimedOut
    case negotiationCancelled
    case disposed
}

@MainActor
final class CodexVoiceCoordinator {
    typealias ClientFactory = @Sendable () async throws -> CodexAppServerClient

    private enum RealtimeLifecycle: Equatable {
        case idle
        case starting
        case active
        case stopping
        case stopped
    }

    private static let ambientServerRequests: Set<String> = [
        "applyPatchApproval",
        "execCommandApproval",
        "item/commandExecution/requestApproval",
        "item/fileChange/requestApproval",
        "item/permissions/requestApproval",
        "item/tool/requestUserInput",
        "mcpServer/elicitation/request",
        "openai/form"
    ]

    private struct PendingSDP {
        let attemptID: UInt64
        let threadID: String
        let clientGeneration: UInt64
        let result: CodexVoiceOneShot<String>
        let timeoutTask: Task<Void, Never>
    }

    private struct ListedThread: Sendable {
        let threadID: String
        let sessionID: String
        let parentThreadID: String
        let title: String
        let preview: String
        let status: String
        let createdAt: Date
        let updatedAt: Date
    }

    private struct ThreadReadCacheKey: Hashable, Sendable {
        let threadID: String
        let sessionID: String
        let parentThreadID: String
        let updatedAt: Date
    }

    private enum ThreadReadCacheValue: Sendable {
        case message(String)
        case noMessage
    }

    private enum ThreadReadValidation: Sendable {
        case invalidIdentity
        case validated(String?)
    }

    private let featureEnabled: Bool
    private let clientFactory: ClientFactory
    private let toolAdapter: (any CodexVoiceCapabilityToolAdapterProtocol)?
    private let rootThreadEphemeral: Bool
    private let workspaceDirectory: URL
    private let restartDelaysNanoseconds: [UInt64]
    private let sdpTimeoutNanoseconds: UInt64
    private var client: CodexAppServerClient?
    private var restartTask: Task<Void, Never>?
    private var pendingSDP: PendingSDP?
    private var transcript: CodexVoiceTranscriptBuffer
    private var availability: CodexVoiceAvailability
    private var sessionStatus: CodexVoiceSessionStatus = .idle
    private var rootThreadID: String?
    private var rootSessionID: String?
    private var rootCreatedAt: Date?
    private var childSessions: [CodexVoiceThreadSummary] = []
    private var threadReadCache: [ThreadReadCacheKey: ThreadReadCacheValue] = [:]
    private var sessionRefreshTask: Task<Void, Never>?
    private var transcriptPublishTask: Task<Void, Never>?
    private var sessionsVisible = false
    private var transportAttached = false
    private var realtimeStopRequested = false
    private var realtimeStopTask: Task<Void, Never>?
    private var realtimeLifecycle: RealtimeLifecycle = .idle
    private var isMuted = true
    private var lastErrorCode: String?
    private var appServerProcessID: Int32?
    private var restartAttempt = 0
    private var voiceCount = 0
    private var nextClientGeneration: UInt64 = 0
    private var clientGeneration: UInt64 = 0
    private var initializingClient: CodexAppServerClient?
    private var initializingClientGeneration: UInt64 = 0
    private var quarantinedClientGenerations: Set<UInt64> = []
    private var rootThreadGeneration: UInt64 = 0
    private var nextSDPAttempt: UInt64 = 0
    private var activeNegotiationAttemptID: UInt64?
    private var isDisposed = false

    var snapshotHandler: ((CodexVoiceSnapshot) -> Void)?

    init(
        featureEnabled: Bool,
        workspaceDirectory: URL? = nil,
        transcriptEntryLimit: Int = 120,
        transcriptCharacterLimit: Int = 32_000,
        restartDelaysNanoseconds: [UInt64] = [0, 450_000_000, 1_400_000_000],
        sdpTimeoutNanoseconds: UInt64 = 20_000_000_000,
        clientFactory: ClientFactory? = nil,
        toolAdapter: (any CodexVoiceCapabilityToolAdapterProtocol)? = nil,
        rootThreadEphemeral: Bool = false
    ) {
        self.featureEnabled = featureEnabled
        self.availability = featureEnabled ? .unavailable : .disabled
        self.workspaceDirectory = workspaceDirectory
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("HoverPocket", isDirectory: true)
                .appendingPathComponent("VoiceWorkspace", isDirectory: true)
        self.transcript = CodexVoiceTranscriptBuffer(
            entryLimit: transcriptEntryLimit,
            characterLimit: transcriptCharacterLimit
        )
        self.restartDelaysNanoseconds = restartDelaysNanoseconds
        self.sdpTimeoutNanoseconds = sdpTimeoutNanoseconds
        self.toolAdapter = toolAdapter
        self.rootThreadEphemeral = rootThreadEphemeral
        self.clientFactory = clientFactory ?? {
            let executableURL = try CodexExecutableResolver.resolve(nil)
            let profile = try CodexVoiceAppServerProfile.prepare(
                executableURL: executableURL
            )
            return try await CodexAppServerClient.start(
                options: CodexAppServerClientOptions(
                    executableURL: executableURL,
                    launchArguments: CodexVoiceAppServerLaunchPolicy.arguments,
                    processEnvironment: profile.processEnvironment,
                    workingDirectoryURL: profile.codexHomeURL,
                    clientTitle: "HoverPocket Voice Lane",
                    clientVersion: Bundle.main.object(
                        forInfoDictionaryKey: "CFBundleShortVersionString"
                    ) as? String ?? "0.0.0",
                    experimentalAPI: true
                )
            )
        }
    }

    var snapshot: CodexVoiceSnapshot {
        CodexVoiceSnapshot(
            featureEnabled: featureEnabled,
            availability: availability,
            sessionStatus: sessionStatus,
            rootThreadID: rootThreadID,
            transportAttached: transportAttached,
            isMuted: isMuted,
            transcript: transcript.snapshot,
            sessions: sessionSummaries,
            lastErrorCode: lastErrorCode,
            appServerProcessID: appServerProcessID,
            restartAttempt: restartAttempt,
            voiceCount: voiceCount
        )
    }

    private var sessionSummaries: [CodexVoiceThreadSummary] {
        guard let rootThreadID, let rootCreatedAt else { return [] }
        let rootState: CodexVoiceThreadState
        switch sessionStatus {
        case .recoverableFailure, .blockedFailure:
            rootState = .failed
        default:
            rootState = .running
        }
        return [
            CodexVoiceThreadSummary(
                threadID: rootThreadID,
                isCurrentRoot: true,
                title: "current",
                detail: sessionStatus.rawValue,
                state: rootState,
                createdAt: rootCreatedAt,
                updatedAt: rootCreatedAt
            )
        ] + childSessions
    }

    func initialize() async {
        guard !isDisposed else { return }
        guard featureEnabled else {
            publish()
            return
        }
        guard client == nil else { return }

        update(availability: .starting, status: .idle, errorCode: nil)
        do {
            try await startClientAndValidate()
            update(availability: .ready, status: .idle, errorCode: nil)
        } catch CodexVoiceRuntimeError.disposed {
            return
        } catch CodexVoiceRuntimeError.signedOut {
            update(availability: .signedOut, status: .blockedFailure, errorCode: "signed_out")
        } catch CodexVoiceRuntimeError.compatibility(let code) {
            update(
                availability: code == "ambient_tool_request_rejected" ? .blocked : .incompatible,
                status: .blockedFailure,
                errorCode: code
            )
        } catch CodexAppServerClientError.executableNotFound,
                CodexAppServerClientError.executableNotRunnable {
            update(availability: .unavailable, status: .blockedFailure, errorCode: "codex_not_found")
        } catch let error as CodexAppServerRPCError {
            update(availability: .incompatible, status: .blockedFailure, errorCode: "rpc_\(error.code)")
        } catch {
            update(
                availability: .faulted,
                status: .recoverableFailure,
                errorCode: String(describing: type(of: error))
            )
        }
    }

    private func startClientAndValidate() async throws {
        let candidate = try await clientFactory()
        nextClientGeneration &+= 1
        let generation = nextClientGeneration
        initializingClient = candidate
        initializingClientGeneration = generation
        await candidate.setNotificationHandler { [weak self, weak candidate] notification in
            guard let self, let candidate else { return }
            await self.receiveNotification(
                notification,
                from: candidate,
                generation: generation
            )
        }
        await candidate.setTransportEndedHandler { [weak self, weak candidate] reason in
            Task { @MainActor in
                guard let self, let candidate else { return }
                await self.handleTransportEnd(
                    client: candidate,
                    generation: generation,
                    reason: reason
                )
            }
        }
        await candidate.setServerRequestAdmissionHandler {
            [weak self, weak candidate] request in
            guard let self, let candidate else { return }
            await self.admitServerRequest(
                client: candidate,
                generation: generation,
                request: request
            )
        }
        await candidate.setServerRequestHandler { [weak self, weak candidate] request in
            guard let self, let candidate else {
                return .failure(code: -32600, message: "HoverPocket Voice session is unavailable.")
            }
            return await self.handleServerRequest(
                client: candidate,
                generation: generation,
                request: request
            )
        }

        do {
            let account = try await candidate.sendRequest(
                "account/read",
                params: .object(["refreshToken": .bool(false)])
            )
            try validateAccount(account)
            let voices = try await candidate.sendRequest(
                "thread/realtime/listVoices",
                params: .object([:])
            )
            let availableVoiceCount = try parseVoices(voices)
            guard !isDisposed, !Task.isCancelled else {
                throw CodexVoiceRuntimeError.disposed
            }
            guard !quarantinedClientGenerations.contains(generation) else {
                throw CodexVoiceRuntimeError.compatibility("ambient_tool_request_rejected")
            }
            client = candidate
            clientGeneration = generation
            initializingClient = nil
            initializingClientGeneration = 0
            appServerProcessID = await candidate.processIdentifier
            voiceCount = availableVoiceCount
        } catch {
            if initializingClient === candidate,
               initializingClientGeneration == generation {
                initializingClient = nil
                initializingClientGeneration = 0
            }
            await candidate.setNotificationHandler(nil)
            await candidate.setTransportEndedHandler(nil)
            await candidate.setServerRequestAdmissionHandler(nil)
            await candidate.setServerRequestHandler(nil)
            await candidate.close()
            throw error
        }
    }

    private func receiveNotification(
        _ notification: CodexAppServerNotification,
        from sourceClient: CodexAppServerClient,
        generation: UInt64
    ) async {
        guard client === sourceClient,
              clientGeneration == generation else { return }
        await processNotification(notification)
    }

    func markSessionRequestingPermission() {
        guard !isDisposed else { return }
        sessionStatus = .requestingPermission
        lastErrorCode = nil
        publish()
    }

    func startWebRTC(sdpOffer: String) async throws -> CodexVoiceWebRTCAnswer {
        guard !isDisposed else { throw CodexVoiceRuntimeError.disposed }
        guard !sdpOffer.isEmpty,
              sdpOffer.utf8.count <= 131_072,
              sdpOffer.hasPrefix("v=0") else {
            throw CodexVoiceRuntimeError.compatibility("webrtc_offer_invalid")
        }
        guard availability == .ready,
              let client,
              clientGeneration > 0 else {
            throw CodexVoiceRuntimeError.compatibility("voice_not_ready")
        }
        guard pendingSDP == nil, activeNegotiationAttemptID == nil else {
            throw CodexVoiceRuntimeError.compatibility("webrtc_negotiation_in_progress")
        }
        guard realtimeStopTask == nil,
              !realtimeStopRequested,
              Self.canStartRealtime(from: realtimeLifecycle) else {
            if realtimeStopTask != nil
                || realtimeStopRequested
                || realtimeLifecycle == .stopping {
                throw CodexVoiceRuntimeError.compatibility("realtime_stopping")
            }
            throw CodexVoiceRuntimeError.compatibility("realtime_already_active")
        }
        let generation = clientGeneration
        realtimeStopRequested = false
        realtimeLifecycle = .starting
        nextSDPAttempt &+= 1
        let attemptID = nextSDPAttempt
        activeNegotiationAttemptID = attemptID
        sessionStatus = .negotiating
        lastErrorCode = nil
        publish()
        defer {
            if pendingSDP?.attemptID == attemptID {
                pendingSDP?.timeoutTask.cancel()
                pendingSDP = nil
            }
            if activeNegotiationAttemptID == attemptID {
                activeNegotiationAttemptID = nil
            }
        }

        var attemptThreadID: String?
        var negotiationStage = "thread_start"
        do {
            let threadID = try await ensureRootThread(
                client: client,
                generation: generation,
                attemptID: attemptID
            )
            attemptThreadID = threadID
            guard activeNegotiationAttemptID == attemptID else {
                throw CodexVoiceRuntimeError.negotiationCancelled
            }

            let result = CodexVoiceOneShot<String>()
            let timeoutNanoseconds = sdpTimeoutNanoseconds
            let timeoutTask = Task {
                do {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                } catch {
                    return
                }
                await result.fail(.sdpTimedOut)
            }
            pendingSDP = PendingSDP(
                attemptID: attemptID,
                threadID: threadID,
                clientGeneration: generation,
                result: result,
                timeoutTask: timeoutTask
            )
            negotiationStage = "realtime_start"
            let requestTask = Task {
                try await client.sendRequest(
                    "thread/realtime/start",
                    params: .object([
                        "threadId": .string(threadID),
                        "outputModality": .string("audio"),
                        "version": .string("v3"),
                        "includeStartupContext": .bool(false),
                        "prompt": .string(
                            "Respond concisely for a compact desktop voice interface. "
                                + "Use only HoverPocket capabilities when they are available."
                        ),
                        "transport": .object([
                            "type": .string("webrtc"),
                            "sdp": .string(sdpOffer)
                        ])
                    ])
                )
            }
            let requestCompletionTask = Task {
                do {
                    _ = try await requestTask.value
                } catch {
                    await result.fail(Self.realtimeStartRequestError(error))
                }
            }
            defer {
                requestCompletionTask.cancel()
                requestTask.cancel()
            }
            negotiationStage = "sdp_wait"
            let answer = try await result.wait()
            guard availability == .ready,
                  activeNegotiationAttemptID == attemptID,
                  rootThreadGeneration == generation,
                  realtimeLifecycle != .stopping,
                  realtimeLifecycle != .stopped else {
                throw CodexVoiceRuntimeError.negotiationCancelled
            }
            realtimeLifecycle = .active
            return CodexVoiceWebRTCAnswer(rootThreadID: threadID, sdp: answer)
        } catch {
            if let attemptThreadID,
               rootThreadID == attemptThreadID,
               rootThreadGeneration == generation {
                await stopRealtime()
                clearRootThreadState()
            }
            if !isDisposed, availability != .blocked {
                update(
                    availability: .ready,
                    status: .recoverableFailure,
                    errorCode: Self.negotiationErrorCode(
                        error,
                        stage: negotiationStage
                    )
                )
            }
            throw error
        }
    }

    private static func realtimeStartRequestError(_ error: Error) -> CodexVoiceRuntimeError {
        if let runtimeError = error as? CodexVoiceRuntimeError {
            return runtimeError
        }
        if error is CancellationError {
            return .negotiationCancelled
        }
        return .compatibility(
            negotiationErrorCode(error, stage: "realtime_start")
        )
    }

    private static func negotiationErrorCode(_ error: Error, stage: String) -> String {
        switch error {
        case CodexVoiceRuntimeError.sdpTimedOut:
            return "sdp_timed_out"
        case CodexVoiceRuntimeError.negotiationCancelled:
            return "negotiation_cancelled"
        case CodexVoiceRuntimeError.disposed:
            return "voice_disposed"
        case CodexVoiceRuntimeError.signedOut:
            return "signed_out"
        case CodexVoiceRuntimeError.compatibility(let code):
            return safeErrorCode(code)
        case let rpcError as CodexAppServerRPCError:
            let boundedCode = min(rpcError.code.magnitude, 999_999)
            let structuredDetail = safeRPCDataCategory(rpcError.data)
                ?? safeRPCMessageCategory(rpcError.message)
            return safeErrorCode(
                [stage, "rpc", String(boundedCode), structuredDetail]
                    .compactMap { $0 }
                    .joined(separator: "_")
            )
        case CodexAppServerClientError.requestTimedOut:
            return "\(stage)_timed_out"
        case is CodexAppServerClientError:
            return "app_server_transport_failed"
        case is CancellationError:
            return "negotiation_cancelled"
        default:
            return "\(stage)_failed"
        }
    }

    private static func safeRPCMessageCategory(_ message: String) -> String? {
        let boundedMessage = String(message.unicodeScalars.prefix(4_096))
        let normalized = String(
            boundedMessage.lowercased().unicodeScalars.map { scalar in
                CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
            }
        )
        let markers: [(needle: String, code: String)] = [
            ("requires api key", "requires_api_key"),
            ("does not support", "not_supported"),
            ("api key", "api_key"),
            ("authentication", "authentication"),
            ("unauthorized", "unauthorized"),
            ("forbidden", "forbidden"),
            ("not enabled", "not_enabled"),
            ("not available", "unavailable"),
            ("unsupported", "unsupported"),
            ("bad request", "bad_request"),
            ("invalid request", "invalid_request"),
            ("invalid argument", "invalid_argument"),
            ("invalid value", "invalid_value"),
            ("failed to start", "start_failed"),
            ("not found", "not_found"),
            ("missing", "missing"),
            ("disabled", "disabled"),
            ("rejected", "rejected"),
            ("unexpected", "unexpected"),
            ("ended", "ended"),
            ("closed", "closed"),
            ("realtime", "realtime"),
            ("conversation", "conversation"),
            ("websocket", "websocket"),
            ("webrtc", "webrtc"),
            ("sdp", "sdp"),
            ("version", "version"),
            ("transport", "transport"),
            ("model", "model"),
            ("voice", "voice"),
            ("session", "session"),
            ("audio", "audio"),
            ("offer", "offer"),
            ("media", "media"),
            ("data channel", "data_channel"),
            ("peer", "peer"),
            ("codec", "codec"),
            ("connection", "connection"),
            ("call", "call"),
            ("rate limit", "rate_limit"),
            ("quota", "quota"),
            ("entitlement", "entitlement"),
            ("access", "access"),
            ("status 400", "http_400"),
            ("status 401", "http_401"),
            ("status 403", "http_403"),
            ("status 404", "http_404"),
            ("status 409", "http_409"),
            ("status 429", "http_429"),
            ("status 500", "http_500"),
            ("status 502", "http_502"),
            ("status 503", "http_503"),
            ("internal", "internal")
        ]
        let matched = markers.compactMap { marker in
            normalized.contains(marker.needle) ? marker.code : nil
        }
        guard !matched.isEmpty else { return nil }
        return matched.prefix(3).joined(separator: "_")
    }

    private static func safeRPCDataCategory(_ data: CodexJSONValue?) -> String? {
        guard let data else { return nil }
        if let value = data.stringValue {
            return safeRPCMessageCategory(value)
        }
        guard let object = data.objectValue else { return nil }
        if let value = object["code"]?.stringValue ?? object["type"]?.stringValue {
            return safeErrorCode(value)
        }
        guard let nested = object["error"]?.objectValue else { return nil }
        if let value = nested["code"]?.stringValue ?? nested["type"]?.stringValue {
            return safeErrorCode(value)
        }
        return nested["message"]?.stringValue.flatMap(safeRPCMessageCategory)
    }

    private func ensureRootThread(
        client: CodexAppServerClient,
        generation: UInt64,
        attemptID: UInt64
    ) async throws -> String {
        guard self.client === client,
              clientGeneration == generation,
              availability == .ready,
              activeNegotiationAttemptID == attemptID else {
            throw CodexVoiceRuntimeError.compatibility("voice_client_stale")
        }
        if let rootThreadID,
           !rootThreadID.isEmpty,
           rootThreadGeneration == generation {
            return rootThreadID
        }
        try FileManager.default.createDirectory(
            at: workspaceDirectory,
            withIntermediateDirectories: true
        )
        let threadStartParams = CodexVoiceThreadContract.startParameters(
            workspaceDirectory: workspaceDirectory,
            dynamicTools: toolAdapter?.dynamicTools ?? [],
            ephemeral: rootThreadEphemeral
        )
        let response = try await client.sendRequest(
            "thread/start",
            params: .object(threadStartParams)
        )
        guard let thread = response.objectValue?["thread"]?.objectValue,
              let id = thread["id"]?.stringValue,
              Self.validThreadIdentifier(id),
              let sessionID = thread["sessionId"]?.stringValue,
              Self.validThreadIdentifier(sessionID),
              let createdAtSeconds = thread["createdAt"]?.integerValue,
              createdAtSeconds > 0,
              createdAtSeconds <= 253_402_300_799 else {
            throw CodexVoiceRuntimeError.compatibility("thread_start_response_invalid")
        }
        guard self.client === client,
              clientGeneration == generation,
              availability == .ready,
              activeNegotiationAttemptID == attemptID else {
            throw CodexVoiceRuntimeError.compatibility("voice_client_stale")
        }
        rootThreadID = id
        rootSessionID = sessionID
        rootCreatedAt = Date(timeIntervalSince1970: TimeInterval(createdAtSeconds))
        rootThreadGeneration = generation
        childSessions = []
        threadReadCache = [:]
        startSessionRefreshIfNeeded()
        publish()
        return id
    }

    private func startSessionRefreshLoop(
        client: CodexAppServerClient,
        generation: UInt64,
        rootThreadID: String,
        rootSessionID: String
    ) {
        sessionRefreshTask?.cancel()
        sessionRefreshTask = Task { @MainActor [weak self, weak client] in
            guard let self, let client else { return }
            while !Task.isCancelled,
                  !self.isDisposed,
                  self.client === client,
                  self.clientGeneration == generation,
                  self.rootThreadID == rootThreadID,
                  self.rootSessionID == rootSessionID {
                await self.refreshChildSessions(
                    client: client,
                    generation: generation,
                    rootThreadID: rootThreadID,
                    rootSessionID: rootSessionID
                )
                do {
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                } catch {
                    return
                }
            }
        }
    }

    private func startSessionRefreshIfNeeded() {
        guard sessionsVisible,
              transportAttached,
              sessionRefreshTask == nil,
              let client,
              let rootThreadID,
              let rootSessionID,
              rootThreadGeneration == clientGeneration else { return }
        startSessionRefreshLoop(
            client: client,
            generation: clientGeneration,
            rootThreadID: rootThreadID,
            rootSessionID: rootSessionID
        )
    }

    func setSessionsVisible(_ visible: Bool) {
        sessionsVisible = visible
        if visible {
            startSessionRefreshIfNeeded()
        } else {
            sessionRefreshTask?.cancel()
            sessionRefreshTask = nil
        }
    }

    private func refreshChildSessions(
        client: CodexAppServerClient,
        generation: UInt64,
        rootThreadID: String,
        rootSessionID: String
    ) async {
        guard !isDisposed,
              self.client === client,
              clientGeneration == generation,
              self.rootThreadID == rootThreadID,
              self.rootSessionID == rootSessionID else { return }
        guard let listed = await fetchListedThreads(
            client: client,
            generation: generation,
            rootThreadID: rootThreadID,
            rootSessionID: rootSessionID
        ) else { return }
        let duplicateIDs = Set(
            Dictionary(grouping: listed, by: \.threadID)
                .filter { $0.value.count > 1 }
                .map(\.key)
        )
        var acceptedIDs: Set<String> = [rootThreadID]
        acceptedIDs.formUnion(childSessions.map(\.threadID))
        var accepted: [ListedThread] = []
        var remaining = listed.filter {
            $0.threadID != rootThreadID
                && $0.sessionID == rootSessionID
                && !duplicateIDs.contains($0.threadID)
        }
        for _ in 0...listed.count {
            var progress = false
            remaining.removeAll { thread in
                if acceptedIDs.contains(thread.threadID) { return true }
                guard acceptedIDs.contains(thread.parentThreadID) else { return false }
                acceptedIDs.insert(thread.threadID)
                accepted.append(thread)
                progress = true
                return true
            }
            if !progress { break }
        }
        let visible = accepted
            .sorted { lhs, rhs in
                if lhs.updatedAt == rhs.updatedAt {
                    return lhs.threadID < rhs.threadID
                }
                return lhs.updatedAt > rhs.updatedAt
            }
            .prefix(16)

        var recentMessages: [String: String] = [:]
        var nextReadCache: [ThreadReadCacheKey: ThreadReadCacheValue] = [:]
        for thread in visible {
            let key = Self.threadReadCacheKey(thread)
            if let cached = threadReadCache[key] {
                nextReadCache[key] = cached
                if case .message(let message) = cached {
                    recentMessages[thread.threadID] = message
                }
            }
        }
        let uncachedThreads = visible.filter {
            nextReadCache[Self.threadReadCacheKey($0)] == nil
        }
        for batchStart in stride(from: 0, to: uncachedThreads.count, by: 4) {
            let batchEnd = min(batchStart + 4, uncachedThreads.count)
            await withTaskGroup(
                of: (ThreadReadCacheKey, ThreadReadValidation?).self
            ) { group in
                for thread in uncachedThreads[batchStart..<batchEnd] {
                    group.addTask {
                        let key = Self.threadReadCacheKey(thread)
                        do {
                            let read = try await client.sendRequest(
                                "thread/read",
                                params: .object([
                                    "threadId": .string(thread.threadID),
                                    "includeTurns": .bool(true)
                                ])
                            )
                            return (
                                key,
                                Self.validateLatestMessage(
                                    from: read,
                                    expectedThreadID: thread.threadID,
                                    expectedSessionID: thread.sessionID,
                                    expectedParentThreadID: thread.parentThreadID
                                )
                            )
                        } catch {
                            return (key, nil)
                        }
                    }
                }
                for await (key, validation) in group {
                    switch validation {
                    case .validated(let message):
                        if let message, !message.isEmpty {
                            nextReadCache[key] = .message(message)
                            recentMessages[key.threadID] = message
                        } else {
                            nextReadCache[key] = .noMessage
                        }
                    case .invalidIdentity, nil:
                        break
                    }
                }
            }
        }
        guard !isDisposed,
              self.client === client,
              clientGeneration == generation,
              self.rootThreadID == rootThreadID,
              self.rootSessionID == rootSessionID else { return }
        threadReadCache = nextReadCache
        childSessions = visible.map { thread in
            let state: CodexVoiceThreadState
            switch thread.status {
            case "active": state = .running
            case "systemError": state = .failed
            default: state = .completed
            }
            return CodexVoiceThreadSummary(
                threadID: thread.threadID,
                isCurrentRoot: false,
                title: thread.title,
                detail: recentMessages[thread.threadID] ?? thread.preview,
                state: state,
                createdAt: thread.createdAt,
                updatedAt: thread.updatedAt
            )
        }
        publish()
    }

    private func fetchListedThreads(
        client: CodexAppServerClient,
        generation: UInt64,
        rootThreadID: String,
        rootSessionID: String
    ) async -> [ListedThread]? {
        guard !isDisposed,
              self.client === client,
              clientGeneration == generation,
              self.rootThreadID == rootThreadID,
              self.rootSessionID == rootSessionID else { return nil }
        let params: [String: CodexJSONValue] = [
            "ancestorThreadId": .string(rootThreadID),
            "archived": .bool(false),
            "limit": .integer(16),
            "sourceKinds": .array([
                .string("appServer"),
                .string("subAgent"),
                .string("subAgentReview"),
                .string("subAgentCompact"),
                .string("subAgentThreadSpawn"),
                .string("subAgentOther")
            ]),
            "sortDirection": .string("desc"),
            "sortKey": .string("updated_at"),
            "useStateDbOnly": .bool(true)
        ]
        let response: CodexJSONValue
        do {
            response = try await client.sendRequest(
                "thread/list",
                params: .object(params)
            )
        } catch {
            return nil
        }
        guard let data = response.objectValue?["data"]?.arrayValue,
              data.count <= 16 else { return nil }
        return data.compactMap(Self.parseListedThread)
    }

    nonisolated private static func parseListedThread(
        _ value: CodexJSONValue
    ) -> ListedThread? {
        guard let thread = value.objectValue,
              let threadID = thread["id"]?.stringValue,
              validThreadIdentifier(threadID),
              let sessionID = thread["sessionId"]?.stringValue,
              validThreadIdentifier(sessionID),
              let parentThreadID = thread["parentThreadId"]?.stringValue,
              validThreadIdentifier(parentThreadID),
              let status = thread["status"]?.objectValue?["type"]?.stringValue,
              ["active", "idle", "notLoaded", "systemError"].contains(status),
              let createdAt = thread["createdAt"]?.integerValue,
              let updatedAt = thread["updatedAt"]?.integerValue,
              createdAt > 0,
              createdAt <= 253_402_300_799,
              updatedAt >= createdAt,
              updatedAt <= 253_402_300_799 else { return nil }
        let name = safeCardText(
            thread["name"]?.stringValue
                ?? thread["agentNickname"]?.stringValue
                ?? "Codex",
            maximumScalars: 72
        )
        let preview = safeCardText(
            thread["preview"]?.stringValue ?? "",
            maximumScalars: 160
        )
        return ListedThread(
            threadID: threadID,
            sessionID: sessionID,
            parentThreadID: parentThreadID,
            title: name.isEmpty ? "Codex" : name,
            preview: preview,
            status: status,
            createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt)),
            updatedAt: Date(timeIntervalSince1970: TimeInterval(updatedAt))
        )
    }

    nonisolated private static func validateLatestMessage(
        from response: CodexJSONValue,
        expectedThreadID: String,
        expectedSessionID: String,
        expectedParentThreadID: String
    ) -> ThreadReadValidation {
        guard let thread = response.objectValue?["thread"]?.objectValue,
              thread["id"]?.stringValue == expectedThreadID,
              thread["sessionId"]?.stringValue == expectedSessionID,
              thread["parentThreadId"]?.stringValue == expectedParentThreadID,
              let turns = thread["turns"]?.arrayValue else {
            return .invalidIdentity
        }
        for turn in turns.reversed() {
            guard let items = turn.objectValue?["items"]?.arrayValue else { continue }
            for item in items.reversed() {
                guard let object = item.objectValue,
                      let type = object["type"]?.stringValue else { continue }
                if type == "agentMessage",
                   let text = object["text"]?.stringValue {
                    let safe = safeCardText(text, maximumScalars: 160)
                    if !safe.isEmpty { return .validated(safe) }
                }
                if type == "userMessage",
                   let content = object["content"]?.arrayValue {
                    for input in content.reversed() {
                        guard let inputObject = input.objectValue,
                              inputObject["type"]?.stringValue == "text",
                              let text = inputObject["text"]?.stringValue else { continue }
                        let safe = safeCardText(text, maximumScalars: 160)
                        if !safe.isEmpty { return .validated(safe) }
                    }
                }
            }
        }
        return .validated(nil)
    }

    nonisolated private static func threadReadCacheKey(
        _ thread: ListedThread
    ) -> ThreadReadCacheKey {
        ThreadReadCacheKey(
            threadID: thread.threadID,
            sessionID: thread.sessionID,
            parentThreadID: thread.parentThreadID,
            updatedAt: thread.updatedAt
        )
    }

    nonisolated private static func validCursor(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 512 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20
                && scalar.value != 0x7F
                && !(0x202A...0x202E).contains(scalar.value)
                && !(0x2066...0x2069).contains(scalar.value)
        }
    }

    nonisolated private static func safeCardText(
        _ value: String,
        maximumScalars: Int
    ) -> String {
        var output = String.UnicodeScalarView()
        var previousWasSpace = false
        for scalar in value.unicodeScalars {
            let codePoint = scalar.value
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if !previousWasSpace, !output.isEmpty {
                    output.append(" ")
                    previousWasSpace = true
                }
                continue
            }
            guard codePoint >= 0x20,
                  !(0x7F...0x9F).contains(codePoint),
                  !(0x202A...0x202E).contains(codePoint),
                  !(0x2066...0x2069).contains(codePoint) else { continue }
            output.append(scalar)
            previousWasSpace = false
            if output.count >= maximumScalars { break }
        }
        return String(output).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func validThreadIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 45...46, 48...58, 65...90, 95, 97...122:
                true
            default:
                false
            }
        }
    }

    private func clearRootThreadState() {
        sessionRefreshTask?.cancel()
        sessionRefreshTask = nil
        transcriptPublishTask?.cancel()
        transcriptPublishTask = nil
        rootThreadID = nil
        rootSessionID = nil
        rootCreatedAt = nil
        rootThreadGeneration = 0
        realtimeLifecycle = .idle
        realtimeStopRequested = false
        childSessions = []
        threadReadCache = [:]
    }

    func markTransportAttached() {
        guard !isDisposed else { return }
        switch realtimeLifecycle {
        case .stopping, .stopped, .idle:
            return
        case .starting, .active:
            realtimeLifecycle = .active
        }
        transportAttached = true
        isMuted = false
        sessionStatus = .connected
        lastErrorCode = nil
        startSessionRefreshIfNeeded()
        publish()
    }

    func setMuted(_ muted: Bool) {
        guard !isDisposed else { return }
        isMuted = muted
        if transportAttached {
            sessionStatus = muted ? .muted : .connected
        }
        publish()
    }

    func clearTransientUIState() {
        guard !isDisposed else { return }
        transportAttached = false
        isMuted = true
        if [.requestingPermission, .negotiating, .connecting, .connected, .muted]
            .contains(sessionStatus) {
            sessionStatus = .reconnecting
        }
        publish()
    }

    func stopRealtime() async {
        guard !isDisposed else { return }
        if let realtimeStopTask {
            await realtimeStopTask.value
            return
        }
        guard Self.shouldIssueStop(from: realtimeLifecycle) else {
            return
        }
        let targetClient = client
        let targetRootThreadID = rootThreadID
        let targetRootGeneration = rootThreadGeneration
        realtimeLifecycle = .stopping
        realtimeStopRequested = true
        sessionStatus = .stopping
        publish()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performStopRealtime(
                client: targetClient,
                rootThreadID: targetRootThreadID,
                rootGeneration: targetRootGeneration
            )
        }
        realtimeStopTask = task
        await task.value
        realtimeStopTask = nil
    }

    private func performStopRealtime(
        client targetClient: CodexAppServerClient?,
        rootThreadID targetRootThreadID: String?,
        rootGeneration targetRootGeneration: UInt64
    ) async {
        guard !isDisposed else { return }
        await cancelPendingSDP(.negotiationCancelled)
        if let targetClient, let targetRootThreadID {
            do {
                _ = try await targetClient.sendRequest(
                    "thread/realtime/stop",
                    params: .object(["threadId": .string(targetRootThreadID)])
                )
                lastErrorCode = nil
            } catch {
                lastErrorCode = "realtime_stop_failed"
                availability = .blocked
            }
        } else {
            realtimeStopRequested = false
        }
        guard rootThreadGeneration == targetRootGeneration,
              rootThreadID == targetRootThreadID else { return }
        realtimeLifecycle = .stopped
        if availability == .blocked {
            transportAttached = false
            isMuted = true
            sessionStatus = .blockedFailure
            publish()
        } else {
            detachTransport(reconnectExpected: false)
        }
    }

    func detachTransport(reconnectExpected: Bool) {
        guard !isDisposed else { return }
        sessionRefreshTask?.cancel()
        sessionRefreshTask = nil
        transportAttached = false
        isMuted = true
        sessionStatus = reconnectExpected ? .reconnecting : .closed
        publish()
    }

    func markSessionFailure(_ errorCode: String) {
        guard !isDisposed else { return }
        transportAttached = false
        isMuted = true
        sessionStatus = .recoverableFailure
        lastErrorCode = Self.safeErrorCode(errorCode)
        publish()
    }

    func resetRealtimeSession(alreadyStopped: Bool = false) async {
        guard !isDisposed else { return }
        if !alreadyStopped {
            await stopRealtime()
        }
        if let rootThreadID {
            toolAdapter?.cancelSession(rootThreadID)
        }
        clearRootThreadState()
        transcript = CodexVoiceTranscriptBuffer(entryLimit: 120, characterLimit: 32_000)
        sessionStatus = .idle
        lastErrorCode = nil
        publish()
    }

    private static func safeErrorCode(_ value: String) -> String {
        let allowed = value.unicodeScalars.filter { scalar in
            switch scalar.value {
            case 48...57, 65...90, 97...122, 95:
                true
            default:
                false
            }
        }
        let bounded = String(String.UnicodeScalarView(allowed.prefix(64)))
        return bounded.isEmpty ? "voice_failed" : bounded
    }

    private func processNotification(_ notification: CodexAppServerNotification) async {
        guard !isDisposed else { return }
        let params = notification.params?.objectValue ?? [:]
        switch notification.method {
        case "thread/realtime/started":
            guard isCurrentRoot(params["threadId"]?.stringValue) else { return }
            guard case .starting = realtimeLifecycle else { return }
            realtimeLifecycle = .active
            sessionStatus = transportAttached ? (isMuted ? .muted : .connected) : .connecting
            lastErrorCode = nil
        case "thread/realtime/transcript/delta":
            guard isCurrentRoot(params["threadId"]?.stringValue) else { return }
            transcript.appendDelta(
                threadID: rootThreadID ?? "",
                role: params["role"]?.stringValue ?? "unknown",
                delta: params["delta"]?.stringValue ?? "",
                now: Date()
            )
            scheduleTranscriptPublish()
            return
        case "thread/realtime/transcript/done":
            guard isCurrentRoot(params["threadId"]?.stringValue) else { return }
            transcript.complete(
                threadID: rootThreadID ?? "",
                role: params["role"]?.stringValue ?? "unknown",
                text: params["text"]?.stringValue,
                now: Date()
            )
            transcriptPublishTask?.cancel()
            transcriptPublishTask = nil
        case "thread/realtime/sdp":
            guard let pendingSDP,
                  pendingSDP.clientGeneration == clientGeneration,
                  params["threadId"]?.stringValue == pendingSDP.threadID,
                  let sdp = params["sdp"]?.stringValue,
                  !sdp.isEmpty,
                  sdp.utf8.count <= 131_072,
                  sdp.hasPrefix("v=0") else { return }
            await pendingSDP.result.succeed(sdp)
            sessionStatus = .connecting
            lastErrorCode = nil
        case "thread/realtime/closed":
            guard isCurrentRoot(params["threadId"]?.stringValue) else { return }
            if let pendingSDP,
               pendingSDP.clientGeneration == clientGeneration,
               params["threadId"]?.stringValue == pendingSDP.threadID {
                await pendingSDP.result.fail(
                    .compatibility("realtime_closed_before_sdp")
                )
            }
            transportAttached = false
            isMuted = true
            realtimeLifecycle = .stopped
            sessionStatus = .closed
            let expectedClose = realtimeStopRequested
            realtimeStopRequested = false
            lastErrorCode = expectedClose || params["reason"]?.stringValue == nil
                ? nil
                : "realtime_closed"
        case "thread/realtime/error":
            guard params["threadId"]?.stringValue.map(isCurrentRoot) ?? true else { return }
            let errorCode = params["message"]?.stringValue
                .flatMap(Self.safeRPCMessageCategory)
                .map { "realtime_error_\($0)" }
                ?? "realtime_error"
            if let pendingSDP,
               pendingSDP.clientGeneration == clientGeneration {
                await pendingSDP.result.fail(.compatibility(errorCode))
            }
            transportAttached = false
            isMuted = true
            realtimeLifecycle = .stopped
            sessionStatus = .recoverableFailure
            lastErrorCode = errorCode
        default:
            return
        }
        publish()
    }

    private func scheduleTranscriptPublish() {
        guard transcriptPublishTask == nil else { return }
        transcriptPublishTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 67_000_000)
            } catch {
                return
            }
            guard let self, !self.isDisposed else { return }
            self.transcriptPublishTask = nil
            self.publish()
        }
    }

    private func isCurrentRoot(_ threadID: String?) -> Bool {
        clientGeneration > 0
            && rootThreadGeneration == clientGeneration
            && threadID == rootThreadID
            && rootThreadID?.isEmpty == false
    }

    private func admitServerRequest(
        client sourceClient: CodexAppServerClient,
        generation: UInt64,
        request: CodexAppServerRequest
    ) {
        guard Self.ambientServerRequests.contains(request.method),
              isKnownClient(sourceClient, generation: generation) else { return }
        quarantinedClientGenerations.insert(generation)
        availability = .blocked
        sessionStatus = .blockedFailure
        transportAttached = false
        isMuted = true
        lastErrorCode = "ambient_tool_request_rejected"
        publish()
    }

    private func isKnownClient(
        _ sourceClient: CodexAppServerClient,
        generation: UInt64
    ) -> Bool {
        (client === sourceClient && clientGeneration == generation)
            || (initializingClient === sourceClient
                && initializingClientGeneration == generation)
    }

    private func handleServerRequest(
        client sourceClient: CodexAppServerClient,
        generation: UInt64,
        request: CodexAppServerRequest
    ) async -> CodexAppServerReply {
        guard request.method == "item/tool/call" else {
            if Self.ambientServerRequests.contains(request.method) {
                return .failure(
                    code: -32601,
                    message: "Unsupported app-server request",
                    afterWrite: { [weak self, weak sourceClient] in
                        guard let self, let sourceClient else { return }
                        await self.stopAfterAmbientRequest(
                            client: sourceClient,
                            generation: generation
                        )
                    }
                )
            }
            return .failure(code: -32601, message: "Unsupported app-server request")
        }
        guard let toolAdapter else {
            return .failure(
                code: -32601,
                message: "HoverPocket has no handler for app-server request: \(request.method)"
            )
        }
        guard !isDisposed,
              client === sourceClient,
              clientGeneration == generation,
              !quarantinedClientGenerations.contains(generation),
              availability == .ready,
              rootThreadGeneration == generation,
              let rootThreadID,
              !rootThreadID.isEmpty else {
            return .failure(
                code: -32600,
                message: "HoverPocket rejected a tool call from a stale or non-ready Codex session."
            )
        }
        return await toolAdapter.handle(
            request: request,
            context: CodexVoiceToolRequestContext(
                rootThreadID: rootThreadID,
                clientGeneration: generation
            )
        )
    }

    private func stopAfterAmbientRequest(
        client sourceClient: CodexAppServerClient,
        generation: UInt64
    ) async {
        guard !isDisposed,
              quarantinedClientGenerations.contains(generation),
              isKnownClient(sourceClient, generation: generation) else { return }
        if client === sourceClient, clientGeneration == generation {
            await stopRealtime()
        }
    }

    static func verifyRealtimeLifecyclePolicy() -> Bool {
        canStartRealtime(from: .idle)
            && canStartRealtime(from: .stopped)
            && !canStartRealtime(from: .starting)
            && !canStartRealtime(from: .active)
            && !canStartRealtime(from: .stopping)
            && !shouldIssueStop(from: .idle)
            && !shouldIssueStop(from: .stopped)
            && shouldIssueStop(from: .starting)
            && shouldIssueStop(from: .active)
            && shouldIssueStop(from: .stopping)
            && ambientServerRequests.contains("execCommandApproval")
            && ambientServerRequests.contains("openai/form")
            && !ambientServerRequests.contains("currentTime/read")
            && !ambientServerRequests.contains("item/tool/call")
    }

    static func verifyOneShotResolutionPolicy() async -> Bool {
        let successFirst = CodexVoiceOneShot<String>()
        await successFirst.succeed("answer")
        await successFirst.fail(.sdpTimedOut)
        guard (try? await successFirst.wait()) == "answer" else { return false }

        let failureFirst = CodexVoiceOneShot<String>()
        await failureFirst.fail(.compatibility("expected"))
        await failureFirst.succeed("late")
        do {
            _ = try await failureFirst.wait()
            return false
        } catch let error as CodexVoiceRuntimeError {
            guard error == .compatibility("expected") else { return false }
        } catch {
            return false
        }

        let pending = CodexVoiceOneShot<String>()
        let waiter = Task { try await pending.wait() }
        var waiterRegistered = false
        for _ in 0..<20 {
            if await pending.waiterCountForVerification() == 1 {
                waiterRegistered = true
                break
            }
            await Task.yield()
        }
        guard waiterRegistered else {
            waiter.cancel()
            return false
        }
        await pending.fail(.sdpTimedOut)
        do {
            _ = try await waiter.value
            return false
        } catch let error as CodexVoiceRuntimeError {
            return error == .sdpTimedOut
        } catch {
            return false
        }
    }

    private static func canStartRealtime(from lifecycle: RealtimeLifecycle) -> Bool {
        switch lifecycle {
        case .idle, .stopped: true
        case .starting, .active, .stopping: false
        }
    }

    private static func shouldIssueStop(from lifecycle: RealtimeLifecycle) -> Bool {
        switch lifecycle {
        case .idle, .stopped: false
        case .starting, .active, .stopping: true
        }
    }

    private func handleTransportEnd(
        client failedClient: CodexAppServerClient,
        generation: UInt64,
        reason: String
    ) async {
        guard !isDisposed,
              client === failedClient,
              clientGeneration == generation else { return }
        let wasQuarantined = quarantinedClientGenerations.contains(generation)
        let failedRootThreadID = rootThreadID
        if let failedRootThreadID {
            toolAdapter?.cancelSession(failedRootThreadID)
        }
        await cancelPendingSDP(.disposed)
        if wasQuarantined {
            client = nil
            clientGeneration = 0
            clearRootThreadState()
            availability = .blocked
            sessionStatus = .blockedFailure
            transportAttached = false
            isMuted = true
            appServerProcessID = nil
            lastErrorCode = "ambient_tool_request_rejected"
            await failedClient.setNotificationHandler(nil)
            await failedClient.setTransportEndedHandler(nil)
            await failedClient.setServerRequestAdmissionHandler(nil)
            await failedClient.setServerRequestHandler(nil)
            await failedClient.close()
            publish()
            return
        }
        availability = .faulted
        sessionStatus = .recoverableFailure
        transportAttached = false
        isMuted = true
        appServerProcessID = nil
        clearRootThreadState()
        lastErrorCode = "transport_\(reason)"
        publish()
        guard restartTask == nil else { return }
        restartTask = Task { @MainActor [weak self] in
            await self?.restart(after: failedClient)
        }
    }

    private func restart(after failedClient: CodexAppServerClient) async {
        defer { restartTask = nil }
        guard !isDisposed, client === failedClient else { return }
        client = nil
        clientGeneration = 0
        clearRootThreadState()
        await failedClient.setNotificationHandler(nil)
        await failedClient.setTransportEndedHandler(nil)
        await failedClient.setServerRequestAdmissionHandler(nil)
        await failedClient.setServerRequestHandler(nil)
        await failedClient.close()

        for (index, delay) in restartDelaysNanoseconds.enumerated() {
            guard !Task.isCancelled, !isDisposed else {
                return
            }
            restartAttempt = index + 1
            availability = .starting
            sessionStatus = .reconnecting
            lastErrorCode = nil
            publish()
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled, !isDisposed else {
                return
            }
            do {
                try await startClientAndValidate()
                guard !Task.isCancelled, !isDisposed else {
                    if let client {
                        self.client = nil
                        clientGeneration = 0
                        await client.close()
                    }
                    return
                }
                availability = .ready
                sessionStatus = rootThreadID == nil ? .idle : .reconnecting
                lastErrorCode = nil
                publish()
                return
            } catch CodexVoiceRuntimeError.signedOut {
                update(availability: .signedOut, status: .blockedFailure, errorCode: "signed_out")
                return
            } catch CodexVoiceRuntimeError.compatibility(let code) {
                update(
                    availability: code == "ambient_tool_request_rejected"
                        ? .blocked
                        : .incompatible,
                    status: .blockedFailure,
                    errorCode: code
                )
                return
            } catch CodexVoiceRuntimeError.disposed {
                return
            } catch {
                availability = .faulted
                sessionStatus = .recoverableFailure
                lastErrorCode = String(describing: type(of: error))
                publish()
            }
        }
        update(availability: .blocked, status: .blockedFailure, errorCode: "restart_exhausted")
    }

    private func cancelPendingSDP(_ error: CodexVoiceRuntimeError) async {
        activeNegotiationAttemptID = nil
        guard let pendingSDP else { return }
        self.pendingSDP = nil
        pendingSDP.timeoutTask.cancel()
        await pendingSDP.result.fail(error)
    }

    private func validateAccount(_ response: CodexJSONValue) throws {
        switch Self.accountAdmissionCode(response) {
        case nil:
            return
        case "signed_out":
            throw CodexVoiceRuntimeError.signedOut
        case let code?:
            throw CodexVoiceRuntimeError.compatibility(code)
        }
    }

    nonisolated static func accountAdmissionCode(_ response: CodexJSONValue) -> String? {
        guard let object = response.objectValue,
              let requiresAuth = object["requiresOpenaiAuth"]?.boolValue else {
            return "account_response_invalid"
        }
        guard requiresAuth else {
            return "codex_chatgpt_account_required"
        }
        guard let account = object["account"]?.objectValue else {
            return "signed_out"
        }
        guard account["type"]?.stringValue == "chatgpt" else {
            return "codex_chatgpt_account_required"
        }
        return nil
    }

    private func parseVoices(_ response: CodexJSONValue) throws -> Int {
        guard let voices = response.objectValue?["voices"]?.objectValue else {
            throw CodexVoiceRuntimeError.compatibility("realtime_voices_unavailable")
        }
        var unique = Set<String>()
        for value in voices.values {
            for item in value.arrayValue ?? [] {
                if let voice = item.stringValue, !voice.isEmpty {
                    unique.insert(voice)
                }
            }
        }
        guard !unique.isEmpty else {
            throw CodexVoiceRuntimeError.compatibility("realtime_voices_unavailable")
        }
        return unique.count
    }

    private func update(
        availability: CodexVoiceAvailability,
        status: CodexVoiceSessionStatus,
        errorCode: String?
    ) {
        self.availability = availability
        sessionStatus = status
        lastErrorCode = errorCode
        publish()
    }

    private func publish() {
        snapshotHandler?(snapshot)
    }

    func close() async {
        guard !isDisposed else { return }
        isDisposed = true
        let restarting = restartTask
        restartTask = nil
        restarting?.cancel()
        transcriptPublishTask?.cancel()
        transcriptPublishTask = nil
        if let restarting {
            await restarting.value
        }
        await cancelPendingSDP(.disposed)
        let connectedClient = client
        let pendingClient = initializingClient
        client = nil
        clientGeneration = 0
        initializingClient = nil
        initializingClientGeneration = 0
        clearRootThreadState()
        if let connectedClient {
            await connectedClient.setNotificationHandler(nil)
            await connectedClient.setTransportEndedHandler(nil)
            await connectedClient.setServerRequestAdmissionHandler(nil)
            await connectedClient.setServerRequestHandler(nil)
            await connectedClient.close()
        }
        if let pendingClient {
            let alreadyClosed = connectedClient.map { pendingClient === $0 } ?? false
            if !alreadyClosed {
                await pendingClient.setNotificationHandler(nil)
                await pendingClient.setTransportEndedHandler(nil)
                await pendingClient.setServerRequestAdmissionHandler(nil)
                await pendingClient.setServerRequestHandler(nil)
                await pendingClient.close()
            }
        }
        quarantinedClientGenerations.removeAll()
        availability = .disabled
        sessionStatus = .closed
        transportAttached = false
        realtimeStopRequested = false
        realtimeStopTask = nil
        isMuted = true
        appServerProcessID = nil
        publish()
    }
}

private actor CodexVoiceOneShot<Value: Sendable> {
    private var result: Result<Value, CodexVoiceRuntimeError>?
    private var waiters: [CheckedContinuation<Value, Error>] = []

    func wait() async throws -> Value {
        if let result {
            return try result.get()
        }
        return try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func succeed(_ value: Value) {
        resolve(.success(value))
    }

    func fail(_ error: CodexVoiceRuntimeError) {
        resolve(.failure(error))
    }

    func waiterCountForVerification() -> Int {
        waiters.count
    }

    private func resolve(_ result: Result<Value, CodexVoiceRuntimeError>) {
        guard self.result == nil else { return }
        self.result = result
        let continuations = waiters
        waiters.removeAll()
        for continuation in continuations {
            continuation.resume(with: result.mapError { $0 as Error })
        }
    }
}

private struct CodexVoiceTranscriptBuffer {
    private let entryLimit: Int
    private let characterLimit: Int
    private var entries: [CodexVoiceTranscriptEntry] = []
    private var characterCount = 0

    init(entryLimit: Int, characterLimit: Int) {
        self.entryLimit = max(1, entryLimit)
        self.characterLimit = max(1, characterLimit)
    }

    var snapshot: [CodexVoiceTranscriptEntry] { entries }

    mutating func appendDelta(
        threadID: String,
        role: String,
        delta: String,
        now: Date
    ) {
        guard !threadID.isEmpty, !delta.isEmpty else { return }
        if let last = entries.last,
           !last.isComplete,
           last.threadID == threadID,
           last.role == role {
            characterCount -= last.text.count
            let replacement = last.text + delta
            entries[entries.count - 1] = CodexVoiceTranscriptEntry(
                threadID: threadID,
                role: role,
                text: replacement,
                isComplete: false,
                updatedAt: now
            )
            characterCount += replacement.count
        } else {
            entries.append(
                CodexVoiceTranscriptEntry(
                    threadID: threadID,
                    role: role,
                    text: delta,
                    isComplete: false,
                    updatedAt: now
                )
            )
            characterCount += delta.count
        }
        trim()
    }

    mutating func complete(
        threadID: String,
        role: String,
        text: String?,
        now: Date
    ) {
        guard !threadID.isEmpty else { return }
        if let last = entries.last,
           !last.isComplete,
           last.threadID == threadID,
           last.role == role {
            characterCount -= last.text.count
            let replacement = text ?? last.text
            entries[entries.count - 1] = CodexVoiceTranscriptEntry(
                threadID: threadID,
                role: role,
                text: replacement,
                isComplete: true,
                updatedAt: now
            )
            characterCount += replacement.count
        } else if let text, !text.isEmpty {
            entries.append(
                CodexVoiceTranscriptEntry(
                    threadID: threadID,
                    role: role,
                    text: text,
                    isComplete: true,
                    updatedAt: now
                )
            )
            characterCount += text.count
        }
        trim()
    }

    private mutating func trim() {
        while entries.count > entryLimit {
            characterCount -= entries.removeFirst().text.count
        }
        while characterCount > characterLimit, entries.count > 1 {
            characterCount -= entries.removeFirst().text.count
        }
        if entries.count == 1, entries[0].text.count > characterLimit {
            characterCount -= entries[0].text.count
            let suffix = String(entries[0].text.suffix(characterLimit))
            entries[0] = CodexVoiceTranscriptEntry(
                threadID: entries[0].threadID,
                role: entries[0].role,
                text: suffix,
                isComplete: entries[0].isComplete,
                updatedAt: entries[0].updatedAt
            )
            characterCount += suffix.count
        }
    }
}
