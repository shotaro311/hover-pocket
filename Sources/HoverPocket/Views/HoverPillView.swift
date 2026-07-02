import AppKit
import SwiftUI

struct HoverPillView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var timerStore = TimerStore.shared
    let onEnter: () -> Void
    let onExit: () -> Void
    let onTap: () -> Void

    var body: some View {
        Group {
            if showsVisibleSideHandle {
                visiblePill
                    .modifier(TimerAlertBounceModifier(alert: timerStore.activeAlert))
            } else {
                Color.black.opacity(0.001)
            }
        }
        .frame(
            minWidth: PanelLayout.notchHandleWidth,
            idealWidth: PanelLayout.defaultPillWidth,
            maxWidth: .infinity
        )
        .frame(height: PanelLayout.pillHeight)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { inside in
            inside ? onEnter() : onExit()
        }
    }

    private var showsVisibleSideHandle: Bool {
        settings.showNotchSideHandleArea && settings.pillHandleIconStyle != .none
    }

    private var alertAccent: Color? {
        timerStore.activeAlert?.color.color
    }

    private var visiblePill: some View {
        ZStack(alignment: .leading) {
            TopDockedPillShape(radius: 10)
                .fill(Color.black.opacity(0.94))

            TopDockedPillShape(radius: 10)
                .strokeBorder(alertAccent?.opacity(0.85) ?? Color.white.opacity(0.09), lineWidth: 1)

            VStack(spacing: 0) {
                Rectangle()
                    .fill(Color.black.opacity(0.94))
                    .frame(height: PanelLayout.topEdgeOverfill)

                Spacer(minLength: 0)
            }
            .allowsHitTesting(false)

            ZStack {
                handleIcon
            }
            .frame(width: PanelLayout.notchHandleWidth, height: PanelLayout.pillHeight)
        }
    }

    @ViewBuilder
    private var handleIcon: some View {
        switch settings.pillHandleIconStyle {
        case .chevron:
            Image(systemName: "chevron.down")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(alertAccent ?? Color.white.opacity(0.72))
        case .pocket:
            PocketHandleGlyph()
                .frame(width: 15, height: 13)
        case .none:
            EmptyView()
        }
    }
}

/// Repeats a small peeking bounce while a timer alert is active: the bar rests
/// retracted into the top edge and pops downward, so it never detaches from
/// the screen edge. Skipped entirely when Reduce Motion is on.
struct TimerAlertBounceModifier: ViewModifier {
    let alert: TimerAlert?

    func body(content: Content) -> some View {
        if let alert, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            TimelineView(.animation) { context in
                content.offset(
                    y: Self.bounceOffset(elapsed: context.date.timeIntervalSince(alert.startedAt))
                )
            }
        } else {
            content
        }
    }

    /// Always <= 0: the bar starts pulled up into the edge (clipped by the
    /// window), pops down to its natural position mid-cycle, and pulls back.
    static func bounceOffset(elapsed: TimeInterval) -> CGFloat {
        guard elapsed >= 0 else { return 0 }
        let period = TimerAlertAnimation.bouncePeriod
        let phase = elapsed.truncatingRemainder(dividingBy: period) / period
        return CGFloat(-4.0 * (1 - abs(sin(.pi * phase))))
    }
}

struct HoverMiniBarView: View {
    let onBarEnter: () -> Void
    let onBarExit: () -> Void
    let onTap: () -> Void
    @State private var isPointerNear = false
    @ObservedObject private var timerStore = TimerStore.shared

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                Color.black.opacity(0.001)
                    .frame(
                        width: PanelLayout.miniBarTriggerWidth,
                        height: PanelLayout.miniBarHitHeight
                    )
                    .contentShape(Rectangle())
                    .onHover { inside in
                        withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.86)) {
                            isPointerNear = inside
                        }
                        if inside {
                            onBarEnter()
                        } else {
                            onBarExit()
                        }
                    }
                    .onTapGesture(perform: onTap)

                Spacer(minLength: 0)
            }
            .zIndex(1)

            VStack(spacing: 0) {
                bar
                    .modifier(TimerAlertBounceModifier(alert: timerStore.activeAlert))
                    .offset(y: isExpandedLook ? PanelLayout.miniBarExpandedTopOffset : 0)

                Spacer(minLength: 0)
            }
        }
        .frame(
            width: PanelLayout.miniBarTriggerWidth,
            height: PanelLayout.miniBarTriggerHeight
        )
        .contentShape(Rectangle())
    }

    private var alertAccent: Color? {
        timerStore.activeAlert?.color.color
    }

    /// While a timer alert is active the bar keeps its expanded look even
    /// without hover, so the bounce and tint stay visible.
    private var isExpandedLook: Bool {
        isPointerNear || alertAccent != nil
    }

    private var bar: some View {
        RoundedRectangle(cornerRadius: isExpandedLook ? 3.5 : 1, style: .continuous)
            .fill(barFillColor)
            .frame(
                width: isExpandedLook ? PanelLayout.miniBarExpandedWidth : PanelLayout.miniBarRestWidth,
                height: isExpandedLook ? PanelLayout.miniBarExpandedHeight : PanelLayout.miniBarRestHeight
            )
            .overlay(
                RoundedRectangle(cornerRadius: isExpandedLook ? 3.5 : 1, style: .continuous)
                    .stroke(barStrokeColor, lineWidth: 0.6)
            )
            .shadow(color: Color.black.opacity(isExpandedLook ? 0.18 : 0), radius: 8, y: 4)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .animation(.interactiveSpring(response: 0.22, dampingFraction: 0.86), value: isExpandedLook)
    }

    private var barFillColor: Color {
        if let alertAccent {
            return alertAccent.opacity(0.66)
        }
        return Color.black.opacity(isExpandedLook ? 0.58 : 0.26)
    }

    private var barStrokeColor: Color {
        if let alertAccent {
            return alertAccent.opacity(0.9)
        }
        return Color.white.opacity(isExpandedLook ? 0.16 : 0.05)
    }
}

private struct PocketHandleGlyph: View {
    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let dotSize = min(size.width, size.height) * 0.22

            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.72))
                    .frame(width: dotSize, height: dotSize)
                    .position(x: size.width / 2, y: dotSize * 0.82)

                PocketCupShape()
                    .stroke(
                        Color.white.opacity(0.72),
                        style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)
                    )
            }
        }
    }
}

private struct PocketCupShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let topY = rect.minY + rect.height * 0.48
        let bottomY = rect.minY + rect.height * 0.82
        let leftX = rect.minX + rect.width * 0.18
        let rightX = rect.maxX - rect.width * 0.18
        let centerX = rect.midX
        path.move(to: CGPoint(x: leftX, y: topY))
        path.addLine(to: CGPoint(x: leftX, y: bottomY - 1))
        path.addQuadCurve(
            to: CGPoint(x: rightX, y: bottomY - 1),
            control: CGPoint(x: centerX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rightX, y: topY))

        return path
    }
}
