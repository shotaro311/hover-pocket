import AppKit
import QuartzCore

@MainActor
private final class LiquidDisplayLinkTarget: NSObject {
    weak var owner: LiquidPanelAnimator?
    @objc func tick(_ link: CADisplayLink) { owner?.tick(link) }
}

@MainActor
final class LiquidPanelAnimator {
    weak var view: LiquidPanelSurfaceView?
    private(set) var reveal = LiquidSpring(value: 0, target: 0)
    private(set) var rect = LiquidSpringRect(.zero)
    private(set) var attachmentReveal = LiquidSpring(value: 0, target: 0)
    private var attachment = PanelAttachmentMetrics(headerHeight: 0, notchWidth: 0)
    var originWidth: CGFloat = 168
    var onSettled: (() -> Void)?
    private var response = PanelAnimationTiming.openResponse
    private var link: CADisplayLink?
    private let linkTarget = LiquidDisplayLinkTarget()
    private var lastTimestamp: CFTimeInterval?
    var isIdle: Bool { link == nil }

    init() { linkTarget.owner = self }

    isolated deinit { link?.invalidate() }

    func snap(progress: Double, frame: NSRect) {
        stop()
        reveal.snap(progress)
        rect = LiquidSpringRect(frame)
        apply()
    }

    func retargetFrame(_ frame: NSRect, animated: Bool) {
        if animated {
            rect.retarget(frame)
            start()
        } else {
            rect = LiquidSpringRect(frame)
            apply()
        }
    }

    func setReveal(_ target: Double) {
        reveal.target = target
        response = target == 1 ? PanelAnimationTiming.openResponse : PanelAnimationTiming.closeResponse
        start()
    }

    func setAttachment(_ metrics: PanelAttachmentMetrics, style: PanelAttachmentStyle, animated: Bool) {
        attachment = metrics
        if animated {
            attachmentReveal.target = style.blend
            if !attachmentReveal.isSettled() { start() }
        } else {
            attachmentReveal.snap(style.blend)
        }
    }

    func apply() {
        view?.apply(progress: reveal.value, screenRect: rect.value,
                    contentRect: rect.target, originWidth: originWidth,
                    attachment: attachment, attachmentBlend: attachmentReveal.value)
    }

    private func start() {
        guard link == nil, let view, view.window != nil else { return }
        lastTimestamp = nil
        let displayLink = view.displayLink(target: linkTarget, selector: #selector(LiquidDisplayLinkTarget.tick(_:)))
        displayLink.add(to: .main, forMode: .common)
        link = displayLink
    }

    fileprivate func tick(_ displayLink: CADisplayLink) {
        let now = displayLink.targetTimestamp
        let seconds = min(1.0 / 30, max(0, now - (lastTimestamp ?? displayLink.timestamp)))
        lastTimestamp = now
        reveal.step(seconds: seconds, response: response)
        rect.step(seconds: seconds)
        attachmentReveal.step(seconds: seconds, response: PanelAnimationTiming.resizeResponse)
        // Closing completes once the invisible surface has reached its origin.
        if reveal.target == 0 && reveal.value <= 0.012 {
            reveal.snap(0)
        }
        if reveal.isSettled() && rect.isSettled && attachmentReveal.isSettled() {
            reveal.snap(reveal.target)
            attachmentReveal.snap(attachmentReveal.target)
            rect = LiquidSpringRect(rect.target)
            apply()
            stop()
            onSettled?()
        } else {
            apply()
        }
    }

    private func stop() {
        link?.invalidate()
        link = nil
        lastTimestamp = nil
    }
}
