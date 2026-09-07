import Foundation

@MainActor
enum PersonalToolVerificationCommand {
    static func verifyLiveCalendarRead() async throws {
        let client = GoogleCalendarAPIClient(oauth: GoogleOAuthService())
        let snapshot = try await client.fetchMonth(containing: Date())
        if let event = snapshot.events.first {
            guard let resource = try await client.personalEventResource(calendarID: event.calendarID, eventID: event.googleEventID),
                  case .string? = resource["etag"], case .object? = resource["start"] else {
                throw CapabilityHandlerError.readbackMismatch("live_calendar_read")
            }
            print("PASS personal Calendar live read: resource and revision verified; no writes")
        } else {
            print("SKIP personal Calendar detail: no events in current month; month read passed")
        }
    }

    static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "HoverPocketPersonalVerification-" + UUID().uuidString)
        let timers = TimerStore(
            storageDirectory: root.appendingPathComponent("timer"), observesWake: false)
        let notes = StickyNotesStore(storageDirectory: root.appendingPathComponent("notes"))
        let controls = PersonalVerificationControls()
        let clock = Date(timeIntervalSince1970: 1_788_600_000)
        let first = try notes.upsertNote(
            stableKey: "test.first", title: "買い物", body: "卵\nパン", color: .yellow, at: clock)
        let second = try notes.upsertNote(
            stableKey: "test.second", title: "買い物", body: "石鹸", color: .blue,
            at: clock.addingTimeInterval(1))
        var preset = TimerPreset.defaultTimerDraft()
        preset.duration = 600
        preset.title = "料理"
        let timer = timers.start(preset: preset, at: clock)!
        let confirmationEnabled = PersonalVerificationFlag()
        var calendarGranted = true
        var reject = false
        var editDuringApproval = false
        var revokeDuringApproval = false
        var waitDuringApproval = false
        var enteredWait = false
        var approvals = 0
        var calendarWrites = 0
        var clipboardReads = 0
        let handlers = try PocketCapabilityHandlerSet(
            handlers: PocketCapabilityDescriptors.builtIn.filter {
                !PersonalToolOperation.allCases.map(\.key).contains($0.key)
            }.map { PersonalVerificationStub(key: $0.key) })
        for operation in PersonalToolOperation.allCases {
            try handlers.register(
                PersonalToolCapabilityHandler(
                    operation: operation, timers: timers, notes: notes, controls: controls,
                    clipboard: {
                        clipboardReads += 1
                        return "打ち合わせ\n明日15時"
                    },
                    calendar: { op, _ in
                        if op == .calendarSearch {
                            return [
                                "items": .array([
                                    .object([
                                        "targetId": .string("calendar:event"),
                                        "title": .string("打ち合わせ"),
                                    ])
                                ])
                            ]
                        }
                        if op.isWrite { calendarWrites += 1 }
                        return [
                            "targetId": .string("calendar:event"), "revision": .string("version-1"),
                            "title": .string("打ち合わせ"),
                        ]
                    }))
        }
        let registry = try CapabilityRegistry(handlers: handlers)
        let broker = CapabilityBroker(
            registry: registry, ledger: try .init(rootDirectory: root),
            auditLog: try .init(rootDirectory: root),
            approvalPresentationResolver: HostCapabilityApprovalPresentationResolver(
                stickyStore: notes, timerStore: timers,
                calendarLabel: { _, _ in "打ち合わせ" }))
        let runtime = try OpenAIRealtimeMacOSCapabilityRuntime(
            context: .init(registry: registry, broker: broker),
            calendarAccessGranted: { calendarGranted }, actionConfirmationEnabled: { confirmationEnabled.value },
            now: { clock },
            approvalHandler: { _ in
                approvals += 1
                if waitDuringApproval {
                    enteredWait = true
                    while waitDuringApproval && !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(10))
                    }
                }
                if editDuringApproval {
                    try? notes.editForCapability(
                        id: first.id, title: "他の画面からの変更", body: nil, color: nil,
                        at: clock.addingTimeInterval(5)
                    )
                }
                if revokeDuringApproval { calendarGranted = false }
                return !reject
            })
        var calls = 0
        func call(
            _ op: PersonalToolOperation, _ args: CapabilityObject = [:],
            session: String = "verify-main",
            callID: String? = nil
        ) async throws -> CapabilityObject {
            calls += 1
            let output = await runtime.execute(
                sessionID: session, callID: callID ?? "call-\(calls)", toolName: op.rawValue,
                argumentsJSON: String(
                    decoding: try CapabilityCanonicalJSON.data(.object(args)), as: UTF8.self))
            return try StrictVoiceJSON.object(output)
        }
        var assertions = 0
        func check(_ condition: Bool, _ label: String) throws {
            guard condition else {
                throw NSError(
                    domain: "PersonalToolVerification", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: label])
            }
            assertions += 1
        }
        func succeeded(_ value: CapabilityObject) -> Bool {
            value["status"] == .string("succeeded")
        }
        func result(_ value: CapabilityObject) -> CapabilityObject {
            if case .object(let value)? = value["result"] { return value }
            return [:]
        }
        if Bundle.main.bundleURL.pathExtension == "app" {
            try check(Bundle.hoverPocketResources.bundleURL.path.hasPrefix(Bundle.main.bundleURL.path + "/"), "packaged resources do not depend on checkout")
        }
        let schemas = try runtime.sessionTools()
        try check(schemas.count == 25, "all tools exposed")
        try check(clipboardReads == 0, "no passive clipboard access")
        try check(
            !succeeded(
                try await call(
                    .stickyDelete, ["targetId": .string(first.id.uuidString.lowercased())])),
            "unknown target rejected")
        let listed = result(try await call(.stickyList))
        try check(listed["total"] == .integer(2), "duplicate titles return candidates")
        let id = first.id.uuidString.lowercased()
        let read = result(try await call(.stickyGet, ["targetId": .string(id)]))
        try check(read["body"] == .string("卵\nパン"), "full note preserves paragraphs")
        try check(
            !succeeded(try await call(.stickyGet, ["targetId": .string(id)], session: "other")),
            "target knowledge isolated")
        try check(
            succeeded(
                try await call(
                    .stickyEdit, ["targetId": .string(id), "body": .string("卵\nパン\n牛乳")])),
            "edit existing note")
        try check(
            notes.notes.count == 2 && notes.note(id: first.id)?.body == "卵\nパン\n牛乳"
                && notes.note(id: second.id)?.body == "石鹸",
            "no replacement note or other-target edit")
        let restored = StickyNotesStore(storageDirectory: root.appendingPathComponent("notes"))
        try check(restored.note(id: first.id)?.body == "卵\nパン\n牛乳", "note edit persists")
        editDuringApproval = true
        try check(
            !succeeded(
                try await call(.stickyEdit, ["targetId": .string(id), "body": .string("古い編集")])),
            "stale note rejected")
        editDuringApproval = false
        confirmationEnabled.value = false
        let approvalsBeforeRejectedDelete = approvals
        reject = true
        try check(
            !succeeded(try await call(.stickyDelete, ["targetId": .string(id)]))
                && notes.note(id: first.id) != nil, "delete rejection writes nothing")
        try check(approvals == approvalsBeforeRejectedDelete + 1, "delete still confirms with confirmation OFF")
        confirmationEnabled.value = true
        reject = false
        try check(
            succeeded(
                try await call(.stickyDelete, ["targetId": .string(id)], callID: "same-delete")),
            "delete succeeds")
        let approvalsAfterDelete = approvals
        try check(
            succeeded(
                try await call(.stickyDelete, ["targetId": .string(id)], callID: "same-delete"))
                && approvals == approvalsAfterDelete, "replay does not delete again")
        try check(
            notes.undoLastAction() && notes.note(id: first.id) != nil,
            "delete supports existing undo")
        _ = try await call(.timerList)
        let tid = timer.id.uuidString.lowercased()
        try check(
            result(try await call(.timerGet, ["targetId": .string(tid)]))["remainingSeconds"]
                == .integer(600), "remaining time")
        try check(succeeded(try await call(.timerPause, ["targetId": .string(tid)])), "pause")
        try check(
            succeeded(
                try await call(
                    .timerEdit,
                    [
                        "targetId": .string(tid), "remainingSeconds": .integer(900),
                        "title": .string("夕食"),
                    ])),
            "extend and rename")
        try check(
            timers.runningTimer(id: timer.id)?.pausedRemaining == 900,
            "paused extension stays paused")
        try check(succeeded(try await call(.timerEdit, ["targetId": .string(tid), "deltaSeconds": .integer(-120)])) && timers.runningTimer(id: timer.id)?.pausedRemaining == 780, "relative shortening")
        try check(!succeeded(try await call(.timerEdit, ["targetId": .string(tid), "deltaSeconds": .integer(30), "remainingSeconds": .integer(50)])), "absolute and relative time conflict rejected")
        try check(!succeeded(try await call(.timerEdit, ["targetId": .string(tid), "deltaSeconds": .integer(-86400), "title": .string("変わってはいけない")] )) && timers.runningTimer(id: timer.id)?.title == "夕食", "invalid duration leaves all fields unchanged")
        try check(
            succeeded(try await call(.timerResume, ["targetId": .string(tid)]))
                && timers.runningTimer(id: timer.id)?.isPaused == false, "resume")
        try check(
            succeeded(try await call(.timerStop, ["targetId": .string(tid)]))
                && timers.runningTimers.isEmpty, "cancel removes timer")
        try check(
            succeeded(try await call(.mediaSet, ["action": .string("pause")]))
                && controls.commands.isEmpty, "pause does not start stopped media")
        try check(
            succeeded(try await call(.mediaSet, ["action": .string("play")]))
                && controls.media.isPlaying,
            "play")
        try check(
            succeeded(try await call(.mediaSet, ["action": .string("pause")]))
                && !controls.media.isPlaying, "pause playing media")
        try check(
            result(try await call(.clipboardRead))["text"] == .string("打ち合わせ\n明日15時")
                && clipboardReads == 1, "explicit clipboard read")
        _ = try await call(
            .calendarSearch,
            [
                "start": .string("2026-09-05T00:00:00+09:00"),
                "end": .string("2026-09-06T00:00:00+09:00"),
            ])
        revokeDuringApproval = true
        try check(
            !succeeded(
                try await call(
                    .calendarEdit, ["targetId": .string("calendar:event"), "title": .string("変更")]))
                && calendarWrites == 0, "calendar revocation during approval")
        revokeDuringApproval = false
        try check(
            !runtime.sessionTools().contains {
                ($0["name"] as? String)?.hasPrefix("calendar_") == true
            },
            "calendar tools disappear after revoke")
        calendarGranted = true
        waitDuringApproval = true
        let pending = Task {
            try await call(.stickyEdit, ["targetId": .string(id), "body": .string("取り消す変更")])
        }
        for _ in 0..<100 where !enteredWait { try await Task.sleep(for: .milliseconds(10)) }
        try check(enteredWait, "confirmation pending")
        let cancelled = try StrictVoiceJSON.object(
            await runtime.execute(
                sessionID: "verify-main", callID: "cancel-pending",
                toolName: "pending_action_cancel",
                argumentsJSON: "{}"))
        try check(cancelled["cancelledPendingAction"] == .bool(true), "cancel pending command")
        waitDuringApproval = false
        try check(
            !succeeded(try await pending.value) && notes.note(id: first.id)?.body != "取り消す変更",
            "pending cancellation writes nothing")
        try check(
            succeeded(try await call(.stickyGet, ["targetId": .string(id)])),
            "conversation continues after cancelling action")

        let event: CapabilityObject = [
            "summary": .string("会議"), "location": .string("会議室"),
            "start": .object(["dateTime": .string("2026-09-05T15:00:00+09:00")]),
            "end": .object(["dateTime": .string("2026-09-05T16:00:00+09:00")]),
        ]
        let patch = try PersonalCalendarEditing.patch(
            arguments: ["title": .string("打合せ")], before: event)
        try check(patch == ["summary": .string("打合せ")], "calendar preserves omitted fields")
        let moved = try PersonalCalendarEditing.patch(
            arguments: ["start": .string("2026-09-05T15:30:00+09:00")], before: event)
        try check(moved["end"] == event["end"], "calendar preserves end when editing start")
        var invalidIntervalRejected = false
        do {
            _ = try PersonalCalendarEditing.patch(
                arguments: ["start": .string("2026-09-05T18:00:00+09:00")], before: event)
        } catch { invalidIntervalRejected = true }
        try check(invalidIntervalRejected, "invalid interval rejected")
        let allDay = try PersonalCalendarEditing.patch(
            arguments: [
                "isAllDay": .bool(true), "start": .string("2026-09-05"),
                "end": .string("2026-09-06"),
            ], before: event)
        try check(
            allDay["end"] == .object(["date": .string("2026-09-06")]), "all-day exclusive end")
        try PersonalCalendarEditing.verify(
            patch: ["start": .object(["dateTime": .string("2026-09-05T15:00:00+09:00")])],
            observed: ["start": .object(["dateTime": .string("2026-09-05T06:00:00Z")])])
        assertions += 1
        var mismatched = false
        do {
            try PersonalCalendarEditing.verify(
                patch: ["summary": .string("新")], observed: ["summary": .string("旧")])
        } catch { mismatched = true }
        try check(mismatched, "calendar readback mismatch rejected")
        runtime.cancelSession("verify-main")
        try check(
            !succeeded(try await call(.clipboardRead)) && clipboardReads == 1,
            "cancelled session cannot read")
        print(
            "PASS personal tools: \(assertions) assertions; isolated stores, no live Calendar or media writes"
        )
    }
}

@MainActor
private final class PersonalVerificationStub: PocketCapabilityHandler {
    let key: PocketCapabilityKey
    init(key: PocketCapabilityKey) { self.key = key }
    func handle(arguments: CapabilityObject, context: CapabilityHandlerContext) async throws
        -> CapabilityObject
    { throw CapabilityHandlerError.unavailable("test_stub") }
}

@MainActor
private final class PersonalVerificationControls: ControlsCapabilityDataSource {
    var media: ControlsNowPlayingState = {
        var value = ControlsNowPlayingState.empty
        value.hasMedia = true
        value.title = "曲"
        value.sourceName = "テスト"
        return value
    }()
    var commands: [String] = []
    func snapshot() async throws -> ControlsCapabilitySnapshot {
        .init(displays: [], volume: .empty, volumeAvailable: false, media: media)
    }
    func setVolume(_ level: Double) async throws -> ControlsVolumeState { .empty }
    func setMuted(_ muted: Bool) async throws -> ControlsVolumeState { .empty }
    func setBrightness(_ level: Double, displayID: String) async throws -> ControlsDisplay {
        throw CapabilityHandlerError.unavailable("display")
    }
    func executeMediaCommand(_ command: String) async throws -> ControlsNowPlayingState {
        commands.append(command)
        if command == "play_pause" { media.isPlaying.toggle() } else { media.title += "次" }
        return media
    }
}

@MainActor
private final class PersonalVerificationFlag { var value = true }

@MainActor
enum VoiceOnlyVerificationCommand {
    static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceOnlyVerification-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let timers = TimerStore(storageDirectory: root.appendingPathComponent("Timer"), observesWake: false)
        let notes = StickyNotesStore(storageDirectory: root.appendingPathComponent("Notes"))
        let controls = PersonalVerificationControls()
        var clock = Date()
        let normal = PersonalVerificationFlag(), destructive = PersonalVerificationFlag()
        normal.value = false
        let personalKeys = Set(PersonalToolOperation.allCases.map(\.key))
        let realKeys: Set<PocketCapabilityKey> = [.init(id: "timer.countdown.start", version: 1), .init(id: "timer.countdown.get", version: 1), .init(id: "sticky.note.upsert", version: 1), .init(id: "sticky.note.get", version: 1)]
        let handlers = try PocketCapabilityHandlerSet(handlers: PocketCapabilityDescriptors.builtIn.filter {
            !personalKeys.contains($0.key) && !realKeys.contains($0.key)
        }.map { PersonalVerificationStub(key: $0.key) })
        for handler: any PocketCapabilityHandler in [
            TimerCapabilityHandler(operation: .start, store: timers), TimerCapabilityHandler(operation: .get, store: timers),
            StickyCapabilityHandler(operation: .upsert, store: notes), StickyCapabilityHandler(operation: .get, store: notes)
        ] { try handlers.register(handler) }
        var calendarGranted = true
        var calendarWrites = 0
        for operation in PersonalToolOperation.allCases {
            try handlers.register(PersonalToolCapabilityHandler(operation: operation, timers: timers, notes: notes,
                controls: controls, clipboard: { "確認" }, calendar: { operation, _ in
                    if operation == .calendarSearch {
                        return ["items": .array([.object(["targetId": .string("calendar:isolated"), "title": .string("隔離予定")])])]
                    }
                    if operation.isWrite { calendarWrites += 1 }
                    return ["targetId": .string("calendar:isolated"), "revision": .string("revision-1"), "title": .string("隔離予定")]
                }))
        }
        let registry = try CapabilityRegistry(handlers: handlers)
        let broker = CapabilityBroker(registry: registry, ledger: try .init(rootDirectory: root.appendingPathComponent("Broker")),
            auditLog: try .init(rootDirectory: root.appendingPathComponent("Broker")),
            approvalPresentationResolver: HostCapabilityApprovalPresentationResolver(stickyStore: notes, timerStore: timers, calendarLabel: { _, _ in "隔離予定" }))
        let runtime = try OpenAIRealtimeMacOSCapabilityRuntime(context: .init(registry: registry, broker: broker),
            calendarAccessGranted: { calendarGranted }, actionConfirmationEnabled: { normal.value },
            destructiveConfirmationEnabled: { destructive.value }, now: { clock })
        defer { runtime.cancelSession("voice-only") }
        let bridge = CodexAppServerCapabilityBridge(runtime: runtime)
        var calls = 0, checks = 0
        func check(_ value: Bool, _ name: String) throws {
            guard value else { throw PocketPreviewValidationError(code: "voice_only_" + name) }
            checks += 1
        }
        func call(_ name: String, _ args: CapabilityObject = [:], id: String? = nil, session: String = "voice-only") async throws -> CapabilityObject {
            calls += 1
            let raw = await runtime.execute(sessionID: session, callID: id ?? "call-\(calls)", toolName: name,
                argumentsJSON: String(decoding: try CapabilityCanonicalJSON.data(.object(args)), as: UTF8.self))
            return try StrictVoiceJSON.object(raw)
        }
        func confirm(_ pending: CapabilityObject, id: String? = nil, session: String = "voice-only") async throws -> CapabilityObject {
            try await call("voice_action_confirm", ["confirmation_id": pending["confirmation_id"] ?? .string("missing"), "confirmed": .bool(true)], id: id, session: session)
        }
        func seed(_ key: String) throws -> StickyNoteItem {
            try notes.upsertNote(stableKey: key, title: "確認用 " + key, body: "保持する本文", color: .yellow, at: clock)
        }
        let defaults = EphemeralAppSettingsDefaults()
        defaults.set(false, forKey: "voiceActionConfirmationEnabled")
        let settings = AppSettings(defaults: defaults)
        try check(!settings.voiceActionConfirmationEnabled && settings.voiceDestructiveConfirmationEnabled, "legacy_setting_preserved")
        settings.voiceDestructiveConfirmationEnabled = false
        try check(!AppSettings(defaults: defaults).voiceDestructiveConfirmationEnabled, "delete_setting_persisted")
        let target = try seed("first")
        let targetArgs: CapabilityObject = ["targetId": .string(target.id.uuidString.lowercased())]
        try check(try await call("sticky_note_delete", targetArgs)["code"] == .string("unknown_target"), "unknown_delete_rejected")
        _ = try await call("sticky_notes_list")
        try check(try await call("sticky_note_edit", targetArgs.merging(["title": .string("音声だけで変更")]) { _, new in new })["status"] == .string("succeeded"), "normal_off_no_confirmation")
        let pending = try await call("sticky_note_delete", targetArgs, id: "pending-delete")
        try check(pending["status"] == .string("awaiting_confirmation") && notes.note(id: target.id) != nil, "delete_waits_without_dialog")
        try check(try await call("sticky_note_delete", targetArgs, id: "pending-delete") == pending, "pending_replay_returns_same_id")
        try check(try await confirm(pending)["code"] == .string("confirmation_mismatch"), "same_utterance_cannot_confirm")
        bridge.noteUserInput(sessionID: "other")
        try check(try await confirm(pending, session: "other")["code"] == .string("confirmation_mismatch"), "other_session_cannot_confirm")
        try check(try await call("clipboard_text_read")["status"] == .string("succeeded"), "reads_during_confirmation")
        bridge.noteUserInput(sessionID: "voice-only")
        try check(try await confirm(pending, id: "confirm-once")["readback"] == .string("verified") && notes.note(id: target.id) == nil, "spoken_confirmation_deletes_and_verifies")
        try check(try await confirm(pending, id: "confirm-once")["status"] == .string("succeeded"), "confirmation_replay_no_duplicate")
        try check(try await confirm(pending)["code"] == .string("confirmation_mismatch"), "consumed_id_rejected")

        let changed = try seed("changed")
        _ = try await call("sticky_notes_list")
        let changedArgs: CapabilityObject = ["targetId": .string(changed.id.uuidString.lowercased())]
        let stale = try await call("sticky_note_delete", changedArgs)
        _ = try notes.editForCapability(id: changed.id, title: "別画面から変更", body: nil, color: nil, at: clock.addingTimeInterval(1))
        bridge.noteUserInput(sessionID: "voice-only")
        try check(try await confirm(stale)["status"] == .string("failed") && notes.note(id: changed.id)?.title == "別画面から変更", "stale_revision_keeps_new_data")
        let cancelled = try await call("sticky_note_delete", changedArgs)
        try check(try await call("pending_action_cancel")["cancelledPendingAction"] == .bool(true), "spoken_cancel")
        await Task.yield()
        bridge.noteUserInput(sessionID: "voice-only")
        try check(try await confirm(cancelled)["status"] == .string("failed") && notes.note(id: changed.id) != nil, "cancelled_id_cannot_execute")
        let expired = try await call("sticky_note_delete", changedArgs)
        clock = clock.addingTimeInterval(301)
        bridge.noteUserInput(sessionID: "voice-only")
        try check(try await confirm(expired)["status"] == .string("failed") && notes.note(id: changed.id) != nil, "expired_id_cannot_execute")
        await Task.yield()

        destructive.value = false
        normal.value = true
        try check(try await call("sticky_note_delete", changedArgs)["readback"] == .string("verified") && notes.note(id: changed.id) == nil, "delete_off_independent_of_normal_on")
        let creation = try await call("timer_countdown_start", ["durationSeconds": .integer(60), "title": .string("音声承認")])
        try check(creation["status"] == .string("awaiting_confirmation") && timers.runningTimers.isEmpty, "normal_on_awaits_voice")
        bridge.noteUserInput(sessionID: "voice-only")
        try check(try await confirm(creation)["readback"] == .string("verified") && timers.runningTimers.count == 1, "timer_voice_approval_readback")
        normal.value = false
        _ = try await call("timer_countdown_list")
        let timerID = timers.runningTimers[0].id.uuidString.lowercased()
        try check(try await call("timer_countdown_cancel", ["targetId": .string(timerID)])["readback"] == .string("verified") && timers.runningTimers.isEmpty, "both_off_timer_cancel")
        _ = try await call("calendar_events_search", ["start": .string("2026-09-07T00:00:00+09:00"), "end": .string("2026-09-08T00:00:00+09:00")])
        try check(try await call("calendar_event_delete", ["targetId": .string("calendar:isolated")])["status"] == .string("succeeded") && calendarWrites == 1, "both_off_calendar_delete")
        destructive.value = true
        let revoked = try await call("calendar_event_delete", ["targetId": .string("calendar:isolated")])
        calendarGranted = false
        bridge.noteUserInput(sessionID: "voice-only")
        try check(try await confirm(revoked)["status"] == .string("failed") && calendarWrites == 1, "calendar_revoked_while_waiting")
        let disconnected = try seed("disconnect")
        _ = try await call("sticky_notes_list")
        let disconnectedPending = try await call("sticky_note_delete", ["targetId": .string(disconnected.id.uuidString.lowercased())])
        bridge.conversationDidDisconnect(sessionID: "voice-only")
        await Task.yield()
        bridge.noteUserInput(sessionID: "voice-only")
        try check(try await confirm(disconnectedPending)["status"] == .string("failed") && notes.note(id: disconnected.id) != nil, "disconnect_invalidates_confirmation")
        print("PASS voice-only confirmation: \(checks) checks; independent normal/delete settings, no native presenter, speech approval/cancel, replay, session/revision/expiry binding, real isolated writes and readback")
    }
}
