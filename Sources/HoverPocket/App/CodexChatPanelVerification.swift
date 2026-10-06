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
            try check(compact == 84 && expanded > compact && limited == 140, "\(size) compact, history, and short display fit")
        }
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
    }
}
