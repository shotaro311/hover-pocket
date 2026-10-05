import AppKit
import SwiftUI

/// One compact composer remains visible even when voice is disabled.
enum CodexChatPanelLayout {
    static let composerHeight: CGFloat = 84

    static func height(panelSize: String, expanded: Bool, availableHeight: CGFloat) -> CGFloat {
        guard expanded else { return composerHeight }
        let desired = CGFloat(VoiceLaneGeometry.expandedHeight(panelSizeRawValue: panelSize)) + 60
        return max(composerHeight, min(desired, availableHeight))
    }
}

struct CodexChatComposer: NSViewRepresentable {
    @ObservedObject var model: CodexChatController
    let placeholder: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let text = ChatInputTextView(frame: .zero)
        text.isRichText = false
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.allowsUndo = true
        text.drawsBackground = false
        text.textColor = .white
        text.insertionPointColor = .white
        text.font = .systemFont(ofSize: 12)
        text.textContainerInset = NSSize(width: 4, height: 5)
        text.isHorizontallyResizable = false
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.lineFragmentPadding = 3
        text.setAccessibilityLabel("Codexへのメッセージ")
        text.delegate = context.coordinator
        text.onSubmit = { [weak model] in model?.send() }
        text.onDismiss = { [weak model] in model?.closePanel?() }
        text.onFocus = { [weak model] focused in
            model?.composerFocused = focused
            // WebKit can retain DOM focus when the native composer becomes first responder.
            if focused { AssetLibraryRuntime.shared.textInput = false }
        }
        scroll.documentView = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? ChatInputTextView else { return }
        if text.string != model.draft && !text.hasMarkedText() { text.string = model.draft }
        text.placeholder = placeholder
        text.needsDisplay = true
        if context.coordinator.focusRequest != model.focusRequest {
            context.coordinator.focusRequest = model.focusRequest
            DispatchQueue.main.async { [weak text] in
                guard let text, let window = text.window, window.isVisible else { return }
                window.makeKey()
                window.makeFirstResponder(text)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        (scroll.documentView as? ChatInputTextView)?.onFocus?(false)
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        let model: CodexChatController
        var focusRequest: Int
        init(model: CodexChatController) { self.model = model; focusRequest = model.focusRequest }
        func textDidChange(_ notification: Notification) {
            guard let text = notification.object as? NSTextView else { return }
            model.draft = text.string
        }
    }
}

final class ChatInputTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onFocus: ((Bool) -> Void)?
    var placeholder = ""

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty {
            (placeholder as NSString).draw(at: NSPoint(x: 7, y: 5), withAttributes: [
                .font: font ?? NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor])
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
        super.mouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocus?(false) }
        return accepted
    }

    override func keyDown(with event: NSEvent) {
        // Marked text belongs to the IME; Return must confirm it before it can submit.
        if event.keyCode == 53, !hasMarkedText() { onDismiss?() }
        else if (event.keyCode == 36 || event.keyCode == 76), !hasMarkedText() {
            if event.modifierFlags.contains(.shift) { insertNewline(nil) }
            else { onSubmit?() }
        } else { super.keyDown(with: event) }
    }
}

struct CodexChatTranscript: View {
    @ObservedObject var model: CodexChatController
    let language: AppLanguage
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if model.messages.isEmpty {
                        Text(language == .japanese ? "質問や素材の整理を、ここから依頼できます。" : "Ask a question or organize your library here.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.messages) { message in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(message.role == "user" ? (language == .japanese ? "あなた" : "You") : "Codex")
                                .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                            Text(message.text).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.id(message.id)
                    }
                }.font(.system(size: 12)).padding(.horizontal, 14).padding(.vertical, 8)
            }
            .accessibilityLabel(language == .japanese ? "チャット履歴" : "Chat history")
            .onAppear { if let id = model.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
            .onChange(of: model.messages.last?.text) { _, _ in
                if let id = model.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }
}
