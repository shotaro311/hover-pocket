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
        GeometryReader { proxy in
            let showsHistory = isHistorySidebarVisible && !store.history.isEmpty
            let metrics = CalculatorLayoutMetrics(size: proxy.size, showsHistory: showsHistory)

            VStack(alignment: .leading, spacing: metrics.outerSpacing) {
                historyToggleButton(metrics: metrics)

                HStack(alignment: .top, spacing: metrics.columnSpacing) {
                    if showsHistory {
                        historySidebar(metrics: metrics)
                            .frame(width: metrics.historySidebarWidth)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }

                    VStack(spacing: metrics.contentSpacing) {
                        displayPanel(metrics: metrics)
                        keypad(metrics: metrics)
                    }
                    .frame(maxWidth: metrics.mainMaxWidth, maxHeight: .infinity, alignment: .top)
                }
            }
            .padding(.horizontal, metrics.horizontalPadding)
            .padding(.vertical, metrics.verticalPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.interactiveSpring(response: 0.24, dampingFraction: 0.86), value: isHistorySidebarVisible)
        .animation(.interactiveSpring(response: 0.24, dampingFraction: 0.86), value: store.history.isEmpty)
        .background(
            CalculatorKeyCatcher { event in
                handleKey(event)
            }
        )
    }

    private func displayPanel(metrics: CalculatorLayoutMetrics) -> some View {
        VStack(alignment: .trailing, spacing: metrics.displaySpacing) {
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
                    .panelTextFont(size: metrics.previewFontSize, weight: .semibold, design: .rounded)
                    .foregroundStyle(.yellow.opacity(0.72))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .frame(maxWidth: .infinity, minHeight: metrics.previewMinHeight, alignment: .trailing)
            }

            Text(store.displayText)
                .panelTextFont(size: store.isShowingExpressionInput ? metrics.expressionInputFontSize : metrics.displayFontSize, weight: .semibold, design: .rounded)
                .foregroundStyle(store.hasError ? .red.opacity(0.9) : .white.opacity(0.92))
                .lineLimit(1)
                .minimumScaleFactor(0.45)
                .frame(maxWidth: .infinity, minHeight: metrics.displayMinHeight, alignment: .trailing)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, metrics.displayHorizontalPadding)
        .padding(.vertical, metrics.displayVerticalPadding)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.065), lineWidth: 1)
        )
    }

    private func keypad(metrics: CalculatorLayoutMetrics) -> some View {
        Grid(horizontalSpacing: metrics.keySpacing, verticalSpacing: metrics.keySpacing) {
            GridRow {
                key(.allClear, title: "AC", style: .utility, metrics: metrics)
                key(.toggleSign, title: "+/-", style: .utility, metrics: metrics)
                key(.percent, title: "%", style: .utility, metrics: metrics)
                key(.operation(.divide), title: "÷", style: .operation, metrics: metrics)
            }
            GridRow {
                key(.digit(7), title: "7", metrics: metrics)
                key(.digit(8), title: "8", metrics: metrics)
                key(.digit(9), title: "9", metrics: metrics)
                key(.operation(.multiply), title: "×", style: .operation, metrics: metrics)
            }
            GridRow {
                key(.digit(4), title: "4", metrics: metrics)
                key(.digit(5), title: "5", metrics: metrics)
                key(.digit(6), title: "6", metrics: metrics)
                key(.operation(.subtract), title: "−", style: .operation, metrics: metrics)
            }
            GridRow {
                key(.digit(1), title: "1", metrics: metrics)
                key(.digit(2), title: "2", metrics: metrics)
                key(.digit(3), title: "3", metrics: metrics)
                key(.operation(.add), title: "+", style: .operation, metrics: metrics)
            }
            GridRow {
                key(.digit(0), title: "0", metrics: metrics)
                    .gridCellColumns(2)
                key(.decimalSeparator, title: ".", metrics: metrics)
                key(.equals, title: "=", style: .equals, metrics: metrics)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func historyToggleButton(metrics: CalculatorLayoutMetrics) -> some View {
        Button {
            isHistorySidebarVisible.toggle()
        } label: {
            Image(systemName: isHistorySidebarVisible ? "sidebar.leading" : "sidebar.left")
                .font(.system(size: metrics.toggleIconSize, weight: .bold))
                .foregroundStyle(.white.opacity(store.history.isEmpty ? 0.32 : 0.78))
                .frame(width: metrics.toggleButtonSize.width, height: metrics.toggleButtonSize.height)
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

    private func historySidebar(metrics: CalculatorLayoutMetrics) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(label(.history))
                    .panelTextFont(size: metrics.historyHeaderFontSize, weight: .bold, design: .monospaced)
                    .foregroundStyle(.white.opacity(0.72))
                Spacer()
                Text("\(store.history.count)")
                    .panelTextFont(size: metrics.historyCountFontSize, weight: .bold, design: .rounded)
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
                        historyRow(entry, metrics: metrics)
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

    private func historyRow(_ entry: CalculatorStore.HistoryEntry, metrics: CalculatorLayoutMetrics) -> some View {
        HStack(spacing: 6) {
            Button {
                store.useHistoryResult(entry)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.inputExpression)
                        .panelTextFont(size: metrics.historyExpressionFontSize, weight: .medium, design: .rounded)
                        .foregroundStyle(.white.opacity(0.48))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)

                    Text(entry.result)
                        .panelTextFont(size: metrics.historyResultFontSize, weight: .bold, design: .rounded)
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
        style: CalculatorKeyStyle = .number,
        metrics: CalculatorLayoutMetrics
    ) -> some View {
        Button {
            store.press(button)
        } label: {
            Group {
                if let systemName {
                    Image(systemName: systemName)
                        .font(.system(size: metrics.keyFontSize, weight: .bold))
                } else {
                    Text(title ?? "")
                        .panelTextFont(size: metrics.keyFontSize, weight: .bold, design: .rounded)
                }
            }
            .frame(maxWidth: .infinity, minHeight: metrics.keyMinHeight)
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
        case "+", "＋", ";", "=":
            store.press(key == "=" ? .equals : .operation(.add))
        case "-":
            store.press(.operation(.subtract))
        case "*", "＊", "×", "x", "X", ":":
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
        case 39:
            store.press(.operation(.multiply))
        case 41:
            store.press(.operation(.add))
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
        case ";":
            store.press(.operation(.add))
        case ":":
            store.press(.operation(.multiply))
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

struct CalculatorLayoutMetrics {
    let size: CGSize
    let showsHistory: Bool

    private var veryCompactHeight: Bool {
        size.height < 340
    }

    private var compactHeight: Bool {
        size.height < 395
    }

    private var compactWidth: Bool {
        size.width < 560
    }

    var horizontalPadding: CGFloat {
        compactWidth ? 10 : 14
    }

    var verticalPadding: CGFloat {
        veryCompactHeight ? 8 : (compactHeight ? 10 : 12)
    }

    var outerSpacing: CGFloat {
        veryCompactHeight ? 5 : (compactHeight ? 7 : 8)
    }

    var columnSpacing: CGFloat {
        compactWidth ? 8 : 10
    }

    var contentSpacing: CGFloat {
        veryCompactHeight ? 6 : (compactHeight ? 7 : 10)
    }

    var historySidebarWidth: CGFloat {
        if compactWidth {
            return 124
        }
        if size.width < 640 {
            return 140
        }
        return 154
    }

    var mainMaxWidth: CGFloat {
        let availableWidth = max(0, size.width - horizontalPadding * 2)
        let historyWidth = showsHistory ? historySidebarWidth + columnSpacing : 0
        let remainingWidth = max(0, availableWidth - historyWidth)
        let preferredWidth: CGFloat = compactWidth ? 380 : 430
        return min(preferredWidth, remainingWidth)
    }

    var toggleButtonSize: CGSize {
        veryCompactHeight ? CGSize(width: 26, height: 24) : CGSize(width: 28, height: 26)
    }

    var toggleIconSize: CGFloat {
        veryCompactHeight ? 12 : 13
    }

    var displaySpacing: CGFloat {
        veryCompactHeight ? 6 : (compactHeight ? 7 : 10)
    }

    var displayHorizontalPadding: CGFloat {
        compactWidth ? 10 : 14
    }

    var displayVerticalPadding: CGFloat {
        veryCompactHeight ? 8 : (compactHeight ? 10 : 12)
    }

    var previewFontSize: CGFloat {
        veryCompactHeight ? 10 : (compactHeight ? 11 : 12)
    }

    var previewMinHeight: CGFloat {
        veryCompactHeight ? 12 : (compactHeight ? 14 : 16)
    }

    var displayFontSize: CGFloat {
        veryCompactHeight ? 30 : (compactHeight ? 34 : 38)
    }

    var expressionInputFontSize: CGFloat {
        veryCompactHeight ? 24 : (compactHeight ? 28 : 32)
    }

    var displayMinHeight: CGFloat {
        veryCompactHeight ? 36 : (compactHeight ? 44 : 50)
    }

    var keySpacing: CGFloat {
        veryCompactHeight ? 5 : (compactHeight ? 6 : 8)
    }

    var keyMinHeight: CGFloat {
        veryCompactHeight ? 27 : (compactHeight ? 31 : 38)
    }

    var keyFontSize: CGFloat {
        veryCompactHeight ? 13 : (compactHeight ? 14 : 15)
    }

    var historyHeaderFontSize: CGFloat {
        veryCompactHeight ? 10 : 11
    }

    var historyCountFontSize: CGFloat {
        veryCompactHeight ? 9 : 10
    }

    var historyExpressionFontSize: CGFloat {
        veryCompactHeight ? 9 : 10
    }

    var historyResultFontSize: CGFloat {
        veryCompactHeight ? 12 : 13
    }

    var estimatedMaxContentHeight: CGFloat {
        let displayActionHeight: CGFloat = 28
        let displayHeight = displayActionHeight
            + displaySpacing
            + previewMinHeight
            + displaySpacing
            + displayMinHeight
            + displayVerticalPadding * 2
        let keypadHeight = keyMinHeight * 5 + keySpacing * 4
        return verticalPadding * 2
            + toggleButtonSize.height
            + outerSpacing
            + displayHeight
            + contentSpacing
            + keypadHeight
    }

    var hasUsableMainColumnWidth: Bool {
        mainMaxWidth >= 300
    }
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
