import Foundation
import CoreGraphics

struct LiquidSpring {
    var value: Double
    var velocity: Double = 0
    var target: Double

    // Exact critical-damping solution keeps the motion identical at 60Hz and 120Hz.
    mutating func step(seconds: Double, response: Double) {
        let omega = 2 * Double.pi / response
        let displacement = value - target
        let coefficient = velocity + omega * displacement
        let decay = exp(-omega * max(0, seconds))
        value = target + (displacement + coefficient * seconds) * decay
        velocity = (velocity - omega * coefficient * seconds) * decay
    }

    func isSettled(position: Double = 0.002, speed: Double = 0.02) -> Bool {
        abs(value - target) < position && abs(velocity) < speed
    }

    mutating func snap(_ destination: Double) {
        value = destination
        target = destination
        velocity = 0
    }
}

struct LiquidSpringRect {
    var centerX: LiquidSpring
    var top: LiquidSpring
    var width: LiquidSpring
    var height: LiquidSpring

    init(_ rect: CGRect) {
        centerX = LiquidSpring(value: rect.midX, target: rect.midX)
        top = LiquidSpring(value: rect.maxY, target: rect.maxY)
        width = LiquidSpring(value: rect.width, target: rect.width)
        height = LiquidSpring(value: rect.height, target: rect.height)
    }

    var value: CGRect {
        CGRect(x: centerX.value - width.value / 2, y: top.value - height.value,
               width: max(0, width.value), height: max(0, height.value))
    }

    var target: CGRect {
        CGRect(x: centerX.target - width.target / 2, y: top.target - height.target,
               width: width.target, height: height.target)
    }

    mutating func retarget(_ rect: CGRect) {
        centerX.target = rect.midX
        top.target = rect.maxY
        width.target = rect.width
        height.target = rect.height
    }

    mutating func step(seconds: Double) {
        centerX.step(seconds: seconds, response: PanelAnimationTiming.resizeResponse)
        top.step(seconds: seconds, response: PanelAnimationTiming.resizeResponse)
        width.step(seconds: seconds, response: PanelAnimationTiming.resizeResponse)
        height.step(seconds: seconds, response: PanelAnimationTiming.resizeResponse)
    }

    var isSettled: Bool {
        [centerX, top, width, height].allSatisfy { $0.isSettled(position: 0.1, speed: 0.5) }
    }
}

struct LiquidPanelShape {
    let rect: CGRect
    let neckRect: CGRect
    let screenTop: CGFloat
    let upperRadius: CGFloat
    let joinRadius: CGFloat
    let topRadius: CGFloat
    let bottomRadius: CGFloat
    let fillOpacity: Double
    let strokeOpacity: Double
    let contentOpacity: Double
    let contentOffset: CGFloat

    var path: CGPath {
        let path = CGMutablePath()
        let left = neckRect.minX, right = neckRect.maxX
        let r = upperRadius, j = joinRadius
        let k: CGFloat = 0.5522847498
        path.move(to: CGPoint(x: left - r, y: neckRect.minY))
        path.addLine(to: CGPoint(x: right + r, y: neckRect.minY))
        path.addLine(to: CGPoint(x: right + r, y: screenTop))
        path.addCurve(to: CGPoint(x: right, y: screenTop + r),
                      control1: CGPoint(x: right + r - k * r, y: screenTop),
                      control2: CGPoint(x: right, y: screenTop + r - k * r))
        path.addLine(to: CGPoint(x: right, y: rect.minY - j))
        path.addCurve(to: CGPoint(x: right + j, y: rect.minY),
                      control1: CGPoint(x: right, y: rect.minY - j + k * j),
                      control2: CGPoint(x: right + j - k * j, y: rect.minY))
        appendBody(to: path)
        path.addLine(to: CGPoint(x: left - j, y: rect.minY))
        path.addCurve(to: CGPoint(x: left, y: rect.minY - j),
                      control1: CGPoint(x: left - j + k * j, y: rect.minY),
                      control2: CGPoint(x: left, y: rect.minY - j + k * j))
        path.addLine(to: CGPoint(x: left, y: screenTop + r))
        path.addCurve(to: CGPoint(x: left - r, y: screenTop),
                      control1: CGPoint(x: left, y: screenTop + r - k * r),
                      control2: CGPoint(x: left - r + k * r, y: screenTop))
        path.addLine(to: CGPoint(x: left - r, y: neckRect.minY))
        path.closeSubpath()
        return path
    }

    // Leave the physical notch and the whole connection free of an outline.
    var strokePath: CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.maxX - topRadius, y: rect.minY))
        appendBody(to: path)
        return path
    }

    private func appendBody(to path: CGMutablePath) {
        let x = rect.minX, y = rect.minY, right = rect.maxX, bottom = rect.maxY
        let t = topRadius, b = bottomRadius
        let k: CGFloat = 0.5522847498
        path.addLine(to: CGPoint(x: right - t, y: y))
        path.addCurve(to: CGPoint(x: right, y: y + t),
                      control1: CGPoint(x: right - t + k * t, y: y),
                      control2: CGPoint(x: right, y: y + t - k * t))
        path.addLine(to: CGPoint(x: right, y: bottom - b))
        path.addCurve(to: CGPoint(x: right - b, y: bottom),
                      control1: CGPoint(x: right, y: bottom - b + k * b),
                      control2: CGPoint(x: right - b + k * b, y: bottom))
        path.addLine(to: CGPoint(x: x + b, y: bottom))
        path.addCurve(to: CGPoint(x: x, y: bottom - b),
                      control1: CGPoint(x: x + b - k * b, y: bottom),
                      control2: CGPoint(x: x, y: bottom - b + k * b))
        path.addLine(to: CGPoint(x: x, y: y + t))
        path.addCurve(to: CGPoint(x: x + t, y: y),
                      control1: CGPoint(x: x, y: y + t - k * t),
                      control2: CGPoint(x: x + t - k * t, y: y))
    }
}

enum LiquidPanelGeometry {
    static func shape(progress: Double, panelRect: CGRect, originWidth: CGFloat,
                      attachment: PanelAttachmentMetrics, attachmentBlend: Double) -> LiquidPanelShape {
        let p = min(1, max(0, progress))
        let blend = min(1, max(0, attachmentBlend))
        let availableWidth = max(0, panelRect.width - PanelLayout.surfaceSidePadding * 2)
        let neckWidth = min(availableWidth, max(0, attachment.notchWidth > 0
            ? attachment.notchWidth + attachment.pixelOverlap * 2 : PanelLayout.miniBarExpandedWidth))
        let origin = min(availableWidth, max(neckWidth, originWidth))
        let preserveWidth = origin + (availableWidth - origin) * (1 - pow(1 - p, 1.8))
        // The spring drives both axes from the complete closed-notch silhouette.
        let coverWidth = neckWidth + (availableWidth - neckWidth) * p
        let width = preserveWidth + (coverWidth - preserveWidth) * blend
        let bodyHeight = max(0, panelRect.height - attachment.contentTop)
        let preserveBottom = attachment.contentTop + bodyHeight * pow(p, 1.3)
        let coverBottom = attachment.contentTop + bodyHeight * p
        let bottom = preserveBottom + (coverBottom - preserveBottom) * blend
        let bodyTop = attachment.contentTop
            + (min(attachment.contentTop, coverBottom / 2) - attachment.contentTop) * blend
        let height = max(0, bottom - bodyTop)
        let connectionReveal = attachment.notchWidth > 0 ? smoothstep(0, 0.4, p) : 1
        let preserveTop = attachment.contentTop
            + (attachment.preservedNeckTop - attachment.contentTop) * connectionReveal
        let drawTop = preserveTop * (1 - blend)
        // Align the meniscus with the hardware edges, including one pixel of overlap.
        // An inset anchor exposes a step where the hardware meets the drawn curve.
        let expandedNeck = neckWidth + (width - neckWidth) * blend
        let spread = max(0, (width - expandedNeck) / 2)
        let upperRadius = min(8 * p * blend, max(0, bodyTop - drawTop))
        let preserveRadius = min(18, preserveWidth / 2, max(0, preserveBottom - attachment.contentTop) / 2)
        let coverRadius = 10 + 8 * p
        let bottomRadius = min(preserveRadius + (coverRadius - preserveRadius) * blend, width / 2, height)
        let contentOpacity = smoothstep(0.38, 0.88, p)
        return LiquidPanelShape(
            rect: CGRect(x: panelRect.midX - width / 2, y: panelRect.minY + bodyTop, width: width, height: height),
            neckRect: CGRect(x: panelRect.midX - expandedNeck / 2, y: panelRect.minY + drawTop,
                             width: expandedNeck, height: max(0, bodyTop - drawTop)),
            screenTop: panelRect.minY + drawTop,
            upperRadius: upperRadius,
            joinRadius: min(6 * (1 - blend) * connectionReveal, spread / 2,
                            max(0, bodyTop - drawTop - upperRadius)),
            topRadius: min(max(0, height - bottomRadius), spread / 2,
                           18 * (1 - blend) * smoothstep(0.10, 0.55, p)),
            bottomRadius: bottomRadius,
            // The physical notch and the meniscus share an opaque black surface.
            fillOpacity: attachment.notchWidth > 0 ? 1 : smoothstep(0, 0.08, p),
            strokeOpacity: 0.08 * smoothstep(0.55, 1, p),
            contentOpacity: contentOpacity,
            contentOffset: -10 * (1 - contentOpacity) * (1 - blend)
        )
    }

    static func smoothstep(_ low: Double, _ high: Double, _ value: Double) -> Double {
        let t = min(1, max(0, (value - low) / (high - low)))
        return t * t * (3 - 2 * t)
    }
}
