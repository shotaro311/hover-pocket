import AppKit
import SwiftUI

struct CalculatorView: View {
    let actions: ProviderActions
    @ObservedObject private var store: CalculatorStore
    @State private var copied = false
    @State private var copyResetTask: Task<Void, Never>?
    @State private var isHistorySidebarVisible = true

    init(actions: ProviderActions, store: CalculatorStore = .shared) {
        self.actions = actions
        self.store = store
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            historyToggleButton

            HStack(alignment: .top, spacing: 10) {
                if isHistorySidebarVisible, !store.history.isEmpty {
                    historySidebar
                        .frame(width: 154)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }

                VStack(spacing: 10) {
                    displayPanel
                    keypad
                }
                .frame(maxWidth: 430, maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(maxWidth: 610, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.interactiveSpring(response: 0.24, dampingFraction: 0.86), value: isHistorySidebarVisible)
        .animation(.interactiveSpring(response: 0.24, dampingFraction: 0.86), value: store.history.isEmpty)
        .background(
            CalculatorKeyCatcher { event in
                handleKey(event)
            }
        )
    }

    private var displayPanel: some View {
        VStack(alignment: .trailing, spacing: 10) {
            HStack(spacing: 8) {
                if copied {
                    Text(label(.copied))
                        .panelTextFont(size: 10, weight: .bold, design: .monospaced)
                        .foregroundStyle(.green.opacity(0.9))
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                }
                Spacer()
                displayAction(systemName: "delete.left", help: label(.backspace)) {
                    store.press(.backspace)
                }
                displayAction(
                    systemName: copied ? "checkmark" : "doc.on.doc",
                    active: copied,
                    help: copied ? label(.copied) : label(.copy)
                ) {
                    copyDisplay()
                }
                .disabled(store.hasError)
            }

            if let expressionPreview = store.expressionPreview, !store.isShowingExpressionInput {
                Text(expressionPreview)
                    .panelTextFont(size: 12, weight: .semibold, design: .rounded)
                    .foregroundStyle(.yellow.opacity(0.72))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .frame(maxWidth: .infinity, minHeight: 16, alignment: .trailing)
            }

            Text(store.displayText)
                .panelTextFont(size: store.isShowingExpressionInput ? 32 : 40, weight: .semibold, design: .rounded)
                .foregroundStyle(store.hasError ? .red.opacity(0.9) : .white.opacity(0.92))
                .lineLimit(1)
                .minimumScaleFactor(0.45)
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .trailing)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.065), lineWidth: 1)
        )
    }

    private var keypad: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                key(.allClear, title: "AC", style: .utility)
                key(.toggleSign, title: "+/-", style: .utility)
                key(.percent, title: "%", style: .utility)
                key(.operation(.divide), title: "÷", style: .operation)
            }
            GridRow {
                key(.digit(7), title: "7")
                key(.digit(8), title: "8")
                key(.digit(9), title: "9")
                key(.operation(.multiply), title: "×", style: .operation)
            }
            GridRow {
                key(.digit(4), title: "4")
                key(.digit(5), title: "5")
                key(.digit(6), title: "6")
                key(.operation(.subtract), title: "−", style: .operation)
            }
            GridRow {
                key(.digit(1), title: "1")
                key(.digit(2), title: "2")
                key(.digit(3), title: "3")
                key(.operation(.add), title: "+", style: .operation)
            }
            GridRow {
                key(.digit(0), title: "0")
                    .gridCellColumns(2)
                key(.decimalSeparator, title: ".")
                key(.equals, title: "=", style: .equals)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var historyToggleButton: some View {
        Button {
            isHistorySidebarVisible.toggle()
        } label: {
            Image(systemName: isHistorySidebarVisible ? "sidebar.leading" : "sidebar.left")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white.opacity(store.history.isEmpty ? 0.32 : 0.78))
                .frame(width: 28, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(0.055))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.white.opacity(0.07), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(store.history.isEmpty)
        .help(label(.toggleHistory))
    }

    private var historySidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(label(.history))
                    .panelTextFont(size: 11, weight: .bold, design: .monospaced)
                    .foregroundStyle(.white.opacity(0.72))
                Spacer()
                Text("\(store.history.count)")
                    .panelTextFont(size: 10, weight: .bold, design: .rounded)
                    .foregroundStyle(.white.opacity(0.42))
                Button {
                    store.clearHistory()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.66))
                        .frame(width: 22, height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.white.opacity(0.055))
                        )
                }
                .buttonStyle(.plain)
                .disabled(store.history.isEmpty)
                .help(label(.clearHistory))
            }
            .padding(.horizontal, 10)
            .padding(.top, 9)

            ScrollView {
                VStack(spacing: 7) {
                    ForEach(store.history) { entry in
                        historyRow(entry)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.never)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.028))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.055), lineWidth: 1)
        )
    }

    private func historyRow(_ entry: CalculatorStore.HistoryEntry) -> some View {
        HStack(spacing: 6) {
            Button {
                store.useHistoryResult(entry)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.inputExpression)
                        .panelTextFont(size: 10, weight: .medium, design: .rounded)
                        .foregroundStyle(.white.opacity(0.48))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)

                    Text(entry.result)
                        .panelTextFont(size: 13, weight: .bold, design: .rounded)
                        .foregroundStyle(.white.opacity(0.88))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help(label(.useHistoryValue))

            Button {
                store.useHistoryExpression(entry)
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.yellow.opacity(0.86))
                    .frame(width: 24, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.yellow.opacity(0.10))
                    )
            }
            .buttonStyle(.plain)
            .help(label(.restoreHistory))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.055), lineWidth: 1)
        )
    }

    private func displayAction(
        systemName: String,
        active: Bool = false,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(active ? .green.opacity(0.92) : .white.opacity(0.68))
                .frame(width: 30, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(active ? 0.09 : 0.055))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(active ? 0.12 : 0.07), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func key(
        _ button: CalculatorStore.Button,
        title: String? = nil,
        systemName: String? = nil,
        style: CalculatorKeyStyle = .number
    ) -> some View {
        Button {
            store.press(button)
        } label: {
            Group {
                if let systemName {
                    Image(systemName: systemName)
                        .font(.system(size: 15, weight: .bold))
                } else {
                    Text(title ?? "")
                        .panelTextFont(size: 15, weight: .bold, design: .rounded)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 42)
            .foregroundStyle(style.foreground)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(style.background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(style.stroke, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .help(title ?? label(.backspace))
    }

    private func handleKey(_ event: NSEvent) {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "c" {
            copyDisplay()
            return
        }
        if handleKeyCode(event.keyCode) {
            return
        }
        let key = event.characters ?? event.charactersIgnoringModifiers ?? ""
        let fallbackKey = event.charactersIgnoringModifiers ?? key
        switch key {
        case "0"..."9":
            if let digit = Int(key) {
                store.press(.digit(digit))
            }
        case ".", ",":
            store.press(.decimalSeparator)
        case "+", "=":
            store.press(key == "=" ? .equals : .operation(.add))
        case "-":
            store.press(.operation(.subtract))
        case "*", "×", "x", "X":
            store.press(.operation(.multiply))
        case "/", "÷":
            store.press(.operation(.divide))
        case "%":
            store.press(.percent)
        case "\r", "\n":
            store.press(.equals)
        case "\u{7F}", "\u{8}":
            store.press(.backspace)
        case "\u{1B}":
            store.press(.allClear)
        default:
            handleFallbackKey(fallbackKey)
        }
    }

    private func handleKeyCode(_ keyCode: UInt16) -> Bool {
        switch keyCode {
        case 36, 76:
            store.press(.equals)
        case 65:
            store.press(.decimalSeparator)
        case 67:
            store.press(.operation(.multiply))
        case 69:
            store.press(.operation(.add))
        case 75:
            store.press(.operation(.divide))
        case 78:
            store.press(.operation(.subtract))
        case 81:
            store.press(.equals)
        case 82:
            store.press(.digit(0))
        case 83:
            store.press(.digit(1))
        case 84:
            store.press(.digit(2))
        case 85:
            store.press(.digit(3))
        case 86:
            store.press(.digit(4))
        case 87:
            store.press(.digit(5))
        case 88:
            store.press(.digit(6))
        case 89:
            store.press(.digit(7))
        case 91:
            store.press(.digit(8))
        case 92:
            store.press(.digit(9))
        default:
            return false
        }
        return true
    }

    private func handleFallbackKey(_ key: String) {
        switch key {
        case "0"..."9":
            if let digit = Int(key) {
                store.press(.digit(digit))
            }
        case ".":
            store.press(.decimalSeparator)
        case "=":
            store.press(.equals)
        default:
            break
        }
    }

    private func copyDisplay() {
        guard !store.hasError else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(store.displayText, forType: .string)
        copied = true
        copyResetTask?.cancel()
        copyResetTask = Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            copied = false
        }
    }

    private func label(_ key: CalculatorLabel) -> String {
        switch (actions.settings.appLanguage, key) {
        case (.japanese, .copy):
            return "コピー"
        case (.japanese, .copied):
            return "コピー済み"
        case (.japanese, .backspace):
            return "1文字削除"
        case (.japanese, .useHistoryValue):
            return "履歴の数値を入力"
        case (.japanese, .restoreHistory):
            return "履歴の式を入力"
        case (.japanese, .toggleHistory):
            return "履歴サイドバーを表示/非表示"
        case (.japanese, .history):
            return "履歴"
        case (.japanese, .clearHistory):
            return "履歴をクリア"
        case (.english, .copy):
            return "Copy"
        case (.english, .copied):
            return "Copied"
        case (.english, .backspace):
            return "Backspace"
        case (.english, .useHistoryValue):
            return "Use history value"
        case (.english, .restoreHistory):
            return "Use history expression"
        case (.english, .toggleHistory):
            return "Show or hide history sidebar"
        case (.english, .history):
            return "History"
        case (.english, .clearHistory):
            return "Clear history"
        }
    }
}

private enum CalculatorLabel {
    case copy
    case copied
    case backspace
    case useHistoryValue
    case restoreHistory
    case toggleHistory
    case history
    case clearHistory
}

private enum CalculatorKeyStyle {
    case number
    case utility
    case operation
    case equals

    var foreground: Color {
        switch self {
        case .number:
            return .white.opacity(0.88)
        case .utility:
            return .white.opacity(0.72)
        case .operation:
            return .yellow.opacity(0.94)
        case .equals:
            return .black.opacity(0.86)
        }
    }

    var background: Color {
        switch self {
        case .number:
            return .white.opacity(0.058)
        case .utility:
            return .white.opacity(0.085)
        case .operation:
            return .yellow.opacity(0.16)
        case .equals:
            return .yellow.opacity(0.88)
        }
    }

    var stroke: Color {
        switch self {
        case .number:
            return .white.opacity(0.07)
        case .utility:
            return .white.opacity(0.09)
        case .operation:
            return .yellow.opacity(0.22)
        case .equals:
            return .yellow.opacity(0.42)
        }
    }
}

private struct CalculatorKeyCatcher: NSViewRepresentable {
    let onKeyDown: (NSEvent) -> Void

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        view.onKeyDown = onKeyDown
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: KeyView, context: Context) {
        nsView.onKeyDown = onKeyDown
        DispatchQueue.main.async {
            nsView.window?.makeFirstResponder(nsView)
        }
    }

    final class KeyView: NSView {
        var onKeyDown: ((NSEvent) -> Void)?

        override var acceptsFirstResponder: Bool {
            true
        }

        override func keyDown(with event: NSEvent) {
            onKeyDown?(event)
        }
    }
}
