import AppKit
import ScreenCaptureKit

@MainActor
final class VoiceCaptureTargets {
    struct Target {
        let id: String
        let title: String
        let windowID: CGWindowID
        let processID: pid_t
        let windowTitle: String
        let displayID: CGDirectDisplayID?
        let expires: Date
    }
    private var targets: [String: Target] = [:]
    private let allowOwnWindows: Bool
    init(allowOwnWindows: Bool = false) {
        self.allowOwnWindows = allowOwnWindows && CommandLine.arguments.contains("--verify-library-voice")
    }
    private func content() async throws -> SCShareableContent {
        guard CGPreflightScreenCaptureAccess() else { throw LibraryVoiceError.failed("screen_capture_permission_required") }
        return try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
    }
    private func eligible(_ window: SCWindow) -> Bool {
        window.isOnScreen && window.windowLayer == 0 && window.frame.width > 30 && window.frame.height > 30
            && window.owningApplication != nil
            && (allowOwnWindows || window.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier)
    }
    private func label(_ window: SCWindow) -> String {
        (window.owningApplication?.applicationName ?? "アプリ") + " — " + (window.title ?? "ウィンドウ")
    }
    private func normalize(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    private func bind(_ window: SCWindow, display: SCDisplay? = nil) throws -> Target {
        targets = targets.filter { $0.value.expires > Date() }
        if let existing = targets.values.first(where: { $0.windowID == window.windowID
            && $0.processID == window.owningApplication?.processID && $0.windowTitle == (window.title ?? "")
            && $0.displayID == display?.displayID }) { return existing }
        guard targets.count < 256 else { throw LibraryVoiceError.failed("too_many_capture_targets") }
        let target = Target(id: UUID().uuidString.lowercased(),
            title: display == nil ? label(window) : "現在のウィンドウがある画面全体",
            windowID: window.windowID, processID: window.owningApplication!.processID,
            windowTitle: window.title ?? "", displayID: display?.displayID, expires: Date().addingTimeInterval(180))
        targets[target.id] = target; return target
    }
    func list(query: String) async throws -> [Target] {
        let content = try await content()
        return try content.windows.filter { eligible($0) && normalize(label($0)).contains(normalize(query)) }
            .prefix(40).map { try bind($0) }
    }
    func resolve(target: String, windowID: String?, windowTitle: String?) async throws -> Target {
        let content = try await content()
        if target == "window" {
            if let windowID {
                let value = try validate(windowID, in: content)
                guard value.displayID == nil, windowTitle == nil || normalize(value.title).contains(normalize(windowTitle!)) else {
                    throw LibraryVoiceError.failed("capture_target_invalid")
                }
                return value
            }
            guard let windowTitle else { throw LibraryVoiceError.failed("window_title_required") }
            let matches = content.windows.filter { eligible($0) && normalize(label($0)).contains(normalize(windowTitle)) }
            let exact = matches.filter { normalize($0.title ?? "") == normalize(windowTitle) }
            guard let window = exact.count == 1 ? exact.first : matches.count == 1 ? matches.first : nil else {
                throw LibraryVoiceError.failed(matches.isEmpty ? "window_not_found" : "window_ambiguous_use_windows_list")
            }
            return try bind(window)
        }
        guard windowID == nil, windowTitle == nil, ["current_window", "screen"].contains(target) else {
            throw LibraryVoiceError.failed("capture_target_invalid")
        }
        // WindowServer's front-to-back order keeps the last external window ahead of other apps,
        // even while HoverPocket's floating conversation panel is in front of it.
        let order = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
            .compactMap { $0[kCGWindowNumber as String] as? UInt32 }
        guard let window = content.windows.filter({ eligible($0) }).min(by: {
            (order.firstIndex(of: $0.windowID) ?? Int.max) < (order.firstIndex(of: $1.windowID) ?? Int.max)
        }) else { throw LibraryVoiceError.failed("current_window_unavailable") }
        if target == "current_window" { return try bind(window) }
        let displays = content.displays.filter { !$0.frame.intersection(window.frame).isEmpty }
        guard let display = displays.max(by: {
            let a = $0.frame.intersection(window.frame), b = $1.frame.intersection(window.frame)
            return a.width * a.height < b.width * b.height
        }) else { throw LibraryVoiceError.failed("screen_unavailable") }
        return try bind(window, display: display)
    }
    private func validate(_ id: String, in content: SCShareableContent) throws -> Target {
        guard let target = targets[id], target.expires > Date() else { throw LibraryVoiceError.failed("capture_target_expired") }
        guard let window = content.windows.first(where: { $0.windowID == target.windowID }), eligible(window),
              window.owningApplication?.processID == target.processID, (window.title ?? "") == target.windowTitle else {
            throw LibraryVoiceError.failed("capture_target_changed")
        }
        return target
    }
    func filter(_ id: String) async throws -> SCContentFilter {
        let content = try await content(), target = try validate(id, in: content)
        try Task.checkCancellation()
        if let displayID = target.displayID {
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw LibraryVoiceError.failed("screen_unavailable")
            }
            return SCContentFilter(display: display,
                excludingApplications: content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier },
                exceptingWindows: [])
        }
        return SCContentFilter(desktopIndependentWindow: content.windows.first { $0.windowID == target.windowID }!)
    }
}
