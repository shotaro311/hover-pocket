import AppKit

@MainActor
final class AssetScreenshotToast: NSObject, NSDraggingSource {
    private let panel: NSPanel
    private let image: CGImage
    private let file: URL
    private var remaining: TimeInterval
    private var timer: Timer?
    private var lastTick = Date()
    private var dragging = false
    init(image: CGImage, file: URL, seconds: Int, screen: NSScreen) {
        self.image = image; self.file = file; remaining = Double(seconds)
        let visible = screen.visibleFrame
        panel = NSPanel(contentRect: CGRect(x: visible.maxX - 320, y: visible.minY + 24, width: 296, height: 180),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.level = .floating; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = true; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = ToastView(image: image); view.owner = self; panel.contentView = view
    }
    func show() {
        panel.orderFrontRegardless(); lastTick = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }
    private func tick() {
        let now = Date(), elapsed = now.timeIntervalSince(lastTick); lastTick = now
        guard !dragging, NSEvent.pressedMouseButtons == 0, !panel.frame.contains(NSEvent.mouseLocation) else { return }
        remaining -= elapsed; if remaining <= 0 { close() }
    }
    func close() { timer?.invalidate(); timer = nil; panel.orderOut(nil) }
    fileprivate func drag(from view: NSView, event: NSEvent) {
        guard !dragging else { return }; dragging = true
        let item = NSDraggingItem(pasteboardWriter: file as NSURL)
        item.setDraggingFrame(view.bounds.insetBy(dx: 12, dy: 24), contents: NSImage(cgImage: image, size: CGSize(width: 270, height: 130)))
        view.beginDraggingSession(with: [item], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ session: NSDraggingSession, endedAt point: NSPoint, operation: NSDragOperation) {
        dragging = false; lastTick = Date(); if operation != [] { close() }
    }
    private final class ToastView: NSView {
        weak var owner: AssetScreenshotToast?
        let image: CGImage
        private var down: CGPoint?
        init(image: CGImage) { self.image = image; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func draw(_ dirtyRect: NSRect) {
            NSColor(calibratedWhite: 0.13, alpha: 0.98).setFill(); NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14).fill()
            let area = bounds.insetBy(dx: 12, dy: 28), scale = min(area.width / CGFloat(image.width), area.height / CGFloat(image.height))
            let size = CGSize(width: CGFloat(image.width)*scale, height: CGFloat(image.height)*scale)
            NSImage(cgImage: image, size: size).draw(in: CGRect(x: area.midX-size.width/2, y: area.midY-size.height/2, width: size.width, height: size.height))
            ("保存済み · ドラッグで取り出す" as NSString).draw(at: CGPoint(x: 12, y: 8), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.white])
            ("×" as NSString).draw(at: CGPoint(x: bounds.maxX-25, y: bounds.maxY-25), withAttributes: [.font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor.white])
        }
        override func mouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            if point.x > bounds.maxX-36 && point.y > bounds.maxY-36 { owner?.close(); return }; down = point
        }
        override func mouseDragged(with event: NSEvent) {
            guard let down else { return }; let point = convert(event.locationInWindow, from: nil)
            if hypot(point.x-down.x, point.y-down.y) > 3 { self.down = nil; owner?.drag(from: self, event: event) }
        }
        override func mouseUp(with event: NSEvent) { down = nil }
    }
}
