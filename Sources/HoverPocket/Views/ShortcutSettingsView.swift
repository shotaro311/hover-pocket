import AppKit
import Carbon
import SwiftUI

struct ShortcutSettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var bindings: [String: String] = [:]
    @State private var notice = ""
    private let titles = ["panel": ("パネルを開く・閉じる", "Toggle panel"), "chat": ("チャット入力", "Chat"), "library": ("素材ライブラリ", "Library"), "settings": ("設定", "Settings"), "voice": ("音声会話を開始・終了", "Toggle voice"), "screenshot": ("スクリーンショット", "Screenshot"), "recording": ("画面収録を開始・停止", "Toggle recording"), "regionRecording": ("範囲収録を開始・停止", "Toggle region recording")]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(settings.appLanguage == .japanese ? "ショートカットキー" : "Shortcuts").font(.headline)
            Text(settings.appLanguage == .japanese ? "欄をクリックしてキーを押してください。Deleteで無効にできます。Cmd・Ctrl・Altを含む組み合わせを使います。" : "Click a field and press your keys. Delete disables an action. Include Cmd, Ctrl or Alt.")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(AppShortcutBindings.actions, id: \.self) { action in
                HStack {
                    Text(settings.appLanguage == .japanese ? titles[action]!.0 : titles[action]!.1)
                    Spacer()
                    ShortcutKeyField(value: Binding(get: { bindings[action] ?? "" }, set: { bindings[action] = $0 }))
                        .frame(width: 180, height: 28)
                        .accessibilityLabel(settings.appLanguage == .japanese ? titles[action]!.0 : titles[action]!.1)
                }
            }
            Button(settings.appLanguage == .japanese ? "保存" : "Save") {
                do {
                    try AssetCaptureController.shared.saveShortcutBindings(bindings, settings: settings)
                    notice = settings.appLanguage == .japanese ? "保存しました。" : "Saved."
                } catch { notice = error.localizedDescription }
            }
            Text(notice).font(.caption).foregroundStyle(.secondary)
        }.onAppear { bindings = AssetCaptureController.shared.shortcutBindings(settings: settings) }
    }
}

private struct ShortcutKeyField: NSViewRepresentable {
    @Binding var value: String
    func makeNSView(context: Context) -> KeyField {
        let field = KeyField()
        field.isEditable = false; field.isSelectable = false; field.isBezeled = true
        field.onKey = { value = $0 }; return field
    }
    func updateNSView(_ view: KeyField, context: Context) { view.stringValue = value; view.onKey = { value = $0 } }
    final class KeyField: NSTextField {
        var onKey: ((String) -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func becomeFirstResponder() -> Bool {
            AssetCaptureController.shared.suspendShortcuts(true); return true
        }
        override func resignFirstResponder() -> Bool {
            AssetCaptureController.shared.suspendShortcuts(false); return true
        }
        override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 48 { window?.selectNextKeyView(self); return }
            if event.keyCode == 51 || event.keyCode == 117 { onKey?(""); return }
            var modifiers: UInt32 = 0
            if event.modifierFlags.contains(.command) { modifiers |= UInt32(cmdKey) }
            if event.modifierFlags.contains(.control) { modifiers |= UInt32(controlKey) }
            if event.modifierFlags.contains(.option) { modifiers |= UInt32(optionKey) }
            if event.modifierFlags.contains(.shift) { modifiers |= UInt32(shiftKey) }
            let text = AppShortcutBindings.format(code: UInt32(event.keyCode), modifiers: modifiers)
            if !text.isEmpty { onKey?(text) }
        }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard window?.firstResponder === self else { return false }
            keyDown(with: event); return true
        }
    }
}
