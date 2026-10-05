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
        web.registerForDraggedTypes([.fileURL])
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
    private var dragCompletion: CheckedContinuation<(Bool, Bool), Never>?
    private var trashRect: NSRect?
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
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { .copy }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if dragCompletion != nil {
            let over = trashRect?.contains(convert(sender.draggingLocation, from: nil)) == true
            pane?.event("assets.trashHover", ["hovered": over]); return over ? .copy : []
        }
        return .copy
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if dragCompletion != nil { return trashRect?.contains(convert(sender.draggingLocation, from: nil)) == true }
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] else { return false }
        AssetLibraryRuntime.shared.dropReceived = true
        pane?.importURLs(urls); return !urls.isEmpty
    }
    func startFileDrag(_ urls: [URL], trashBounds: [String: Double]?) async -> (Bool, Bool) {
        guard canStartFileDrag, let event = dragEvent else { return (false, false) }
        trashRect = trashBounds.map {
            let y = $0["y"] ?? 0, height = $0["height"] ?? 0
            return NSRect(x: $0["x"] ?? 0, y: isFlipped ? y : bounds.height - y - height,
                          width: $0["width"] ?? 0, height: height)
        }
        let items = urls.map { url in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            item.setDraggingFrame(NSRect(origin: convert(event.locationInWindow, from: nil), size: NSSize(width: 64, height: 64)), contents: NSWorkspace.shared.icon(forFile: url.path)); return item
        }
        return await withCheckedContinuation { continuation in
            dragCompletion = continuation
            beginDraggingSession(with: items, event: event, source: self)
        }
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ session: NSDraggingSession, endedAt point: NSPoint, operation: NSDragOperation) {
        let local = window.map { convert($0.convertPoint(fromScreen: point), from: nil) } ?? .zero
        let trash = operation != [] && trashRect?.contains(local) == true
        dragCompletion?.resume(returning: (operation != [], trash)); dragCompletion = nil; trashRect = nil
    }
}
