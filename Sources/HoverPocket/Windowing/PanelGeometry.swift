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
    static let collapsedPreviewSize = NSSize(width: 72, height: 12)
    static let compactVoiceLaneHeight: CGFloat = 64

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

    static func voiceLaneHeight(
        for panelSize: PanelSizeOption,
        mode: VoiceLaneDisplayMode
    ) -> CGFloat {
        switch mode {
        case .disabled:
            return 0
        case .compact:
            return compactVoiceLaneHeight
        case .expanded:
            switch panelSize {
            case .small:
                return 190
            case .medium:
                return 220
            case .large:
                return 250
            case .extraLarge:
                return 280
            }
        }
    }

    static func resolvedVoiceLaneMode(
        requested: VoiceLaneDisplayMode,
        panelSize: PanelSizeOption,
        availableHeight: CGFloat
    ) -> VoiceLaneDisplayMode {
        guard requested == .expanded else { return requested }
        let expandedHeight = panelTotalSize(for: panelSize, voiceLaneMode: .expanded).height
        return expandedHeight <= availableHeight ? .expanded : .compact
    }

    static func panelTotalSize(
        for panelSize: PanelSizeOption,
        voiceLaneMode: VoiceLaneDisplayMode = .disabled
    ) -> NSSize {
        let baseline = previewSize(for: panelSize)
        return NSSize(
            width: baseline.width,
            height: baseline.height + voiceLaneHeight(for: panelSize, mode: voiceLaneMode)
        )
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
    let voiceLaneMode: VoiceLaneDisplayMode
}

enum PanelGeometry {
    static func frames(
        on screen: NSScreen,
        panelSize: PanelSizeOption,
        requestedVoiceLaneMode: VoiceLaneDisplayMode = .disabled,
        showsNotchSideHandleArea: Bool = true
    ) -> PanelFrames {
        let notchProfile = notchProfile(on: screen)
        let access = accessMetrics(
            on: screen,
            notchProfile: notchProfile,
            showsNotchSideHandleArea: showsNotchSideHandleArea
        )
        let availableHeight = max(0, access.previewTopY - screen.visibleFrame.minY)
        let resolvedVoiceLaneMode = PanelLayout.resolvedVoiceLaneMode(
            requested: requestedVoiceLaneMode,
            panelSize: panelSize,
            availableHeight: availableHeight
        )
        let previewSize = PanelLayout.panelTotalSize(
            for: panelSize,
            voiceLaneMode: resolvedVoiceLaneMode
        )
        let accessFrame = NSRect(
            x: access.minX,
            y: screen.frame.maxY - access.height,
            width: access.width,
            height: access.height
        )

        let previewX = notchProfile.centerX - previewSize.width / 2
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
            accessStyle: access.style,
            voiceLaneMode: resolvedVoiceLaneMode
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
