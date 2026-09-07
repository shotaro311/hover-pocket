import SwiftUI
import WebKit

/// Generated code lives in an opaque sandboxed child frame. Only its trusted parent can call Swift.
struct PocketHTMLSurfaceView: NSViewRepresentable {
    @ObservedObject var model: PocketSurfaceHostModel
    let html: String
    @Environment(\.panelTextSize) private var panelTextSize

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> WKWebView {
        Self.makeWebView(coordinator: context.coordinator, html: html, fontSize: panelTextSize.scaled(12))
    }

    static func makeWebView(coordinator: Coordinator, html: String, fontSize: CGFloat = 13) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.addScriptMessageHandler(coordinator, contentWorld: .page, name: "pocket")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.underPageBackgroundColor = NSColor(PocketToolTheme.background)
        view.navigationDelegate = coordinator
        view.uiDelegate = coordinator
        coordinator.webView = view
        coordinator.fontSize = fontSize
        coordinator.load(html: html, in: view)
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        let size = panelTextSize.scaled(12)
        guard context.coordinator.fontSize != size else { return }
        context.coordinator.fontSize = size
        nsView.evaluateJavaScript("document.getElementById('tool').contentWindow.postMessage({pocketTheme:\(size)},'*')", completionHandler: nil)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.active = false
        view.stopLoading()
        view.configuration.userContentController.removeScriptMessageHandler(forName: "pocket", contentWorld: .page)
        view.navigationDelegate = nil
        view.uiDelegate = nil
        view.loadHTMLString("", baseURL: nil)
    }

    static let contentPolicy = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; font-src data:; connect-src 'none'; frame-src about:; child-src about:; worker-src 'none'; media-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'"

    static func document(html: String, fontSize: CGFloat = 13) -> String {
        let bootstrap = """
        <meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <script>
        (()=>{let serial=0;const pending=new Map();
        const call=(method,args={})=>new Promise((resolve,reject)=>{
          if(pending.size>=16){reject(new Error('BUSY'));return;}
          const id=++serial;const timer=setTimeout(()=>{pending.delete(id);reject(new Error('TIMEOUT'));},15000);
          pending.set(id,{resolve,reject,timer});parent.postMessage({pocket:1,id,method,args},'*');
        });
        addEventListener('message',event=>{if(event.source!==parent)return;
          if(Number.isFinite(event.data?.pocketTheme)&&event.data.pocketTheme>=12&&event.data.pocketTheme<=15){document.documentElement.style.setProperty('font-size',event.data.pocketTheme+'px','important');return;}
          if(event.data?.pocket!==1)return;
          const entry=pending.get(event.data.id);if(!entry)return;pending.delete(event.data.id);clearTimeout(entry.timer);
          event.data.error?entry.reject(new Error(event.data.error)):entry.resolve(event.data.result);
        });
        let editingTimer;
        document.addEventListener('input',event=>{if(event.target.matches?.('[data-pocket-action=search]'))return;clearTimeout(editingTimer);editingTimer=setTimeout(()=>call('view.editing',{editing:true}).catch(()=>{}),120);},true);
        document.addEventListener('click',event=>{const action=event.target.closest?.('[data-pocket-action]')?.dataset.pocketAction;if(action==='save'||action==='cancel')clearTimeout(editingTimer);if(action==='cancel')call('view.editing',{editing:false}).catch(()=>{});},true);
        Object.defineProperty(window,'pocket',{value:Object.freeze({
          collections:Object.freeze({list:()=>call('collections.list'),read:collection=>call('collections.read',{collection}),
          insert:(collection,fields,revision)=>call('collections.insert',{collection,fields,revision}),
          update:(collection,id,fields,revision)=>call('collections.update',{collection,id,fields,revision}),
          delete:(collection,id,revision)=>call('collections.delete',{collection,id,revision})}),
          workflow:(workflow,inputs={})=>call('workflow.prepare',{workflow,inputs})
        }),writable:false,configurable:false});})();
        </script>
        """
        // Attribute escaping keeps even closing script/iframe tags inside the untrusted child document.
        let child = (bootstrap + html + "<style>" + PocketToolTheme.stylesheet(fontSize: fontSize) + "</style>").replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(contentPolicy)">
        <style>html,body{margin:0;width:100%;height:100%;overflow:hidden;background:#050506}iframe{display:block;width:100%;height:100%;border:0;color-scheme:dark}</style>
        </head><body><iframe id="tool" title="ツールの画面" sandbox="allow-scripts" referrerpolicy="no-referrer" srcdoc="\(child)"></iframe>
        <script>(()=>{const frame=document.getElementById('tool');let inFlight=0;
        addEventListener('message',async event=>{
          if(event.source!==frame.contentWindow||event.data?.pocket!==1)return;
          const message=event.data;
          if(!Number.isSafeInteger(message.id)||typeof message.method!=='string')return;
          const reply=value=>frame.contentWindow.postMessage({pocket:1,id:message.id,...value},'*');
          if(inFlight>=16||JSON.stringify(message).length>65536){reply({error:'LIMIT_EXCEEDED'});return;}
          inFlight++;try{const result=await window.webkit.messageHandlers.pocket.postMessage(message);reply({result});}
          catch(_){reply({error:'HOST_REQUEST_REJECTED'});}finally{inFlight--;}
        });})();</script></body></html>
        """
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandlerWithReply, WKNavigationDelegate, WKUIDelegate {
        let model: PocketSurfaceHostModel
        weak var webView: WKWebView?
        var active = true
        var fontSize: CGFloat = 13
        private var windowStarted = Date()
        private var requestCount = 0

        init(model: PocketSurfaceHostModel) { self.model = model }

        func load(html: String, in view: WKWebView) {
            let rules = "[" + ["http", "https", "ws", "wss", "ftp", "file"].map { scheme in
                "{\"trigger\":{\"url-filter\":\"^\(scheme)://\"},\"action\":{\"type\":\"block\"}}"
            }.joined(separator: ",") + "]"
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "PocketToolsNoNetwork-v1",
                encodedContentRuleList: rules) { [weak self, weak view] rules, _ in
                guard let self, self.active, let view else { return }
                guard let rules else {
                    view.loadHTMLString("<p>画面の保護設定を読み込めませんでした。</p>", baseURL: nil)
                    return
                }
                view.configuration.userContentController.add(rules)
                view.loadHTMLString(PocketHTMLSurfaceView.document(html: html, fontSize: self.fontSize), baseURL: nil)
            }
        }

        func userContentController(_ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage, replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
            guard active, model.activationAvailable, message.frameInfo.isMainFrame,
                  message.webView === webView else { replyHandler(nil, "NOT_ACTIVE"); return }
            if Date().timeIntervalSince(windowStarted) > 1 { windowStarted = Date(); requestCount = 0 }
            requestCount += 1
            guard requestCount <= 60, let object = message.body as? [String: Any],
                  JSONSerialization.isValidJSONObject(object),
                  let bytes = try? JSONSerialization.data(withJSONObject: object), bytes.count <= 65_536,
                  Set(object.keys) == ["pocket", "id", "method", "args"],
                  PocketCollectionSchema.integer(object["pocket"]) == 1,
                  PocketCollectionSchema.integer(object["id"]) != nil,
                  let method = object["method"] as? String,
                  let args = object["args"] as? [String: Any] else { replyHandler(nil, "INVALID_REQUEST"); return }
            do { replyHandler(try dispatch(method, args: args), nil) }
            catch PocketCollectionError.revisionConflict { replyHandler(nil, "REVISION_CONFLICT"); }
            catch { replyHandler(nil, "REQUEST_REJECTED"); }
        }

        private func dispatch(_ method: String, args: [String: Any]) throws -> Any {
            if method == "view.editing" {
                guard Set(args.keys) == ["editing"], let editing = args["editing"] as? Bool else { throw PocketCollectionError.invalidRecord }
                model.hasUnsavedHTMLInput = editing
                return ["editing": editing]
            }
            if method == "collections.list" {
                guard args.isEmpty else { throw PocketCollectionError.invalidRecord }
                return model.collectionSchemas.keys.sorted().map { ["id": $0, "title": model.collectionSchemas[$0]!.title] }
            }
            if method == "workflow.prepare" {
                guard Set(args.keys) == ["workflow", "inputs"], let workflow = args["workflow"] as? String,
                      let inputs = args["inputs"] as? [String: Any] else { throw PocketCollectionError.invalidRecord }
                try model.prepareHTMLWorkflow(workflow, values: inputs)
                return ["status": "preparing"]
            }
            guard let collection = args["collection"] as? String else { throw PocketCollectionError.invalidRecord }
            if method == "collections.read" {
                guard Set(args.keys) == ["collection"] else { throw PocketCollectionError.invalidRecord }
                return try model.collectionSnapshot(collection).json
            }
            guard let revision = PocketCollectionSchema.integer(args["revision"]), revision >= 0 else { throw PocketCollectionError.invalidRecord }
            if method == "collections.delete" {
                guard Set(args.keys) == ["collection", "id", "revision"], let id = args["id"] as? String else { throw PocketCollectionError.invalidRecord }
                return try model.deleteCollectionRecord(collection, recordID: id, revision: revision).json
            }
            guard method == "collections.insert" || method == "collections.update",
                  Set(args.keys) == (method == "collections.insert" ? ["collection", "fields", "revision"] : ["collection", "id", "fields", "revision"]),
                  let rawFields = args["fields"] as? [String: Any] else { throw PocketCollectionError.invalidRecord }
            let fields = try rawFields.mapValues { try PocketJSONValue(any: $0, path: "$.fields") }
            if method == "collections.update", args["id"] as? String == nil { throw PocketCollectionError.invalidRecord }
            return try model.writeCollection(collection, recordID: args["id"] as? String, fields: fields, revision: revision).json
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            let url = navigationAction.request.url?.absoluteString
            decisionHandler(active && navigationAction.navigationType == .other
                && (url == "about:blank" || (url == "about:srcdoc" && navigationAction.targetFrame?.isMainFrame == false)) ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                     decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) { decisionHandler(.deny) }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            active = false
            webView.loadHTMLString("<p>画面を停止しました。ツールを開き直してください。</p>", baseURL: nil)
        }
    }
}
