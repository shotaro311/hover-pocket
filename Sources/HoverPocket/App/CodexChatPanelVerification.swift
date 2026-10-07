import AppKit

@MainActor
enum CodexChatPanelVerification {
    static func run() throws {
        func check(_ condition: Bool, _ name: String) throws {
            guard condition else { throw LibraryError.message(name) }
            print("PASS chat panel: " + name)
        }
        for size in ["small", "medium", "large", "extraLarge"] {
            let compact = CodexChatPanelLayout.height(panelSize: size, expanded: false, availableHeight: 600)
            let expanded = CodexChatPanelLayout.height(panelSize: size, expanded: true, availableHeight: 600)
            let limited = CodexChatPanelLayout.height(panelSize: size, expanded: true, availableHeight: 140)
            try check(compact == CodexChatPanelLayout.composerHeight && expanded > compact && limited == 140, "\(size) compact, history, and short display fit")
        }
        let defaults = EphemeralAppSettingsDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.panelResizing = true; settings.customPanelSize = CGSize(width: 720, height: 580)
        try check(defaults.object(forKey: "customPanelWidth") == nil, "resize drag avoids writing every movement")
        settings.panelResizing = false; settings.persistPanelSize()
        let restored = AppSettings(defaults: defaults)
        try check(restored.customPanelSize == CGSize(width: 720, height: 580), "custom panel size restores after restart")
        restored.panelSize = .small
        try check(restored.customPanelSize == nil, "size preset resets the custom dimensions")
        let bindings = AppShortcutBindings.defaults.merging(["screenshot": "Cmd+Alt+S", "recording": "Cmd+Alt+R"]) { _, new in new }
        try check(try AppShortcutBindings.validate(bindings).count == 8, "main actions accept custom shortcut bindings")
        var duplicate = bindings; duplicate["chat"] = "Alt+Cmd+P"
        do { _ = try AppShortcutBindings.validate(duplicate); throw LibraryError.message("duplicate accepted") }
        catch { try check(error.localizedDescription != "duplicate accepted", "equivalent shortcut combinations reject duplicates") }
        let editor = ChatInputTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
        editor.isRichText = false
        var submits = 0
        editor.onSubmit = { submits += 1 }
        func enter(_ modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                isARepeat: false, keyCode: 36)!
        }
        editor.string = "draft"
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.keyDown(with: enter(.shift))
        try check(submits == 0 && editor.string.contains("\n"), "Shift Return inserts a newline without submitting")
        editor.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        try check(editor.hasMarkedText(), "Japanese IME composition is active")
        editor.keyDown(with: enter())
        try check(submits == 0, "Return during IME composition never submits")
        editor.unmarkText()
        editor.keyDown(with: enter())
        try check(submits == 1, "Return after composition submits exactly once")
        var hides = 0
        editor.onDismiss = { hides += 1 }
        let draft = editor.string
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53)!
        editor.keyDown(with: escape)
        try check(hides == 1 && editor.string == draft, "Escape requests hiding without losing the draft")
        try check(ChatEffortPresentation.title("medium", language: .japanese) == "推論: 標準" && ChatEffortPresentation.title("high", language: .english) == "Reasoning: High", "reasoning names are readable in both languages")
    }
}
