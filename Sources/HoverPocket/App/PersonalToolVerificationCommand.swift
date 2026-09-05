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
        try check(schemas.count == 24, "all tools exposed")
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
