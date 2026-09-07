import Foundation

/// Returns a pending-confirmation reply before the original execution task finishes.
@MainActor
final class VoiceToolReplyChannel {
    private var latest: String?
    private var waiters: [CheckedContinuation<String, Never>] = []

    func value() async -> String {
        if let latest { return latest }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func publish(_ value: String) {
        latest = value
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume(returning: value) }
    }
}
