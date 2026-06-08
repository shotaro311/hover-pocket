import AppKit

enum PanelLayout {
    static let pillHeight: CGFloat = 33
    static let topEdgeOverfill: CGFloat = 3
    static let notchHandleWidth: CGFloat = 54
    static let previewGap: CGFloat = 0
    static let collapsedPreviewSize = NSSize(width: 72, height: 12)

    static var defaultPillWidth: CGFloat {
        notchHandleWidth
    }

    static func previewSize(for panelSize: PanelSizeOption) -> NSSize {
        switch panelSize {
        case .small:
            return NSSize(width: 456, height: 326)
        case .medium:
            return NSSize(width: 520, height: 372)
        case .large:
            return NSSize(width: 600, height: 430)
        }
    }
}

enum ScreenNotchProfile {
    case actual(minX: CGFloat, width: CGFloat, centerX: CGFloat)
    case none(centerX: CGFloat)

    var centerX: CGFloat {
        switch self {
        case let .actual(_, _, centerX), let .none(centerX):
            centerX
        }
    }
}

struct PillMetrics {
    let minX: CGFloat
    let width: CGFloat
}

struct PanelFrames {
    let pill: NSRect
    let preview: NSRect
    let collapsedPreview: NSRect
}

enum PanelGeometry {
    static func frames(on screen: NSScreen, panelSize: PanelSizeOption) -> PanelFrames {
        let notchProfile = notchProfile(on: screen)
        let pill = pillMetrics(on: screen, notchProfile: notchProfile)
        let previewSize = PanelLayout.previewSize(for: panelSize)
        let pillY = screen.frame.maxY - PanelLayout.pillHeight
        let pillFrame = NSRect(
            x: pill.minX,
            y: pillY,
            width: pill.width,
            height: PanelLayout.pillHeight
        )

        let previewX = screen.frame.midX - previewSize.width / 2
        let previewY = pillFrame.minY - previewSize.height - PanelLayout.previewGap
        let previewFrame = NSRect(
            x: previewX,
            y: previewY,
            width: previewSize.width,
            height: previewSize.height
        )

        let collapsedFrame = NSRect(
            x: notchProfile.centerX - PanelLayout.collapsedPreviewSize.width / 2,
            y: pillFrame.midY - PanelLayout.collapsedPreviewSize.height / 2,
            width: PanelLayout.collapsedPreviewSize.width,
            height: PanelLayout.collapsedPreviewSize.height
        )

        return PanelFrames(
            pill: pillFrame,
            preview: previewFrame,
            collapsedPreview: collapsedFrame
        )
    }

    static func notchProfile(on screen: NSScreen) -> ScreenNotchProfile {
        if let leftArea = screen.auxiliaryTopLeftArea,
           let rightArea = screen.auxiliaryTopRightArea,
           rightArea.minX > leftArea.maxX {
            let minX = leftArea.maxX
            let width = rightArea.minX - leftArea.maxX
            return .actual(minX: minX, width: width, centerX: minX + width / 2)
        }

        return .none(centerX: screen.frame.midX)
    }

    private static func pillMetrics(on screen: NSScreen, notchProfile: ScreenNotchProfile) -> PillMetrics {
        switch notchProfile {
        case let .actual(minX, width, _):
            return PillMetrics(
                minX: minX - PanelLayout.notchHandleWidth,
                width: PanelLayout.notchHandleWidth + width
            )
        case .none:
            return PillMetrics(
                minX: screen.frame.midX - PanelLayout.notchHandleWidth / 2,
                width: PanelLayout.notchHandleWidth
            )
        }
    }
}
