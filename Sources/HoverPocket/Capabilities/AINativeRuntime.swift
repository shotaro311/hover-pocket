import Foundation

@MainActor
final class AINativeRuntime {
    static let shared = AINativeRuntime()

    private let principal = CapabilityPrincipal(userID: "local-user")
    private var adapter: TodayFocusTextAdapter?

    private init() {}

    var isAvailable: Bool { adapter != nil }

    func configure(adapter: TodayFocusTextAdapter?) {
        self.adapter = adapter
    }

    func prepareTodayFocus(
        event: GoogleCalendarEventOccurrence,
        durationSeconds: Int = 1_500,
        now: Date = Date()
    ) throws -> TodayFocusDraft {
        guard let adapter else {
            throw CapabilityBrokerError.unavailable(PocketCapabilityKeys.timerStart)
        }
        let purpose = event.title.isEmpty ? "今日の予定" : event.title
        return try adapter.prepareFocus(
            event: TodayFocusCalendarEvent(
                eventRef: event.id,
                safeTitle: purpose,
                start: event.start,
                end: event.end
            ),
            durationSeconds: durationSeconds,
            purpose: purpose,
            principal: principal,
            permissions: permissionSet,
            now: now
        )
    }

    func approveAndExecute(_ draft: TodayFocusDraft, now: Date = Date()) async throws -> CapabilityWorkflowReceipt {
        guard let adapter else {
            throw CapabilityBrokerError.unavailable(PocketCapabilityKeys.timerStart)
        }
        return try await adapter.approveAndExecute(
            draft,
            permissions: permissionSet,
            now: now
        )
    }

    func reject(_ draft: TodayFocusDraft, now: Date = Date()) {
        guard let adapter,
              let request = draft.preparation.approvalRequest else { return }
        do {
            _ = try adapter.reject(
                requestID: request.id,
                planDigest: draft.preparation.planDigest,
                now: now
            )
        } catch CapabilityBrokerError.approvalRejected {
        } catch {
        }
    }

    private var permissionSet: CapabilityPermissionSet {
        CapabilityPermissionSet(
            principal: principal,
            permissions: ["calendar.events.read", "sticky.write", "timer.write"]
        )
    }
}
