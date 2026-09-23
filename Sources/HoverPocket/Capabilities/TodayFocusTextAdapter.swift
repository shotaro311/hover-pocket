import Foundation

struct TodayFocusCalendarEvent: Equatable, Sendable {
    let eventRef: String
    let safeTitle: String
    let start: Date
    let end: Date
}

struct TodayFocusDraft: Equatable, Sendable {
    let plan: CapabilityExecutionPlan
    let preparation: CapabilityBrokerPreparation
    let approvalText: String
}

enum TodayFocusApprovalText {
    private static let bidirectionalControls: Set<UInt32> = [
        0x061C, 0x200E, 0x200F,
        0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
        0x2066, 0x2067, 0x2068, 0x2069
    ]

    static func sanitize(_ value: String) -> String {
        var result = ""
        var pendingSpace = false
        for scalar in value.unicodeScalars {
            let disallowed = CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.newlines.contains(scalar)
                || bidirectionalControls.contains(scalar.value)
            if disallowed || CharacterSet.whitespaces.contains(scalar) {
                pendingSpace = !result.isEmpty
                continue
            }
            if pendingSpace {
                result.append(" ")
                pendingSpace = false
            }
            result.append(String(scalar))
        }
        let normalized = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? "予定名なし" : normalized.prefixingUnicodeScalars(80)
    }
}

@MainActor
final class TodayFocusTextAdapter {
    private let broker: CapabilityBroker
    private let activationLease: PocketAppActivationLease?

    init(
        broker: CapabilityBroker,
        activationLease: PocketAppActivationLease? = nil
    ) {
        self.broker = broker
        self.activationLease = activationLease
    }

    func listToday(
        timezone: TimeZone,
        principal: CapabilityPrincipal,
        permissions: CapabilityPermissionSet,
        now: Date = Date()
    ) async throws -> [TodayFocusCalendarEvent] {
        try activationLease?.requireActive()
        let nonce = UUID().uuidString.lowercased()
        let plan = CapabilityExecutionPlan(
            id: "today-focus-read:\(nonce)",
            createdAt: now,
            origin: .text,
            principal: principal,
            appContext: nil,
            steps: [
                CapabilityPlanStep(
                    id: "listCalendar",
                    capability: PocketCapabilityKeys.calendarList,
                    arguments: [
                        "range": .string("today"),
                        "timezone": .string(timezone.identifier)
                    ],
                    idempotencyKey: "today-focus-read.\(nonce)",
                    dependencies: []
                )
            ],
            requiredPermissions: ["calendar.events.read"]
        )
        let preparation = try broker.prepare(plan, permissions: permissions, now: now)
        guard preparation.approvalRequest == nil else {
            throw CapabilityBrokerError.invalidPlan("read_approval")
        }
        let receipt = try await executeTracked {
            try await self.broker.execute(
                plan,
                permissions: permissions,
                approvalGrant: nil,
                now: now
            )
        }
        try activationLease?.requireActive()
        guard receipt.status == .succeeded,
              let output = receipt.steps.first?.output,
              case .array(let events)? = output["events"] else {
            throw CapabilityBrokerError.unavailable(PocketCapabilityKeys.calendarList)
        }
        return try events.map { value in
            guard case .object(let event) = value,
                  case .string(let eventRef)? = event["eventRef"],
                  case .string(let safeTitle)? = event["safeTitle"],
                  case .string(let startValue)? = event["start"],
                  case .string(let endValue)? = event["end"],
                  let start = CapabilityDateCodec.date(from: startValue),
                  let end = CapabilityDateCodec.date(from: endValue) else {
                throw CapabilityBrokerError.unavailable(PocketCapabilityKeys.calendarList)
            }
            return TodayFocusCalendarEvent(
                eventRef: eventRef,
                safeTitle: safeTitle,
                start: start,
                end: end
            )
        }
    }

    func prepareFocus(
        event: TodayFocusCalendarEvent,
        durationSeconds: Int,
        purpose: String,
        principal: CapabilityPrincipal,
        permissions: CapabilityPermissionSet,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) throws -> TodayFocusDraft {
        try activationLease?.requireActive()
        guard (1...86_400).contains(durationSeconds),
              !purpose.isEmpty,
              purpose.unicodeScalars.count <= 10_000 else {
            throw CapabilityBrokerError.invalidPlan("today_focus_input")
        }
        let nonce = UUID().uuidString.lowercased()
        let stableDate = Self.dateKey(now, timeZone: timeZone)
        let approvalText = TodayFocusApprovalText.sanitize(purpose)
        let plan = CapabilityExecutionPlan(
            id: "today-focus-write:\(nonce)",
            createdAt: now,
            origin: .text,
            principal: principal,
            appContext: nil,
            steps: [
                CapabilityPlanStep(
                    id: "startTimer",
                    capability: PocketCapabilityKeys.timerStart,
                    arguments: [
                        "durationSeconds": .integer(durationSeconds),
                        "title": .string(approvalText),
                        "sourceRef": .string(event.eventRef)
                    ],
                    idempotencyKey: "today-focus-timer.\(nonce)",
                    dependencies: []
                ),
                CapabilityPlanStep(
                    id: "savePurpose",
                    capability: PocketCapabilityKeys.stickyUpsert,
                    arguments: [
                        "stableKey": .string("today-focus:\(stableDate)"),
                        "title": .string("今日の目的"),
                        "body": .string(approvalText),
                        "color": .string("yellow")
                    ],
                    idempotencyKey: "today-focus-sticky.\(nonce)",
                    dependencies: ["startTimer"]
                )
            ],
            requiredPermissions: ["sticky.write", "timer.write"]
        )
        return TodayFocusDraft(
            plan: plan,
            preparation: try broker.prepare(plan, permissions: permissions, now: now),
            approvalText: approvalText
        )
    }

    func approveAndExecute(
        _ draft: TodayFocusDraft,
        permissions: CapabilityPermissionSet,
        now: Date = Date()
    ) async throws -> CapabilityWorkflowReceipt {
        try activationLease?.requireActive()
        guard let request = draft.preparation.approvalRequest else {
            throw CapabilityBrokerError.approvalRequired
        }
        let grant = try broker.decideApproval(
            requestID: request.id,
            planDigest: draft.preparation.planDigest,
            decision: .approve,
            now: now
        )
        let receipt = try await executeTracked {
            try await self.broker.execute(
                draft.plan,
                permissions: permissions,
                approvalGrant: grant,
                now: now
            )
        }
        try activationLease?.requireActive()
        return receipt
    }

    func reject(
        requestID: String,
        planDigest: String,
        now: Date
    ) throws -> CapabilityApprovalGrant {
        try activationLease?.requireActive()
        return try broker.decideApproval(
            requestID: requestID,
            planDigest: planDigest,
            decision: .reject,
            now: now
        )
    }

    private func executeTracked<T: Sendable>(
        _ operation: @escaping @MainActor @Sendable () async throws -> T
    ) async throws -> T {
        try activationLease?.requireActive()
        let task = Task { @MainActor in
            try Task.checkCancellation()
            return try await operation()
        }
        let registration = activationLease?.registerCancellation { task.cancel() }
        defer { activationLease?.unregisterCancellation(registration) }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func dateKey(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
