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
        try check(!settings.codexAllowAllAppActions, "automatic app actions default off")
        settings.codexAllowAllAppActions = true; settings.chatSplitRatio = 0.42
        let saved = AppSettings(defaults: defaults)
        try check(saved.codexAllowAllAppActions && saved.chatSplitRatio == 0.42, "app permission and chat boundary persist after restart")
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
        try verifyChoiceMenu(settings: settings, defaults: defaults)
    }

    private static func verifyChoiceMenu(settings: AppSettings, defaults: EphemeralAppSettingsDefaults) throws {
        NSApp.setActivationPolicy(.accessory)
        let menu = ChatChoiceMenu(choices: [.init(id: "first", title: "First"), .init(id: "second", title: "Second")],
            selectedID: "first", placeholder: "Loading", enabled: true, onChoose: { settings.chatModel = $0 })
        let coordinator = menu.makeCoordinator()
        let button = menu.makeButton(coordinator: coordinator)
        button.frame = NSRect(x: 10, y: 10, width: 160, height: 24)
        let panel = NSPanel(contentRect: NSRect(x: 300, y: 300, width: 200, height: 48),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 48))
        panel.contentView?.addSubview(button)
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil); panel.close() }
        for select in [true, false] {
            let before = settings.chatModel
            coordinator.tracked = false
            let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification,
                object: button.menu, queue: .main) { _ in MainActor.assumeIsolated { coordinator.tracked = true } }
            let timer = Timer(timeInterval: 0.15, repeats: false) { _ in
                MainActor.assumeIsolated {
                    if select { button.menu?.performActionForItem(at: 1) }
                    button.menu?.cancelTracking()
                }
            }
            RunLoop.main.add(timer, forMode: .eventTracking)
            RunLoop.main.add(timer, forMode: .common)
            button.performClick(nil)
            timer.invalidate()
            NotificationCenter.default.removeObserver(observer)
            guard coordinator.tracked, select ? settings.chatModel == "second" : settings.chatModel == before else {
                throw LibraryError.message("Native model popup selection/cancellation failed")
            }
            print("PASS chat panel: native model popup \(select ? "selection saves" : "cancellation preserves") settings")
        }
        let selected = ChatChoiceMenu(choices: menu.choices, selectedID: "second", placeholder: "Loading", enabled: true, onChoose: menu.onChoose)
        selected.apply(to: button, coordinator: coordinator)
        guard button.selectedItem?.representedObject as? String == "second",
              AppSettings(defaults: defaults).chatModel == "second" else {
            throw LibraryError.message("Native model title readback failed")
        }
        print("PASS chat panel: native model title reflects saved selection")
        let missing = ChatChoiceMenu(choices: menu.choices, selectedID: "unavailable", placeholder: "Unavailable", enabled: true, onChoose: menu.onChoose)
        missing.apply(to: button, coordinator: coordinator)
        guard button.title == "Unavailable", button.selectedItem?.isEnabled == false else {
            throw LibraryError.message("Unavailable model silently replaced by another choice")
        }
        print("PASS chat panel: unavailable saved model stays explicit without silent substitution")
    }
}
