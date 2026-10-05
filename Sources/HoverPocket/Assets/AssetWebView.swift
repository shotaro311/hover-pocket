import AppKit
import SwiftUI
import WebKit

struct AssetWebView: NSViewRepresentable {
    let pane: AssetPaneModel
    let language: AppLanguage
    let organizer: Bool
    func makeNSView(context: Context) -> AssetNativeWebView {
        let configuration = pane.configuration()
        let settings = "window.assetConfiguration={language:'\(language == .japanese ? "ja" : "en")',organizer:\(organizer)};"
        configuration.userContentController.addUserScript(WKUserScript(source: settings, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let web = AssetNativeWebView(frame: .zero, configuration: configuration)
        web.registerForDraggedTypes(AssetIncomingDrop.types)
        pane.web = web; pane.organizer = organizer; web.pane = pane
        if organizer { AssetLibraryRuntime.shared.organizerPane = pane }
        web.navigationDelegate = pane; web.setValue(false, forKey: "drawsBackground")
        web.appearance = NSAppearance(named: .darkAqua)
        let base = Bundle.main.resourceURL!.appendingPathComponent("AssetUI")
        web.loadFileURL(base.appendingPathComponent("index.html"), allowingReadAccessTo: base)
        return web
    }
    func updateNSView(_ web: AssetNativeWebView, context: Context) {}
    static func dismantleNSView(_ web: AssetNativeWebView, coordinator: ()) {
        web.stopMouseMonitor()
        web.pane?.setActive(false); web.configuration.userContentController.removeScriptMessageHandler(forName: "assets")
    }
}

@MainActor
final class AssetNativeWebView: WKWebView, NSDraggingSource {
    weak var pane: AssetPaneModel?
    private var dragCompletion: CheckedContinuation<(Bool, [String: String]?), Never>?
    private var dropTargets: [(NSRect, [String: String])] = []
    private var acceptedDrop: [String: String]?
    private var legacyTrashTarget: [String: Any]?
    func updateDropTargets(_ targets: [[String: Any]]) {
        dropTargets = (targets + (legacyTrashTarget.map { [$0] } ?? [])).compactMap { item in
            guard let kind = item["kind"] as? String, ["folder", "trash", "favorite", "unfiled"].contains(kind),
                  let rect = item["bounds"] as? [String: Double], let x = rect["x"], let y = rect["y"],
                  let width = rect["width"], let height = rect["height"],
                  [x, y, width, height].allSatisfy({ $0.isFinite }), width > 0, height > 0 else { return nil }
            var value = ["kind": kind]
            if let id = item["folderId"] as? String { value["folderId"] = id }
            let bounds = NSRect(x: x, y: isFlipped ? y : self.bounds.height - y - height, width: width, height: height)
            return (bounds, value)
        }
    }
    private func target(at point: NSPoint) -> [String: String]? { dropTargets.first { $0.0.contains(point) }?.1 }
    private var pasteboardProviders: [AssetDragPasteboardProvider] = []
    private var mouseMonitor: Any?
    private var dragEvent: NSEvent?
    private var mouseIsDown = false
    var canStartFileDrag: Bool { mouseIsDown && dragEvent != nil && dragCompletion == nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMouseMonitor()
        if window != nil {
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
                MainActor.assumeIsolated {
                    if let self, event.window === self.window {
                        self.mouseIsDown = event.type != .leftMouseUp
                        if self.mouseIsDown { self.dragEvent = event }
                    }
                }
                return event
            }
        }
        if pane?.organizer == true { window?.delegate = pane }
    }
    func stopMouseMonitor() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil; mouseIsDown = false; dragEvent = nil
    }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if dragCompletion != nil {
            let point = convert(sender.draggingLocation, from: nil)
            pane?.event("assets.dragMoved", ["x": point.x, "y": isFlipped ? point.y : bounds.height - point.y])
            return target(at: point) != nil ? .copy : []
        }
        return AssetIncomingDrop.accepts(sender.draggingPasteboard) ? .copy : []
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if dragCompletion != nil {
            acceptedDrop = target(at: convert(sender.draggingLocation, from: nil))
            return acceptedDrop != nil
        }
        return AssetIncomingDrop.receive(sender.draggingPasteboard) { [weak self] urls, error in
            if let error { self?.pane?.event("assets.dropUnsupported", ["message": error]) }
            guard !urls.isEmpty else { return }
            AssetLibraryRuntime.shared.dropReceived = true
            self?.pane?.importURLs(urls)
        }
    }
    func startFileDrag(_ copies: [AssetDragCopy], trashBounds: [String: Double]?, dropTargets: [[String: Any]] = []) async -> (Bool, [String: String]?) {
        guard canStartFileDrag, let event = dragEvent else { return (false, nil) }
        AssetLibraryRuntime.shared.internalDrag = true
        defer { AssetLibraryRuntime.shared.internalDrag = false }
        acceptedDrop = nil
        legacyTrashTarget = trashBounds.map { ["kind": "trash", "bounds": $0] }
        updateDropTargets(dropTargets)
        pasteboardProviders = copies.map { copy in
            AssetDragPasteboardProvider(copy) { [weak self] message in
                Task { @MainActor in self?.pane?.event("assets.dropUnsupported", ["message": message]) }
            }
        }
        let items = pasteboardProviders.map { provider in
            let boardItem = NSPasteboardItem(); boardItem.setDataProvider(provider, forTypes: [.fileURL])
            let item = NSDraggingItem(pasteboardWriter: boardItem)
            item.setDraggingFrame(NSRect(origin: convert(event.locationInWindow, from: nil), size: NSSize(width: 64, height: 64)), contents: NSWorkspace.shared.icon(forFile: provider.copy.original.path)); return item
        }
        return await withCheckedContinuation { continuation in
            dragCompletion = continuation
            beginDraggingSession(with: items, event: event, source: self)
        }
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { context == .withinApplication ? [.copy, .move] : .copy }
    func draggingSession(_ session: NSDraggingSession, endedAt point: NSPoint, operation: NSDragOperation) {
        dragCompletion?.resume(returning: (operation != [], operation != [] ? acceptedDrop : nil))
        dragCompletion = nil; dropTargets = []; acceptedDrop = nil; legacyTrashTarget = nil
    }
}
