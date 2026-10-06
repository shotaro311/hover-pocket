import AppKit

@MainActor
struct PanelScreenSelection {
    let mode: DisplayPlacementMode

    var access: [NSScreen] {
        switch mode {
        case .allDisplays:
            return NSScreen.screens.sorted(by: Self.precedes)
        case .mainDisplay, .secondaryDisplay:
            return target.map { [$0] } ?? []
        }
    }

    var target: NSScreen? {
        switch mode {
        case .mainDisplay: return main
        case .secondaryDisplay: return secondary ?? main
        case .allDisplays: return containingMouse ?? main
        }
    }

    func isSecondaryDisplay(_ screen: NSScreen) -> Bool {
        guard let main else { return false }
        return !Self.isSameDisplay(screen, main)
    }

    static func isSameDisplay(_ lhs: NSScreen, _ rhs: NSScreen) -> Bool {
        if let lhsID = lhs.displayID, let rhsID = rhs.displayID { return lhsID == rhsID }
        return lhs === rhs
    }

    static func key(_ screen: NSScreen) -> String {
        if let displayID = screen.displayID { return String(displayID) }
        return "\(screen.frame.origin.x),\(screen.frame.origin.y),\(screen.frame.width),\(screen.frame.height)"
    }

    private var main: NSScreen? {
        NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main ?? NSScreen.screens.first
    }

    private var containingMouse: NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(location) }
    }

    private var secondary: NSScreen? {
        guard let main else { return NSScreen.screens.first }
        let candidates = NSScreen.screens.filter { !Self.isSameDisplay($0, main) }
        guard !candidates.isEmpty else { return nil }
        if let mouseScreen = containingMouse,
           candidates.contains(where: { Self.isSameDisplay($0, mouseScreen) }) {
            return mouseScreen
        }
        return candidates.sorted(by: Self.precedes).first
    }

    private static func precedes(_ lhs: NSScreen, _ rhs: NSScreen) -> Bool {
        if lhs.frame.minX == rhs.frame.minX { return lhs.frame.minY < rhs.frame.minY }
        return lhs.frame.minX < rhs.frame.minX
    }
}
