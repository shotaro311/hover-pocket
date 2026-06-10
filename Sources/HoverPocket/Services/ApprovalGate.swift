import Foundation

@MainActor
final class ApprovalGate: ObservableObject {
    @Published private(set) var pendingAction: PocketAction?

    func requestApproval(for action: PocketAction) {
        guard action.requiresApproval else { return }
        pendingAction = action
    }

    func approvePendingAction() -> PocketAction? {
        defer { pendingAction = nil }
        return pendingAction
    }

    func rejectPendingAction() {
        pendingAction = nil
    }
}
