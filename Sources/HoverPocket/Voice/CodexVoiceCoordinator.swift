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

    private let featureEnabled: Bool
    private let clientFactory: ClientFactory
    private let toolAdapter: (any CodexVoiceCapabilityToolAdapterProtocol)?
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
    private var sessionRefreshTask: Task<Void, Never>?
    private var transportAttached = false
    private var isMuted = true
    private var lastErrorCode: String?
    private var appServerProcessID: Int32?
    private var restartAttempt = 0
    private var voiceCount = 0
    private var defaultVoice: String?
    private var nextClientGeneration: UInt64 = 0
    private var clientGeneration: UInt64 = 0
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
        toolAdapter: (any CodexVoiceCapabilityToolAdapterProtocol)? = nil
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
        self.clientFactory = clientFactory ?? {
            try await CodexAppServerClient.start(
                options: CodexAppServerClientOptions(
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
                updatedAt: Date()
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
            update(availability: .incompatible, status: .blockedFailure, errorCode: code)
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
        await candidate.setNotificationHandler { [weak self, weak candidate] notification in
            Task { @MainActor in
                guard let self,
                      let candidate,
                      self.client === candidate,
                      self.clientGeneration == generation else { return }
                await self.processNotification(notification)
            }
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
            let voiceSnapshot = try parseVoices(voices)
            guard !isDisposed, !Task.isCancelled else {
                throw CodexVoiceRuntimeError.disposed
            }
            client = candidate
            clientGeneration = generation
            appServerProcessID = await candidate.processIdentifier
            voiceCount = voiceSnapshot.count
            defaultVoice = voiceSnapshot.defaultVoice
        } catch {
            await candidate.close()
            throw error
        }
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
        guard let defaultVoice else {
            throw CodexVoiceRuntimeError.compatibility("realtime_voice_missing")
        }
        guard pendingSDP == nil, activeNegotiationAttemptID == nil else {
            throw CodexVoiceRuntimeError.compatibility("webrtc_negotiation_in_progress")
        }

        let generation = clientGeneration
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
            _ = try await client.sendRequest(
                "thread/realtime/start",
                params: .object([
                    "threadId": .string(threadID),
                    "outputModality": .string("audio"),
                    "version": .string("v1"),
                    "voice": .string(defaultVoice),
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
            let answer = try await result.wait()
            return CodexVoiceWebRTCAnswer(rootThreadID: threadID, sdp: answer)
        } catch {
            if let attemptThreadID,
               rootThreadID == attemptThreadID,
               rootThreadGeneration == generation {
                clearRootThreadState()
            }
            if !isDisposed {
                update(
                    availability: .ready,
                    status: .recoverableFailure,
                    errorCode: "webrtc_negotiation_failed"
                )
            }
            throw error
        }
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
        let response = try await client.sendRequest(
            "thread/start",
            params: .object([
                "cwd": .string(workspaceDirectory.path),
                "sandbox": .string("read-only"),
                "approvalPolicy": .string("never"),
                "approvalsReviewer": .string("user"),
                "ephemeral": .bool(false),
                "runtimeWorkspaceRoots": .array([]),
                "selectedCapabilityRoots": .array([]),
                "dynamicTools": .array(toolAdapter?.dynamicTools ?? []),
                "threadSource": .string("hoverpocket_voice"),
                "sessionStartSource": .string("startup"),
                "baseInstructions": .string(
                    "You are the HoverPocket Voice Lane. Do not use shell, filesystem, "
                        + "network, or arbitrary code tools. Only invoke explicitly provided "
                        + "HoverPocket capabilities. Keep spoken replies concise."
                )
            ])
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
        startSessionRefreshLoop(
            client: client,
            generation: generation,
            rootThreadID: id,
            rootSessionID: sessionID
        )
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
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    return
                }
            }
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
        let response: CodexJSONValue
        do {
            response = try await client.sendRequest(
                "thread/list",
                params: .object([
                    "ancestorThreadId": .string(rootThreadID),
                    "archived": .bool(false),
                    "limit": .integer(64),
                    "sourceKinds": .array([
                        .string("appServer"),
                        .string("subAgent"),
                        .string("subAgentReview"),
                        .string("subAgentCompact"),
                        .string("subAgentThreadSpawn"),
                        .string("subAgentOther")
                    ]),
                    "sortDirection": .string("asc"),
                    "sortKey": .string("created_at"),
                    "useStateDbOnly": .bool(true)
                ])
            )
        } catch {
            return
        }
        guard let data = response.objectValue?["data"]?.arrayValue else { return }
        let listed = data.prefix(64).compactMap(Self.parseListedThread)
        var acceptedIDs: Set<String> = [rootThreadID]
        var accepted: [ListedThread] = []
        var remaining = listed.filter {
            $0.threadID != rootThreadID && $0.sessionID == rootSessionID
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

        let previousByID = Dictionary(
            childSessions.map { ($0.threadID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var recentMessages: [String: String] = [:]
        for thread in visible {
            if let previous = previousByID[thread.threadID],
               previous.updatedAt == thread.updatedAt,
               !previous.detail.isEmpty {
                recentMessages[thread.threadID] = previous.detail
            }
        }
        await withTaskGroup(of: (String, String?).self) { group in
            for thread in visible where recentMessages[thread.threadID] == nil {
                group.addTask {
                    do {
                        let read = try await client.sendRequest(
                            "thread/read",
                            params: .object([
                                "threadId": .string(thread.threadID),
                                "includeTurns": .bool(true)
                            ])
                        )
                        return (
                            thread.threadID,
                            Self.latestMessage(
                                from: read,
                                expectedThreadID: thread.threadID,
                                expectedSessionID: thread.sessionID,
                                expectedParentThreadID: thread.parentThreadID
                            )
                        )
                    } catch {
                        return (thread.threadID, nil)
                    }
                }
            }
            for await (threadID, message) in group {
                if let message, !message.isEmpty {
                    recentMessages[threadID] = message
                }
            }
        }
        guard !isDisposed,
              self.client === client,
              clientGeneration == generation,
              self.rootThreadID == rootThreadID,
              self.rootSessionID == rootSessionID else { return }
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

    nonisolated private static func latestMessage(
        from response: CodexJSONValue,
        expectedThreadID: String,
        expectedSessionID: String,
        expectedParentThreadID: String
    ) -> String? {
        guard let thread = response.objectValue?["thread"]?.objectValue,
              thread["id"]?.stringValue == expectedThreadID,
              thread["sessionId"]?.stringValue == expectedSessionID,
              thread["parentThreadId"]?.stringValue == expectedParentThreadID,
              let turns = thread["turns"]?.arrayValue else {
            return nil
        }
        for turn in turns.reversed() {
            guard let items = turn.objectValue?["items"]?.arrayValue else { continue }
            for item in items.reversed() {
                guard let object = item.objectValue,
                      let type = object["type"]?.stringValue else { continue }
                if type == "agentMessage",
                   let text = object["text"]?.stringValue {
                    let safe = safeCardText(text, maximumScalars: 160)
                    if !safe.isEmpty { return safe }
                }
                if type == "userMessage",
                   let content = object["content"]?.arrayValue {
                    for input in content.reversed() {
                        guard let inputObject = input.objectValue,
                              inputObject["type"]?.stringValue == "text",
                              let text = inputObject["text"]?.stringValue else { continue }
                        let safe = safeCardText(text, maximumScalars: 160)
                        if !safe.isEmpty { return safe }
                    }
                }
            }
        }
        return nil
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
        rootThreadID = nil
        rootSessionID = nil
        rootCreatedAt = nil
        rootThreadGeneration = 0
        childSessions = []
    }

    func markTransportAttached() {
        guard !isDisposed else { return }
        transportAttached = true
        isMuted = false
        sessionStatus = .connected
        lastErrorCode = nil
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
        await cancelPendingSDP(.negotiationCancelled)
        guard let client, let rootThreadID else {
            detachTransport(reconnectExpected: false)
            return
        }
        sessionStatus = .stopping
        publish()
        do {
            _ = try await client.sendRequest(
                "thread/realtime/stop",
                params: .object(["threadId": .string(rootThreadID)])
            )
        } catch {
            lastErrorCode = "realtime_stop_failed"
        }
        detachTransport(reconnectExpected: false)
    }

    func detachTransport(reconnectExpected: Bool) {
        guard !isDisposed else { return }
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
        case "thread/realtime/transcript/done":
            guard isCurrentRoot(params["threadId"]?.stringValue) else { return }
            transcript.complete(
                threadID: rootThreadID ?? "",
                role: params["role"]?.stringValue ?? "unknown",
                text: params["text"]?.stringValue,
                now: Date()
            )
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
            transportAttached = false
            isMuted = true
            sessionStatus = .closed
            lastErrorCode = params["reason"]?.stringValue == nil ? nil : "realtime_closed"
        case "thread/realtime/error":
            guard params["threadId"]?.stringValue.map(isCurrentRoot) ?? true else { return }
            transportAttached = false
            isMuted = true
            sessionStatus = .recoverableFailure
            lastErrorCode = "realtime_error"
        default:
            return
        }
        publish()
    }

    private func isCurrentRoot(_ threadID: String?) -> Bool {
        clientGeneration > 0
            && rootThreadGeneration == clientGeneration
            && threadID == rootThreadID
            && rootThreadID?.isEmpty == false
    }

    private func handleServerRequest(
        client sourceClient: CodexAppServerClient,
        generation: UInt64,
        request: CodexAppServerRequest
    ) async -> CodexAppServerReply {
        guard let toolAdapter else {
            return .failure(
                code: -32601,
                message: "HoverPocket has no handler for app-server request: \(request.method)"
            )
        }
        guard !isDisposed,
              client === sourceClient,
              clientGeneration == generation,
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

    private func handleTransportEnd(
        client failedClient: CodexAppServerClient,
        generation: UInt64,
        reason: String
    ) async {
        guard !isDisposed,
              client === failedClient,
              clientGeneration == generation else { return }
        await cancelPendingSDP(.disposed)
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
                update(availability: .incompatible, status: .blockedFailure, errorCode: code)
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
        guard let object = response.objectValue,
              let requiresAuth = object["requiresOpenaiAuth"]?.boolValue else {
            throw CodexVoiceRuntimeError.compatibility("account_response_invalid")
        }
        if requiresAuth && object["account"]?.objectValue == nil {
            throw CodexVoiceRuntimeError.signedOut
        }
    }

    private func parseVoices(_ response: CodexJSONValue) throws -> (count: Int, defaultVoice: String) {
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
        guard !unique.isEmpty,
              let defaultVoice = voices["defaultV1"]?.stringValue
                ?? voices["defaultV2"]?.stringValue,
              !defaultVoice.isEmpty else {
            throw CodexVoiceRuntimeError.compatibility("realtime_voices_unavailable")
        }
        return (unique.count, defaultVoice)
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
        if let restarting {
            await restarting.value
        }
        await cancelPendingSDP(.disposed)
        let connectedClient = client
        client = nil
        clientGeneration = 0
        clearRootThreadState()
        if let connectedClient {
            await connectedClient.setNotificationHandler(nil)
            await connectedClient.setTransportEndedHandler(nil)
            await connectedClient.setServerRequestHandler(nil)
            await connectedClient.close()
        }
        availability = .disabled
        sessionStatus = .closed
        transportAttached = false
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
            entries[entries.count - 1] = CodexVoiceTranscriptEntry(
                threadID: threadID,
                role: role,
                text: last.text + delta,
                isComplete: false,
                updatedAt: now
            )
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
            entries[entries.count - 1] = CodexVoiceTranscriptEntry(
                threadID: threadID,
                role: role,
                text: text ?? last.text,
                isComplete: true,
                updatedAt: now
            )
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
        }
        trim()
    }

    private mutating func trim() {
        while entries.count > entryLimit {
            entries.removeFirst()
        }
        while entries.reduce(0, { $0 + $1.text.count }) > characterLimit,
              entries.count > 1 {
            entries.removeFirst()
        }
        if entries.count == 1, entries[0].text.count > characterLimit {
            let suffix = String(entries[0].text.suffix(characterLimit))
            entries[0] = CodexVoiceTranscriptEntry(
                threadID: entries[0].threadID,
                role: entries[0].role,
                text: suffix,
                isComplete: entries[0].isComplete,
                updatedAt: entries[0].updatedAt
            )
        }
    }
}
