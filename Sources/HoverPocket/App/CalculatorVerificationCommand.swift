import Foundation

enum CalculatorVerificationCommand {
    @MainActor
    static func run() -> Never {
        let outputURL = outputFileURL()
        let sequence = requestedSequence()

        let store = CalculatorStore()
        let buttons = parse(sequence)
        let display = store.runSequence(buttons)
        let ok = verifyBuiltInCases() && !display.isEmpty
        let outputLines = [
            "calculator_verify=\(ok ? "ok" : "failed")",
            "calculator_sequence=\(sequence)",
            "calculator_display=\(display)",
            "calculator_display_text=\(store.displayText)",
            "calculator_history_count=\(store.history.count)"
        ]

        outputLines.forEach { print($0) }
        if let outputURL {
            let output = outputLines.joined(separator: "\n") + "\n"
            try? output.write(to: outputURL, atomically: true, encoding: .utf8)
        }
        exit(ok ? 0 : 1)
    }

    @MainActor
    private static func verifyBuiltInCases() -> Bool {
        let cases: [([CalculatorStore.Button], String)] = [
            ([.digit(1), .operation(.add), .digit(2), .equals], "3"),
            ([.digit(7), .operation(.divide), .digit(0), .equals], "Error"),
            ([.digit(1), .digit(2), .decimalSeparator, .digit(5), .toggleSign], "-12.5"),
            ([.digit(2), .digit(0), .percent], "0.2"),
            ([.digit(1), .digit(2), .backspace], "1"),
            ([
                .digit(6), .operation(.add), .digit(5),
                .operation(.add), .digit(9), .operation(.divide), .digit(2),
                .operation(.add), .digit(3), .operation(.subtract), .digit(5),
                .equals
            ], "13.5")
        ]
        for (buttons, expected) in cases {
            let store = CalculatorStore()
            guard store.runSequence(buttons) == expected else {
                return false
            }
        }
        let jisKeyboardStore = CalculatorStore()
        guard jisKeyboardStore.runSequence(parse("5;6:2=")) == "17" else {
            return false
        }
        return verifyHistoryCases()
    }

    @MainActor
    private static func verifyHistoryCases() -> Bool {
        let store = CalculatorStore()
        guard store.runSequence([.digit(1), .operation(.add), .digit(2), .equals]) == "3",
              let entry = store.history.first,
              store.expressionPreview == "1 + 2 = 3",
              entry.inputExpression == "1 + 2",
              entry.expression == "1 + 2 = 3"
        else {
            return false
        }

        let operatorStore = CalculatorStore()
        operatorStore.runSequence([.digit(5), .operation(.add), .digit(6)])
        guard operatorStore.expressionPreview == "5 + 6" else {
            return false
        }

        let continuousStore = CalculatorStore()
        continuousStore.runSequence([
            .digit(6), .operation(.add), .digit(5),
            .operation(.add), .digit(9), .operation(.divide), .digit(2),
            .operation(.add), .digit(3), .operation(.subtract), .digit(5),
            .equals
        ])
        guard continuousStore.display == "13.5",
              let continuousEntry = continuousStore.history.first,
              continuousEntry.inputExpression == "6 + 5 + 9 ÷ 2 + 3 − 5",
              continuousEntry.expression == "6 + 5 + 9 ÷ 2 + 3 − 5 = 13.5"
        else {
            return false
        }
        continuousStore.useHistoryExpression(continuousEntry)
        guard continuousStore.displayText == "6 + 5 + 9 ÷ 2 + 3 − 5" else {
            return false
        }
        continuousStore.runSequence([.equals])
        guard continuousStore.display == "13.5" else {
            return false
        }
        continuousStore.clearHistory()
        guard continuousStore.history.isEmpty else {
            return false
        }

        store.runSequence([.digit(9)])
        store.useHistoryResult(entry)
        guard store.display == "3", store.displayText == "3" else {
            return false
        }

        store.runSequence([.digit(8)])
        store.useHistoryExpression(entry)
        guard store.display == "3", store.displayText == "1 + 2" else {
            return false
        }

        store.runSequence([.equals])
        guard store.display == "3", store.displayText == "3" else {
            return false
        }

        store.runSequence([.operation(.add), .digit(4), .equals])
        return store.display == "7"
    }

    private static func parse(_ sequence: String) -> [CalculatorStore.Button] {
        sequence.compactMap { character in
            switch character {
            case "0"..."9":
                return Int(String(character)).map(CalculatorStore.Button.digit)
            case ".":
                return .decimalSeparator
            case "+", "＋", ";":
                return .operation(.add)
            case "-":
                return .operation(.subtract)
            case "*", "＊", "x", "X", ":":
                return .operation(.multiply)
            case "/":
                return .operation(.divide)
            case "=":
                return .equals
            case "%":
                return .percent
            case "c", "C":
                return .allClear
            case "b", "B":
                return .backspace
            case "s", "S":
                return .toggleSign
            default:
                return nil
            }
        }
    }

    private static func requestedSequence() -> String {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--calculator-sequence") else {
            return "12.5*2="
        }
        let valueIndex = arguments.index(after: index)
        guard arguments.indices.contains(valueIndex) else {
            return "12.5*2="
        }
        return arguments[valueIndex]
    }

    private static func outputFileURL() -> URL? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--verify-output") else {
            return nil
        }
        let pathIndex = arguments.index(after: index)
        guard arguments.indices.contains(pathIndex) else {
            return nil
        }
        return URL(fileURLWithPath: arguments[pathIndex])
    }
}
