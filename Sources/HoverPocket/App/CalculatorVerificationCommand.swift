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
            "calculator_display=\(display)"
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
            ([.digit(1), .digit(2), .backspace], "1")
        ]
        for (buttons, expected) in cases {
            let store = CalculatorStore()
            guard store.runSequence(buttons) == expected else {
                return false
            }
        }
        return true
    }

    private static func parse(_ sequence: String) -> [CalculatorStore.Button] {
        sequence.compactMap { character in
            switch character {
            case "0"..."9":
                return Int(String(character)).map(CalculatorStore.Button.digit)
            case ".":
                return .decimalSeparator
            case "+":
                return .operation(.add)
            case "-":
                return .operation(.subtract)
            case "*", "x", "X":
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
