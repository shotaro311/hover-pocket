import AppKit
import SwiftUI
import WebKit

struct PocketPreviewValidationError: Error, CustomStringConvertible {
    let code: String
    var description: String { "Host preview check failed: " + code }
}

/// Runs generated surfaces with disposable stores and no capability grants.
@MainActor
enum PocketGeneratedPreviewValidator {
    private final class Receiver: NSObject, WKScriptMessageHandler {
        var result: [String: Any]?
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard !message.frameInfo.isMainFrame else { return }
            result = message.body as? [String: Any]
        }
    }

    static func validate(_ package: PocketAppPackage) async throws -> String {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PocketPreviewCheck-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let broker = CapabilityBroker(registry: try CapabilityRegistry(handlers: PocketCapabilityHandlerSet()),
            ledger: try CapabilityBrokerLedger(rootDirectory: root.appendingPathComponent("Broker")),
            auditLog: try CapabilityBrokerAuditLog(rootDirectory: root.appendingPathComponent("Broker")))
        var stores: [String: PocketCollectionStore] = [:]
        for (id, schema) in package.collections {
            stores[id] = try PocketCollectionStore(packageID: package.manifest.id, collectionID: id, schema: schema,
                                                  rootDirectory: root.appendingPathComponent("Data"))
        }
        let runtime = PocketAppExecutionRuntime(package: package, broker: broker, userID: "isolated-preview",
            grantedPermissions: [], collectionStores: stores)
        for id in package.surfaces.keys.sorted() {
            try Task.checkCancellation()
            let model = try PocketSurfaceHostModel(runtime: runtime, surfaceID: id)
            if model.surface.root.type == "html", case .string(let html)? = model.surface.root.properties["html"] {
                try await validateHTML(model: model, html: html, width: 520, testInteractions: true)
                try await validateHTML(model: model, html: html, width: 300, testInteractions: false)
            } else {
                let view = NSHostingView(rootView: PocketSurfaceHostView(model: model).environment(\.panelTextSize, .extraLarge))
                view.frame = NSRect(x: 0, y: 0, width: 520, height: 310)
                view.layoutSubtreeIfNeeded()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                    throw PocketPreviewValidationError(code: "native_render_unavailable")
                }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                guard bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0 else { throw PocketPreviewValidationError(code: "native_render_empty") }
            }
        }
        // Exercise the authoritative stores independently of generated JavaScript.
        for (id, store) in stores {
            let initial = try store.snapshot()
            let fields = sampleFields(package.collections[id]!)
            let inserted = try store.insert(fields: fields, expectedRevision: initial.revision)
            guard let record = inserted.records.last else { throw PocketPreviewValidationError(code: "store_insert") }
            _ = try store.update(id: record.id, fields: fields, expectedRevision: inserted.revision)
            let reopened = try PocketCollectionStore(packageID: package.manifest.id, collectionID: id, schema: package.collections[id]!, rootDirectory: root.appendingPathComponent("Data"))
            let readback = try reopened.snapshot()
            guard readback.records.last?.fields == fields else { throw PocketPreviewValidationError(code: "store_readback") }
            let deleted = try reopened.delete(id: record.id, expectedRevision: readback.revision)
            guard deleted.records.count == initial.records.count else { throw PocketPreviewValidationError(code: "store_delete") }
        }
        let storage = package.collections.isEmpty ? "no-collection" : "store-readback"
        if package.surfaces.values.contains(where: { $0.root.type == "html" }) {
            let interactions = package.collections.isEmpty ? "workflow-not-executed" : "representative-collection-input-save-search-cancel"
            return "contract; isolated-web-render; layout-520-and-300-max-text; \(interactions); \(storage). Workflow execution and subjective design quality require separate acceptance."
        }
        return "contract; isolated-native-render-max-text; \(storage). Native click paths, workflow execution and subjective design quality require separate acceptance."
    }

    private static func sampleFields(_ schema: PocketCollectionSchema) -> [String: PocketJSONValue] {
        schema.fields.mapValues { field in
            switch field.type {
            case "number": return .number(1)
            case "boolean": return .bool(true)
            case "date": return .string("2026-01-02")
            case "enum": return .string(field.choices.first ?? "")
            default: return .string(String("確認用の記録".prefix(field.maximumLength)))
            }
        }
    }

    private static func validateHTML(model: PocketSurfaceHostModel, html: String, width: CGFloat, testInteractions: Bool) async throws {
        let coordinator = PocketHTMLSurfaceView.Coordinator(model: model)
        let web = PocketHTMLSurfaceView.makeWebView(coordinator: coordinator, html: html, fontSize: 15)
        let receiver = Receiver()
        web.configuration.userContentController.add(receiver, name: "previewCheck")
        let fieldMap: [String: Any] = model.collectionSchemas.mapValues { sampleFields($0).mapValues(\.foundationValue) }
        let data = try JSONSerialization.data(withJSONObject: fieldMap, options: [.sortedKeys])
        guard let samples = String(data: data, encoding: .utf8) else { throw PocketPreviewValidationError(code: "sample_data") }
        let script = "const samples=" + samples + "; const interactions=" + (testInteractions ? "true;" : "false;") + Self.inspectionScript
        web.configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        web.configuration.userContentController.addUserScript(WKUserScript(source: "if(window!==top){window.__pocketErrors=[];addEventListener('error',()=>__pocketErrors.push('script_error'));addEventListener('unhandledrejection',()=>__pocketErrors.push('unhandled_rejection'));}", injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: width, height: 310), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.orderFront(nil)
        defer {
            web.configuration.userContentController.removeScriptMessageHandler(forName: "previewCheck")
            PocketHTMLSurfaceView.dismantleNSView(web, coordinator: coordinator)
            window.orderOut(nil)
        }
        let deadline = Date().addingTimeInterval(20)
        while receiver.result == nil, Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let result = receiver.result, result["ok"] as? Bool == true else {
            let code = receiver.result?["code"] as? String ?? "preview_timeout"
            let allowed = ["horizontal_overflow", "empty_surface", "script_error", "missing_add_save_cancel_search_or_field_semantics", "input_save_not_persisted", "cancel_wrote_data", "search_did_not_filter", "unhandled_rejection", "preview_timeout", "control_outside_viewport"]
            throw PocketPreviewValidationError(code: allowed.contains(code) ? code : "preview_interaction_failed")
        }
    }

    private static let inspectionScript = #"""
    if(window!==top)(async()=>{
      const wait=ms=>new Promise(r=>setTimeout(r,ms));
      const fail=code=>{throw Error(code)};
      const visible=e=>!!e&&!!(e.offsetWidth||e.offsetHeight||e.getClientRects().length)&&getComputedStyle(e).visibility!=='hidden';
      const action=name=>[...document.querySelectorAll('[data-pocket-action]')].find(e=>e.dataset.pocketAction===name&&visible(e));
      const layout=()=>{
        if(Math.max(document.documentElement.scrollWidth,document.body.scrollWidth)>innerWidth+2)fail('horizontal_overflow');
        if(!document.body.innerText.trim()&&!document.querySelector('input,button'))fail('empty_surface');
        for(const e of document.querySelectorAll('button,input,select,textarea'))if(visible(e)){
          const r=e.getBoundingClientRect();if(r.left < -2 || r.right>innerWidth+2)fail('control_outside_viewport');
        }
      };
      const setValue=(element,value)=>{
        if(element.type==='checkbox')element.checked=!!value;else element.value=String(value);
        element.dispatchEvent(new Event('input',{bubbles:true}));element.dispatchEvent(new Event('change',{bubbles:true}));
      };
      try{
        await wait(300);layout();
        const collection=document.querySelector('[data-pocket-collection]')?.dataset.pocketCollection||Object.keys(samples)[0];
        if(interactions&&collection){
          const before=await pocket.collections.read(collection);
          const add=action('add');if(!add)fail('missing_add_save_cancel_search_or_field_semantics');
          add.click();await wait(80);layout();
          for(const [key,value] of Object.entries(samples[collection])){
            const field=[...document.querySelectorAll('[data-pocket-field]')].find(e=>e.dataset.pocketField===key&&visible(e));
            if(!field)fail('missing_add_save_cancel_search_or_field_semantics');setValue(field,value);
          }
          const cancel=action('cancel');if(!cancel)fail('missing_add_save_cancel_search_or_field_semantics');
          cancel.click();await wait(120);
          if((await pocket.collections.read(collection)).revision!==before.revision)fail('cancel_wrote_data');
          const addAgain=action('add');if(!addAgain)fail('missing_add_save_cancel_search_or_field_semantics');addAgain.click();await wait(60);
          for(const [key,value] of Object.entries(samples[collection])){
            const field=[...document.querySelectorAll('[data-pocket-field]')].find(e=>e.dataset.pocketField===key&&visible(e));
            if(!field)fail('missing_add_save_cancel_search_or_field_semantics');setValue(field,value);
          }
          const save=action('save');if(!save)fail('missing_add_save_cancel_search_or_field_semantics');save.click();
          let after;for(let i=0;i<30;i++){await wait(100);after=await pocket.collections.read(collection);if(after.records.length>before.records.length)break;}
          if(after.records.length!==before.records.length+1)fail('input_save_not_persisted');
          layout();
          const search=action('search');if(!search)fail('missing_add_save_cancel_search_or_field_semantics');
          const rows=()=>[...document.querySelectorAll('[data-pocket-record]')].filter(visible);
          if(!rows().length)fail('missing_add_save_cancel_search_or_field_semantics');
          setValue(search,'zz_no_matching_preview_record_zz');await wait(200);
          if(rows().length)fail('search_did_not_filter');setValue(search,'');await wait(100);layout();
        }
        if(window.__pocketErrors?.length)fail(window.__pocketErrors[0]);
        window.webkit.messageHandlers.previewCheck.postMessage({ok:true});
      }catch(e){window.webkit.messageHandlers.previewCheck.postMessage({ok:false,code:String(e.message)});}
    })();
    """#
}
