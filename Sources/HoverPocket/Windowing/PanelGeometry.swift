import AppKit

enum PanelLayout {
    static let pillHeight: CGFloat = 33
    static let topEdgeOverfill: CGFloat = 3
    static let notchHandleWidth: CGFloat = 54
    static let miniBarTriggerWidth: CGFloat = 260
    static let miniBarTriggerHeight: CGFloat = 32
    static let miniBarRestWidth: CGFloat = 150
    static let miniBarRestHeight: CGFloat = 2
    static let miniBarExpandedWidth: CGFloat = 168
    static let miniBarExpandedHeight: CGFloat = 7
    static let miniBarExpandedTopOffset: CGFloat = 5
    static let previewGap: CGFloat = 0
    static let collapsedPreviewSize = NSSize(width: 72, height: 12)

    static var defaultPillWidth: CGFloat {
        notchHandleWidth
    }

    static let aiPaletteHeight: CGFloat = 132

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

    // AIパレットは Provider 領域を侵食せず、パネル全体の高さに加算する
    static func panelTotalSize(for panelSize: PanelSizeOption) -> NSSize {
        let preview = previewSize(for: panelSize)
        return NSSize(width: preview.width, height: preview.height + aiPaletteHeight)
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

enum PanelAccessStyle: Equatable {
    case notchPill
    case miniBar
}

struct PillMetrics {
    let minX: CGFloat
    let width: CGFloat
    let height: CGFloat
    let previewTopY: CGFloat
    let style: PanelAccessStyle
}

struct PanelFrames {
    let access: NSRect
    let preview: NSRect
    let collapsedPreview: NSRect
    let accessStyle: PanelAccessStyle
}

enum PanelGeometry {
    static func frames(
        on screen: NSScreen,
        panelSize: PanelSizeOption,
        showsNotchSideHandleArea: Bool = true
    ) -> PanelFrames {
        let notchProfile = notchProfile(on: screen)
        let access = accessMetrics(
            on: screen,
            notchProfile: notchProfile,
            showsNotchSideHandleArea: showsNotchSideHandleArea
        )
        let previewSize = PanelLayout.panelTotalSize(for: panelSize)
        let accessFrame = NSRect(
            x: access.minX,
            y: screen.frame.maxY - access.height,
            width: access.width,
            height: access.height
        )

        let previewX = screen.frame.midX - previewSize.width / 2
        let previewY = access.previewTopY - previewSize.height - PanelLayout.previewGap
        let previewFrame = NSRect(
            x: previewX,
            y: previewY,
            width: previewSize.width,
            height: previewSize.height
        )

        let collapsedFrame = NSRect(
            x: notchProfile.centerX - PanelLayout.collapsedPreviewSize.width / 2,
            y: access.previewTopY - PanelLayout.collapsedPreviewSize.height / 2,
            width: PanelLayout.collapsedPreviewSize.width,
            height: PanelLayout.collapsedPreviewSize.height
        )

        return PanelFrames(
            access: accessFrame,
            preview: previewFrame,
            collapsedPreview: collapsedFrame,
            accessStyle: access.style
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

    private static func accessMetrics(
        on screen: NSScreen,
        notchProfile: ScreenNotchProfile,
        showsNotchSideHandleArea: Bool
    ) -> PillMetrics {
        switch notchProfile {
        case let .actual(minX, width, _):
            guard showsNotchSideHandleArea else {
                return PillMetrics(
                    minX: minX,
                    width: width,
                    height: PanelLayout.pillHeight,
                    previewTopY: screen.frame.maxY - PanelLayout.pillHeight,
                    style: .notchPill
                )
            }
            return PillMetrics(
                minX: minX - PanelLayout.notchHandleWidth,
                width: PanelLayout.notchHandleWidth + width,
                height: PanelLayout.pillHeight,
                previewTopY: screen.frame.maxY - PanelLayout.pillHeight,
                style: .notchPill
            )
        case .none:
            return PillMetrics(
                minX: screen.frame.midX - PanelLayout.miniBarTriggerWidth / 2,
                width: PanelLayout.miniBarTriggerWidth,
                height: PanelLayout.miniBarTriggerHeight,
                previewTopY: screen.frame.maxY - PanelLayout.miniBarExpandedTopOffset - PanelLayout.miniBarExpandedHeight,
                style: .miniBar
            )
        }
    }
}
