import AppKit
import PDFKit
import WebKit
import SwiftUI

@MainActor
enum AssetLibraryVerification {
    static func run() async throws {
        let args = CommandLine.arguments
        func option(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        guard let evidencePath = option("--asset-evidence"), let sourcePath = option("--asset-source-root") else { throw LibraryError.message("検証専用の --asset-evidence と --asset-source-root が必要です。") }
        let evidence = URL(fileURLWithPath: evidencePath).resolvingSymlinksInPath(), source = URL(fileURLWithPath: sourcePath)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        let contract = source.appendingPathComponent("shared/asset-library")
        var checks: [String] = []
        func check(_ passed: Bool, _ name: String) throws {
            guard passed else { throw LibraryError.message("FAIL " + name) }; checks.append(name); print("PASS " + name)
        }
        let store = try AssetLibraryStore(root: evidence.appendingPathComponent("library"), contractRoot: contract)
        try await store.start()
        if args.contains("--verify-asset-reopen") {
            let page = try await store.query(LibraryQuery())
            try check(page.total >= 3, "new process reads persisted assets")
            for asset in page.items { _ = try await store.path(asset, verifyHash: true) }
            try check(true, "new process original hashes")
        } else if args.contains("--verify-asset-ui") {
            AssetLibraryRuntime.shared.verificationStore = store
            let pane = AssetPaneModel()
            let view = AssetVerificationSurface(pane: pane)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1000, height: 700), styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
            window.title = "HoverPocket 素材検証"; window.contentView = host; window.backgroundColor = .black
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            let deadline = Date().addingTimeInterval(20)
            while pane.web == nil || pane.web?.isLoading == true {
                guard Date() < deadline else { throw LibraryError.message("WebView load timeout") }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard let web = pane.web else { throw LibraryError.message("WebView missing") }
            try await Task.sleep(for: .seconds(1))
            let startup = try await web.callAsyncJavaScript("return {url:location.href,config:window.assetConfiguration||null,pane:!!window.assetPane,errors:window.assetErrors||[]};", arguments: [:], in: nil, contentWorld: .page)
            try JSONSerialization.data(withJSONObject: startup ?? [:], options: [.prettyPrinted]).write(to: evidence.appendingPathComponent("web-startup.json"))
            let result = try await web.callAsyncJavaScript("return await window.verifyAssetSelection();", arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
            try JSONSerialization.data(withJSONObject: result ?? [:], options: [.prettyPrinted, .sortedKeys]).write(to: evidence.appendingPathComponent("web-interactions.json"))
            try check(result?["ok"] as? Bool == true, "Windows interaction suite in WKWebView: \(String(describing: result?["error"]))")
            if let names = result?["checks"] as? [String] { checks += names }
            _ = try await web.evaluateJavaScript("window.assetEvent('assets.changed')")
            try await Task.sleep(for: .seconds(1))
            let nativeText = try await web.evaluateJavaScript("document.body.innerText") as? String ?? ""
            try Data(nativeText.utf8).write(to: evidence.appendingPathComponent("native-ui.txt"))
            try await AssetMediaVerification.snapshot(window: window, to: evidence.appendingPathComponent("library-ui.png"))
            let cards = try await web.evaluateJavaScript("document.querySelectorAll('.assets-card').length") as? Int ?? 0
            try check(cards > 0, "native bridge renders persisted assets: " + nativeText)
            let imageID = try await store.query(LibraryQuery()).items.first { $0.kind == "image" }?.id
            if let imageID {
                _ = try await web.callAsyncJavaScript("document.querySelector('[data-asset-id=\"'+id+'\"] img').dispatchEvent(new MouseEvent('dblclick',{bubbles:true}));", arguments: ["id": imageID], in: nil, contentWorld: .page)
                try await Task.sleep(for: .seconds(1))
                let preview = try await web.evaluateJavaScript("document.querySelector('.assets-root').classList.contains('has-preview')") as? Bool
                try check(preview == true, "native image preview")
                let edit = Task { (try await pane.request("assets.editImage", ["id": imageID]) as? [String: Any])?["ok"] as? Bool == true }
                let editorDeadline = Date().addingTimeInterval(5)
                while pane.editor == nil {
                    guard Date() < editorDeadline else { throw LibraryError.message("editor timeout") }
                    try await Task.sleep(for: .milliseconds(20))
                }
                let session = pane.editor!, actualSave = session.onSave
                session.annotations = [AssetAnnotation(tool: .arrow, points: [CGPoint(x: 50, y: 50), CGPoint(x: 200, y: 200)], color: .white, width: 8)]
                try await AssetMediaVerification.snapshot(window: window, to: evidence.appendingPathComponent("image-editor.png"))
                session.onSave = { _, _ in throw LibraryError.message("verification save failure") }
                session.save(); session.save()
                try await Task.sleep(for: .milliseconds(100))
                try check(!session.saving && !session.error.isEmpty && session.annotations.count == 1 && pane.editor != nil, "editor failed save retains annotations and permits retry")
                session.onSave = actualSave; session.save(); session.save()
                let saved = try await edit.value
                try check(saved && pane.editor == nil, "editor saves once and returns to preview")
                _ = try await store.path(store.get(imageID)!, verifyHash: true)
                try check(true, "editor preserves original image hash")
                pane.invalidatePreview()
                try await Task.sleep(for: .milliseconds(200))
                try check(try await web.evaluateJavaScript("document.querySelector('.assets-root').classList.contains('has-preview')") as? Bool == false, "preview close invalidates UI")
            }
            let page = try await store.query(LibraryQuery())
            for asset in page.items where asset.kind == "pdf" || asset.kind == "video" {
                _ = try await web.callAsyncJavaScript("await window.assetPane.refresh();document.querySelector('[data-asset-id=\"'+id+'\"] img').dispatchEvent(new MouseEvent('dblclick',{bubbles:true}));", arguments: ["id": asset.id], in: nil, contentWorld: .page)
                try await Task.sleep(for: .milliseconds(600))
                if asset.kind == "pdf" {
                    let pdf = try await web.callAsyncJavaScript("const input=document.querySelector('.assets-preview-bottom input');input.value=2;input.dispatchEvent(new Event('change'));await new Promise(r=>setTimeout(r,300));return {page:document.querySelector('.assets-preview-bottom input').value,decoded:document.querySelector('.assets-media img').naturalWidth};", arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
                    try check(pdf?["page"] as? String == "2" && (pdf?["decoded"] as? Int ?? 0) > 0, "native PDF page switching")
                } else {
                    let video = try await web.callAsyncJavaScript("const v=document.querySelector('video');v.muted=true;await v.play();await new Promise(r=>setTimeout(r,200));v.pause();v.currentTime=2;await new Promise(r=>setTimeout(r,300));window.testVideo=v;return {time:v.currentTime,duration:v.duration,ready:v.readyState};", arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
                    try check(abs((video?["time"] as? Double ?? 0) - 2) < 0.3 && (video?["ready"] as? Int ?? 0) >= 2, "native MP4 playback and seeking")
                    _ = try await web.evaluateJavaScript("document.querySelector('[data-action=fullscreen]').click()")
                    try await Task.sleep(for: .seconds(1))
                    try check(pane.organizerIsFullscreen && window.frame == window.screen?.frame, "native fullscreen entered")
                    _ = try await web.evaluateJavaScript("document.querySelector('[data-action=fullscreen]').click()")
                    try await Task.sleep(for: .seconds(1))
                    let preserved = try await web.evaluateJavaScript("testVideo===document.querySelector('video') && Math.abs(testVideo.currentTime-2)<0.3") as? Bool == true
                    try check(!pane.organizerIsFullscreen && window.frame.width == 1000 && preserved, "fullscreen exit preserves player and seek time")
                    pane.invalidatePreview()
                    try await Task.sleep(for: .milliseconds(90))
                    try check(try await web.evaluateJavaScript("testVideo.paused && !testVideo.hasAttribute('src')") as? Bool == true, "preview close releases player source within 100ms")
                }
                pane.invalidatePreview(); try await Task.sleep(for: .milliseconds(100))
            }
            if args.contains("--keep-asset-ui") {
                try Data("ready".utf8).write(to: evidence.appendingPathComponent("ui-ready"))
                while window.isVisible { try await Task.sleep(for: .seconds(1)) }
            }
            window.orderOut(nil)
            if !args.contains("--keep-asset-ui") {
                let controller = HoverWindowController(settingsDefaults: EphemeralAppSettingsDefaults(), providerRegistry: ProviderRegistry(providers: [TimerProvider(), AssetsProvider()]))
                try await controller.runAssetPanelVerification(evidence: evidence)
                try check(true, "20 animated notch preview and fullscreen cycles")
            }
        } else {
            let format = try LibraryFormat(contractRoot: contract)
            try check(format.normalize("ＡＢＣ Straße Σςσ İ I") == "abc strasse σσσ i̇ i", "Unicode NFKC and shared full case folding")
            let inputs = evidence.appendingPathComponent("inputs"); try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
            let file = inputs.appendingPathComponent("ＡＢＣ_猫.txt")
            try Data("Original user data\n".utf8).write(to: file)
            let originalHash = try AssetLibraryStore.hash(file)
            let folder = try await store.category(type: "folder", name: "資料")
            let child = try await store.category(type: "folder", name: "子", parent: folder)
            let tag = try await store.category(type: "tag", name: "Ｈａｌｆ幅")
            let saved = try await store.importFile(file, folder: child)
            guard let id = saved.assetId, let asset = try await store.get(id) else { throw LibraryError.message("import missing") }
            try check(saved.status == "saved", "import committed")
            try check(try AssetLibraryStore.hash(file) == originalHash, "source unchanged")
            let managed = try await store.path(asset, verifyHash: true)
            let permissions = try FileManager.default.attributesOfItem(atPath: managed.path)[.posixPermissions] as? NSNumber
            try check(permissions?.intValue == 0o444, "managed original read only")
            try check(try await store.importFile(file).status == "duplicate", "hash deduplication")
            try await store.update(ids: [id], operation: "classify", value: tag)
            try await store.update(ids: [id], operation: "rename", value: "新しい名前")
            let renamed = try await store.get(id)!
            try check(renamed.id == id && renamed.extension == "txt" && renamed.name == "新しい名前.txt" && renamed.sha256 == originalHash, "rename preserves ID extension original")
            try await store.update(ids: [id], operation: "trash")
            try check(try await store.query(LibraryQuery()).total == 0, "trash hidden")
            try check(try await store.importFile(file).status == "restoreAvailable", "duplicate in trash offers restore")
            try await store.undoLast()
            try check(try await store.query(LibraryQuery()).total == 1, "undo restores selection metadata")
            try await store.update(ids: [id], operation: "favorite")
            var query = LibraryQuery(); query.text = "half"
            try check(try await store.query(query).total == 1, "tag normalized search")
            query.text = ""; query.version = 2; query.extension = "txt"; query.sortBy = "name"; query.descending = false
            try await store.saveSearch(name: "名前順", query: query)
            try check(try await store.query(query).total == 1, "search v2 extension sort")
            query.version = 1
            do { _ = try await store.query(query); throw LibraryError.message("accepted invalid v1") }
            catch { try check(error.localizedDescription != "accepted invalid v1", "v1 refuses v2 search semantics") }
            do { try await store.changeCategory(id: folder, operation: "move", name: nil, parent: child); throw LibraryError.message("accepted cycle") }
            catch { try check(error.localizedDescription != "accepted cycle", "category cycle rejected") }
            let copy = try await store.copyOut(id)
            try Data("External editor changes".utf8).write(to: copy)
            try check(try AssetLibraryStore.hash(managed) == originalHash, "external working copy cannot alter original")
            let symlink = inputs.appendingPathComponent("link.txt")
            try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: file)
            do { _ = try await store.importFile(symlink); throw LibraryError.message("accepted link") }
            catch { try check(error.localizedDescription != "accepted link", "symlink import rejected") }
            let image = try fixtureImage()
            let png = inputs.appendingPathComponent("検証画像.png"); try AssetMedia.png(image).write(to: png)
            let imageImport = try await store.importFile(png)
            let pdfURL = inputs.appendingPathComponent("検証.pdf")
            let pdf = PDFDocument(); pdf.insert(PDFPage(image: NSImage(cgImage: image, size: CGSize(width: 640, height: 360)))!, at: 0)
            pdf.insert(PDFPage(image: NSImage(cgImage: image, size: CGSize(width: 360, height: 640)))!, at: 1)
            guard pdf.write(to: pdfURL) else { throw LibraryError.message("PDF fixture write failed") }
            let pdfImport = try await store.importFile(pdfURL)
            let videoURL = inputs.appendingPathComponent("検証動画.mp4")
            try await AssetMediaVerification.movie(at: videoURL, image: image)
            let videoImport = try await store.importFile(videoURL)
            for item in [imageImport, pdfImport, videoImport] {
                let asset = try await store.get(item.assetId!)!, url = try await store.path(asset, verifyHash: true)
                let frame = await AssetMedia.frame(asset, url: url)
                try check(frame.error == nil && frame.width > 0 && frame.dataUrl != nil, "native \(asset.kind) decode")
            }
            let editor = AssetEditorSession(image: image)
            editor.annotations = [AssetAnnotation(tool: .rectangle, points: [CGPoint(x: 20, y: 20), CGPoint(x: 220, y: 150)], color: .red, width: 8),
                AssetAnnotation(tool: .text, points: [CGPoint(x: 40, y: 50)], color: .white, width: 4, text: "Mac検証")]
            let rendered = try editor.render()
            try rendered.write(to: evidence.appendingPathComponent("annotated.png"))
            let decoded = try AssetMedia.image(evidence.appendingPathComponent("annotated.png"))
            try check(decoded.width == image.width && decoded.height == image.height && rendered != AssetMedia.png(image), "annotation render keeps dimensions and adds pixels")
            let backup = evidence.appendingPathComponent("mac-backup")
            let exported = try await store.export(to: backup)
            let restored = try AssetLibraryStore(root: evidence.appendingPathComponent("restored"), contractRoot: contract)
            try await restored.start(); try await restored.restore(from: backup)
            try check(try await restored.query(LibraryQuery()).total == exported.assets.count, "Mac backup roundtrip")
            let fixture = try AssetLibraryStore(root: evidence.appendingPathComponent("windows-fixture"), contractRoot: contract)
            try await fixture.start(); try await fixture.restore(from: contract.appendingPathComponent("fixtures/v1"))
            var trash = LibraryQuery(); trash.view = "trash"
            let fixturePage = try await fixture.query(trash)
            try check(fixturePage.total == 1 && fixturePage.items[0].favorite && fixturePage.items[0].internetOrigin && fixturePage.searches.count == 2, "Windows fixture schema1 metadata and searches v1 v2")
            _ = try await fixture.export(to: evidence.appendingPathComponent("windows-roundtrip"))
            try check(true, "Windows fixture exported by Mac")
            let capture = try await AssetMediaVerification.capture(to: evidence)
            try JSONSerialization.data(withJSONObject: capture, options: [.prettyPrinted, .sortedKeys]).write(to: evidence.appendingPathComponent("capture-result.json"))
            print("capture_verification=\(capture["status"] ?? "unknown")")
            checks += try await AssetStorageVerification.run(at: evidence, contract: contract)
            // Unknown versions must fail before schema execution, without silently downgrading.
            let future = evidence.appendingPathComponent("future")
            try FileManager.default.createDirectory(at: future, withIntermediateDirectories: true)
            let db = try LibraryDatabase(future.appendingPathComponent("library.sqlite")); try db.script("PRAGMA user_version=99")
            do { _ = try AssetLibraryStore(root: future, contractRoot: contract); throw LibraryError.message("accepted future") }
            catch { try check(error.localizedDescription != "accepted future", "future DB writer refused") }
        }
        try JSONSerialization.data(withJSONObject: ["passed": checks, "count": checks.count], options: [.prettyPrinted, .sortedKeys]).write(to: evidence.appendingPathComponent(args.contains("--verify-asset-ui") ? "ui-result.json" : args.contains("--verify-asset-reopen") ? "reopen-result.json" : "core-result.json"))
        print("asset_verification=ok checks=\(checks.count)")
    }
    static func fixtureImage() throws -> CGImage {
        guard let context = CGContext(data: nil, width: 640, height: 360, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw LibraryError.message("image context") }
        context.setFillColor(NSColor.systemBlue.cgColor); context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
        context.setFillColor(NSColor.systemYellow.cgColor); context.fill(CGRect(x: 0, y: 180, width: 320, height: 180))
        context.setFillColor(NSColor.systemGreen.cgColor); context.fill(CGRect(x: 320, y: 0, width: 320, height: 180))
        return context.makeImage()!
    }
}

private struct AssetVerificationSurface: View {
    @ObservedObject var pane: AssetPaneModel
    var body: some View {
        ZStack {
            AssetWebView(pane: pane, language: .japanese, organizer: true)
            if let editor = pane.editor { AssetAnnotationEditor(session: editor) }
        }
    }
}
