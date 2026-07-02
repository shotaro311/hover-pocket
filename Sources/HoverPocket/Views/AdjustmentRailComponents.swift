import AppKit
import SwiftUI

/// Shared inline adjustment rail used by the Calendar date/time editor and the
/// Timer duration editor. Shows tick marks with an accent dot that follows the
/// current drag/scroll offset.
struct AdjustmentRail: View {
    let isActive: Bool
    let offset: CGFloat
    let accentColor: Color

    var body: some View {
        ZStack(alignment: .center) {
            Capsule()
                .fill(Color.white.opacity(isActive ? 0.06 : 0))
                .frame(height: 14)

            HStack(spacing: 4) {
                ForEach(0..<23, id: \.self) { index in
                    Capsule()
                        .fill(tickColor(for: index))
                        .frame(width: 1.4, height: index % 4 == 0 ? 12 : 7)
                }
            }

            Capsule()
                .fill(accentColor.opacity(isActive ? 0.72 : 0))
                .frame(width: 3, height: 18)

            Circle()
                .fill(accentColor.opacity(isActive ? 1 : 0))
                .frame(width: 15, height: 15)
                .shadow(color: accentColor.opacity(isActive ? 0.48 : 0), radius: 8, x: 0, y: 0)
                .offset(x: offset)
        }
        .frame(height: 24)
        .opacity(isActive ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: isActive)
    }

    private func tickColor(for index: Int) -> Color {
        guard isActive else {
            return .clear
        }
        return index == 11 ? accentColor.opacity(0.9) : Color.white.opacity(index % 4 == 0 ? 0.42 : 0.26)
    }
}

/// AppKit-backed capture layer that turns raw drag/scroll events on the rail
/// into adjustment callbacks.
struct RailInputCaptureView: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: () -> Void

    func makeNSView(context: Context) -> RailInputCaptureNSView {
        let view = RailInputCaptureNSView()
        view.onScroll = onScroll
        view.onDragChanged = onDragChanged
        view.onDragEnded = onDragEnded
        return view
    }

    func updateNSView(_ nsView: RailInputCaptureNSView, context: Context) {
        nsView.onScroll = onScroll
        nsView.onDragChanged = onDragChanged
        nsView.onDragEnded = onDragEnded
    }
}

final class RailInputCaptureNSView: NSView {
    var onScroll: (CGFloat) -> Void = { _ in }
    var onDragChanged: (CGFloat) -> Void = { _ in }
    var onDragEnded: () -> Void = {}

    private var dragStartX: CGFloat?

    override func hitTest(_ point: NSPoint) -> NSView? {
        self
    }

    override func mouseDown(with event: NSEvent) {
        dragStartX = convert(event.locationInWindow, from: nil).x
    }

    override func mouseDragged(with event: NSEvent) {
        let currentX = convert(event.locationInWindow, from: nil).x
        let startX = dragStartX ?? currentX
        dragStartX = startX
        onDragChanged(currentX - startX)
    }

    override func mouseUp(with event: NSEvent) {
        dragStartX = nil
        onDragEnded()
    }

    override func mouseExited(with event: NSEvent) {
        dragStartX = nil
    }

    override func scrollWheel(with event: NSEvent) {
        let dominantDelta = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX)
            ? event.scrollingDeltaY
            : event.scrollingDeltaX

        guard dominantDelta != 0 else {
            super.scrollWheel(with: event)
            return
        }

        onScroll(dominantDelta)
    }
}
