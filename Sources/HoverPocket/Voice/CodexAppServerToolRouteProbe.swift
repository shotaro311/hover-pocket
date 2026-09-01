import Darwin
import Foundation

enum CodexAppServerToolRouteProbeError: Error, Equatable, Sendable {
    case socketFailed
    case bindFailed
    case listenFailed
    case missingPort
    case requestTimedOut
    case requestInvalid
    case toolRouteMismatch
}

struct CodexAppServerToolRouteProbeInvocation: Sendable {
    let toolName: String
    let arguments: CodexJSONValue
    let handler: @Sendable (CodexAppServerRequest, String) async -> CodexAppServerReply
}

struct CodexAppServerToolRouteProbeInvocationResult: Sendable {
    let request: CodexAppServerRequest
    let reply: CodexAppServerReply
}

enum CodexVoiceAppServerLaunchPolicy {
    private static let baseConfigurationArguments = [
        "-c",
        "features.realtime_conversation=true"
    ]

    static let arguments = baseConfigurationArguments + [
        "app-server",
        "--stdio"
    ]

    static func toolRouteProbeArguments(baseURL: String) -> [String] {
        baseConfigurationArguments + [
            "-c", "model=\"hoverpocket-route-probe\"",
            "-c", "model_provider=\"hoverpocket_probe\"",
            "-c", "model_providers.hoverpocket_probe.name=\"HoverPocket tool route probe\"",
            "-c", "model_providers.hoverpocket_probe.base_url=\"" + baseURL + "\"",
            "-c", "model_providers.hoverpocket_probe.wire_api=\"responses\"",
            "-c", "model_providers.hoverpocket_probe.request_max_retries=0",
            "-c", "model_providers.hoverpocket_probe.stream_max_retries=0",
            "-c", "model_providers.hoverpocket_probe.requires_openai_auth=false",
            "app-server",
            "--stdio"
        ]
    }
}

enum CodexAppServerToolRouteProbe {
    static func run(
        executableURL: URL,
        profile: CodexVoiceAppServerProfile,
        dynamicTools: [CodexJSONValue]
    ) async throws {
        _ = try await runCore(
            executableURL: executableURL,
            profile: profile,
            dynamicTools: dynamicTools,
            invocation: nil
        )
    }

    static func runInvocation(
        executableURL: URL,
        profile: CodexVoiceAppServerProfile,
        dynamicTools: [CodexJSONValue],
        invocation: CodexAppServerToolRouteProbeInvocation
    ) async throws -> CodexAppServerToolRouteProbeInvocationResult {
        guard let result = try await runCore(
            executableURL: executableURL,
            profile: profile,
            dynamicTools: dynamicTools,
            invocation: invocation
        ) else {
            throw CodexAppServerToolRouteProbeError.requestInvalid
        }
        return result
    }

    private static func runCore(
        executableURL: URL,
        profile: CodexVoiceAppServerProfile,
        dynamicTools: [CodexJSONValue],
        invocation: CodexAppServerToolRouteProbeInvocation?
    ) async throws -> CodexAppServerToolRouteProbeInvocationResult? {
        guard let expectedNames = CodexVoiceThreadContract.toolNames(dynamicTools),
              !expectedNames.isEmpty else {
            throw CodexAppServerToolRouteProbeError.toolRouteMismatch
        }
        if let invocation,
           !expectedNames.contains(invocation.toolName) {
            throw CodexAppServerToolRouteProbeError.toolRouteMismatch
        }

        let server = try CodexToolRouteProbeHTTPServer(invocation: invocation)
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(
            "HoverPocketCodexToolRoute-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: workspace,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            server.stop()
            throw CodexAppServerToolRouteProbeError.requestInvalid
        }
        let probeCodexHome = workspace.appendingPathComponent("CodexHome", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: probeCodexHome,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let configuration = try Data(
                contentsOf: profile.codexHomeURL.appendingPathComponent("config.toml")
            )
            let probeConfiguration = probeCodexHome.appendingPathComponent("config.toml")
            try configuration.write(to: probeConfiguration, options: .atomic)
            guard chmod(probeConfiguration.path, 0o600) == 0 else {
                throw CodexAppServerToolRouteProbeError.requestInvalid
            }
        } catch {
            server.stop()
            try? FileManager.default.removeItem(at: workspace)
            throw CodexAppServerToolRouteProbeError.requestInvalid
        }
        var probeEnvironment = profile.processEnvironment
        probeEnvironment["CODEX_HOME"] = probeCodexHome.path
        probeEnvironment["HOME"] = workspace.path

        let client: CodexAppServerClient
        do {
            client = try await CodexAppServerClient.start(
                options: CodexAppServerClientOptions(
                    executableURL: executableURL,
                    launchArguments: CodexVoiceAppServerLaunchPolicy.toolRouteProbeArguments(
                        baseURL: server.baseURL
                    ),
                    processEnvironment: probeEnvironment,
                    workingDirectoryURL: probeCodexHome,
                    requestTimeout: 8,
                    clientName: "hover_pocket_tool_route_probe",
                    clientTitle: "HoverPocket Tool Route Probe",
                    clientVersion: "1",
                    experimentalAPI: true
                )
            )
        } catch {
            server.stop()
            try? FileManager.default.removeItem(at: workspace)
            throw error
        }

        var invocationResult: CodexAppServerToolRouteProbeInvocationResult?
        do {
            let threadResponse = try await client.sendRequest(
                "thread/start",
                params: .object(CodexVoiceThreadContract.startParameters(
                    workspaceDirectory: workspace,
                    dynamicTools: dynamicTools,
                    ephemeral: true
                ))
            )
            guard let threadID = threadResponse.objectValue?["thread"]?
                    .objectValue?["id"]?.stringValue,
                  VoiceTextSafety.sanitizeIdentifier(threadID) == threadID,
                  let modelProvider = threadResponse.objectValue?["modelProvider"]?.stringValue,
                  modelProvider == "hoverpocket_probe" else {
                throw CodexAppServerToolRouteProbeError.requestInvalid
            }

            let invocationCapture = invocation.map { _ in
                CodexToolRouteProbeInvocationCapture()
            }
            if let invocation, let invocationCapture {
                await client.setServerRequestHandler { request in
                    let reply = await invocation.handler(request, threadID)
                    return CodexAppServerReply(
                        result: reply.result,
                        error: reply.error,
                        afterWrite: {
                            if let afterWrite = reply.afterWrite {
                                await afterWrite()
                            }
                            invocationCapture.complete(request: request, reply: reply)
                        }
                    )
                }
            }

            async let capturedBody = server.waitForResponsesRequest(timeout: 8)
            _ = try await client.sendRequest(
                "turn/start",
                params: .object([
                    "threadId": .string(threadID),
                    "input": .array([
                        .object([
                            "type": .string("text"),
                            "text": .string("Reply with ok."),
                            "textElements": .array([])
                        ])
                    ])
                ])
            )
            let body = try await capturedBody
            guard body.count <= 2 * 1_024 * 1_024,
                  let request = try? JSONDecoder().decode(CodexJSONValue.self, from: body),
                  let actualTools = request.objectValue?["tools"]?.arrayValue,
                  actualTools.count == dynamicTools.count,
                  CodexVoiceThreadContract.toolNames(actualTools) == expectedNames else {
                throw CodexAppServerToolRouteProbeError.toolRouteMismatch
            }
            if let invocationCapture {
                invocationResult = try await invocationCapture.wait(timeout: 8)
            }
        } catch {
            await client.close()
            server.stop()
            try? FileManager.default.removeItem(at: workspace)
            throw error
        }

        await client.close()
        server.stop()
        try? FileManager.default.removeItem(at: workspace)
        return invocationResult
    }
}

private final class CodexToolRouteProbeHTTPServer: @unchecked Sendable {
    private static let maximumRequestBytes = 2 * 1_024 * 1_024

    private let socketFD: Int32
    private let source: DispatchSourceRead
    private let queue = DispatchQueue(label: "local.codex.hover-pocket.tool-route-probe")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var pendingResult: Result<Data, Error>?
    private var didCapture = false
    private var stopped = false
    private let invocation: CodexAppServerToolRouteProbeInvocation?
    private var responsesRequestCount = 0

    let baseURL: String

    init(invocation: CodexAppServerToolRouteProbeInvocation?) throws {
        self.invocation = invocation
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw CodexAppServerToolRouteProbeError.socketFailed
        }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindStatus = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindStatus == 0 else {
            Darwin.close(fd)
            throw CodexAppServerToolRouteProbeError.bindFailed
        }
        guard listen(fd, 4) == 0 else {
            Darwin.close(fd)
            throw CodexAppServerToolRouteProbeError.listenFailed
        }
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            Darwin.close(fd)
            throw CodexAppServerToolRouteProbeError.listenFailed
        }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameStatus = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        let port = UInt16(bigEndian: boundAddress.sin_port)
        guard nameStatus == 0, port > 0 else {
            Darwin.close(fd)
            throw CodexAppServerToolRouteProbeError.missingPort
        }

        socketFD = fd
        baseURL = "http://127.0.0.1:\(port)/v1"
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setCancelHandler { [fd] in
            Darwin.close(fd)
        }
        source.setEventHandler { [weak self] in
            self?.acceptConnections()
        }
        source.resume()
    }

    func waitForResponsesRequest(timeout: TimeInterval) async throws -> Data {
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

            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.complete(.failure(CodexAppServerToolRouteProbeError.requestTimedOut))
            }
        }
    }

    func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        lock.unlock()
        source.cancel()
    }

    private func acceptConnections() {
        while true {
            let clientFD = accept(socketFD, nil, nil)
            guard clientFD >= 0 else { return }
            handleConnection(clientFD)
        }
    }

    private func handleConnection(_ clientFD: Int32) {
        defer { Darwin.close(clientFD) }
        let clientFlags = fcntl(clientFD, F_GETFL, 0)
        guard clientFlags >= 0,
              fcntl(clientFD, F_SETFL, clientFlags & ~O_NONBLOCK) == 0 else {
            return
        }

        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(
            clientFD,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
        guard let request = readRequest(from: clientFD) else {
            sendResponse(status: "400 Bad Request", contentType: "text/plain", body: Data(), to: clientFD)
            return
        }
        if request.method == "GET", request.path.hasSuffix("/models?client_version=0.149.0")
            || request.path.contains("/models?") {
            sendResponse(
                status: "501 Not Implemented",
                contentType: "text/plain",
                body: Data("model catalog unavailable".utf8),
                to: clientFD
            )
            return
        }
        guard request.method == "POST", request.path.hasSuffix("/responses") else {
            sendResponse(status: "404 Not Found", contentType: "text/plain", body: Data(), to: clientFD)
            return
        }

        responsesRequestCount += 1
        let response: Data
        if responsesRequestCount == 1, let invocation {
            guard let functionCallResponse = Self.functionCallResponse(invocation) else {
                sendResponse(status: "500 Internal Server Error", contentType: "text/plain", body: Data(), to: clientFD)
                complete(.failure(CodexAppServerToolRouteProbeError.requestInvalid))
                return
            }
            response = functionCallResponse
        } else {
            response = Self.completedResponse()
        }
        sendResponse(
            status: "200 OK",
            contentType: "text/event-stream",
            body: response,
            to: clientFD
        )
        complete(.success(request.body))
    }

    private static func functionCallResponse(
        _ invocation: CodexAppServerToolRouteProbeInvocation
    ) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let argumentsData = try? encoder.encode(invocation.arguments),
              let arguments = String(data: argumentsData, encoding: .utf8) else {
            return nil
        }
        let itemID = "fc-hoverpocket-probe"
        let callID = "call-hoverpocket-probe"
        let pendingItem: CodexJSONValue = .object([
            "arguments": .string(""),
            "call_id": .string(callID),
            "id": .string(itemID),
            "name": .string(invocation.toolName),
            "status": .string("in_progress"),
            "type": .string("function_call")
        ])
        let completedItem: CodexJSONValue = .object([
            "arguments": .string(arguments),
            "call_id": .string(callID),
            "id": .string(itemID),
            "name": .string(invocation.toolName),
            "status": .string("completed"),
            "type": .string("function_call")
        ])
        return stream([
            (
                "response.created",
                .object([
                    "type": .string("response.created"),
                    "response": .object([
                        "id": .string("resp-hoverpocket-probe"),
                        "output": .array([]),
                        "status": .string("in_progress")
                    ])
                ])
            ),
            (
                "response.output_item.added",
                .object([
                    "type": .string("response.output_item.added"),
                    "output_index": .integer(0),
                    "item": pendingItem
                ])
            ),
            (
                "response.function_call_arguments.done",
                .object([
                    "type": .string("response.function_call_arguments.done"),
                    "arguments": .string(arguments),
                    "item_id": .string(itemID),
                    "name": .string(invocation.toolName),
                    "output_index": .integer(0)
                ])
            ),
            (
                "response.output_item.done",
                .object([
                    "type": .string("response.output_item.done"),
                    "output_index": .integer(0),
                    "item": completedItem
                ])
            ),
            (
                "response.completed",
                .object([
                    "type": .string("response.completed"),
                    "response": .object([
                        "id": .string("resp-hoverpocket-probe"),
                        "output": .array([completedItem]),
                        "status": .string("completed"),
                        "usage": usage
                    ])
                ])
            )
        ])
    }

    private static func completedResponse() -> Data {
        stream([
            (
                "response.created",
                .object([
                    "type": .string("response.created"),
                    "response": .object([
                        "id": .string("resp-hoverpocket-probe-final"),
                        "output": .array([]),
                        "status": .string("in_progress")
                    ])
                ])
            ),
            (
                "response.completed",
                .object([
                    "type": .string("response.completed"),
                    "response": .object([
                        "id": .string("resp-hoverpocket-probe-final"),
                        "output": .array([]),
                        "status": .string("completed"),
                        "usage": usage
                    ])
                ])
            )
        ]) ?? Data()
    }

    private static var usage: CodexJSONValue {
        .object([
            "input_tokens": .integer(0),
            "input_tokens_details": .null,
            "output_tokens": .integer(0),
            "output_tokens_details": .null,
            "total_tokens": .integer(0)
        ])
    }

    private static func stream(_ events: [(String, CodexJSONValue)]) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var result = Data()
        for (name, payload) in events {
            guard let payloadData = try? encoder.encode(payload) else { return nil }
            result.append(Data("event: \(name)\ndata: ".utf8))
            result.append(payloadData)
            result.append(Data("\n\n".utf8))
        }
        result.append(Data("\n".utf8))
        return result
    }

    private func readRequest(from clientFD: Int32) -> (method: String, path: String, body: Data)? {
        let delimiter = Data("\r\n\r\n".utf8)
        var data = Data()
        var headerRange: Range<Data.Index>?
        var contentLength = 0
        while data.count <= Self.maximumRequestBytes {
            var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
            let count = Darwin.read(clientFD, &buffer, buffer.count)
            guard count > 0 else { return nil }
            data.append(contentsOf: buffer.prefix(count))
            if headerRange == nil,
               let range = data.range(of: delimiter),
               let header = String(data: data[..<range.lowerBound], encoding: .utf8) {
                headerRange = range
                contentLength = Self.contentLength(in: header)
                guard contentLength >= 0,
                      range.upperBound + contentLength <= Self.maximumRequestBytes else {
                    return nil
                }
            }
            if let headerRange, data.count >= headerRange.upperBound + contentLength {
                guard let header = String(data: data[..<headerRange.lowerBound], encoding: .utf8),
                      let firstLine = header.components(separatedBy: "\r\n").first else {
                    return nil
                }
                let parts = firstLine.split(separator: " ")
                guard parts.count >= 2 else { return nil }
                let bodyStart = headerRange.upperBound
                return (
                    String(parts[0]),
                    String(parts[1]),
                    data.subdata(in: bodyStart..<(bodyStart + contentLength))
                )
            }
        }
        return nil
    }

    private static func contentLength(in header: String) -> Int {
        for line in header.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2,
               parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare("Content-Length") == .orderedSame {
                return Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
            }
        }
        return 0
    }

    private func sendResponse(
        status: String,
        contentType: String,
        body: Data,
        to clientFD: Int32
    ) {
        let header = """
        HTTP/1.1 \(status)\r
        Content-Type: \(contentType)\r
        Content-Length: \(body.count)\r
        Connection: close\r
        \r

        """
        var response = Data(header.utf8)
        response.append(body)
        response.withUnsafeBytes { pointer in
            guard let baseAddress = pointer.baseAddress else { return }
            _ = Darwin.send(clientFD, baseAddress, response.count, MSG_NOSIGNAL)
        }
    }

    private func complete(_ result: Result<Data, Error>) {
        lock.lock()
        guard !didCapture else {
            lock.unlock()
            return
        }
        didCapture = true
        let continuation = continuation
        self.continuation = nil
        if continuation == nil {
            pendingResult = result
        }
        lock.unlock()
        continuation?.resume(with: result)
    }
}

private final class CodexToolRouteProbeInvocationCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CodexAppServerToolRouteProbeInvocationResult, Error>?
    private var pendingResult: CodexAppServerToolRouteProbeInvocationResult?
    private var completed = false

    func wait(timeout: TimeInterval) async throws -> CodexAppServerToolRouteProbeInvocationResult {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let pendingResult {
                self.pendingResult = nil
                lock.unlock()
                continuation.resume(returning: pendingResult)
                return
            }
            self.continuation = continuation
            lock.unlock()
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.failIfPending()
            }
        }
    }

    func complete(request: CodexAppServerRequest, reply: CodexAppServerReply) {
        let result = CodexAppServerToolRouteProbeInvocationResult(request: request, reply: reply)
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
        continuation?.resume(returning: result)
    }

    private func failIfPending() {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(throwing: CodexAppServerToolRouteProbeError.requestTimedOut)
    }
}
