import Foundation

enum OAuthURLCallbackReceiverError: LocalizedError {
    case cancelled

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "The OAuth URL callback listener was cancelled."
        }
    }
}

final class OAuthURLCallbackReceiver: @unchecked Sendable {
    let callbackScheme: String

    private let lock = NSLock()
    private var continuation: CheckedContinuation<OAuthCallback, Error>?
    private var pendingResult: Result<OAuthCallback, Error>?
    private var didComplete = false

    init(callbackScheme: String) {
        self.callbackScheme = callbackScheme.lowercased()
        OAuthURLCallbackCoordinator.shared.register(self)
    }

    func waitForCallback() async throws -> OAuthCallback {
        try await withTaskCancellationHandler {
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
        } onCancel: {
            cancel()
        }
    }

    func cancel() {
        complete(with: .failure(OAuthURLCallbackReceiverError.cancelled))
    }

    fileprivate func receive(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == callbackScheme else {
            return false
        }
        let callback = Self.oauthCallback(from: url)
        complete(with: .success(callback))
        return true
    }

    private static func oauthCallback(from url: URL) -> OAuthCallback {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return OAuthCallback(code: nil, state: nil, error: nil)
        }
        let items = components.queryItems ?? []
        return OAuthCallback(
            code: items.first { $0.name == "code" }?.value,
            state: items.first { $0.name == "state" }?.value,
            error: items.first { $0.name == "error" }?.value
        )
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

        OAuthURLCallbackCoordinator.shared.unregister(self)
        guard let continuation else { return }
        switch result {
        case .success(let callback):
            continuation.resume(returning: callback)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

final class OAuthURLCallbackCoordinator: @unchecked Sendable {
    static let shared = OAuthURLCallbackCoordinator()

    private let lock = NSLock()
    private var receivers: [String: [OAuthURLCallbackReceiver]] = [:]

    private init() {}

    func register(_ receiver: OAuthURLCallbackReceiver) {
        lock.lock()
        receivers[receiver.callbackScheme, default: []].append(receiver)
        lock.unlock()
    }

    func unregister(_ receiver: OAuthURLCallbackReceiver) {
        lock.lock()
        var schemeReceivers = receivers[receiver.callbackScheme] ?? []
        schemeReceivers.removeAll { $0 === receiver }
        if schemeReceivers.isEmpty {
            receivers.removeValue(forKey: receiver.callbackScheme)
        } else {
            receivers[receiver.callbackScheme] = schemeReceivers
        }
        lock.unlock()
    }

    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else {
            return false
        }

        lock.lock()
        let receiver = receivers[scheme]?.last
        lock.unlock()

        return receiver?.receive(url) ?? false
    }
}
