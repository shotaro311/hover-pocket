import Darwin
import Foundation

struct OAuthCallback: Sendable {
    let code: String?
    let state: String?
    let error: String?
}

enum LoopbackOAuthReceiverError: LocalizedError {
    case socketFailed
    case bindFailed
    case listenFailed
    case missingPort
    case invalidRequest
    case cancelled

    var errorDescription: String? {
        switch self {
        case .socketFailed:
            return "Could not create a local OAuth callback socket."
        case .bindFailed:
            return "Could not bind the local OAuth callback socket."
        case .listenFailed:
            return "Could not listen for the local OAuth callback."
        case .missingPort:
            return "Could not open a local OAuth callback port."
        case .invalidRequest:
            return "The OAuth callback was not valid."
        case .cancelled:
            return "The OAuth callback listener was cancelled."
        }
    }
}

final class LoopbackOAuthReceiver: @unchecked Sendable {
    private let socketFD: Int32
    private let source: DispatchSourceRead
    private let queue = DispatchQueue(label: "local.codex.hover-pocket.oauth-loopback")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<OAuthCallback, Error>?
    private var pendingResult: Result<OAuthCallback, Error>?
    private var didComplete = false

    let redirectURI: String

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw LoopbackOAuthReceiverError.socketFailed
        }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

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
            close(fd)
            throw LoopbackOAuthReceiverError.bindFailed
        }

        guard listen(fd, 1) == 0 else {
            close(fd)
            throw LoopbackOAuthReceiverError.listenFailed
        }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameStatus = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard nameStatus == 0 else {
            close(fd)
            throw LoopbackOAuthReceiverError.missingPort
        }

        let port = UInt16(bigEndian: boundAddress.sin_port)
        guard port > 0 else {
            close(fd)
            throw LoopbackOAuthReceiverError.missingPort
        }
        socketFD = fd
        redirectURI = "http://127.0.0.1:\(port)"

        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setCancelHandler { [fd] in
            close(fd)
        }
        source.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        source.resume()
    }

    func waitForCallback() async throws -> OAuthCallback {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let pendingResult {
                self.pendingResult = nil
                lock.unlock()
                switch pendingResult {
                case .success(let callback):
                    continuation.resume(returning: callback)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    func cancel() {
        complete(with: .failure(LoopbackOAuthReceiverError.cancelled))
    }

    private func acceptConnection() {
        let clientFD = accept(socketFD, nil, nil)
        guard clientFD >= 0 else { return }
        defer {
            close(clientFD)
        }

        var buffer = [UInt8](repeating: 0, count: 8192)
        let count = read(clientFD, &buffer, buffer.count)
        guard count > 0 else {
            sendResponse(to: clientFD, success: false)
            complete(with: .failure(LoopbackOAuthReceiverError.invalidRequest))
            return
        }

        let data = Data(buffer.prefix(count))
        let callback = parseCallback(from: data)
        sendResponse(to: clientFD, success: callback?.code != nil || callback?.error != nil)

        guard let callback else {
            complete(with: .failure(LoopbackOAuthReceiverError.invalidRequest))
            return
        }
        complete(with: .success(callback))
    }

    private func parseCallback(from data: Data) -> OAuthCallback? {
        guard
            let request = String(data: data, encoding: .utf8),
            let firstLine = request.components(separatedBy: "\r\n").first
        else {
            return nil
        }

        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else {
            return nil
        }

        let path = String(parts[1])
        guard let components = URLComponents(string: "http://127.0.0.1\(path)") else {
            return nil
        }

        let items = components.queryItems ?? []
        return OAuthCallback(
            code: items.first { $0.name == "code" }?.value,
            state: items.first { $0.name == "state" }?.value,
            error: items.first { $0.name == "error" }?.value
        )
    }

    private func sendResponse(to clientFD: Int32, success: Bool) {
        let title = success ? "Google Calendar connected" : "Google Calendar sign-in failed"
        let body = """
        <html><head><meta charset="utf-8"><title>\(title)</title></head>
        <body style="font-family:-apple-system;padding:24px">
        <h3>\(title)</h3><p>You can return to ホバーポケット.</p>
        </body></html>
        """
        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
        let data = Data(response.utf8)
        data.withUnsafeBytes { pointer in
            guard let baseAddress = pointer.baseAddress else { return }
            _ = write(clientFD, baseAddress, data.count)
        }
    }

    private func complete(with result: Result<OAuthCallback, Error>) {
        lock.lock()
        guard !didComplete else {
            lock.unlock()
            return
        }
        didComplete = true
        let continuation = continuation
        self.continuation = nil
        if continuation == nil {
            pendingResult = result
        }
        lock.unlock()

        source.cancel()
        guard let continuation else { return }
        switch result {
        case .success(let callback):
            continuation.resume(returning: callback)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}
