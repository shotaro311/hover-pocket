import AppKit
import WebKit

@MainActor
enum PocketToolsHTMLVerification {
    final class Receiver: NSObject, WKScriptMessageHandler {
        var result: [String: Any]?
        var frame: WKFrameInfo?
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard !message.frameInfo.isMainFrame else { return }
            frame = message.frameInfo
            result = message.body as? [String: Any]
        }
    }

    static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PocketHTML-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let definition: [String: Any] = ["$schema": "hoverpocket://schemas/pocket-collection/v1", "schemaVersion": 1,
            "title": "記録", "fields": ["title": ["title": "名前", "type": "string", "required": true, "nullable": false],
                                       "count": ["title": "数", "type": "number", "required": false, "nullable": false]]]
        let packageRoot = root.appendingPathComponent("Package")
        let files = try PocketToolsPlatformVerification.fixtureFiles(collection: definition)
        try PocketAppFileSnapshot(rootDirectory: packageRoot, files: files, identities: [:]).materialize(at: packageRoot)
        let package = try PocketAppPackageRuntime().load(directory: packageRoot)
        let brokerRoot = root.appendingPathComponent("Broker")
        let broker = CapabilityBroker(registry: try CapabilityRegistry(handlers: PocketCapabilityHandlerSet()),
            ledger: try CapabilityBrokerLedger(rootDirectory: brokerRoot), auditLog: try CapabilityBrokerAuditLog(rootDirectory: brokerRoot))
        let store = try PocketCollectionStore(packageID: package.manifest.id, collectionID: "items",
            schema: package.collections["items"]!, rootDirectory: root.appendingPathComponent("Data"))
        let runtime = PocketAppExecutionRuntime(package: package, broker: broker, userID: "verification", grantedPermissions: [], collectionStores: ["items": store])
        let model = try PocketSurfaceHostModel(runtime: runtime, surfaceID: "main")
        let coordinator = PocketHTMLSurfaceView.Coordinator(model: model)
        let webView = PocketHTMLSurfaceView.makeWebView(coordinator: coordinator, html: "<style>body{background:white;color:black}h1{font-size:40px}</style><h1>HTML bridge verification</h1><input id='draft' value='未保存の入力'>")
        let receiver = Receiver()
        webView.configuration.userContentController.add(receiver, name: "verification")
        // Test-only instrumentation runs inside the same opaque frame as generated JavaScript.
        webView.configuration.userContentController.addUserScript(WKUserScript(source: #"""
        if(window !== window.top) (async()=>{
          const checks=[];
          const check=(value,name)=>{if(!value)throw Error(name);checks.push(name);};
          const rejects=async(action,name)=>{let denied=false;try{await action();}catch(_){denied=true;}check(denied,name);};
          try {
            check(getComputedStyle(document.body).backgroundColor==='rgb(5, 5, 6)','host-dark-background');
            check(parseFloat(getComputedStyle(document.querySelector('h1')).fontSize)<18,'host-compact-title');
            check(parseFloat(getComputedStyle(document.documentElement).fontSize)===13,'host-text-size');
            await rejects(()=>parent.document.body,'opaque-parent');
            await rejects(()=>localStorage.setItem('x','1'),'no-local-storage');
            await rejects(()=>fetch('https://example.com/'),'no-network');
            await rejects(()=>fetch('file:///etc/hosts'),'no-file');
            await rejects(()=>window.webkit.messageHandlers.pocket.postMessage({pocket:1,id:1,method:'collections.list',args:{}}),'no-child-native-bridge');
            const list=await pocket.collections.list();check(list.length===1&&list[0].id==='items','collection-scope');
            let value=await pocket.collections.read('items');check(value.revision===0,'empty');
            value=await pocket.collections.insert('items',{title:'保存確認',count:1},value.revision);
            check(value.records.length===1&&value.records[0].fields.count===1,'insert-number-one');
            const id=value.records[0].id;
            await rejects(()=>pocket.collections.insert('items',{title:'古い入力'},0),'conflict');
            await rejects(()=>pocket.collections.read('../other'),'no-path-escape');
            await rejects(()=>pocket.collections.read('other'),'no-other-collection');
            value=await pocket.collections.update('items',id,{title:'更新確認',count:2},value.revision);
            check(value.records[0].id===id&&value.records[0].fields.title==='更新確認','update');
            value=await pocket.collections.delete('items',id,value.revision);check(value.records.length===0,'delete');
            value=await pocket.collections.insert('items',{title:'再起動確認',count:1},value.revision);
            check(value.records[0].fields.title==='再起動確認','final-write');
            window.webkit.messageHandlers.verification.postMessage({ok:true,checks});
          } catch(error) {window.webkit.messageHandlers.verification.postMessage({ok:false,error:String(error),checks});}
        })();
        """#, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 500, height: 540), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = webView
        window.orderFront(nil)
        defer {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "verification")
            PocketHTMLSurfaceView.dismantleNSView(webView, coordinator: coordinator)
            window.orderOut(nil)
        }
        let deadline = Date().addingTimeInterval(35)
        while receiver.result == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        guard let result = receiver.result, result["ok"] as? Bool == true else {
            throw PocketAppPackageError.invalid("html-verification: \(receiver.result?["error"] as? String ?? "timeout")")
        }
        let reopened = try PocketCollectionStore(packageID: package.manifest.id, collectionID: "items",
            schema: package.collections["items"]!, rootDirectory: root.appendingPathComponent("Data"))
        guard try reopened.snapshot().records.first?.fields["title"] == .string("再起動確認") else {
            throw PocketAppPackageError.invalid("html-readback")
        }
        receiver.result = nil
        let observeTheme = "addEventListener('message',e=>{if(e.source===parent&&e.data?.pocketTheme===15)setTimeout(()=>window.webkit.messageHandlers.verification.postMessage({ok:parseFloat(getComputedStyle(document.documentElement).fontSize)===15&&document.getElementById('draft').value==='未保存の入力'}),0);});"
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            webView.evaluateJavaScript(observeTheme, in: receiver.frame, in: WKContentWorld.page) { result in
                switch result {
                case .success: continuation.resume()
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
        _ = try await webView.evaluateJavaScript("document.getElementById('tool').contentWindow.postMessage({pocketTheme:15},'*')")
        let themeDeadline = Date().addingTimeInterval(5)
        while receiver.result == nil, Date() < themeDeadline { try await Task.sleep(for: .milliseconds(50)) }
        guard receiver.result?["ok"] as? Bool == true else { throw PocketAppPackageError.invalid("html-live-theme-keeps-input") }
        model.invalidateActivation()
        receiver.result = nil
        let script = "pocket.collections.insert('items',{title:'失効後'},4).then(()=>window.webkit.messageHandlers.verification.postMessage({ok:false}),()=>window.webkit.messageHandlers.verification.postMessage({ok:true}));"
        webView.evaluateJavaScript(script, in: receiver.frame, in: WKContentWorld.page) { _ in }
        let invalidationDeadline = Date().addingTimeInterval(20)
        while receiver.result == nil, Date() < invalidationDeadline { try await Task.sleep(for: .milliseconds(100)) }
        guard receiver.result?["ok"] as? Bool == true, try reopened.snapshot().records.count == 1 else {
            throw PocketAppPackageError.invalid("html-invalidation")
        }
        print("PASS actual WebKit: \((result["checks"] as? [String] ?? []).count + 3) sandbox, live panel theme, bridge CRUD, independent readback and invalidation checks")
    }
}

extension PocketToolsHTMLVerification {
    static func runGenerated(packageDirectory: URL, previousDirectory: URL? = nil) async throws {
        let source = try PocketAppPackageRuntime().load(directory: packageDirectory)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PocketGeneratedUI-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dataRoot = root.appendingPathComponent("Data")
        let definitionRoot = root.appendingPathComponent("Host")
        let lifecycle = try PocketAppLifecycleManager(rootDirectory: definitionRoot, userDataRoot: dataRoot)
        var preservedRecordID: String?
        if let previousDirectory {
            let previous = try PocketAppPackageRuntime().load(directory: previousDirectory)
            let initialProposal = try lifecycle.stage(draftDirectory: previousDirectory)
            let initialGrant = try lifecycle.approve(requestID: initialProposal.requestID, bindingDigest: initialProposal.bindingDigest)
            _ = try lifecycle.install(initialProposal, approvalGrant: initialGrant)
            let store = try PocketCollectionStore(packageID: previous.manifest.id, collectionID: "plants",
                schema: previous.collections["plants"]!, rootDirectory: dataRoot)
            preservedRecordID = try store.insert(fields: ["name": .string("変更前からの植物"), "lastWatered": .string("2026-09-01")], expectedRevision: 0).records[0].id
        }
        let proposal = try lifecycle.stage(draftDirectory: packageDirectory)
        if previousDirectory != nil, proposal.dataMigration == nil { throw PocketAppPackageError.invalid("generated-migration-missing") }
        let grant = try lifecycle.approve(requestID: proposal.requestID, bindingDigest: proposal.bindingDigest)
        let receipt = try lifecycle.install(proposal, approvalGrant: grant)
        let brokerRoot = root.appendingPathComponent("Broker")
        let broker = CapabilityBroker(registry: try CapabilityRegistry(handlers: PocketCapabilityHandlerSet()),
            ledger: try CapabilityBrokerLedger(rootDirectory: brokerRoot), auditLog: try CapabilityBrokerAuditLog(rootDirectory: brokerRoot))
        let registry = try PocketAppRuntimeActivationRegistry(rootDirectory: definitionRoot, userDataRoot: dataRoot, broker: broker, userID: "verification")
        _ = try registry.synchronize(receipt)
        guard registry.surfaceRegistry.routes.contains(where: { $0.appID == source.manifest.id }),
              let model = try registry.surfaceRegistry.model(appID: source.manifest.id, surfaceID: "main"),
              case .string(let html)? = model.surface.root.properties["html"] else { throw PocketAppPackageError.invalid("generated-route") }
        let coordinator = PocketHTMLSurfaceView.Coordinator(model: model)
        let webView = PocketHTMLSurfaceView.makeWebView(coordinator: coordinator, html: html)
        let receiver = Receiver()
        webView.configuration.userContentController.add(receiver, name: "verification")
        webView.configuration.userContentController.addUserScript(WKUserScript(source: #"""
        if(window!==window.top)(async()=>{
          const checks=[];
          const check=(v,name)=>{if(!v)throw Error(name);checks.push(name);};
          const wait=async fn=>{for(let i=0;i<150;i++){if(fn())return;await new Promise(r=>setTimeout(r,100));}throw Error('UI timeout');};
          const el=id=>document.getElementById(id);
          const fill=(name,date)=>{el('name').value=name;el('date').value=date;if(el('location'))el('location').value='窓辺';el('form').requestSubmit();};
          const card=name=>Array.from(document.querySelectorAll('.card')).find(c=>c.querySelector('h2')?.textContent===name);
          const click=(node,label)=>{const b=Array.from(node.querySelectorAll('button')).find(b=>b.textContent===label);if(!b)throw Error('button missing');b.click();};
          try{
            await wait(()=>el('save')&&!el('save').disabled);
            check(!el('error').textContent,'loaded');
            fill('検証用モンステラ','2026-09-06');await wait(()=>card('検証用モンステラ')&&!el('save').disabled);
            check(el('status').textContent.includes('保存しました'),'form-insert');
            click(card('検証用モンステラ'),'編集');fill('編集したモンステラ','2026-09-07');
            await wait(()=>card('編集したモンステラ')&&!el('save').disabled);check(!!card('編集したモンステラ'),'form-edit');
            let snapshot=await pocket.collections.read('plants');
            await pocket.collections.insert('plants',{name:'別画面の入力',lastWatered:'2026-09-06'},snapshot.revision);
            fill('競合後に保存する植物','2026-09-08');await wait(()=>el('error').textContent&&!el('save').disabled);
            check(el('name').value==='競合後に保存する植物'&&!!card('別画面の入力'),'conflict-keeps-input-and-refreshes');
            el('form').requestSubmit();await wait(()=>card('競合後に保存する植物')&&!el('save').disabled);
            click(card('編集したモンステラ'),'削除');click(card('編集したモンステラ'),'削除する');
            await wait(()=>!card('編集したモンステラ')&&!el('save').disabled);
            check(!!card('競合後に保存する植物'),'delete-confirmation');
            check(document.documentElement.scrollWidth<=innerWidth,'narrow-layout');
            window.webkit.messageHandlers.verification.postMessage({ok:true,checks});
          }catch(error){window.webkit.messageHandlers.verification.postMessage({ok:false,error:String(error),checks});}
        })();
        """#, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 320, height: 720), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "生成した水やりツールの検証"
        window.contentView = webView
        window.orderFront(nil)
        defer {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "verification")
            PocketHTMLSurfaceView.dismantleNSView(webView, coordinator: coordinator)
            window.orderOut(nil)
        }
        let deadline = Date().addingTimeInterval(55)
        while receiver.result == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        guard let result = receiver.result, result["ok"] as? Bool == true else {
            throw PocketAppPackageError.invalid("generated-ui: \(receiver.result?["error"] as? String ?? "timeout")")
        }
        let image = try await webView.takeSnapshot(configuration: nil)
        if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            try png.write(to: root.appendingPathComponent("generated-plant-ui.png"))
        }
        let freshRegistry = try PocketAppRuntimeActivationRegistry(rootDirectory: definitionRoot, userDataRoot: dataRoot, broker: broker, userID: "verification")
        _ = freshRegistry.restoreEnabledApps()
        guard let reloaded = try freshRegistry.surfaceRegistry.model(appID: source.manifest.id, surfaceID: "main") else {
            throw PocketAppPackageError.invalid("generated-restart-route")
        }
        let saved = try reloaded.collectionSnapshot("plants")
        guard saved.records.count == (preservedRecordID == nil ? 2 : 3),
              saved.records.contains(where: { $0.fields["name"] == .string("競合後に保存する植物") }) else {
            throw PocketAppPackageError.invalid("generated-restart-data")
        }
        if let preservedRecordID {
            guard saved.records.contains(where: { $0.id == preservedRecordID && $0.fields["name"] == .string("変更前からの植物") }),
                  saved.records.contains(where: { $0.fields["name"] == .string("競合後に保存する植物") && $0.fields["location"] == .string("窓辺") }) else {
                throw PocketAppPackageError.invalid("generated-migration-preserve-and-new-input")
            }
            print("PASS actual conversational schema edit: prior record ID preserved and new field saved through generated UI")
        }
        let removed = try lifecycle.remove(packageID: source.manifest.id, dataDisposition: .preserve)
        _ = try freshRegistry.synchronize(removed)
        guard freshRegistry.surfaceRegistry.routes.isEmpty, !reloaded.activationAvailable,
              try PocketToolDataMigration.capture(directory: dataRoot.appendingPathComponent(source.manifest.id)).isEmpty == false else {
            throw PocketAppPackageError.invalid("generated-remove")
        }
        print("PASS actual generated UI: \((result["checks"] as? [String] ?? []).count + 3) UI, provider route, restart and preserve-data removal checks")
        print("Generated UI evidence: \(root.path)")
    }
}
