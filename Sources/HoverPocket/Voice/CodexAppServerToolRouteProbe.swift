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
        guard let expectedNames = CodexVoiceThreadContract.toolNames(dynamicTools),
              !expectedNames.isEmpty else {
            throw CodexAppServerToolRouteProbeError.toolRouteMismatch
        }

        let server = try CodexToolRouteProbeHTTPServer()
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
        } catch {
            await client.close()
            server.stop()
            try? FileManager.default.removeItem(at: workspace)
            throw error
        }

        await client.close()
        server.stop()
        try? FileManager.default.removeItem(at: workspace)
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

    let baseURL: String

    init() throws {
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

        let response = """
        event: response.created
        data: {"type":"response.created","response":{"id":"resp-hoverpocket-probe"}}

        event: response.completed
        data: {"type":"response.completed","response":{"id":"resp-hoverpocket-probe","usage":{"input_tokens":0,"input_tokens_details":null,"output_tokens":0,"output_tokens_details":null,"total_tokens":0}}}


        """
        sendResponse(
            status: "200 OK",
            contentType: "text/event-stream",
            body: Data(response.utf8),
            to: clientFD
        )
        complete(.success(request.body))
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
