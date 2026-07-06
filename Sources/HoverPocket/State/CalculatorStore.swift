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
    @Published private(set) var history: [HistoryEntry] = []

    private var accumulator: Decimal?
    private var pendingOperation: Operation?
    private var isEnteringNewValue = true
    private var lastOperand: Decimal?
    private var lastOperation: Operation?

    struct HistoryEntry: Identifiable {
        let id: UUID
        let expression: String
        let result: String
        fileprivate let state: CalculatorState
    }

    fileprivate struct CalculatorState {
        let display: String
        let hasError: Bool
        let accumulator: Decimal?
        let pendingOperation: Operation?
        let isEnteringNewValue: Bool
        let lastOperand: Decimal?
        let lastOperation: Operation?
    }

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

    func useHistoryResult(_ entry: HistoryEntry) {
        guard !entry.result.isEmpty, entry.result != "Error" else { return }
        display = entry.result
        hasError = false
        accumulator = nil
        pendingOperation = nil
        isEnteringNewValue = false
        lastOperand = nil
        lastOperation = nil
    }

    func restore(_ entry: HistoryEntry) {
        apply(entry.state)
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
            let expression = expressionText(lhs: accumulator, rhs: current, operation: pendingOperation, result: result)
            self.accumulator = result
            display = Self.format(result)
            addHistory(expression: expression, result: display)
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
        let expression = expressionText(lhs: lhs, rhs: rhs, operation: operation, result: result)

        display = Self.format(result)
        accumulator = result
        pendingOperation = nil
        lastOperation = operation
        lastOperand = rhs
        isEnteringNewValue = true
        addHistory(expression: expression, result: display)
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
        let expression = "\(Self.format(current))% = \(Self.format(result))"
        display = Self.format(result)
        isEnteringNewValue = false
        addHistory(expression: expression, result: display)
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

    private func expressionText(lhs: Decimal, rhs: Decimal, operation: Operation, result: Decimal) -> String {
        "\(Self.format(lhs)) \(operation.displaySymbol) \(Self.format(rhs)) = \(Self.format(result))"
    }

    private func addHistory(expression: String, result: String) {
        let entry = HistoryEntry(
            id: UUID(),
            expression: expression,
            result: result,
            state: snapshot()
        )
        history.insert(entry, at: 0)
        if history.count > 12 {
            history.removeLast(history.count - 12)
        }
    }

    private func snapshot() -> CalculatorState {
        CalculatorState(
            display: display,
            hasError: hasError,
            accumulator: accumulator,
            pendingOperation: pendingOperation,
            isEnteringNewValue: isEnteringNewValue,
            lastOperand: lastOperand,
            lastOperation: lastOperation
        )
    }

    private func apply(_ state: CalculatorState) {
        display = state.display
        hasError = state.hasError
        accumulator = state.accumulator
        pendingOperation = state.pendingOperation
        isEnteringNewValue = state.isEnteringNewValue
        lastOperand = state.lastOperand
        lastOperation = state.lastOperation
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

extension CalculatorStore.Operation {
    var displaySymbol: String {
        switch self {
        case .add:
            return "+"
        case .subtract:
            return "−"
        case .multiply:
            return "×"
        case .divide:
            return "÷"
        }
    }
}
