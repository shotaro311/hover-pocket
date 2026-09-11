import AppKit
import Foundation

@MainActor
enum StickyReminderPresentationVerification {
    private static var previewController: HoverWindowController?
    private static var previewReminders: StickyReminderController?

    static func run(showPreview: Bool) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HoverPocketStickyReminderVerification-\(UUID().uuidString)")
        let notes = StickyNotesStore(storageDirectory: root.appendingPathComponent("StickyNotes"))
        let timers = TimerStore(storageDirectory: root.appendingPathComponent("Timer"),
            observesWake: false, persistenceEnabled: false)
        var now = Date()
        let initial = now
        let reminders = StickyReminderController(notes: notes, timers: timers,
            clock: { now }, schedulesAutomatically: false, soundEnabled: false)
        defer { reminders.stop() }
        var checks = 0
        func check(_ result: Bool, _ name: String) throws {
            guard result else { throw VoiceFoundationVerificationError.failed(name) }
            checks += 1
        }
        let first = try notes.upsertNote(stableKey: "reminder-first", title: "First", body: "", color: .yellow,
            reminderChange: .set(scheduledAt: initial.addingTimeInterval(10), timeZone: "Asia/Tokyo"), at: initial)
        let second = try notes.upsertNote(stableKey: "reminder-second", title: "Second", body: "", color: .mint,
            reminderChange: .set(scheduledAt: initial.addingTimeInterval(11), timeZone: "Asia/Tokyo"), at: initial)
        reminders.refresh()
        try check(reminders.activeNote == nil, "reminder_not_early")
        now = initial.addingTimeInterval(12)
        reminders.refresh()
        try check(reminders.activeNote?.id == first.id, "reminder_first_due")
        var preset = TimerPreset.defaultTimerDraft()
        preset.duration = 1
        preset.soundEnabled = false
        let firstTimer = timers.start(preset: preset, at: initial)
        let secondTimer = timers.start(preset: preset, at: initial)
        timers.tick(at: now)
        reminders.refresh()
        try check(timers.activeAlert?.id == firstTimer?.id && reminders.activeNote == nil,
            "timer_precedes_reminder_without_losing_it")
        timers.stopAlert()
        reminders.refresh()
        try check(timers.activeAlert?.id == secondTimer?.id && reminders.activeNote == nil,
            "simultaneous_timer_alerts_are_queued")
        timers.stopAlert()
        reminders.refresh()
        try check(reminders.activeNote?.id == first.id, "reminder_resumes_after_timers")
        try check(reminders.acknowledge() && reminders.activeNote?.id == second.id,
            "acknowledge_advances_to_next_reminder")
        let restartedNotes = StickyNotesStore(storageDirectory: root.appendingPathComponent("StickyNotes"))
        let restarted = StickyReminderController(notes: restartedNotes, timers: timers,
            clock: { now }, schedulesAutomatically: false, soundEnabled: false)
        try check(restarted.activeNote?.id == second.id, "restart_restores_only_unacknowledged_reminder")
        restarted.stop()
        try check(notes.archiveNote(id: second.id), "archive_due_note")
        reminders.refresh()
        try check(reminders.activeNote == nil, "archive_cancels_visible_reminder")
        try check(notes.undoLastAction(), "undo_archive")
        reminders.refresh()
        try check(reminders.activeNote?.id == second.id, "undo_restores_unacknowledged_reminder")
        try check(notes.updateNote(id: second.id, title: "Rescheduled", body: "", color: .mint,
            reminderChange: .set(scheduledAt: now.addingTimeInterval(30), timeZone: "Asia/Tokyo"), at: now),
            "reschedule_active_reminder")
        reminders.refresh()
        try check(reminders.activeNote == nil, "reschedule_cancels_old_presentation")
        now = now.addingTimeInterval(31)
        reminders.refresh()
        try check(reminders.activeNote?.id == second.id, "rescheduled_reminder_fires")
        try check(notes.deleteNote(id: second.id), "delete_due_note")
        reminders.refresh()
        try check(reminders.activeNote == nil, "delete_cancels_presentation")
        checks += try await verifyAutomaticScheduling(root: root)
        print("sticky_reminder_presentation=passed checks=\(checks)")

        if showPreview {
            NSApp.setActivationPolicy(.regular)
            let previewRoot = root.appendingPathComponent("Preview")
            let previewNotes = StickyNotesStore(storageDirectory: previewRoot)
            let previewTimers = TimerStore(storageDirectory: root.appendingPathComponent("PreviewTimer"),
                observesWake: false, persistenceEnabled: false)
            let previewReminders = StickyReminderController(notes: previewNotes, timers: previewTimers,
                soundEnabled: !CommandLine.arguments.contains("--silent-preview"))
            _ = try previewNotes.upsertNote(stableKey: "preview-reminder", title: "リマインダーの動作確認",
                body: "この付箋は検証用です。普段の付箋には影響しません。", color: .yellow,
                reminderChange: .set(scheduledAt: Date().addingTimeInterval(20), timeZone: TimeZone.current.identifier))
            let controller = HoverWindowController(settingsDefaults: EphemeralAppSettingsDefaults(),
                providerRegistry: ProviderRegistry(providers: [CalculatorProvider(), StickyNotesProvider(store: previewNotes, reminders: previewReminders)]),
                stickyReminders: previewReminders)
            controller.appSettings.appLanguage = .japanese
            controller.appSettings.voiceEnabled = false
            controller.appSettings.showNotchSideHandleArea = true
            if CommandLine.arguments.contains("--hidden-sticky-preview") {
                controller.appSettings.hiddenProviderRawValues = [StickyNotesProvider.pluginID.rawValue]
            }
            controller.showPill()
            controller.openPanel(showing: StickyNotesProvider.pluginID)
            NSApp.activate(ignoringOtherApps: true)
            self.previewController = controller
            self.previewReminders = previewReminders
            print("sticky_reminder_preview_started isolated=true")
            try await Task.sleep(for: .seconds(300))
            previewReminders.stop()
        }
    }

    private static func verifyAutomaticScheduling(root: URL) async throws -> Int {
        let notes = StickyNotesStore(storageDirectory: root.appendingPathComponent("Automatic"))
        let timers = TimerStore(storageDirectory: root.appendingPathComponent("AutomaticTimer"),
            observesWake: false, persistenceEnabled: false)
        let reminders = StickyReminderController(notes: notes, timers: timers, soundEnabled: false)
        defer { reminders.stop() }
        func waitFor(_ name: String, condition: () -> Bool) async throws {
            for _ in 0..<100 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw VoiceFoundationVerificationError.failed(name)
        }
        let note = try notes.upsertNote(stableKey: "automatic", title: "Automatic", body: "", color: .blue,
            reminderChange: .set(scheduledAt: Date().addingTimeInterval(0.2), timeZone: "UTC"))
        try await waitFor("automatic_deadline_from_store_change") { reminders.activeNote?.id == note.id }
        var preset = TimerPreset.defaultTimerDraft()
        preset.duration = 1
        preset.soundEnabled = false
        _ = timers.start(preset: preset, at: Date().addingTimeInterval(-2))
        timers.tick()
        try await waitFor("automatic_timer_precedence") { reminders.activeNote == nil }
        timers.stopAlert()
        try await waitFor("automatic_resume_after_timer") { reminders.activeNote?.id == note.id }
        guard notes.updateReminder(id: note.id, reminderChange: .clear) else {
            throw VoiceFoundationVerificationError.failed("automatic_clear_saved")
        }
        try await waitFor("automatic_clear_stops_alert") { reminders.activeNote == nil }
        return 4
    }
}
