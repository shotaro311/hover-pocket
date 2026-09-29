import Combine
import Foundation

enum StickyReminderVerificationCommand {
    @MainActor
    static func run() -> Never {
        var checks: [(String, Bool)] = []
        func check(_ name: String, _ passed: Bool) { checks.append((name, passed)) }
        do {
            try verify(check: check)
        } catch {
            check("unexpected_error", false)
        }
        let ok = !checks.isEmpty && checks.allSatisfy(\.1)
        let output = (["sticky_reminders_verify=\(ok ? "ok" : "failed")",
                       "sticky_reminders_checks=\(checks.count)"]
            + checks.map { "sticky_reminders_\($0.0)=\($0.1 ? "ok" : "failed")" })
            .joined(separator: "\n") + "\n"
        print(output, terminator: "")
        if let index = CommandLine.arguments.firstIndex(of: "--verify-output"),
           CommandLine.arguments.indices.contains(index + 1) {
            do {
                try output.write(toFile: CommandLine.arguments[index + 1], atomically: true, encoding: .utf8)
            } catch { exit(1) }
        }
        exit(ok ? 0 : 1)
    }

    @MainActor
    private static func verify(check: (String, Bool) -> Void) throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("sticky-reminders-verify-\(UUID().uuidString)")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let url = directory.appendingPathComponent("notes.json")
        let now = Date(timeIntervalSinceReferenceDate: 100_000)
        let deadline = now.addingTimeInterval(60)
        let firstID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let secondID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let legacy = try JSONSerialization.data(withJSONObject: [[
            "id": firstID.uuidString, "title": "Legacy", "body": "Keep me", "color": "yellow",
            "createdAt": now.timeIntervalSinceReferenceDate, "updatedAt": now.timeIntervalSinceReferenceDate,
            "sortIndex": 0
        ]], options: [.sortedKeys])
        try legacy.write(to: url)
        let store = StickyNotesStore(storageDirectory: directory)
        check("legacy_decode", store.notes.count == 1 && store.note(id: firstID)?.reminder == nil)
        check("legacy_read_only", try Data(contentsOf: url) == legacy)
        check("set_future", store.updateReminder(id: firstID, reminderChange: .set(scheduledAt: deadline, timeZone: "Asia/Tokyo"), at: now))
        let backupURLs = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("notes.before-reminders-") }
        check("legacy_backup_once", backupURLs.count == 1)
        if let backupURL = backupURLs.first {
            check("legacy_backup_exact_bytes", try Data(contentsOf: backupURL) == legacy)
        }
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]]
        let reminderJSON = json?.first?["reminder"] as? [String: Any]
        check("ack_null_contract", reminderJSON?["acknowledgedAt"] is NSNull)
        check("not_due_early", store.dueReminders(at: deadline.addingTimeInterval(-1)).isEmpty)
        check("due_at_deadline", store.dueReminders(at: deadline).map(\.id) == [firstID])
        check("crash_restart_unacknowledged", StickyNotesStore(storageDirectory: directory).dueReminders(at: deadline).map(\.id) == [firstID])
        check("body_edit_preserves", store.updateNote(id: firstID, title: "Edited", body: "Body", color: .pink, at: now)
              && store.note(id: firstID)?.reminder?.scheduledAt == deadline)
        try store.editForCapability(id: firstID, title: "Capability edit", body: nil, color: nil, at: now)
        check("capability_edit_preserves", store.note(id: firstID)?.reminder?.scheduledAt == deadline)
        let second = try store.upsertNote(stableKey: "second", title: "Second", body: "", color: .blue,
                                          reminderChange: .set(scheduledAt: deadline, timeZone: "UTC"), id: secondID, at: now)
        _ = try store.upsertNote(stableKey: "second", title: "v1 edit", body: "Preserve", color: .mint, at: now)
        check("v1_upsert_preserves", store.note(id: second.id)?.reminder == second.reminder)
        check("same_deadline_order", store.dueReminders(at: deadline).map(\.id) == [firstID, secondID])
        check("stale_ack_rejected", try !store.acknowledgeReminder(noteID: firstID, scheduledAt: deadline.addingTimeInterval(1), at: deadline))
        check("early_ack_rejected", try !store.acknowledgeReminder(noteID: firstID, scheduledAt: deadline, at: now))
        check("ack_success", try store.acknowledgeReminder(noteID: firstID, scheduledAt: deadline, at: deadline))
        check("ack_repeat_noop", try !store.acknowledgeReminder(noteID: firstID, scheduledAt: deadline, at: deadline))
        check("ack_restart", StickyNotesStore(storageDirectory: directory).dueReminders(at: deadline).map(\.id) == [secondID])
        check("ack_archive_undo_preserves", store.archiveNote(id: firstID) && store.undoLastAction()
              && store.note(id: firstID)?.reminder?.acknowledgedAt == deadline)
        check("ack_delete_undo_preserves", store.deleteNote(id: firstID) && store.undoLastAction()
              && store.note(id: firstID)?.reminder?.acknowledgedAt == deadline)
        _ = try store.acknowledgeReminder(noteID: secondID, scheduledAt: deadline, at: deadline)
        _ = try store.upsertNote(stableKey: "second", title: "v1 acknowledged", body: "", color: .mint, at: deadline)
        check("v1_upsert_does_not_rearm", store.note(id: secondID)?.reminder?.acknowledgedAt == deadline)
        _ = store.updateReminder(id: secondID, reminderChange: .set(scheduledAt: deadline, timeZone: "UTC"), at: now)
        _ = store.updateNote(id: firstID, title: "After ack", body: "", color: .pink, at: deadline)
        check("edit_does_not_rearm", store.note(id: firstID)?.reminder?.acknowledgedAt == deadline)
        check("reschedule_rearms", store.updateReminder(id: firstID, reminderChange: .set(scheduledAt: deadline.addingTimeInterval(60), timeZone: "Asia/Tokyo"), at: deadline)
              && store.note(id: firstID)?.reminder?.acknowledgedAt == nil)
        check("clear", store.updateReminder(id: firstID, reminderChange: .clear, at: deadline)
              && store.note(id: firstID)?.reminder == nil)
        check("clear_restart", StickyNotesStore(storageDirectory: directory).note(id: firstID)?.reminder == nil)
        let beforeInvalid = store.notes
        for (name, change) in [
            ("past_rejected", StickyNoteReminderChange.set(scheduledAt: now.addingTimeInterval(-1), timeZone: "UTC")),
            ("present_rejected", .set(scheduledAt: now, timeZone: "UTC")),
            ("infinite_rejected", .set(scheduledAt: Date(timeIntervalSinceReferenceDate: .infinity), timeZone: "UTC")),
            ("timezone_rejected", .set(scheduledAt: deadline, timeZone: "Invalid/Zone"))
        ] {
            check(name, !store.updateReminder(id: firstID, reminderChange: change, at: now) && store.notes == beforeInvalid)
        }
        check("archive_suppresses", store.archiveNote(id: secondID) && store.dueReminders(at: deadline).isEmpty)
        check("archive_undo_restores", store.undoLastAction() && store.dueReminders(at: deadline).map(\.id) == [secondID])
        check("delete_suppresses", store.deleteNote(id: secondID) && store.dueReminders(at: deadline).isEmpty)
        check("delete_undo_restores", store.undoLastAction() && store.dueReminders(at: deadline).map(\.id) == [secondID])
        let reloaded = StickyNotesStore(storageDirectory: directory)
        check("backup_survives_restart", reloaded.updateReminder(id: firstID, reminderChange: .set(scheduledAt: deadline, timeZone: "UTC"), at: now))
        let backupsAfter = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("notes.before-reminders-") }
        let backupBytesUnchanged = try backupURLs.first.map { try Data(contentsOf: $0) == legacy } ?? false
        check("backup_not_overwritten", backupURLs == backupsAfter && backupBytesUnchanged)
        try verifySaveFailure(store: reloaded, directory: directory, now: now, deadline: deadline, firstID: firstID, secondID: secondID, check: check)
    }

    @MainActor
    private static func verifySaveFailure(
        store: StickyNotesStore, directory: URL, now: Date, deadline: Date,
        firstID: UUID, secondID: UUID, check: (String, Bool) -> Void
    ) throws {
        let fm = FileManager.default
        check("failure_fixture_undo", store.deleteNote(id: secondID))
        let originalNotes = store.notes
        let originalUndo = store.lastAction
        let url = directory.appendingPathComponent("notes.json")
        let preservedURL = directory.appendingPathComponent("preserved.json")
        let originalBytes = try Data(contentsOf: url)
        try fm.moveItem(at: url, to: preservedURL)
        // A directory at the file destination causes a real atomic write failure even when run as root.
        try fm.createDirectory(at: url, withIntermediateDirectories: false)
        var publications = 0
        let observation = store.$notes.dropFirst().sink { _ in publications += 1 }
        defer { observation.cancel() }
        check("failure_reminder_rollback", !store.updateReminder(id: firstID, reminderChange: .clear, at: now))
        check("failure_edit_rollback", !store.updateNote(id: firstID, title: "Lost", body: "", color: .blue, at: now))
        do {
            _ = try store.upsertNote(stableKey: "failure", title: "Lost", body: "", color: .blue, at: now)
            check("failure_upsert_throws", false)
        } catch { check("failure_upsert_throws", true) }
        do {
            try store.editForCapability(id: firstID, title: "Lost", body: nil, color: nil, at: now)
            check("failure_capability_edit_throws", false)
        } catch { check("failure_capability_edit_throws", true) }
        do {
            _ = try store.acknowledgeReminder(noteID: firstID, scheduledAt: deadline, at: deadline)
            check("failure_ack_throws", false)
        } catch { check("failure_ack_throws", true) }
        check("failure_archive_rollback", !store.archiveNote(id: firstID))
        check("failure_delete_rollback", !store.deleteNote(id: firstID))
        check("failure_discard_rollback", !store.discardNote(id: firstID))
        check("failure_undo_rollback", !store.undoLastAction())
        check("failure_move_rollback", !store.moveNote(id: firstID, toIndex: 0))
        _ = store.createNote()
        check("failure_memory_unchanged", store.notes == originalNotes && store.lastAction == originalUndo)
        check("failure_no_transient_publication", publications == 0)
        check("failure_error_visible", store.lastErrorMessage != nil)
        check("failure_ack_still_due", store.dueReminders(at: deadline).map(\.id) == [firstID])
        check("failure_disk_preserved", try Data(contentsOf: preservedURL) == originalBytes)
        try fm.removeItem(at: url)
        try fm.moveItem(at: preservedURL, to: url)
        check("failure_restart_recovery", StickyNotesStore(storageDirectory: directory).notes == originalNotes)
        check("failure_retry_undo", store.undoLastAction() && store.note(id: secondID) != nil)
        check("failure_retry_ack", try store.acknowledgeReminder(noteID: firstID, scheduledAt: deadline, at: deadline))
        check("failure_retry_clears_error", store.lastErrorMessage == nil)
        check("failure_retry_restart", StickyNotesStore(storageDirectory: directory).dueReminders(at: deadline).map(\.id) == [secondID])
    }
}
