import Foundation

@MainActor
final class CalculatorStore: ObservableObject {
    static let shared = CalculatorStore()

    enum Button: Equatable, Sendable {
        case digit(Int)
        case decimalSeparator
        case operation(Operation)
        case equals
        case allClear
        case backspace
        case toggleSign
        case percent
    }

    enum Operation: String, Equatable, Sendable {
        case add = "+"
        case subtract = "-"
        case multiply = "*"
        case divide = "/"
    }

    @Published private(set) var display = "0"
    @Published private(set) var hasError = false

    private var accumulator: Decimal?
    private var pendingOperation: Operation?
    private var isEnteringNewValue = true
    private var lastOperand: Decimal?
    private var lastOperation: Operation?

    init() {}

    func press(_ button: Button) {
        switch button {
        case .digit(let digit):
            inputDigit(digit)
        case .decimalSeparator:
            inputDecimalSeparator()
        case .operation(let operation):
            inputOperation(operation)
        case .equals:
            inputEquals()
        case .allClear:
            reset()
        case .backspace:
            backspace()
        case .toggleSign:
            toggleSign()
        case .percent:
            percent()
        }
    }

    @discardableResult
    func runSequence(_ buttons: [Button]) -> String {
        buttons.forEach(press)
        return display
    }

    func reset() {
        display = "0"
        hasError = false
        accumulator = nil
        pendingOperation = nil
        isEnteringNewValue = true
        lastOperand = nil
        lastOperation = nil
    }

    private func inputDigit(_ digit: Int) {
        guard (0...9).contains(digit) else { return }
        recoverFromErrorIfNeeded()
        if isEnteringNewValue {
            display = String(digit)
            isEnteringNewValue = false
            return
        }
        if display == "0" {
            display = String(digit)
        } else if display == "-0" {
            display = "-\(digit)"
        } else {
            display += String(digit)
        }
    }

    private func inputDecimalSeparator() {
        recoverFromErrorIfNeeded()
        if isEnteringNewValue {
            display = "0."
            isEnteringNewValue = false
            return
        }
        guard !display.contains(".") else { return }
        display += "."
    }

    private func inputOperation(_ operation: Operation) {
        recoverFromErrorIfNeeded()
        guard let current = currentDecimal else { return }

        if let pendingOperation, let accumulator, !isEnteringNewValue {
            guard let result = calculate(accumulator, current, pendingOperation) else {
                showError()
                return
            }
            self.accumulator = result
            display = Self.format(result)
        } else {
            accumulator = current
        }

        pendingOperation = operation
        lastOperand = nil
        lastOperation = nil
        isEnteringNewValue = true
    }

    private func inputEquals() {
        recoverFromErrorIfNeeded()
        guard let current = currentDecimal else { return }

        let operation: Operation?
        let rhs: Decimal
        if let pendingOperation, let accumulator {
            operation = pendingOperation
            rhs = current
            self.accumulator = accumulator
        } else if let lastOperation, let lastOperand {
            operation = lastOperation
            rhs = lastOperand
            accumulator = current
        } else {
            isEnteringNewValue = true
            return
        }

        guard let operation, let lhs = accumulator else { return }
        guard let result = calculate(lhs, rhs, operation) else {
            showError()
            return
        }

        display = Self.format(result)
        accumulator = result
        pendingOperation = nil
        lastOperation = operation
        lastOperand = rhs
        isEnteringNewValue = true
    }

    private func backspace() {
        recoverFromErrorIfNeeded()
        guard !isEnteringNewValue else {
            display = "0"
            return
        }
        if display.count <= 1 || (display.hasPrefix("-") && display.count <= 2) {
            display = "0"
            isEnteringNewValue = true
            return
        }
        display.removeLast()
        if display == "-0" || display == "-" {
            display = "0"
            isEnteringNewValue = true
        }
    }

    private func toggleSign() {
        recoverFromErrorIfNeeded()
        guard display != "0" else {
            display = "-0"
            isEnteringNewValue = false
            return
        }
        if display.hasPrefix("-") {
            display.removeFirst()
        } else {
            display = "-\(display)"
        }
        isEnteringNewValue = false
    }

    private func percent() {
        recoverFromErrorIfNeeded()
        guard let current = currentDecimal else { return }
        let result = current / Decimal(100)
        display = Self.format(result)
        isEnteringNewValue = false
    }

    private func calculate(_ lhs: Decimal, _ rhs: Decimal, _ operation: Operation) -> Decimal? {
        switch operation {
        case .add:
            return lhs + rhs
        case .subtract:
            return lhs - rhs
        case .multiply:
            return lhs * rhs
        case .divide:
            guard rhs != 0 else { return nil }
            return lhs / rhs
        }
    }

    private var currentDecimal: Decimal? {
        Decimal(string: display.replacingOccurrences(of: "_", with: ""), locale: Locale(identifier: "en_US_POSIX"))
    }

    private func showError() {
        display = "Error"
        hasError = true
        accumulator = nil
        pendingOperation = nil
        isEnteringNewValue = true
        lastOperand = nil
        lastOperation = nil
    }

    private func recoverFromErrorIfNeeded() {
        if hasError {
            reset()
        }
    }

    private static func format(_ value: Decimal) -> String {
        let number = NSDecimalNumber(decimal: value)
        if number == .notANumber {
            return "Error"
        }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 12
        formatter.roundingMode = .halfUp
        return formatter.string(from: number) ?? "\(number)"
    }
}
