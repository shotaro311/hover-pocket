import Foundation

enum CodexVoiceRuntimeError: Error, Equatable, Sendable {
    case signedOut
    case compatibility(String)
    case sdpTimedOut
    case disposed
}

@MainActor
final class CodexVoiceCoordinator {
    typealias ClientFactory = @Sendable () async throws -> CodexAppServerClient

    private struct PendingSDP {
        let threadID: String
        let result: CodexVoiceOneShot<String>
        let timeoutTask: Task<Void, Never>
    }

    private let featureEnabled: Bool
    private let clientFactory: ClientFactory
    private let workspaceDirectory: URL
    private let restartDelaysNanoseconds: [UInt64]
    private var client: CodexAppServerClient?
    private var restartTask: Task<Void, Never>?
    private var pendingSDP: PendingSDP?
    private var transcript: CodexVoiceTranscriptBuffer
    private var availability: CodexVoiceAvailability
    private var sessionStatus: CodexVoiceSessionStatus = .idle
    private var rootThreadID: String?
    private var transportAttached = false
    private var isMuted = true
    private var lastErrorCode: String?
    private var appServerProcessID: Int32?
    private var restartAttempt = 0
    private var voiceCount = 0
    private var defaultVoice: String?
    private var isDisposed = false

    var snapshotHandler: ((CodexVoiceSnapshot) -> Void)?

    init(
        featureEnabled: Bool,
        workspaceDirectory: URL? = nil,
        transcriptEntryLimit: Int = 120,
        transcriptCharacterLimit: Int = 32_000,
        restartDelaysNanoseconds: [UInt64] = [0, 450_000_000, 1_400_000_000],
        clientFactory: ClientFactory? = nil
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
            lastErrorCode: lastErrorCode,
            appServerProcessID: appServerProcessID,
            restartAttempt: restartAttempt,
            voiceCount: voiceCount
        )
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
        await candidate.setNotificationHandler { [weak self, weak candidate] notification in
            Task { @MainActor in
                guard let self, let candidate, self.client === candidate else { return }
                await self.processNotification(notification)
            }
        }
        await candidate.setTransportEndedHandler { [weak self, weak candidate] reason in
            Task { @MainActor in
                guard let self, let candidate else { return }
                self.handleTransportEnd(client: candidate, reason: reason)
            }
        }
        await candidate.setServerRequestHandler(nil)

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
            client = candidate
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
              sdpOffer.count <= 131_072,
              sdpOffer.hasPrefix("v=0") else {
            throw CodexVoiceRuntimeError.compatibility("webrtc_offer_invalid")
        }
        guard availability == .ready, let client else {
            throw CodexVoiceRuntimeError.compatibility("voice_not_ready")
        }
        guard let defaultVoice else {
            throw CodexVoiceRuntimeError.compatibility("realtime_voice_missing")
        }

        let threadID = try await ensureRootThread(client: client)
        sessionStatus = .negotiating
        lastErrorCode = nil
        publish()

        let result = CodexVoiceOneShot<String>()
        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled else { return }
            await result.fail(.sdpTimedOut)
        }
        pendingSDP?.timeoutTask.cancel()
        pendingSDP = PendingSDP(threadID: threadID, result: result, timeoutTask: timeoutTask)
        defer {
            if pendingSDP?.threadID == threadID {
                pendingSDP?.timeoutTask.cancel()
                pendingSDP = nil
            }
        }

        do {
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
            update(
                availability: .ready,
                status: .recoverableFailure,
                errorCode: "webrtc_negotiation_failed"
            )
            throw error
        }
    }

    private func ensureRootThread(client: CodexAppServerClient) async throws -> String {
        if let rootThreadID, !rootThreadID.isEmpty {
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
                "dynamicTools": .array([]),
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
              !id.isEmpty else {
            throw CodexVoiceRuntimeError.compatibility("thread_start_response_invalid")
        }
        rootThreadID = id
        publish()
        return id
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
            rootThreadID = params["threadId"]?.stringValue ?? rootThreadID
            sessionStatus = transportAttached ? (isMuted ? .muted : .connected) : .connecting
            lastErrorCode = nil
        case "thread/realtime/transcript/delta":
            transcript.appendDelta(
                threadID: params["threadId"]?.stringValue ?? rootThreadID ?? "",
                role: params["role"]?.stringValue ?? "unknown",
                delta: params["delta"]?.stringValue ?? "",
                now: Date()
            )
        case "thread/realtime/transcript/done":
            transcript.complete(
                threadID: params["threadId"]?.stringValue ?? rootThreadID ?? "",
                role: params["role"]?.stringValue ?? "unknown",
                text: params["text"]?.stringValue,
                now: Date()
            )
        case "thread/realtime/sdp":
            guard let pendingSDP,
                  params["threadId"]?.stringValue == pendingSDP.threadID,
                  let sdp = params["sdp"]?.stringValue,
                  !sdp.isEmpty,
                  sdp.count <= 131_072,
                  sdp.hasPrefix("v=0") else { return }
            await pendingSDP.result.succeed(sdp)
            sessionStatus = .connecting
            lastErrorCode = nil
        case "thread/realtime/closed":
            transportAttached = false
            isMuted = true
            sessionStatus = .closed
            lastErrorCode = params["reason"]?.stringValue == nil ? nil : "realtime_closed"
        case "thread/realtime/error":
            transportAttached = false
            isMuted = true
            sessionStatus = .recoverableFailure
            lastErrorCode = "realtime_error"
        default:
            return
        }
        publish()
    }

    private func handleTransportEnd(client failedClient: CodexAppServerClient, reason: String) {
        guard !isDisposed, client === failedClient else { return }
        availability = .faulted
        sessionStatus = .recoverableFailure
        transportAttached = false
        isMuted = true
        appServerProcessID = nil
        lastErrorCode = "transport_\(reason)"
        publish()
        guard restartTask == nil else { return }
        restartTask = Task { @MainActor [weak self] in
            await self?.restart(after: failedClient)
        }
    }

    private func restart(after failedClient: CodexAppServerClient) async {
        guard !isDisposed, client === failedClient else {
            restartTask = nil
            return
        }
        client = nil
        await failedClient.setNotificationHandler(nil)
        await failedClient.setTransportEndedHandler(nil)
        await failedClient.setServerRequestHandler(nil)
        await failedClient.close()

        for (index, delay) in restartDelaysNanoseconds.enumerated() {
            guard !Task.isCancelled, !isDisposed else {
                restartTask = nil
                return
            }
            restartAttempt = index + 1
            availability = .starting
            sessionStatus = .reconnecting
            lastErrorCode = nil
            publish()
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            do {
                try await startClientAndValidate()
                availability = .ready
                sessionStatus = rootThreadID == nil ? .idle : .reconnecting
                lastErrorCode = nil
                publish()
                restartTask = nil
                return
            } catch CodexVoiceRuntimeError.signedOut {
                update(availability: .signedOut, status: .blockedFailure, errorCode: "signed_out")
                restartTask = nil
                return
            } catch CodexVoiceRuntimeError.compatibility(let code) {
                update(availability: .incompatible, status: .blockedFailure, errorCode: code)
                restartTask = nil
                return
            } catch {
                availability = .faulted
                sessionStatus = .recoverableFailure
                lastErrorCode = String(describing: type(of: error))
                publish()
            }
        }
        update(availability: .blocked, status: .blockedFailure, errorCode: "restart_exhausted")
        restartTask = nil
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
        restartTask?.cancel()
        pendingSDP?.timeoutTask.cancel()
        if let pendingSDP {
            await pendingSDP.result.fail(.disposed)
        }
        pendingSDP = nil
        let connectedClient = client
        client = nil
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
