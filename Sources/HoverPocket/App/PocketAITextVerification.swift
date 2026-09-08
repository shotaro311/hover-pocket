import AppKit
import WebKit
import SwiftUI

actor PocketAITextFixture: PocketAITextGenerating {
    private(set) var calls = 0
    func generate(_ request: PocketAITextRequest) async throws -> String {
        calls += 1
        if request.instructions == "wait" { try await Task.sleep(for: .seconds(120)) }
        return "確認した要約"
    }
}

actor PocketAITextObservedService: PocketAITextGenerating {
    private(set) var result: String?
    func generate(_ request: PocketAITextRequest) async throws -> String {
        let text = try await PocketAITextService.shared.generate(request)
        result = text
        return text
    }
}

@MainActor
enum PocketAITextVerification {
    static func fixture(root: URL, service: any PocketAITextGenerating, granted: Bool = true) throws -> PocketSurfaceHostModel {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("contracts/pocket/v2/fixtures/start-work")
        var files = try PocketAppFileSnapshot.capture(directory: directory).files
        var manifest = try JSONSerialization.jsonObject(with: files["manifest.json"]!) as! [String: Any]
        manifest["requestedCapabilities"] = [["id": "ai.text.generate", "version": 1]]
        manifest["workflows"] = [String: String]()
        manifest["tests"] = ["tests/surface.json"]
        files = files.filter { !$0.key.hasPrefix("workflows/") && !$0.key.hasPrefix("tests/") }
        files["manifest.json"] = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        files["tests/surface.json"] = Data(#"{"case":"surface-renders","expected":"pass"}"#.utf8)
        let package = try PocketAppPackageRuntime().load(snapshot: .init(rootDirectory: root, files: files, identities: [:]))
        let broker = CapabilityBroker(registry: try CapabilityRegistry(handlers: PocketCapabilityHandlerSet()),
            ledger: try CapabilityBrokerLedger(rootDirectory: root.appendingPathComponent("Broker")),
            auditLog: try CapabilityBrokerAuditLog(rootDirectory: root.appendingPathComponent("Broker")))
        let runtime = PocketAppExecutionRuntime(package: package, broker: broker, userID: "verification",
            grantedPermissions: granted ? [PocketAITextService.permission] : [], aiTextService: service)
        return try PocketSurfaceHostModel(runtime: runtime, surfaceID: "main")
    }

    static func showApproval() throws -> NSWindow {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PocketAIApprovalUI-" + UUID().uuidString)
        let model = try fixture(root: root, service: PocketAITextFixture())
        let window = NSWindow(contentRect: NSRect(x: 180, y: 100, width: 520, height: 420), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "AI送信確認の検証（通信なし）"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: VStack {
            Button("検証用のAI依頼") {
                do {
                    try model.requestAIText(["instructions": "日本語で短く要約する", "text": "明日の会議は10時からです。参加者は資料を確認してください。これは検証用の文章です。"] ) { _, error in
                        FileHandle.standardError.write(Data(((error ?? "AI_UI_RESULT_RECEIVED") + "\n").utf8))
                    }
                } catch { FileHandle.standardError.write(Data("AI_UI_REQUEST_FAILED\n".utf8)) }
            }
            PocketSurfaceHostView(model: model)
        })
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        return window
    }

    static func run() async throws {
        var checks = 0
        func check(_ value: Bool, _ name: String) throws {
            guard value else { throw PocketAppPackageError.invalid("ai-verification:" + name) }; checks += 1
        }
        func rejects(_ name: String, _ body: () throws -> Void) throws {
            var rejected = false; do { try body() } catch { rejected = true }; try check(rejected, name)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PocketAITextVerification-" + UUID().uuidString)
        let fake = PocketAITextFixture()
        let model = try fixture(root: root, service: fake)
        var answers: [(Any?, String?)] = []
        let args = ["instructions": "要約", "text": "明日は打合せ。その前に資料を確認する。"]
        try rejects("empty-input") { _ = try PocketAITextRequest(instructions: "", text: "abc") }
        try rejects("long-instructions") { _ = try PocketAITextRequest(instructions: String(repeating: "a", count: 1001), text: "abc") }
        try rejects("long-text") { _ = try PocketAITextRequest(instructions: "a", text: String(repeating: "a", count: 16001)) }
        try rejects("nul-input") { _ = try PocketAITextRequest(instructions: "a", text: "a\0b") }
        let denied = try fixture(root: root.appendingPathComponent("Denied"), service: fake, granted: false)
        try rejects("unapproved-install-permission") { try denied.requestAIText(args) { answers.append(($0, $1)) } }
        try model.requestAIText(args) { answers.append(($0, $1)) }
        try check(await fake.calls == 0 && model.showsAIApproval, "no-send-before-confirmation")
        try check(model.aiApprovalText.contains(args["text"]!) && model.aiApprovalText.contains("OpenAI"), "full-text-and-destination")
        try rejects("parallel-call-denied") { try model.requestAIText(args) { _, _ in } }
        model.cancelAIText()
        try check(await fake.calls == 0 && answers.last?.1 == "AI_CANCELLED", "reject-sends-nothing")
        model.approveAIText()
        try check(await fake.calls == 0, "old-approval-inert")
        try model.requestAIText(args) { answers.append(($0, $1)) }
        model.approveAIText()
        let deadline = Date().addingTimeInterval(5)
        while model.isAIExecuting, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try check(await fake.calls == 1, "exactly-one-approved-call")
        try check((answers.last?.0 as? [String: String])?["text"] == "確認した要約", "result-returned")
        try check(model.aiApprovalText.isEmpty && !model.showsAIApproval, "clear-input-after-completion")
        try model.requestAIText(["instructions": "wait", "text": "cancel"]) { answers.append(($0, $1)) }
        model.approveAIText()
        try await Task.sleep(for: .milliseconds(30))
        model.cancelAIText()
        let count = answers.count
        try await Task.sleep(for: .milliseconds(30))
        try check(answers.count == count && answers.last?.1 == "AI_CANCELLED", "cancel-once-no-late-result")
        try model.requestAIText(args) { answers.append(($0, $1)) }
        model.invalidateActivation()
        try check(answers.last?.1 == "AI_CANCELLED" && !model.showsAIApproval, "unload-cancels-pending")
        try rejects("stale-tool-rejected") { try model.requestAIText(args) { _, _ in } }
        let catalog = try PocketLibraryCatalog()
        try check(catalog.isAvailable("pocket.ai-text"), "ai-library-available")
        let off = try catalog.settingEnabled(false, id: "pocket.ai-text", consumers: [:])
        try check(!off.generationCapabilities(namespace: "x").contains { $0.id == "ai.text.generate" }, "disabled-ai-not-advertised")

        let webModel = try fixture(root: root.appendingPathComponent("WebKit"), service: fake)
        let coordinator = PocketHTMLSurfaceView.Coordinator(model: webModel)
        let receiver = PocketToolsHTMLVerification.Receiver()
        let view = PocketHTMLSurfaceView.makeWebView(coordinator: coordinator, html: "<p>AI bridge verification</p>")
        view.configuration.userContentController.add(receiver, name: "verification")
        view.configuration.userContentController.addUserScript(WKUserScript(source: #"""
        if(window!==window.top)(async()=>{try{
          const result=await pocket.ai.generate({instructions:'要約',text:'確認用の文章'});
          window.webkit.messageHandlers.verification.postMessage({ok:result.text==='確認した要約'});
        }catch(e){window.webkit.messageHandlers.verification.postMessage({ok:false,error:String(e)});}})();
        """#, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 310), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view; window.orderFront(nil)
        defer {
            view.configuration.userContentController.removeScriptMessageHandler(forName: "verification")
            PocketHTMLSurfaceView.dismantleNSView(view, coordinator: coordinator); window.orderOut(nil)
        }
        let webDeadline = Date().addingTimeInterval(15)
        while !webModel.showsAIApproval, Date() < webDeadline { try await Task.sleep(for: .milliseconds(50)) }
        try check(webModel.showsAIApproval, "real-webkit-requests-host-approval")
        webModel.approveAIText()
        while receiver.result == nil, Date() < webDeadline { try await Task.sleep(for: .milliseconds(50)) }
        try check(receiver.result?["ok"] as? Bool == true, "real-webkit-async-result")
        print("PASS pocket AI text: \(checks) checks; evidence=\(root.path)")
    }

    static func liveGenerated() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PocketAIGenerated-" + UUID().uuidString)
        let generator = try CodexAppServerPocketGenerator(workspaceRoot: root.appendingPathComponent("Generator"), diagnostic: { print("CHECK " + $0) })
        let allowed: Set<String> = ["pocket.html", "pocket.ai-text", "pocket.codex"]
        let catalog = try PocketLibraryCatalog(disabled: Set(PocketLibraryCatalog.bundled.map(\.id)).subtracting(allowed))
        var request = PocketAppGenerationRequest(requestID: "ai-generated-test", userRequest: "文章を入力してAIに短く要約してもらうHTMLツールを作ってください。送信内容の確認はHostに任せ、結果とエラーを画面に表示し、キャンセルもできるようにしてください。記録の自動保存は不要です。aiガイドの検証用属性を付けてください。", appID: "local.verification.ai-summary", version: "1.0.0", namespace: "ai-summary", capabilities: catalog.generationCapabilities(namespace: "ai-summary"))
        request.libraryCatalog = catalog
        let envelope = try await generator.generate(request, cancellation: PocketAppGenerationCancellation())
        let drafts = try PocketAppPinnedDirectory(url: root.appendingPathComponent("Drafts"))
        let result = try PocketAppGenerationMaterializer(rootDirectory: drafts.url).materialize(envelope: envelope, request: request)
        guard try catalog.dependencies(of: result.package) == allowed else { throw PocketAITextError.failed }
        let host = root.appendingPathComponent("Host"), data = root.appendingPathComponent("Data")
        let lifecycle = try PocketAppLifecycleManager(rootDirectory: host, userDataRoot: data, libraryCatalog: { catalog })
        let proposal = try lifecycle.stage(draftDirectory: result.directory)
        guard proposal.permissionDiff.added == [PocketAITextService.permission] else { throw PocketAITextError.failed }
        let grant = try lifecycle.approve(requestID: proposal.requestID, bindingDigest: proposal.bindingDigest)
        _ = try lifecycle.install(proposal, approvalGrant: grant)
        let package = try lifecycle.activePackage(packageID: result.package.manifest.id)!
        let broker = CapabilityBroker(registry: try CapabilityRegistry(handlers: PocketCapabilityHandlerSet()), ledger: try CapabilityBrokerLedger(rootDirectory: root.appendingPathComponent("Broker")), auditLog: try CapabilityBrokerAuditLog(rootDirectory: root.appendingPathComponent("Broker")))
        let observedService = PocketAITextObservedService()
        let runtime = PocketAppExecutionRuntime(package: package, broker: broker, userID: "verification", grantedPermissions: [PocketAITextService.permission], aiTextService: observedService)
        let model = try PocketSurfaceHostModel(runtime: runtime, surfaceID: "main")
        guard case .string(let html)? = model.surface.root.properties["html"] else { throw PocketAITextError.failed }
        let coordinator = PocketHTMLSurfaceView.Coordinator(model: model)
        let view = PocketHTMLSurfaceView.makeWebView(coordinator: coordinator, html: html)
        let receiver = PocketToolsHTMLVerification.Receiver()
        view.configuration.userContentController.add(receiver, name: "verification")
        view.configuration.userContentController.addUserScript(WKUserScript(source: #"""
        if(window!==window.top)(async()=>{try{
          const source=document.querySelector('[data-pocket-ai="text"]');
          const button=document.querySelector('[data-pocket-action="ai-generate"]');
          const result=document.querySelector('[data-pocket-ai="result"]');
          if(!source||!button||!result)throw Error('missing-controls');
          source.value='明日の会議は10時からです。議題は新商品の紹介です。参加者は資料を事前に確認してください。';
          source.dispatchEvent(new Event('input',{bubbles:true}));button.click();
          window.webkit.messageHandlers.verification.postMessage({clicked:true});
        }catch(e){window.webkit.messageHandlers.verification.postMessage({ok:false,error:String(e)});}})();
        """#, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 310), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view; window.orderFront(nil)
        defer { view.configuration.userContentController.removeScriptMessageHandler(forName: "verification"); PocketHTMLSurfaceView.dismantleNSView(view, coordinator: coordinator); window.orderOut(nil) }
        let deadline = Date().addingTimeInterval(180)
        while !model.showsAIApproval, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        guard model.showsAIApproval, model.aiApprovalText.contains("明日の会議は10時") else { throw PocketAITextError.failed }
        model.approveAIText()
        while model.isAIExecuting, Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        guard let expected = await observedService.result, let frame = receiver.frame else { throw PocketAITextError.failed }
        let displayed: String = try await withCheckedThrowingContinuation { continuation in
            view.evaluateJavaScript("document.querySelector('[data-pocket-ai=result]').textContent", in: frame, in: WKContentWorld.page) { result in
                switch result {
                case .success(let value): continuation.resume(returning: value as? String ?? "")
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
        guard displayed.contains(expected), !expected.isEmpty else { throw PocketAITextError.failed }
        print("PASS live generated AI tool: library selection, install permission, real HTML input, Host approval, real Codex result displayed; package=\(result.directory.path)")
    }

    static func live() async throws {
        let result = try await PocketAITextService.shared.generate(.init(instructions: "次の文章から数字だけを返してください。", text: "確認用の番号は42です。"))
        guard result.trimmingCharacters(in: .whitespacesAndNewlines) == "42" else { throw PocketAITextError.failed }
        print("PASS live AI text: ephemeral Codex thread, confined tools, validated result=42")
    }
}
