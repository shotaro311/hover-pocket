import AppKit
import SwiftUI

/// Click-through overlay window that renders the timer-alert ripple below the
/// notch bar. It lives in its own window because the access windows are only a
/// few points tall and enlarging them would disturb hover-region hit testing.
@MainActor
final class TimerAlertOverlayController {
    private var window: NSPanel?

    func show(alert: TimerAlert, on screen: NSScreen) {
        hide()
        let size = NSSize(width: 380, height: 180)
        let centerX = PanelGeometry.notchProfile(on: screen).centerX
        let frame = NSRect(
            x: centerX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.contentViewController = NSHostingController(rootView: TimerRippleView(alert: alert))
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        window = panel
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
    }
}

/// Ripple rings radiating downward from the bar, phase-locked to the bar's
/// bounce via the shared `TimerAlertAnimation.bouncePeriod`.
private struct TimerRippleView: View {
    let alert: TimerAlert

    private static let ringCount = 3
    private static let cycle = TimerAlertAnimation.bouncePeriod * Double(ringCount)

    var body: some View {
        GeometryReader { geometry in
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                staticGlow(in: geometry.size)
            } else {
                TimelineView(.animation) { context in
                    ripples(
                        elapsed: context.date.timeIntervalSince(alert.startedAt),
                        size: geometry.size
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func ripples(elapsed: TimeInterval, size: CGSize) -> some View {
        ZStack {
            ForEach(0..<Self.ringCount, id: \.self) { index in
                if let phase = ripplePhase(elapsed: elapsed, index: index) {
                    ring(phase: phase, size: size)
                }
            }
        }
        .frame(width: size.width, height: size.height)
    }

    /// A new ring spawns on every bounce; each ring travels for a full cycle.
    private func ripplePhase(elapsed: TimeInterval, index: Int) -> Double? {
        let delay = TimerAlertAnimation.bouncePeriod * Double(index)
        let ringElapsed = elapsed - delay
        guard ringElapsed >= 0 else { return nil }
        return (ringElapsed.truncatingRemainder(dividingBy: Self.cycle)) / Self.cycle
    }

    private func ring(phase: Double, size: CGSize) -> some View {
        let diameter = 26 + phase * Double(size.height) * 2.1
        let opacity = 0.72 * pow(1 - phase, 1.4)
        return Circle()
            .stroke(alert.color.color.opacity(opacity), lineWidth: 2.6 - 1.4 * phase)
            .frame(width: diameter, height: diameter)
            .position(x: size.width / 2, y: 0)
    }

    private func staticGlow(in size: CGSize) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [alert.color.color.opacity(0.4), .clear],
                    center: .center,
                    startRadius: 2,
                    endRadius: 90
                )
            )
            .frame(width: 180, height: 180)
            .position(x: size.width / 2, y: 0)
    }
}
