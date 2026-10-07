import AppKit
import Combine
import WebKit

@MainActor
final class AssetPaneModel: NSObject, ObservableObject, WKScriptMessageHandlerWithReply, WKNavigationDelegate, NSWindowDelegate {
    @Published var editor: AssetEditorSession?
    weak var web: AssetNativeWebView?
    var organizer = false
    var active = true
    private var organizerPlacement: (NSRect, NSWindow.StyleMask, NSWindow.Level)?
    var organizerIsFullscreen: Bool { organizerPlacement != nil }
    private var revision = 0
    private var mediaSize = CGSize(width: 800, height: 600)
    private let mediaScheme = AssetMediaScheme()
    private var cancellables = Set<AnyCancellable>()
    private var importTask: Task<Void, Never>?
    private var importProgress: [String: Any] = [:]
    private let runtime = AssetLibraryRuntime.shared

    override init() {
        super.init()
        NotificationCenter.default.publisher(for: AssetLibraryRuntime.changed).sink { [weak self] _ in
            Task { @MainActor in self?.event("assets.changed") }
        }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: AssetLibraryRuntime.closed).sink { [weak self] _ in
            Task { @MainActor in if self?.organizer == false { self?.invalidatePreview() } }
        }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: Notification.Name("HoverPocket.assets.drop")).sink { [weak self] _ in
            Task { @MainActor in self?.consumeDrop() }
        }.store(in: &cancellables)
    }
    func configuration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "assets")
        config.setURLSchemeHandler(mediaScheme, forURLScheme: "hpasset")
        config.mediaTypesRequiringUserActionForPlayback = [.audio, .video]
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        if CommandLine.arguments.contains("--verify-asset-ui") {
            config.userContentController.addUserScript(WKUserScript(source: "window.assetErrors=[];addEventListener('error',e=>assetErrors.push(e.message));addEventListener('unhandledrejection',e=>assetErrors.push(String(e.reason)));addEventListener('securitypolicyviolation',e=>assetErrors.push(e.violatedDirective+':'+e.blockedURI));", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        return config
    }
    func event(_ name: String, _ data: Any = [String: String]()) {
        guard let encoded = try? JSONSerialization.data(withJSONObject: [name, data]),
              let json = String(data: encoded, encoding: .utf8) else { return }
        web?.evaluateJavaScript("window.assetEvent?.(...\(json))", completionHandler: nil)
    }
    func invalidatePreview() {
        if organizer { setOrganizerFullscreen(false) }
        revision += 1; mediaScheme.revoke(); event("assets.previewEnded")
    }
    private func setOrganizerFullscreen(_ value: Bool) {
        guard let window = web?.window else { return }
        if value, organizerPlacement == nil, let screen = window.screen {
            organizerPlacement = (window.frame, window.styleMask, window.level)
            window.styleMask = [.borderless]; window.level = .statusBar
            window.setFrame(screen.frame, display: true)
            window.makeKeyAndOrderFront(nil)
        } else if !value, let previous = organizerPlacement {
            organizerPlacement = nil; window.styleMask = previous.1; window.level = previous.2
            window.setFrame(previous.0, display: true)
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let editor, !editor.cancel() { return false }
        invalidatePreview(); return true
    }
    func setActive(_ value: Bool) {
        guard active != value else { return }; active = value
        if value { event("panel.opened") }
        else if editor == nil { invalidatePreview(); event("panel.closed"); if !organizer { runtime.endPreview() } }
    }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any], let method = body["method"] as? String,
              web?.url?.isFileURL == true else { replyHandler(nil, "無効な素材操作です。"); return }
        let params = body["params"] as? [String: Any] ?? [:]
        Task { @MainActor in
            do { replyHandler(try await request(method, params), nil) }
            catch { replyHandler(nil, error.localizedDescription) }
        }
    }
    private func json<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
    private func decode<T: Decodable>(_ value: Any, as: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: value))
    }
    private func text(_ params: [String: Any], _ key: String) throws -> String {
        guard let value = params[key] as? String else { throw LibraryError.message("操作の値がありません。") }; return value
    }
    private func pinned<T>(_ action: () async throws -> T) async rethrows -> T {
        runtime.holdCount += 1; defer { runtime.holdCount -= 1 }
        return try await action()
    }
    private func confirm(_ text: String) -> Bool {
        let alert = NSAlert(); alert.messageText = text
        alert.addButton(withTitle: "続ける"); alert.addButton(withTitle: "キャンセル")
        return alert.runModal() == .alertFirstButtonReturn
    }
    func request(_ method: String, _ p: [String: Any]) async throws -> Any {
        if method == "assets.ready" { consumeDrop(); return ["ok": true] }
        if method == "panel.beginTextInput" { if !organizer, p["editing"] as? Bool == true { runtime.textInput = true }; return ["ok": true] }
        if method == "panel.endTextInput" { runtime.textInput = false; return ["ok": true] }
        if method == "assets.transition" { return ["revision": revision] }
        if method == "assets.visibility" { return ["ok": true] }
        if method == "assets.endPreview" {
            invalidatePreview(); if !organizer { runtime.panelSize = nil; runtime.fullscreen = false; runtime.onLayout?() }; return ["ok": true]
        }
        if method == "assets.layout" {
            guard active else { return ["cancelled": true] }
            if organizer { setOrganizerFullscreen(p["fullscreen"] as? Bool ?? false) }
            else if let screen = web?.window?.screen ?? NSScreen.main {
                runtime.textInput = false
                runtime.setLayout(media: mediaSize, fullscreen: p["fullscreen"] as? Bool ?? false, screen: screen, baseline: runtime.baselineSize?() ?? CGSize(width: 600, height: 430))
            }
            return ["ok": true]
        }
        if method == "assets.openOrganizer" { runtime.showOrganizer(); return ["ok": true] }
        if method == "assets.organizer" { return ["ok": true] }
        if method == "assets.importState" { return importProgress }
        if method == "assets.cancelImport" { importTask?.cancel(); return ["ok": true] }
        if method == "assets.capture" {
            let kind = p["kind"] as? String ?? "screenshot"
            if ["cameraPhoto", "cameraVideo", "audio"].contains(kind) { AssetDeviceCapture.shared.show(kind: kind, folder: p["folderId"] as? String) }
            else if kind == "regionRecording" { await AssetCaptureController.shared.toggleRegionRecording(folder: p["folderId"] as? String) }
            else if kind == "recording" { await AssetCaptureController.shared.toggleRecording(folder: p["folderId"] as? String) }
            else { await AssetCaptureController.shared.screenshot(folder: p["folderId"] as? String) }
            return ["ok": true]
        }
        let store = try await runtime.store()
        switch method {
        case "assets.dragTargets": web?.updateDropTargets(p["dropTargets"] as? [[String: Any]] ?? []); return ["ok": true]
        case "assets.status": return ["warning": await store.notice ?? ""]
        case "assets.query": return try json(await store.query(decode(p, as: LibraryQuery.self)))
        case "assets.matches": return try ["matches": await store.matches(text(p, "id"), query: decode(p["query"] ?? [:], as: LibraryQuery.self))]
        case "assets.selectionRange": return try ["ids": await store.range(decode(p["query"] ?? [:], as: LibraryQuery.self), anchor: text(p, "anchorId"), target: text(p, "targetId"))]
        case "assets.update":
            if p["operation"] as? String == "organize" {
                guard let destination = p["destination"] as? [String: Any] else { throw LibraryError.message("移動先がありません。") }
                let token = try await store.organize(ids: p["ids"] as? [String] ?? [], destination: text(destination, "kind"),
                    folderId: destination["folderId"] as? String, sourceFolderId: p["sourceFolderId"] as? String)
                runtime.notifyChange(); return ["ok": true, "undoToken": token]
            } else if p["operation"] as? String == "undoOrganize" {
                try await store.undoOrganize(token: text(p, "undoToken"))
            } else {
                try await store.update(ids: p["ids"] as? [String] ?? [], operation: text(p, "operation"), value: p["value"] as? String)
            }
            runtime.notifyChange(); return ["ok": true]
        case "assets.undo": try await store.undoLast(); runtime.notifyChange(); return ["ok": true]
        case "assets.category":
            let id = try await store.category(type: text(p, "type"), name: text(p, "name"), parent: p["parentId"] as? String)
            runtime.notifyChange(); return ["id": id]
        case "assets.categoryUpdate":
            try await store.changeCategory(id: text(p, "id"), operation: text(p, "operation"), name: p["name"] as? String, parent: p["parentId"] as? String)
            runtime.notifyChange(); return ["ok": true]
        case "assets.saveSearch": try await store.saveSearch(name: text(p, "name"), query: decode(p["filter"] ?? [:], as: LibraryQuery.self)); return ["ok": true]
        case "assets.thumbnail", "assets.preview":
            let isPreview = method == "assets.preview"
            if isPreview { revision += 1 }
            let current = revision
            guard let a = try await store.get(text(p, "id")) else { throw LibraryError.message("素材がありません。") }
            let url = try await store.readPath(a)
            var frame = await AssetMedia.frame(a, url: url, page: p["page"] as? Int ?? 1, thumbnail: !isPreview)
            if isPreview {
                guard current == revision, active else { return ["cancelled": true] }
                mediaScheme.revoke()
                if a.kind == "video" { frame.videoUrl = mediaScheme.lease(url) }
                else if AssetMedia.audioExtensions.contains(a.extension) { frame.audioUrl = mediaScheme.lease(url); frame.width = 500; frame.height = 120 }
                mediaSize = CGSize(width: max(1, frame.width), height: max(1, frame.height))
            }
            return try json(frame)
        case "assets.pick":
            return await pinned {
                let panel = NSOpenPanel(); panel.allowsMultipleSelection = true
                panel.canChooseDirectories = p["kind"] as? String == "folder"; panel.canChooseFiles = !panel.canChooseDirectories
                if panel.runModal() == .OK { importURLs(panel.urls) }
                return ["ok": true]
            }
        case "assets.clipboard":
            let board = NSPasteboard.general
            if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty { importURLs(urls) }
            else if let image = NSImage(pasteboard: board), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("HoverPocket-Paste-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = folder.appendingPathComponent("貼り付け.png"); try AssetMedia.png(cg).write(to: url)
                importURLs([url.resolvingSymlinksInPath()])
            } else { throw LibraryError.message("コピーした画像またはファイルがありません。") }
            return ["ok": true]
        case "assets.copy":
            let id = try text(p, "id"), ids = p["ids"] as? [String] ?? [id], mode = p["mode"] as? String ?? "copy"
            return try await pinned {
                if mode == "save" {
                    let panel = NSSavePanel(); panel.nameFieldStringValue = try await store.get(id)?.name ?? "素材"
                    guard panel.runModal() == .OK, let url = panel.url else { return ["cancelled": true] }
                    _ = try await store.copyOut(id, destination: url); return ["ok": true]
                }
                if mode == "drag" {
                    var copies: [AssetDragCopy] = []
                    for id in ids { copies.append(try await store.prepareDragCopy(id)) }
                    guard let web, web.canStartFileDrag else { return ["ok": false] }
                    let result = await web.startFileDrag(copies, trashBounds: p["trashBounds"] as? [String: Double], dropTargets: p["dropTargets"] as? [[String: Any]] ?? [])
                    return ["ok": result.0, "droppedInTrash": result.1?["kind"] == "trash", "dropTarget": result.1 as Any? ?? NSNull()]
                }
                var urls: [URL] = []
                for id in ids { urls.append(try await store.copyOut(id)) }
                if mode == "open", let url = urls.first {
                    if ["exe", "com", "bat", "cmd", "ps1", "sh", "command", "app", "workflow", "scpt", "jar", "py", "js", "applescript", "vbs"].contains(url.pathExtension.lowercased()),
                       !confirm("実行可能なファイルです。外部アプリで開きますか？") { return ["cancelled": true] }
                    guard NSWorkspace.shared.open(url) else { throw LibraryError.message("この形式を開くアプリがありません。作業コピーは保持しています。") }
                }
                else { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects(urls as [NSURL]) }
                return ["ok": true]
            }
        case "assets.editImage":
            return try await pinned {
                guard editor == nil, let asset = try await store.get(text(p, "id")) else { throw LibraryError.message("編集中の画像を保存または取り消してください。") }
                let url = try await store.path(asset, verifyHash: true)
                let session = try await AssetEditorSession.load(url: url, asset: asset, store: store)
                runtime.editorSessions.append(session)
                editor = session; if !organizer { runtime.editing = session }
                let result = await session.waitForResult()
                runtime.editorSessions.removeAll { $0.id == session.id }
                editor = nil; if !organizer { runtime.editing = nil }
                runtime.notifyChange()
                if let result { return try ["ok": true, "asset": json(result)] }
                return ["cancelled": true]
            }
        case "assets.backup":
            return try await pinned {
                let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
                guard panel.runModal() == .OK, let url = panel.url else { return ["cancelled": true] }
                if p["mode"] as? String == "export" {
                    let target = url.appendingPathComponent("HoverPocket-Backup-" + LibraryFormat.now().replacingOccurrences(of: ":", with: "-"))
                    let manifest = try await store.export(to: target)
                    return ["ok": true, "excludedPending": manifest.excludedPending ?? 0]
                }
                try await store.restore(from: url); runtime.notifyChange(); return ["ok": true]
            }
        case "assets.emptyTrash":
            return try await pinned {
                guard confirm("ライブラリのごみ箱をMacのゴミ箱へ移します。アプリ内では元に戻せません。") else { return ["cancelled": true] }
                let count = try await store.emptyTrash(); runtime.notifyChange(); return ["removed": count]
            }
        case "assets.recover": let count = try await store.recoverOrphans(); runtime.notifyChange(); return ["recovered": count]
        case "assets.databaseSnapshots": return try await store.snapshots()
        case "assets.restoreDatabase":
            return try await pinned {
                guard confirm("分類と名前を選択したDBスナップショットへ戻します。現在のDBは退避し、原本は保持します。") else { return ["cancelled": true] }
                try await store.restoreSnapshot(text(p, "name")); runtime.notifyChange(); return ["ok": true]
            }
        case "assets.cleanCopies":
            return try await pinned {
                guard confirm("外部アプリで作業コピーを使い終えましたか？ outbox内のコピーをMacのゴミ箱へ移します。") else { return ["cancelled": true] }
                let outbox = store.root.appendingPathComponent("outbox")
                let copies = try FileManager.default.contentsOfDirectory(at: outbox, includingPropertiesForKeys: nil)
                for copy in copies { try FileManager.default.trashItem(at: copy, resultingItemURL: nil) }
                return ["removed": copies.count]
            }
        default: throw LibraryError.message("この操作は対応していません: " + method)
        }
    }
    func importURLs(_ urls: [URL], folderId: String? = nil, completion: ((String) -> Void)? = nil) {
        guard importTask == nil else { completion?("取り込み中です。完了後にもう一度ドロップしてください。"); return }
        importTask = Task { @MainActor in
            var completed = 0, failed = 0, duplicates = 0, skipped = 0, restore: [String] = [], lastError = ""
            @MainActor func report(_ busy: Bool) {
                importProgress = ["busy": busy, "completed": completed, "failed": failed, "duplicates": duplicates, "skipped": skipped,
                    "restoreAvailable": restore.count, "error": lastError]
                event("assets.importChanged", importProgress)
            }
            report(true)
            do {
                let estimate = try await Task.detached { try AssetLibraryStore.importEstimate(urls) }.value
                if estimate.count >= 1000 || estimate.bytes >= 1_073_741_824 {
                    runtime.holdCount += 1
                    let accepted = confirm("\(estimate.count)件（\(ByteCountFormatter.string(fromByteCount: estimate.bytes, countStyle: .file))）を取り込みます。")
                    runtime.holdCount -= 1
                    if !accepted { report(false); importTask = nil; completion?("取り消しました。"); return }
                }
                let store = try await runtime.store()
                var visited = 0
                @MainActor func visit(_ url: URL, folder: String?) async throws {
                    try Task.checkCancellation()
                    try AssetLibraryStore.noLinks(url)
                    let flags = try url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isRegularFileKey])
                    if flags.isPackage == true || [".DS_Store", "Thumbs.db", "desktop.ini"].contains(url.lastPathComponent) { skipped += 1; return }
                    if flags.isDirectory == true {
                        let category = try await store.category(type: "folder", name: url.lastPathComponent, parent: folder)
                        for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey]) {
                            do { try await visit(child, folder: category) }
                            catch is CancellationError { throw CancellationError() }
                            catch { failed += 1; lastError = error.localizedDescription }
                        }
                    } else {
                        let result = try await store.importFile(url, folder: folder)
                        if result.status == "saved" { completed += 1 }
                        else if result.status == "duplicate" || result.status == "restoreAvailable" { duplicates += 1; if result.status == "restoreAvailable", let id = result.assetId { restore.append(id) } }
                        else { skipped += 1 }
                        visited += 1; if visited % 5 == 0 { report(true) }
                    }
                }
                for url in urls {
                    do { try await visit(url, folder: folderId) }
                    catch is CancellationError { break }
                    catch { failed += 1; lastError = error.localizedDescription }
                }
            } catch { failed += 1; lastError = error.localizedDescription }
            report(false); if !restore.isEmpty { event("assets.restoreAvailable", ["ids": restore]) }
            runtime.notifyChange(); importTask = nil
            completion?(failed > 0 ? "\(failed)件の取り込みに失敗: \(lastError)" : restore.isEmpty ? "\(completed)件を保存・\(duplicates)件は登録済み" : "ゴミ箱に同じ素材があります。ライブラリから復元してください。")
        }
    }
    private func consumeDrop() {
        guard !organizer, !runtime.pendingDropURLs.isEmpty, importTask == nil else { return }
        let urls = runtime.pendingDropURLs; runtime.pendingDropURLs = []; importURLs(urls)
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.navigationType == .other && action.request.url?.isFileURL == true ? .allow : .cancel)
    }
}
