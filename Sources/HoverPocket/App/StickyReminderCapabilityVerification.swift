import Foundation

@MainActor
enum StickyReminderCapabilityVerification {
    private struct Failure: Error { let label: String }
    private static func check(_ value: Bool, _ label: String) throws {
        if !value { throw Failure(label: label) }
    }

    static func verify(root: URL) async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let directory = root.appendingPathComponent("reminder-capability")
        let store = StickyNotesStore(storageDirectory: directory)
        let handlers = try PocketCapabilityHandlerSet(handlers: [
            StickyCapabilityHandler(operation: .upsert, store: store),
            StickyCapabilityHandler(operation: .get, store: store),
            StickyCapabilityHandler(operation: .upsertV2, store: store),
            StickyCapabilityHandler(operation: .getV2, store: store)
        ])
        let registry = try CapabilityRegistry(handlers: handlers)
        let descriptor = try registry.resolve(PocketCapabilityKeys.stickyUpsertV2)
        try check(descriptor.approvalPolicy == .brokerPolicy && descriptor.idempotency == .required,
                  "v2_preserves_broker_policy")
        try check(descriptor.readback.query == PocketCapabilityKeys.stickyGetV2 && descriptor.readback.matchFields.contains("reminder"),
                  "v2_readback_includes_reminder")
        let context = CapabilityHandlerContext(idempotencyKey: "sticky-reminder-verifier-001", now: now)
        let scheduled = "2027-01-16T15:00:00+09:00"
        let reminder: CapabilityValue = .object(["scheduledAt": .string(scheduled), "timeZone": .string("Asia/Tokyo")])
        var arguments: CapabilityObject = ["stableKey": .string("verify:reminder"), "title": .string("資料"),
            "body": .string("資料を送る"), "color": .string("yellow"), "reminder": reminder]
        try descriptor.validateInput(arguments)
        let created = try await handlers.invoke(PocketCapabilityKeys.stickyUpsertV2, arguments: arguments, context: context)
        try descriptor.validateOutput(created)
        guard case .string(let id)? = created["noteId"], let uuid = UUID(uuidString: id) else { throw Failure(label: "note_id") }
        let restored = StickyNotesStore(storageDirectory: directory)
        try check(restored.note(id: uuid)?.reminder?.scheduledAt == CapabilityDateCodec.date(from: scheduled), "date_disk_readback")
        try check(restored.note(id: uuid)?.reminder?.timeZone == "Asia/Tokyo", "timezone_disk_readback")
        try check(try await handlers.invoke(PocketCapabilityKeys.stickyGetV2, arguments: ["noteId": .string(id)]) == created, "v2_get_readback")

        arguments.removeValue(forKey: "reminder")
        arguments["body"] = .string("更新")
        let preserved = try await handlers.invoke(PocketCapabilityKeys.stickyUpsertV2, arguments: arguments, context: context)
        try check(preserved["reminder"] == created["reminder"], "v2_omission_preserves")
        let legacy = try await handlers.invoke(PocketCapabilityKeys.stickyUpsert, arguments: arguments, context: context)
        try registry.resolve(PocketCapabilityKeys.stickyUpsert).validateOutput(legacy)
        try check(legacy["reminder"] == nil && store.note(id: uuid)?.reminder != nil, "v1_preserves_reminder_and_schema")
        arguments["reminder"] = .null
        let cleared = try await handlers.invoke(PocketCapabilityKeys.stickyUpsertV2, arguments: arguments, context: context)
        try check(cleared["reminder"] == .null && StickyNotesStore(storageDirectory: directory).note(id: uuid)?.reminder == nil,
                  "v2_null_clears_atomically")
        let invalidReminders: [CapabilityValue] = [
            .object(["scheduledAt": .string("2027-01-16T15:00:00"), "timeZone": .string("Asia/Tokyo")]),
            .object(["scheduledAt": .string(scheduled), "timeZone": .string("Unknown/Place")]),
            .object(["scheduledAt": .string(scheduled), "timeZone": .string("Asia/Tokyo"), "acknowledgedAt": .null]),
            .object(["scheduledAt": .string("2027-02-30T15:00:00+09:00"), "timeZone": .string("Asia/Tokyo")]),
            .object(["scheduledAt": .string("2027-01-16T15:00:00+99:00"), "timeZone": .string("Asia/Tokyo")]),
            .object(["scheduledAt": .string("2027-01-16T15:00:00+09:99"), "timeZone": .string("Asia/Tokyo")]),
            .object(["scheduledAt": .string(scheduled + "\n"), "timeZone": .string("Asia/Tokyo")]),
            .string(scheduled)
        ]
        for invalid in invalidReminders {
            arguments["reminder"] = invalid
            do { try descriptor.validateInput(arguments); throw Failure(label: "invalid_reminder_accepted") }
            catch is CapabilityBrokerError {}
        }
        arguments["reminder"] = .object(["scheduledAt": .string(CapabilityDateCodec.string(from: now)), "timeZone": .string("UTC")])
        do {
            _ = try await handlers.invoke(PocketCapabilityKeys.stickyUpsertV2, arguments: arguments, context: context)
            throw Failure(label: "past_reminder_accepted")
        } catch is CapabilityHandlerError {}
        try check(store.note(id: uuid)?.reminder == nil, "past_reminder_no_partial_mutation")

        let blocked = root.appendingPathComponent("blocked-reminder-store")
        try Data("block directory".utf8).write(to: blocked)
        let blockedStore = StickyNotesStore(storageDirectory: blocked)
        arguments["reminder"] = reminder
        do {
            _ = try await StickyCapabilityHandler(operation: .upsertV2, store: blockedStore).handle(arguments: arguments, context: context)
            throw Failure(label: "persistence_failure_accepted")
        } catch CapabilityHandlerError.unavailable {}
        try check(blockedStore.notes.isEmpty, "persistence_failure_rolls_back_note_and_reminder")
        print("capability_sticky_reminder_v2=ok")
    }
}
