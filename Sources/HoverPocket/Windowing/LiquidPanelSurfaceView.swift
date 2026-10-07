import AppKit
import QuartzCore

private final class LiquidShapeView: NSView {
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func makeBackingLayer() -> CALayer { CAShapeLayer() }
    var shapeLayer: CAShapeLayer { layer as! CAShapeLayer }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class LiquidContentView: NSView {
    override var isFlipped: Bool { true }
}

final class LiquidPanelSurfaceView: NSView {
    override var isFlipped: Bool { true }
    private let fillView = LiquidShapeView()
    private let contentContainer = LiquidContentView()
    private let strokeView = LiquidShapeView()
    private let maskLayer = CAShapeLayer()
    private let strokeClipLayer = CAShapeLayer()
    let hostingView: NSView
    private(set) var currentShape = LiquidPanelGeometry.shape(
        progress: 0, panelRect: .zero, originWidth: 0,
        attachment: PanelAttachmentMetrics(headerHeight: 0, notchWidth: 0), attachmentBlend: 0)

    init(hostingView: NSView) {
        self.hostingView = hostingView
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
        for view in [fillView, contentContainer, strokeView] {
            view.wantsLayer = true
            view.layerContentsRedrawPolicy = .never
            addSubview(view)
        }
        fillView.shapeLayer.fillColor = NSColor.black.cgColor
        strokeView.shapeLayer.fillColor = nil
        strokeView.shapeLayer.strokeColor = NSColor.white.cgColor
        strokeView.shapeLayer.lineWidth = 1
        strokeView.layer?.mask = strokeClipLayer
        contentContainer.layer?.mask = maskLayer
        contentContainer.addSubview(hostingView)
        hostingView.autoresizingMask = []
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        AssetLibraryRuntime.shared.canAcceptDrop?() == true ? .copy : []
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard AssetLibraryRuntime.shared.canAcceptDrop?() == true,
              let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
        if !AssetLibraryRuntime.shared.incomingDrag { AssetLibraryRuntime.shared.openForDrop?() }
        AssetLibraryRuntime.shared.receiveDrop(urls); return true
    }

    func layoutContent(size: NSSize) {
        hostingView.setFrameSize(NSSize(width: max(0, size.width - PanelLayout.surfaceSidePadding * 2),
                                        height: size.height))
    }

    func apply(progress: Double, screenRect: NSRect, contentRect: NSRect, originWidth: CGFloat,
               attachment: PanelAttachmentMetrics, attachmentBlend: Double) {
        guard let window else { return }
        let localRect = CGRect(x: screenRect.minX - window.frame.minX,
                               y: window.frame.maxY - screenRect.maxY,
                               width: screenRect.width, height: screenRect.height)
        let shape = LiquidPanelGeometry.shape(progress: progress, panelRect: localRect, originWidth: originWidth,
                                              attachment: attachment, attachmentBlend: attachmentBlend)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for view in [fillView, contentContainer, strokeView] { view.frame = bounds }
        if contentContainer.layer?.mask !== maskLayer { contentContainer.layer?.mask = maskLayer }
        maskLayer.frame = contentContainer.bounds
        maskLayer.path = shape.path
        fillView.shapeLayer.path = shape.path
        fillView.shapeLayer.fillColor = NSColor.black.withAlphaComponent(shape.fillOpacity).cgColor
        strokeView.shapeLayer.path = shape.strokePath
        strokeView.shapeLayer.fillColor = nil
        strokeView.shapeLayer.strokeColor = NSColor.white.withAlphaComponent(shape.strokeOpacity).cgColor
        strokeView.shapeLayer.lineWidth = 1
        // The border belongs to the body, never across the notch-to-body connection.
        strokeClipLayer.frame = strokeView.bounds
        let strokeTop = attachment.notchWidth > 0
            ? shape.screenTop + max(0, shape.rect.minY - shape.screenTop)
                * (1 - min(1, max(0, attachmentBlend)))
            : shape.screenTop
        strokeClipLayer.path = CGPath(rect: CGRect(x: bounds.minX, y: strokeTop,
            width: bounds.width, height: max(0, bounds.maxY - strokeTop)), transform: nil)
        let top = window.frame.maxY - screenRect.maxY + shape.contentOffset
        hostingView.setFrameOrigin(NSPoint(x: screenRect.midX - window.frame.minX - hostingView.frame.width / 2,
                                          y: top))
        hostingView.alphaValue = shape.contentOpacity
        hostingView.setAccessibilityHidden(shape.contentOpacity < 0.6)
        CATransaction.commit()
        currentShape = shape
    }

    func contains(screenPoint: NSPoint, tolerance: CGFloat = 0) -> Bool {
        guard let window else { return false }
        let local = NSPoint(x: screenPoint.x - window.frame.minX, y: window.frame.maxY - screenPoint.y)
        if currentShape.path.contains(local) { return true }
        return tolerance > 0 && currentShape.path.copy(strokingWithWidth: tolerance * 2,
            lineCap: .round, lineJoin: .round, miterLimit: 2).contains(local)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        guard currentShape.path.contains(local) else { return nil }
        guard currentShape.contentOpacity >= 0.6 else { return self }
        return super.hitTest(point)
    }
}
