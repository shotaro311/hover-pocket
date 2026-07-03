import AppKit
import SwiftUI

struct CalculatorView: View {
    let actions: ProviderActions
    @ObservedObject private var store: CalculatorStore
    @State private var copied = false
    @State private var copyResetTask: Task<Void, Never>?

    init(actions: ProviderActions, store: CalculatorStore = .shared) {
        self.actions = actions
        self.store = store
    }

    var body: some View {
        VStack(spacing: 10) {
            displayPanel
            keypad
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            CalculatorKeyCatcher { event in
                handleKey(event)
            }
        )
    }

    private var displayPanel: some View {
        VStack(alignment: .trailing, spacing: 8) {
            HStack {
                Text(label(.title))
                    .panelTextFont(size: 10, weight: .bold, design: .monospaced)
                    .foregroundStyle(.white.opacity(0.56))
                Spacer()
                Button {
                    copyDisplay()
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(copied ? .green.opacity(0.9) : .white.opacity(0.68))
                        .frame(width: 24, height: 22)
                        .background(Capsule().fill(Color.white.opacity(0.055)))
                }
                .buttonStyle(.plain)
                .help(label(.copy))
            }

            Text(store.display)
                .panelTextFont(size: 34, weight: .semibold, design: .rounded)
                .foregroundStyle(store.hasError ? .red.opacity(0.9) : .white.opacity(0.92))
                .lineLimit(1)
                .minimumScaleFactor(0.45)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .trailing)
                .contentTransition(.numericText())
        }
        .padding(12)
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
        VStack(spacing: 7) {
            HStack(spacing: 7) {
                key(.allClear, title: "AC", style: .utility)
                key(.toggleSign, title: "+/-", style: .utility)
                key(.percent, title: "%", style: .utility)
                key(.operation(.divide), title: "/", style: .operation)
            }
            HStack(spacing: 7) {
                key(.digit(7), title: "7")
                key(.digit(8), title: "8")
                key(.digit(9), title: "9")
                key(.operation(.multiply), title: "*", style: .operation)
            }
            HStack(spacing: 7) {
                key(.digit(4), title: "4")
                key(.digit(5), title: "5")
                key(.digit(6), title: "6")
                key(.operation(.subtract), title: "-", style: .operation)
            }
            HStack(spacing: 7) {
                key(.digit(1), title: "1")
                key(.digit(2), title: "2")
                key(.digit(3), title: "3")
                key(.operation(.add), title: "+", style: .operation)
            }
            HStack(spacing: 7) {
                key(.digit(0), title: "0", span: 2)
                key(.decimalSeparator, title: ".")
                key(.equals, title: "=", style: .equals)
            }
            HStack(spacing: 7) {
                key(.backspace, systemName: "delete.left", style: .utility, span: 2)
                Button {
                    copyDisplay()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11, weight: .bold))
                        Text(copied ? label(.copied) : label(.copy))
                            .panelTextFont(size: 11, weight: .bold, design: .monospaced)
                    }
                    .frame(maxWidth: .infinity, minHeight: 30)
                    .foregroundStyle(copied ? .green.opacity(0.95) : .white.opacity(0.72))
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(0.045))
                    )
                }
                .buttonStyle(.plain)
                .help(label(.copy))
            }
        }
    }

    private func key(
        _ button: CalculatorStore.Button,
        title: String? = nil,
        systemName: String? = nil,
        style: CalculatorKeyStyle = .number,
        span: CGFloat = 1
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
            .frame(maxWidth: .infinity, minHeight: 34)
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
        .layoutPriority(span)
        .help(title ?? label(.backspace))
    }

    private func handleKey(_ event: NSEvent) {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "c" {
            copyDisplay()
            return
        }
        guard let key = event.charactersIgnoringModifiers else { return }
        switch key {
        case "0"..."9":
            if let digit = Int(key) {
                store.press(.digit(digit))
            }
        case ".":
            store.press(.decimalSeparator)
        case "+", "=":
            store.press(key == "=" ? .equals : .operation(.add))
        case "-":
            store.press(.operation(.subtract))
        case "*":
            store.press(.operation(.multiply))
        case "/":
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
            break
        }
    }

    private func copyDisplay() {
        guard !store.hasError else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(store.display, forType: .string)
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
        case (.japanese, .title):
            return "電卓"
        case (.japanese, .copy):
            return "コピー"
        case (.japanese, .copied):
            return "コピー済み"
        case (.japanese, .backspace):
            return "1文字削除"
        case (.english, .title):
            return "Calculator"
        case (.english, .copy):
            return "Copy"
        case (.english, .copied):
            return "Copied"
        case (.english, .backspace):
            return "Backspace"
        }
    }
}

private enum CalculatorLabel {
    case title
    case copy
    case copied
    case backspace
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
            return .white.opacity(0.052)
        case .utility:
            return .white.opacity(0.08)
        case .operation:
            return .yellow.opacity(0.15)
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
