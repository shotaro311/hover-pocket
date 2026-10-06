import AppKit

extension NSRect {
    func isApproximatelyEqual(to other: NSRect, tolerance: CGFloat = 0.5) -> Bool {
        abs(minX - other.minX) <= tolerance
            && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
    }
}

enum PanelLayout {
    static let pillHeight: CGFloat = 33
    static let topEdgeOverfill: CGFloat = 3
    static let notchHandleWidth: CGFloat = 54
    static let miniBarTriggerWidth: CGFloat = 520
    static let miniBarHitHeight: CGFloat = 8
    static let miniBarRestWidth: CGFloat = 150
    static let miniBarRestHeight: CGFloat = 2
    static let miniBarExpandedWidth: CGFloat = 168
    static let miniBarExpandedHeight: CGFloat = 7
    static let miniBarExpandedTopOffset: CGFloat = 5
    static let miniBarTriggerHeight: CGFloat = miniBarExpandedTopOffset + miniBarExpandedHeight
    static let previewGap: CGFloat = 0
    static let surfaceSidePadding: CGFloat = 8

    static var defaultPillWidth: CGFloat {
        notchHandleWidth
    }

    static func previewSize(for panelSize: PanelSizeOption) -> NSSize {
        switch panelSize {
        case .small:
            return NSSize(width: 520, height: 372)
        case .medium:
            return NSSize(width: 600, height: 430)
        case .large:
            return NSSize(width: 680, height: 488)
        case .extraLarge:
            return NSSize(width: 760, height: 546)
        }
    }

    static func panelTotalSize(for panelSize: PanelSizeOption) -> NSSize {
        previewSize(for: panelSize)
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
    let surfaceOriginWidth: CGFloat
    let accessStyle: PanelAccessStyle
    let attachment: PanelAttachmentMetrics
}

struct PanelAttachmentMetrics: Equatable {
    let headerHeight: CGFloat
    let notchWidth: CGFloat
    var pixelOverlap: CGFloat = 0.5

    var preservedNeckTop: CGFloat {
        // Only the compact lower meniscus may blend into the physical notch.
        if notchWidth > 0 {
            let top = headerHeight - min(6, max(0, headerHeight / 2))
            guard pixelOverlap > 0 else { return top }
            return min(headerHeight, ceil(top / pixelOverlap) * pixelOverlap)
        }
        return 0
    }

    var contentTop: CGFloat { headerHeight }
    var reservedNotchWidth: CGFloat { notchWidth > 0 ? notchWidth + 16 : 0 }
}

enum PanelGeometry {
    static func frames(
        on screen: NSScreen,
        panelSize: PanelSizeOption,
        additionalPreviewHeight: CGFloat = 0,
        showsNotchSideHandleArea: Bool = true,
        showsVoiceConversation: Bool = false
    ) -> PanelFrames {
        let notchProfile = notchProfile(on: screen)
        let access = accessMetrics(
            on: screen,
            notchProfile: notchProfile,
            showsNotchSideHandleArea: showsNotchSideHandleArea,
            showsVoiceConversation: showsVoiceConversation
        )
        let previewSize = previewSize(
            panelSize: panelSize,
            additionalHeight: additionalPreviewHeight
        )
        let accessFrame = NSRect(
            x: access.minX,
            y: screen.frame.maxY - access.height,
            width: access.width,
            height: access.height
        )

        let notchWidth: CGFloat
        switch notchProfile {
        case let .actual(_, width, _): notchWidth = width
        case .none: notchWidth = 0
        }
        let attachment = PanelAttachmentMetrics(
            headerHeight: screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top
                : max(screen.frame.maxY - screen.visibleFrame.maxY, NSStatusBar.system.thickness),
            notchWidth: notchWidth,
            pixelOverlap: 1 / max(1, screen.backingScaleFactor)
        )
        let previewX = notchProfile.centerX - previewSize.width / 2 - PanelLayout.surfaceSidePadding
        let previewY = screen.frame.maxY - attachment.headerHeight - previewSize.height
        let previewFrame = NSRect(
            x: previewX,
            y: previewY,
            width: previewSize.width + PanelLayout.surfaceSidePadding * 2,
            height: previewSize.height + attachment.contentTop
        )

        let originWidth: CGFloat
        switch notchProfile {
        case let .actual(_, width, _):
            originWidth = min(previewSize.width, width + (showsVoiceConversation ? 108 : 0))
        case .none:
            originWidth = showsVoiceConversation ? 108 : PanelLayout.miniBarExpandedWidth
        }

        return PanelFrames(
            access: accessFrame,
            preview: previewFrame,
            surfaceOriginWidth: originWidth,
            accessStyle: access.style,
            attachment: attachment
        )
    }

    static func previewSize(
        panelSize: PanelSizeOption,
        additionalHeight: CGFloat = 0
    ) -> NSSize {
        let baseline = PanelLayout.panelTotalSize(for: panelSize)
        return NSSize(
            width: baseline.width,
            height: baseline.height + max(0, additionalHeight)
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

    static func voiceAccessHeight(topInset: CGFloat, backingScaleFactor: CGFloat) -> CGFloat {
        // Leave one physical pixel above the usable content area on each display.
        max(0, min(PanelLayout.pillHeight, topInset) - 1 / max(1, backingScaleFactor))
    }

    static func accessMetrics(
        on screen: NSScreen,
        notchProfile: ScreenNotchProfile,
        showsNotchSideHandleArea: Bool,
        showsVoiceConversation: Bool = false
    ) -> PillMetrics {
        if showsVoiceConversation {
            let topInset = screen.safeAreaInsets.top > 0
                ? screen.safeAreaInsets.top : screen.frame.maxY - screen.visibleFrame.maxY
            let height = voiceAccessHeight(topInset: topInset > 0 ? topInset : NSStatusBar.system.thickness,
                backingScaleFactor: screen.backingScaleFactor)
            let width: CGFloat
            let style: PanelAccessStyle
            switch notchProfile {
            case .actual(_, let notchWidth, _):
                width = notchWidth + PanelLayout.notchHandleWidth * 2
                style = .notchPill
            case .none:
                width = PanelLayout.notchHandleWidth * 2
                style = .miniBar
            }
            return PillMetrics(minX: notchProfile.centerX - width / 2, width: width,
                height: height, previewTopY: screen.frame.maxY - height,
                style: style)
        }
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
