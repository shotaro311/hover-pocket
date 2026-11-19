import AppKit
import SwiftUI

struct AiUsageOrderItem: Hashable {
    let service: AiUsageService
    let section: AiUsageSection
}

@Observable @MainActor
final class AiUsageReordering {
    private struct Drag {
        let item: AiUsageOrderItem
        let original: [AiUsageService]
        let frames: [AiUsageService: CGRect]
        var preview: [AiUsageService]
    }

    private final class FrameReference {
        weak var view: NSView?
        init(_ view: NSView) { self.view = view }
    }

    private var drag: Drag?
    @ObservationIgnored private var frameViews: [AiUsageOrderItem: FrameReference] = [:]

    func register(_ view: NSView, for item: AiUsageOrderItem) {
        frameViews[item] = FrameReference(view)
    }

    func order(in section: AiUsageSection, settings: AppSettings) -> [AiUsageService] {
        if let drag, drag.item.section == section { return drag.preview }
        return settings.aiUsageOrder(in: section)
    }

    func isMoving(_ item: AiUsageOrderItem) -> Bool { drag?.item == item }

    func begin(_ item: AiUsageOrderItem, in window: NSWindow, settings: AppSettings) {
        begin(item, in: frames(in: item.section, window: window), settings: settings)
    }

    func frames(in section: AiUsageSection, window: NSWindow) -> [AiUsageService: CGRect] {
        var frames: [AiUsageService: CGRect] = [:]
        for (key, reference) in frameViews where key.section == section {
            guard let view = reference.view, view.window === window else { continue }
            let bounds = view.convert(view.bounds, to: nil)
            let clip = view.enclosingScrollView?.contentView
            let viewport = clip.map { $0.convert($0.bounds, to: nil) } ?? bounds
            let visible = bounds.intersection(viewport)
            if !visible.isEmpty { frames[key.service] = visible }
        }
        return frames
    }

    func begin(_ item: AiUsageOrderItem, in frames: [AiUsageService: CGRect], settings: AppSettings) {
        let original = settings.aiUsageOrder(in: item.section)
        guard allowsMovement(in: item.section, settings: settings), original.contains(item.service),
              frames[item.service] != nil else { return }
        drag = Drag(item: item, original: original, frames: frames, preview: original)
    }

    func move(_ item: AiUsageOrderItem, to point: CGPoint) {
        guard var drag, drag.item == item else { return }
        guard let target = drag.original.first(where: { drag.frames[$0]?.contains(point) == true }) else { return }
        let preview = item.section.moving(item.service, to: target, in: drag.original)
        if preview != drag.preview {
            drag.preview = preview
            self.drag = drag
        }
    }

    func end(_ item: AiUsageOrderItem, at point: CGPoint, insideWindow: Bool, settings: AppSettings) {
        guard drag?.item == item else { return }
        defer { cancel() }
        guard insideWindow, allowsMovement(in: item.section, settings: settings) else { return }
        move(item, to: point)
        guard let drag, settings.aiUsageOrder(in: item.section) == drag.original else { return }
        settings.saveAiUsageOrder(drag.preview, in: item.section)
    }

    func cancel() { drag = nil }

    func step(_ item: AiUsageOrderItem, by offset: Int, among visible: [AiUsageService], settings: AppSettings) {
        guard allowsMovement(in: item.section, settings: settings) else { return }
        cancel()
        settings.stepAiUsageService(item.service, in: item.section, by: offset, among: visible)
    }

    func allowsMovement(in section: AiUsageSection, settings: AppSettings) -> Bool {
        section == .balances || settings.aiUsageLayout == .meter || settings.aiUsageSort == nil
    }
}

struct AiUsageReorderFrame: NSViewRepresentable {
    let item: AiUsageOrderItem
    let reordering: AiUsageReordering

    func makeNSView(context: Context) -> NSView { FrameView() }
    func updateNSView(_ view: NSView, context: Context) { reordering.register(view, for: item) }

    private final class FrameView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

struct AiUsageReorderHandle: NSViewRepresentable {
    let item: AiUsageOrderItem
    let title: String
    let copy: AiUsageCopy
    let settings: AppSettings
    let reordering: AiUsageReordering
    let visible: [AiUsageService]

    func makeNSView(context: Context) -> AiUsageOrderHandleView {
        let view = AiUsageOrderHandleView()
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        view.focusRingType = .exterior
        return view
    }

    func updateNSView(_ view: AiUsageOrderHandleView, context: Context) {
        view.item = item
        view.settings = settings
        view.reordering = reordering
        view.visible = visible
        let label = copy.text("\(title)を移動", "Move \(title)")
        view.setAccessibilityLabel(label)
        view.toolTip = label
        view.setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: copy.text("上へ", "Move up")) { [weak view] in
                view?.step(-1) ?? false
            },
            NSAccessibilityCustomAction(name: copy.text("下へ", "Move down")) { [weak view] in
                view?.step(1) ?? false
            }
        ])
    }
}

final class AiUsageOrderHandleView: NSView {
    var item: AiUsageOrderItem?
    weak var settings: AppSettings?
    weak var reordering: AiUsageReordering?
    var visible: [AiUsageService] = []

    var isReordering: Bool {
        guard let item else { return false }
        return reordering?.isMoving(item) == true
    }

    override var acceptsFirstResponder: Bool { true }
    override var needsPanelToBecomeKey: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.secondaryLabelColor.setFill()
        for y in [-4.5, 0, 4.5] {
            for x in [-2.25, 2.25] {
                let dot = NSRect(x: bounds.midX + x - 1.25, y: bounds.midY + y - 1.25, width: 2.5, height: 2.5)
                NSBezierPath(ovalIn: dot).fill()
            }
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        guard let item, let window, let settings else { return }
        window.makeFirstResponder(self)
        reordering?.begin(item, in: window, settings: settings)
    }

    override func mouseDragged(with event: NSEvent) {
        if let item { reordering?.move(item, to: event.locationInWindow) }
    }

    override func mouseUp(with event: NSEvent) {
        guard let item, let window, let settings else { return }
        let point = event.locationInWindow
        let inside = window.frame.contains(window.convertPoint(toScreen: point))
        reordering?.end(item, at: point, insideWindow: inside, settings: settings)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:
            if isReordering { reordering?.cancel() }
            else { super.keyDown(with: event) }
        case 123, 126: _ = step(-1)
        case 124, 125: _ = step(1)
        case 48 where event.modifierFlags.contains(.shift): window?.selectPreviousKeyView(self)
        case 48: window?.selectNextKeyView(self)
        default: super.keyDown(with: event)
        }
    }

    func step(_ offset: Int) -> Bool {
        guard let item, let settings, let reordering else { return false }
        let before = settings.aiUsageOrder(in: item.section)
        reordering.step(item, by: offset, among: visible, settings: settings)
        return before != settings.aiUsageOrder(in: item.section)
    }
}
