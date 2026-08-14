import Darwin
import Foundation

struct CodexAppServerClientOptions: Sendable {
    var executableURL: URL?
    var launchArguments: [String]?
    var requestTimeout: TimeInterval
    var clientName: String
    var clientTitle: String
    var clientVersion: String
    var experimentalAPI: Bool

    init(
        executableURL: URL? = nil,
        launchArguments: [String]? = nil,
        requestTimeout: TimeInterval = 15,
        clientName: String = "hover_pocket",
        clientTitle: String = "HoverPocket",
        clientVersion: String = "0.0.0",
        experimentalAPI: Bool = false
    ) {
        self.executableURL = executableURL
        self.launchArguments = launchArguments
        self.requestTimeout = requestTimeout
        self.clientName = clientName
        self.clientTitle = clientTitle
        self.clientVersion = clientVersion
        self.experimentalAPI = experimentalAPI
    }
}

struct CodexAppServerRequest: Sendable {
    let id: CodexAppServerMessageID
    let method: String
    let params: CodexJSONValue?
}

struct CodexAppServerNotification: Sendable {
    let method: String
    let params: CodexJSONValue?
}

struct CodexAppServerReplyError: Sendable {
    let code: Int
    let message: String
    let data: CodexJSONValue?
}

struct CodexAppServerReply: Sendable {
    let result: CodexJSONValue?
    let error: CodexAppServerReplyError?

    static func success(_ result: CodexJSONValue = .object([:])) -> CodexAppServerReply {
        CodexAppServerReply(result: result, error: nil)
    }

    static func failure(
        code: Int,
        message: String,
        data: CodexJSONValue? = nil
    ) -> CodexAppServerReply {
        CodexAppServerReply(
            result: nil,
            error: CodexAppServerReplyError(code: code, message: message, data: data)
        )
    }
}

struct CodexAppServerMetrics: Equatable, Sendable {
    let malformedOutputLines: Int
    let unknownResponses: Int
    let unhandledServerRequests: Int
}

struct CodexAppServerRPCError: Error, Equatable, Sendable {
    let code: Int
    let message: String
    let data: CodexJSONValue?
}

enum CodexAppServerClientError: Error, Equatable, Sendable {
    case executableNotFound
    case executableNotRunnable
    case launchFailed
    case invalidMessage
    case requestTimedOut(String)
    case transportEnded(String)
    case closed
}

actor CodexAppServerClient {
    typealias NotificationHandler = @Sendable (CodexAppServerNotification) -> Void
    typealias TransportEndedHandler = @Sendable (String) -> Void
    typealias ServerRequestHandler = @Sendable (CodexAppServerRequest) async -> CodexAppServerReply

    private struct PendingRequest {
        let continuation: CheckedContinuation<CodexJSONValue, Error>
        let timeoutTask: Task<Void, Never>
    }

    private static let maximumProtocolLineBytes = 2 * 1_024 * 1_024
    private static let maximumErrorBufferBytes = 128 * 1_024

    private let options: CodexAppServerClientOptions
    private let process: Process
    private let inputHandle: FileHandle
    private let outputHandle: FileHandle
    private let errorHandle: FileHandle
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private var outputBuffer = Data()
    private var errorBuffer = Data()
    private var errorTail: [String] = []
    private var pendingRequests: [CodexAppServerMessageID: PendingRequest] = [:]
    private var notificationHandler: NotificationHandler?
    private var transportEndedHandler: TransportEndedHandler?
    private var serverRequestHandler: ServerRequestHandler?
    private var nextRequestID: Int64 = 0
    private var malformedOutputLines = 0
    private var unknownResponses = 0
    private var unhandledServerRequests = 0
    private var isInitialized = false
    private var isClosed = false
    private var didPublishTransportEnd = false

    private init(
        options: CodexAppServerClientOptions,
        process: Process,
        inputHandle: FileHandle,
        outputHandle: FileHandle,
        errorHandle: FileHandle
    ) {
        self.options = options
        self.process = process
        self.inputHandle = inputHandle
        self.outputHandle = outputHandle
        self.errorHandle = errorHandle
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
    }

    static func start(
        options: CodexAppServerClientOptions = CodexAppServerClientOptions()
    ) async throws -> CodexAppServerClient {
        guard options.requestTimeout > 0 else {
            throw CodexAppServerClientError.invalidMessage
        }
        let executableURL = try CodexExecutableResolver.resolve(options.executableURL)
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = options.launchArguments ?? ["app-server", "--stdio"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw CodexAppServerClientError.launchFailed
        }

        let client = CodexAppServerClient(
            options: options,
            process: process,
            inputHandle: inputPipe.fileHandleForWriting,
            outputHandle: outputPipe.fileHandleForReading,
            errorHandle: errorPipe.fileHandleForReading
        )
        await client.installReaders()
        do {
            try await client.initialize()
            return client
        } catch {
            await client.close()
            throw error
        }
    }

    var processIdentifier: Int32? {
        isClosed ? nil : process.processIdentifier
    }

    func setNotificationHandler(_ handler: NotificationHandler?) {
        notificationHandler = handler
    }

    func setTransportEndedHandler(_ handler: TransportEndedHandler?) {
        transportEndedHandler = handler
    }

    func setServerRequestHandler(_ handler: ServerRequestHandler?) {
        serverRequestHandler = handler
    }

    func metrics() -> CodexAppServerMetrics {
        CodexAppServerMetrics(
            malformedOutputLines: malformedOutputLines,
            unknownResponses: unknownResponses,
            unhandledServerRequests: unhandledServerRequests
        )
    }

    func boundedErrorTail() -> [String] {
        errorTail
    }

    func sendRequest(
        _ method: String,
        params: CodexJSONValue? = nil
    ) async throws -> CodexJSONValue {
        guard isInitialized else { throw CodexAppServerClientError.closed }
        return try await sendRequestCore(method, params: params)
    }

    func sendNotification(
        _ method: String,
        params: CodexJSONValue? = nil
    ) throws {
        guard isInitialized else { throw CodexAppServerClientError.closed }
        try writeMessage(
            .object([
                "method": .string(method),
                "params": params ?? .null
            ])
        )
    }

    private func initialize() async throws {
        _ = try await sendRequestCore(
            "initialize",
            params: .object([
                "clientInfo": .object([
                    "name": .string(options.clientName),
                    "title": .string(options.clientTitle),
                    "version": .string(options.clientVersion)
                ]),
                "capabilities": .object([
                    "experimentalApi": .bool(options.experimentalAPI)
                ])
            ])
        )
        try writeMessage(
            .object([
                "method": .string("initialized"),
                "params": .object([:])
            ])
        )
        isInitialized = true
    }

    private func sendRequestCore(
        _ method: String,
        params: CodexJSONValue?
    ) async throws -> CodexJSONValue {
        guard !isClosed, !method.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CodexAppServerClientError.closed
        }
        nextRequestID += 1
        let requestID = CodexAppServerMessageID.integer(nextRequestID)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeoutNanoseconds = UInt64(options.requestTimeout * 1_000_000_000)
                let timeoutTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                    guard !Task.isCancelled else { return }
                    await self?.timeoutRequest(requestID, method: method)
                }
                pendingRequests[requestID] = PendingRequest(
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
                do {
                    try writeMessage(
                        .object([
                            "id": requestID.jsonValue,
                            "method": .string(method),
                            "params": params ?? .null
                        ])
                    )
                } catch {
                    finishRequest(requestID, result: .failure(error))
                }
            }
        } onCancel: {
            Task { await self.cancelRequest(requestID) }
        }
    }

    private func timeoutRequest(_ id: CodexAppServerMessageID, method: String) {
        finishRequest(id, result: .failure(CodexAppServerClientError.requestTimedOut(method)))
    }

    private func cancelRequest(_ id: CodexAppServerMessageID) {
        finishRequest(id, result: .failure(CancellationError()))
    }

    private func finishRequest(
        _ id: CodexAppServerMessageID,
        result: Result<CodexJSONValue, Error>
    ) {
        guard let pending = pendingRequests.removeValue(forKey: id) else { return }
        pending.timeoutTask.cancel()
        pending.continuation.resume(with: result)
    }

    private func writeMessage(_ message: CodexJSONValue) throws {
        guard !isClosed else { throw CodexAppServerClientError.closed }
        var data = try encoder.encode(message)
        data.append(0x0A)
        do {
            try inputHandle.write(contentsOf: data)
        } catch {
            throw CodexAppServerClientError.transportEnded("stdin")
        }
    }

    private func installReaders() {
        outputHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { await self?.consumeOutput(data) }
        }
        errorHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { await self?.consumeError(data) }
        }
        process.terminationHandler = { [weak self] process in
            let code = process.terminationStatus
            Task { await self?.handleTransportEnd("exit_\(code)") }
        }
    }

    private func consumeOutput(_ data: Data) {
        guard !isClosed else { return }
        guard !data.isEmpty else {
            handleTransportEnd("stdout_closed")
            return
        }
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer.prefix(upTo: newline)
            outputBuffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            guard line.count <= Self.maximumProtocolLineBytes else {
                malformedOutputLines += 1
                continue
            }
            handleProtocolLine(Data(line))
        }
        if outputBuffer.count > Self.maximumProtocolLineBytes {
            outputBuffer.removeAll(keepingCapacity: false)
            malformedOutputLines += 1
        }
    }

    private func consumeError(_ data: Data) {
        guard !data.isEmpty else { return }
        errorBuffer.append(data)
        while let newline = errorBuffer.firstIndex(of: 0x0A) {
            let lineData = errorBuffer.prefix(upTo: newline)
            errorBuffer.removeSubrange(...newline)
            if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                errorTail.append(String(line.prefix(500)))
                if errorTail.count > 50 {
                    errorTail.removeFirst(errorTail.count - 50)
                }
            }
        }
        if errorBuffer.count > Self.maximumErrorBufferBytes {
            errorBuffer = Data(errorBuffer.suffix(Self.maximumErrorBufferBytes))
        }
    }

    private func handleProtocolLine(_ data: Data) {
        guard let root = try? decoder.decode(CodexJSONValue.self, from: data),
              let object = root.objectValue else {
            malformedOutputLines += 1
            return
        }

        if let method = object["method"]?.stringValue, !method.isEmpty {
            let params = object["params"]
            if let idValue = object["id"], let id = CodexAppServerMessageID(idValue) {
                let request = CodexAppServerRequest(id: id, method: method, params: params)
                Task { await self.handleServerRequest(request) }
            } else if let handler = notificationHandler {
                handler(CodexAppServerNotification(method: method, params: params))
            }
            return
        }

        guard let idValue = object["id"], let id = CodexAppServerMessageID(idValue) else {
            malformedOutputLines += 1
            return
        }
        guard pendingRequests[id] != nil else {
            unknownResponses += 1
            return
        }
        if let errorValue = object["error"],
           let errorObject = errorValue.objectValue {
            let code = Int(errorObject["code"]?.integerValue ?? 0)
            let message = errorObject["message"]?.stringValue ?? "Unknown app-server error"
            finishRequest(
                id,
                result: .failure(
                    CodexAppServerRPCError(
                        code: code,
                        message: message,
                        data: errorObject["data"]
                    )
                )
            )
            return
        }
        finishRequest(id, result: .success(object["result"] ?? .object([:])))
    }

    private func handleServerRequest(_ request: CodexAppServerRequest) async {
        let reply: CodexAppServerReply
        if let handler = serverRequestHandler {
            reply = await handler(request)
        } else {
            unhandledServerRequests += 1
            reply = .failure(code: -32601, message: "Unsupported app-server request")
        }

        do {
            var object: [String: CodexJSONValue] = ["id": request.id.jsonValue]
            if let error = reply.error {
                var errorObject: [String: CodexJSONValue] = [
                    "code": .integer(Int64(error.code)),
                    "message": .string(error.message)
                ]
                if let data = error.data {
                    errorObject["data"] = data
                }
                object["error"] = .object(errorObject)
            } else {
                object["result"] = reply.result ?? .object([:])
            }
            try writeMessage(.object(object))
        } catch {
            handleTransportEnd("server_reply")
        }
    }

    private func handleTransportEnd(_ reason: String) {
        guard !didPublishTransportEnd else { return }
        didPublishTransportEnd = true
        let error = CodexAppServerClientError.transportEnded(reason)
        let ids = Array(pendingRequests.keys)
        for id in ids {
            finishRequest(id, result: .failure(error))
        }
        guard !isClosed else { return }
        transportEndedHandler?(reason)
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        isInitialized = false
        outputHandle.readabilityHandler = nil
        errorHandle.readabilityHandler = nil
        process.terminationHandler = nil
        try? inputHandle.close()
        try? outputHandle.close()
        try? errorHandle.close()

        let ids = Array(pendingRequests.keys)
        for id in ids {
            finishRequest(id, result: .failure(CodexAppServerClientError.closed))
        }

        if process.isRunning {
            process.terminate()
            for _ in 0..<20 where process.isRunning {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
    }
}

private enum CodexExecutableResolver {
    static func resolve(_ explicitURL: URL?) throws -> URL {
        if let explicitURL {
            return try validate(explicitURL)
        }
        if let configured = ProcessInfo.processInfo.environment["HOVERPOCKET_CODEX_EXECUTABLE"],
           !configured.isEmpty {
            return try validate(URL(fileURLWithPath: configured))
        }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["codex"]
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw CodexAppServerClientError.executableNotFound
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0,
              let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            throw CodexAppServerClientError.executableNotFound
        }
        return try validate(URL(fileURLWithPath: path))
    }

    private static func validate(_ url: URL) throws -> URL {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: resolved.path) else {
            throw CodexAppServerClientError.executableNotFound
        }
        guard FileManager.default.isExecutableFile(atPath: resolved.path) else {
            throw CodexAppServerClientError.executableNotRunnable
        }
        return resolved
    }
}
