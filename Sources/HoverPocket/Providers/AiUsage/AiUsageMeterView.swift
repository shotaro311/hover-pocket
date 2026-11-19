import SwiftUI

struct AiUsageMeterView: View {
    static let width: CGFloat = 116
    static let height: CGFloat = 106

    let quota: AiUsageQuota
    let copy: AiUsageCopy
    let now: Date
    var readingOpacity: Double = 1
    private var window: AiUsageWindow { quota.window }

    var body: some View {
        ZStack(alignment: .top) {
            Canvas { context, _ in
                let remaining = window.remaining
                var arcs = context
                arcs.opacity = readingOpacity
                arcs.stroke(arc(radius: 46, from: 0, to: 100), with: .color(aiUsageColor(0x161b22)), lineWidth: 5)
                for (index, tint) in AiUsageTint.allCases.enumerated() {
                    let upper = AiUsageTint.allCases.dropFirst(index + 1).first?.lowerBound ?? 100
                    let lower = tint.lowerBound
                    let path = arc(radius: 51, from: lower == 0 ? lower : lower + 0.7,
                                   to: upper == 100 ? upper : upper - 0.7)
                    let color = remaining == nil ? aiUsageColor(0x343b46) : tint.color.opacity(0.45)
                    arcs.stroke(path, with: .color(color), lineWidth: 1.6)
                }
                for tick in stride(from: 0, through: 100, by: 5) {
                    let major = tick.isMultiple(of: 25)
                    let path = radialLine(at: Double(tick), from: major ? 37.5 : 39.5, to: 42)
                    context.stroke(path, with: .color(aiUsageColor(major ? 0x8a94a6 : 0x343b46)), lineWidth: 1)
                }
                if let remaining {
                    let tint = AiUsageTint(remaining: remaining).color
                    if remaining > 0 {
                        arcs.stroke(arc(radius: 46, from: 0, to: remaining), with: .color(tint),
                                       style: StrokeStyle(lineWidth: 5, dash: [2.6, 1.3]))
                    }
                    arcs.stroke(radialLine(at: remaining, from: 37, to: 52), with: .color(.white),
                                   style: StrokeStyle(lineWidth: 2, lineCap: .round))
                }
            }

            Text(copy.text("残り", "left"))
                .font(.system(size: 11)).foregroundStyle(aiUsageColor(0x697386))
                .position(x: 58, y: 35)
            value.position(x: 58, y: 55)
            Text(copy.windowLabel(window))
                .font(.system(size: 11)).foregroundStyle(aiUsageColor(0x9ba6b5))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 58)
                .position(x: 58, y: 76)
            if let detail = quota.meterDetail(copy, now: now) {
                Text(detail).font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(aiUsageColor(0x697386))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(width: Self.width)
                    .position(x: 58, y: 98)
            }
        }
        .frame(width: Self.width, height: Self.height)
        .help(quota.help(copy))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(copy.meterAccessibility(quota, now: now))
    }

    @ViewBuilder private var value: some View {
        if let remaining = window.remaining {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(String(copy.percent(remaining).dropLast()))
                    .font(.system(size: 22, weight: .semibold)).monospacedDigit()
                Text("%").font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(AiUsageTint(remaining: remaining).color)
            .opacity(readingOpacity)
        } else {
            Text("—").font(.system(size: 22)).foregroundStyle(aiUsageColor(0x9ba6b5))
        }
    }

    private static let center = CGPoint(x: 58, y: 54)

    static func angle(at remaining: Double) -> Double { 135 + 270 * remaining / 100 }

    private func arc(radius: CGFloat, from start: Double, to end: Double) -> Path {
        Path { path in
            path.addRelativeArc(center: Self.center, radius: radius,
                                startAngle: .degrees(Self.angle(at: start)),
                                delta: .degrees(Self.angle(at: end) - Self.angle(at: start)))
        }
    }

    private func radialLine(at remaining: Double, from inner: CGFloat, to outer: CGFloat) -> Path {
        let radians = Self.angle(at: remaining) * .pi / 180
        func point(_ radius: CGFloat) -> CGPoint {
            CGPoint(x: Self.center.x + cos(radians) * radius, y: Self.center.y + sin(radians) * radius)
        }
        return Path { path in
            path.move(to: point(inner))
            path.addLine(to: point(outer))
        }
    }
}
