import AppKit
import AVFoundation
import WebKit

@MainActor
enum LibraryVoiceVerification {
    static func run() async throws {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--asset-evidence"), index + 1 < args.count else {
            throw LibraryError.message("--asset-evidence is required")
        }
        let root = URL(fileURLWithPath: args[index + 1]).appendingPathComponent("voice")
        let store = try AssetLibraryStore(root: root.appendingPathComponent("library"),
            contractRoot: Bundle.main.resourceURL!.appendingPathComponent("AssetLibrary"))
        try await store.start()
        AssetLibraryRuntime.shared.verificationStore = store
        let capture = AssetCaptureController(store: { store }, pendingRoot: root.appendingPathComponent("pending"))
        let targets = VoiceCaptureTargets(allowOwnWindows: true)
        let service = LibraryVoiceService(capture: capture, targets: targets, store: { store })
        let keys = Set(LibraryVoiceOperation.allCases.map(\.key))
        let handlers = try PocketCapabilityHandlerSet(handlers: PocketCapabilityDescriptors.builtIn.filter {
            !keys.contains($0.key)
        }.map { LibraryVerificationStub(key: $0.key) })
        for op in LibraryVoiceOperation.allCases { try handlers.register(LibraryVoiceHandler(op, service: service)) }
        let registry = try CapabilityRegistry(handlers: handlers)
        let broker = CapabilityBroker(registry: registry, ledger: try .init(rootDirectory: root), auditLog: try .init(rootDirectory: root))
        var approve = true, approvals = 0
        var duringApproval: (() -> Void)?
        let runtime = try OpenAIRealtimeMacOSCapabilityRuntime(context: .init(registry: registry, broker: broker),
            library: service, calendarAccessGranted: { false }, approvalHandler: { _ in
                approvals += 1; duringApproval?(); return approve
            })
        let bridge = CodexAppServerCapabilityBridge(runtime: runtime)
        var calls = 0, checks: [String] = []
        func check(_ condition: Bool, _ label: String) throws {
            guard condition else { throw LibraryError.message("FAIL " + label) }
            checks.append(label); print("PASS " + label)
        }
        func call(_ op: LibraryVoiceOperation, _ arguments: CapabilityObject = [:], id: String? = nil,
                  session: String = "library-verify") async throws -> CapabilityObject {
            calls += 1
            let raw = await runtime.execute(sessionID: session, callID: id ?? "call-\(calls)", toolName: op.rawValue,
                argumentsJSON: String(decoding: try CapabilityCanonicalJSON.data(.object(arguments)), as: UTF8.self))
            return try StrictVoiceJSON.object(raw)
        }
        func object(_ value: CapabilityValue?) -> CapabilityObject {
            if case .object(let value)? = value { return value }; return [:]
        }
        func result(_ value: CapabilityObject) -> CapabilityObject { object(value["result"]) }
        func succeeded(_ value: CapabilityObject) -> Bool { value["status"] == .string("succeeded") && value["readback"] == .string("verified") }
        if ProcessInfo.processInfo.environment["HOVERPOCKET_LIBRARY_ACTIONS_ONLY"] == "1" {
            let file = root.appendingPathComponent("retain.txt")
            try Data("original to retain".utf8).write(to: file)
            let id = try await store.importFile(file).assetId!
            try await store.update(ids: [id], operation: "favoriteSet", value: "true")
            let original = try await store.path(store.get(id)!, verifyHash: true)
            let bytes = try Data(contentsOf: original)
            approve = false
            let denied = try await call(.trashAll), afterDenied = try await store.get(id)!
            try check(!succeeded(denied) && !afterDenied.trashed, "denied bulk trash writes nothing")
            approve = true
            try check(succeeded(try await call(.trash, ["assetId": .string(id)])), "single trash has verified readback")
            try check(succeeded(try await call(.search, ["trash": .bool(true)])), "AI can search trash")
            let restored = try await call(.restore, ["assetId": .string(id)]), afterRestore = try await store.get(id)!
            try check(succeeded(restored) && afterRestore.favorite, "restore retains favorite")
            try check(!succeeded(try await call(.trashAll, ["selectionToken": .string("injected")])), "model cannot inject selection token")
            let (bound, _) = try await service.prepare(.trashAll, [:])
            let late = root.appendingPathComponent("later.txt"); try Data("arrived after preparation".utf8).write(to: late)
            let lateID = try await store.importFile(late).assetId!
            let snapshot = try await service.execute(.trashAll, bound)
            let afterLate = try await store.get(lateID)!
            try check(snapshot["moved"] == .integer(1) && !afterLate.trashed, "bulk trash only affects prepared targets")
            try check(try Data(contentsOf: original) == bytes, "original bytes retained after trash and restore")
            let all = try await call(.trashAll, id: "all-once")
            let afterAll = try await store.query(LibraryQuery())
            try check(succeeded(all) && afterAll.total == 0, "bulk trash includes remaining assets")
            try check(try await call(.trashAll, id: "all-once") == all, "bulk replay does not repeat writes")
            print("library_actions_verification=ok checks=\(checks.count) evidence=\(root.path)")
            return
        }
        func fixture(_ title: String, x: CGFloat, color: NSColor) -> NSWindow {
            let window = NSWindow(contentRect: NSRect(x: x, y: 100, width: 440, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
            window.title = title; window.isReleasedWhenClosed = false
            window.backgroundColor = color; window.makeKeyAndOrderFront(nil); return window
        }
        let title = "HoverPocket AI Fixture " + UUID().uuidString.prefix(8)
        let window = fixture(title, x: 60, color: .systemBlue)
        let other = fixture("Other " + title, x: 560, color: .systemRed)
        defer { window.orderOut(nil); other.orderOut(nil) }
        NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .milliseconds(400))
        let tools = try runtime.sessionTools()
        try check(LibraryVoiceOperation.allCases.allSatisfy { op in tools.contains { $0["name"] as? String == op.rawValue } }, "all library tools exposed")
        try check(LibraryVoiceOperation.allCases.allSatisfy { op in bridge.dynamicTools.contains { $0.objectValue?["name"]?.stringValue == op.rawValue } }, "all library tools reach Codex bridge")
        try check(succeeded(try await call(.search, ["text": .string("")])), "empty search text accepted")
        let empty = result(try await call(.search))
        try check(empty["total"] == .integer(0) && approvals == 0, "isolated search is read only")
        try check(!succeeded(try await call(.search, ["limit": .integer(21)])), "query size bounded")
        try check(!succeeded(try await call(.screenshot, ["targetToken": .string("injected")])), "internal capture token cannot be supplied by AI")
        try check(!succeeded(try await call(.folder, ["name": .string(" ")])), "blank name rejected")
        try check(!succeeded(try await call(.open, ["path": .string("/tmp/file")])), "arbitrary file paths rejected")
        approve = false
        try check(!succeeded(try await call(.folder, ["name": .string("Rejected")])), "denied approval writes nothing")
        try check(try await store.query(LibraryQuery()).folders.isEmpty, "rejected folder absent in database")
        approve = true
        let folderReply = try await call(.folder, ["name": .string("AI 資料")], id: "create-once")
        let folderID = object(result(folderReply)["folder"]).text("id")!
        try check(succeeded(folderReply), "folder created after approval")
        let beforeReplay = approvals
        try check(try await call(.folder, ["name": .string("AI 資料")], id: "create-once") == folderReply && approvals == beforeReplay, "call replay does not execute or approve twice")
        try check(object(result(try await call(.folder, ["name": .string("ＡＩ 資料")]))["folder"]).text("id") == folderID, "normalized folder names reuse existing folder")
        let folder2 = object(result(try await call(.folder, ["name": .string("Second")]))["folder"]).text("id")!
        let target = try await targets.resolve(target: "window", windowID: nil, windowTitle: title)
        let targetArgs: CapabilityObject = ["target": .string("window"), "windowId": .string(target.id), "folderId": .string(folderID)]
        try check(succeeded(try await call(.windows, ["query": .string(title)])), "window candidates available")
        let prepared = try await service.prepare(.recordStart, targetArgs).0
        try check(prepared["microphone"] == .bool(false) && prepared["systemAudio"] == .bool(true), "recording defaults honor system setting and keep microphone off")
        duringApproval = { other.makeKeyAndOrderFront(nil) }
        let shot = try await call(.screenshot, targetArgs.merging(["name": .string("音声の画像")]) { _, b in b }, id: "shot-once")
        duringApproval = nil
        try check(succeeded(shot), "approved screenshot saved")
        let assetID = object(result(shot)["asset"]).text("id")!
        let asset = try await store.get(assetID)!, file = try await store.path(asset, verifyHash: true)
        let image = NSBitmapImageRep(data: try Data(contentsOf: file))!
        let pixel = image.colorAt(x: image.pixelsWide / 2, y: image.pixelsHigh / 2)!.usingColorSpace(.deviceRGB)!
        try check(pixel.blueComponent > pixel.redComponent + 0.2, "approval binds the original blue window despite foreground change")
        try check(image.pixelsWide < 1500 && image.pixelsHigh < 1000 && asset.name == "音声の画像.png" && asset.folderIds.contains(folderID), "PNG dimensions, name, folder and hash verified")
        let count = try await store.query(LibraryQuery()).total
        let shotReplay = try await call(.screenshot, targetArgs.merging(["name": .string("音声の画像")]) { _, b in b }, id: "shot-once")
        try check(try await store.query(LibraryQuery()).total == count && shotReplay == shot, "screenshot replay creates no second image")
        try check(!succeeded(try await call(.screenshot, ["target": .string("window"), "windowTitle": .string("missing-" + title)])), "missing window never falls back to screen")
        other.title = title
        try await Task.sleep(for: .milliseconds(100))
        try check(!succeeded(try await call(.screenshot, ["target": .string("window"), "windowTitle": .string(title)])), "ambiguous window rejected")
        other.title = "Other " + title
        duringApproval = { window.title = "Changed " + title }
        try check(!succeeded(try await call(.screenshot, targetArgs)), "changed target during approval rejected")
        duringApproval = nil; window.title = title
        let assetArgs: CapabilityObject = ["assetId": .string(assetID)]
        let favorite = assetArgs.merging(["favorite": .bool(true)]) { _, b in b }
        let favoriteFirst = try await call(.favorite, favorite), favoriteAgain = try await call(.favorite, favorite)
        try check(try await store.get(assetID)?.favorite == true && succeeded(favoriteFirst) && succeeded(favoriteAgain), "favorite is an explicit state, not a toggle")
        let cleared = try await call(.favorite, assetArgs.merging(["favorite": .bool(false)]) { _, b in b })
        try check(try await store.get(assetID)?.favorite == false && succeeded(cleared), "favorite can be cleared")
        let classified = try await call(.classify, assetArgs.merging(["folderId": .string(folder2)]) { _, b in b })
        try check(try await Set(store.get(assetID)!.folderIds) == Set([folderID, folder2]) && succeeded(classified), "classification preserves existing folder memberships")
        let renamed = try await call(.rename, assetArgs.merging(["name": .string("整理した画像")]) { _, b in b })
        try check(try await store.get(assetID)?.name == "整理した画像.png" && succeeded(renamed), "rename preserves extension")
        try check(try AssetLibraryStore.hash(file) == asset.sha256, "metadata edits preserve original file hash")
        try check(result(try await call(.search, ["text": .string("整理した"), "kind": .string("image"), "folderId": .string(folder2)]))["total"] == .integer(1), "search returns updated metadata")
        try check(result(try await call(.search, ["favorites": .bool(true)]))["total"] == .integer(0), "favorite search obeys false state")
        let serialized = String(decoding: try CapabilityCanonicalJSON.data(.object(shot)), as: UTF8.self)
        try check(!serialized.contains(root.path) && !serialized.contains("base64") && !serialized.contains("data:image"), "AI result contains metadata only")
        try check(succeeded(try await call(.open, assetArgs)), "AI opens image in actual library WebView")
        guard let web = AssetLibraryRuntime.shared.organizerPane?.web else { throw LibraryError.message("library WebView missing") }
        try check(try await web.evaluateJavaScript("document.querySelector('.assets-media img').naturalWidth > 0") as? Bool == true, "preview image decoded")
        let recordingArgs = targetArgs.merging(["name": .string("音声の動画"), "systemAudio": .bool(false)]) { _, b in b }
        let started = try await call(.recordStart, recordingArgs)
        try check(succeeded(started) && capture.recording, "real window recording starts")
        let recordingID = capture.recordingID!
        try check(!succeeded(try await call(.recordStart, recordingArgs)) && capture.recordingID == recordingID, "second start does not replace active recording")
        try check(object(result(try await call(.recordStatus))["state"])["recording"] == .bool(true), "recording status reads active recorder")
        try await Task.sleep(for: .seconds(1))
        let oldStop = try await service.prepare(.recordStop, [:]).0
        let beforeStop = approvals
        let stopped = try await call(.recordStop, id: "stop-once")
        try check(succeeded(stopped) && !capture.recording && approvals == beforeStop, "stop saves without confirmation")
        let video = capture.lastRecordingAsset!, videoURL = try await store.path(video, verifyHash: true)
        let media = AVURLAsset(url: videoURL)
        let duration = try await media.load(.duration).seconds
        let tracks = try await media.loadTracks(withMediaType: .audio)
        try check(duration > 0 && tracks.isEmpty && video.name == "音声の動画.mp4", "saved MP4 is playable and contains no microphone/system audio")
        _ = try await AVAssetImageGenerator(asset: media).image(at: .zero)
        try check(true, "saved MP4 frame decodes")
        try check(succeeded(try await call(.open, ["assetId": .string(video.id)])), "AI opens video preview")
        try check(try await web.evaluateJavaScript("document.querySelector('video').paused && !document.querySelector('video').autoplay") as? Bool == true, "AI video preview does not autoplay")
        try check(succeeded(try await call(.recordStart, recordingArgs)), "subsequent recording starts")
        try check(try await call(.recordStop, id: "stop-once") == stopped && capture.recording, "old stop replay cannot stop a new recording")
        var staleRejected = false
        do { _ = try await service.execute(.recordStop, oldStop) } catch { staleRejected = true }
        try check(staleRejected && capture.recording, "stale recording identity rejected")
        try await Task.sleep(for: .seconds(1))
        try check(succeeded(try await call(.recordStop)), "new recording stops with its own identity")
        runtime.cancelSession("cancelled")
        let foldersBeforeCancel = try await store.query(LibraryQuery()).folders.count
        let cancelled = try await call(.folder, ["name": .string("Cancelled")], session: "cancelled")
        try check(try await store.query(LibraryQuery()).folders.count == foldersBeforeCancel && !succeeded(cancelled), "cancelled session cannot write")
        let spoken = try OpenAIRealtimeMacOSCapabilityRuntime(context: .init(registry: registry, broker: broker),
            library: service, calendarAccessGranted: { false })
        let spokenBridge = CodexAppServerCapabilityBridge(runtime: spoken)
        func voice(_ name: String, _ arguments: CapabilityObject = [:], id: String) async throws -> CapabilityObject {
            try StrictVoiceJSON.object(await spoken.execute(sessionID: "spoken-library", callID: id, toolName: name,
                argumentsJSON: String(decoding: try CapabilityCanonicalJSON.data(.object(arguments)), as: UTF8.self)))
        }
        let pending = try await voice("library_folder_create", ["name": .string("Spoken confirmation")], id: "pending-folder")
        try check(pending["status"] == .string("awaiting_confirmation"), "real voice confirmation waits without a native dialog")
        let confirmArgs: CapabilityObject = ["confirmation_id": pending["confirmation_id"]!, "confirmed": .bool(true)]
        try check(!succeeded(try await voice("voice_action_confirm", confirmArgs, id: "too-early")), "same utterance cannot approve its own library change")
        spokenBridge.noteUserInput(sessionID: "spoken-library")
        let confirmed = try await voice("voice_action_confirm", confirmArgs, id: "spoken-confirm")
        let spokenFolder = try await store.query(LibraryQuery()).folders.first { $0.name == "Spoken confirmation" }
        try check(succeeded(confirmed) && spokenFolder != nil, "next spoken reply approves and verifies library write")
        try check(try await voice("voice_action_confirm", confirmArgs, id: "spoken-confirm") == confirmed, "spoken confirmation replay returns the saved result")
        let pendingCancel = try await voice("library_folder_create", ["name": .string("Spoken cancelled")], id: "pending-cancel")
        try check(pendingCancel["status"] == .string("awaiting_confirmation"), "second library change waits for confirmation")
        _ = try await voice("pending_action_cancel", id: "cancel-action")
        spokenBridge.noteUserInput(sessionID: "spoken-library")
        let cancelledConfirm = try await voice("voice_action_confirm", ["confirmation_id": pendingCancel["confirmation_id"]!, "confirmed": .bool(true)], id: "confirm-cancelled")
        let hasCancelledFolder = try await store.query(LibraryQuery()).folders.contains { $0.name == "Spoken cancelled" }
        try check(!succeeded(cancelledConfirm) && !hasCancelledFolder, "spoken cancellation leaves library unchanged")
        let bridgeReply = await bridge.handle(request: .init(id: .string("library-request"), method: "item/tool/call",
            params: .object(["threadId": .string("bridge-library"), "turnId": .string("turn-one"),
                "callId": .string("bridge-search"), "tool": .string("library_search"), "arguments": .object([:])])),
            context: .init(rootThreadID: "bridge-library", clientGeneration: 1))
        try check(bridgeReply.error == nil && bridgeReply.result?.objectValue?["success"] == .bool(true), "Codex dynamic tool request executes library search through Broker")
        let textRuntime = try OpenAIRealtimeMacOSCapabilityRuntime(context: .init(registry: registry, broker: broker),
            library: service, inputOrigin: .text, calendarAccessGranted: { false })
        let textReply = try StrictVoiceJSON.object(await textRuntime.execute(sessionID: "typed-library", callID: "typed-search", toolName: "library_search", argumentsJSON: "{}"))
        let audit = try CapabilityBrokerAuditLog(rootDirectory: root).combinedData()
        let entries = String(decoding: audit, as: UTF8.self).split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        try check(succeeded(textReply) && entries.contains { $0["origin"] as? String == "text" }, "typed library requests retain text origin in Broker readback")
        let report: [String: Any] = ["checks": checks, "count": checks.count, "png": file.path, "mp4": videoURL.path,
            "scope": "isolated runtime, real ScreenCaptureKit and WKWebView; no microphone or external AI connection"]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("report.json"))
        print("PASS library voice: \(checks.count) checks; isolated PNG/MP4, approval, replay, target binding, metadata and real preview")
    }
}

@MainActor
private final class LibraryVerificationStub: PocketCapabilityHandler {
    let key: PocketCapabilityKey
    init(key: PocketCapabilityKey) { self.key = key }
    func handle(arguments: CapabilityObject, context: CapabilityHandlerContext) async throws -> CapabilityObject {
        throw CapabilityHandlerError.unavailable("test_stub")
    }
}
