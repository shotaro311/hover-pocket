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
    @Published private(set) var expressionPreview: String?
    @Published private(set) var expressionInput: String?

    private var accumulator: Decimal?
    private var pendingOperation: Operation?
    private var isEnteringNewValue = true
    private var lastOperand: Decimal?
    private var lastOperation: Operation?

    var displayText: String {
        expressionInput ?? display
    }

    var isShowingExpressionInput: Bool {
        expressionInput != nil
    }

    struct HistoryEntry: Identifiable {
        let id: UUID
        let inputExpression: String
        let expression: String
        let result: String
        fileprivate let state: CalculatorState
    }

    fileprivate struct CalculatorState {
        let display: String
        let hasError: Bool
        let expressionPreview: String?
        let expressionInput: String?
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
        expressionPreview = nil
        expressionInput = nil
    }

    func useHistoryResult(_ entry: HistoryEntry) {
        guard !entry.result.isEmpty, entry.result != "Error" else { return }
        display = entry.result
        hasError = false
        expressionPreview = nil
        expressionInput = nil
        accumulator = nil
        pendingOperation = nil
        isEnteringNewValue = false
        lastOperand = nil
        lastOperation = nil
    }

    func useHistoryExpression(_ entry: HistoryEntry) {
        guard !entry.inputExpression.isEmpty, entry.result != "Error" else { return }
        display = entry.result
        hasError = false
        expressionPreview = nil
        expressionInput = entry.inputExpression
        accumulator = nil
        pendingOperation = nil
        isEnteringNewValue = true
        lastOperand = nil
        lastOperation = nil
    }

    func restore(_ entry: HistoryEntry) {
        apply(entry.state)
    }

    private func inputDigit(_ digit: Int) {
        guard (0...9).contains(digit) else { return }
        beginFreshInputIfShowingExpression()
        recoverFromErrorIfNeeded()
        clearPreviewForFreshEntryIfNeeded()
        if isEnteringNewValue {
            display = String(digit)
            isEnteringNewValue = false
            updatePendingExpressionPreview()
            return
        }
        if display == "0" {
            display = String(digit)
        } else if display == "-0" {
            display = "-\(digit)"
        } else {
            display += String(digit)
        }
        updatePendingExpressionPreview()
    }

    private func inputDecimalSeparator() {
        beginFreshInputIfShowingExpression()
        recoverFromErrorIfNeeded()
        clearPreviewForFreshEntryIfNeeded()
        if isEnteringNewValue {
            display = "0."
            isEnteringNewValue = false
            updatePendingExpressionPreview()
            return
        }
        guard !display.contains(".") else { return }
        display += "."
        updatePendingExpressionPreview()
    }

    private func inputOperation(_ operation: Operation) {
        recoverFromErrorIfNeeded()
        guard commitExpressionInputIfNeeded(addToHistory: false) else { return }
        guard let current = currentDecimal else { return }

        if let pendingOperation, let accumulator, !isEnteringNewValue {
            guard let result = calculate(accumulator, current, pendingOperation) else {
                showError()
                return
            }
            let inputExpression = expressionInputText(lhs: accumulator, rhs: current, operation: pendingOperation)
            let expression = expressionText(inputExpression: inputExpression, result: result)
            self.accumulator = result
            display = Self.format(result)
            addHistory(inputExpression: inputExpression, expression: expression, result: display)
        } else {
            accumulator = current
        }

        pendingOperation = operation
        lastOperand = nil
        lastOperation = nil
        isEnteringNewValue = true
        updatePendingExpressionPreview()
    }

    private func inputEquals() {
        recoverFromErrorIfNeeded()
        if expressionInput != nil {
            _ = commitExpressionInputIfNeeded(addToHistory: true)
            return
        }
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
        let inputExpression = expressionInputText(lhs: lhs, rhs: rhs, operation: operation)
        let expression = expressionText(inputExpression: inputExpression, result: result)

        display = Self.format(result)
        accumulator = result
        pendingOperation = nil
        lastOperation = operation
        lastOperand = rhs
        isEnteringNewValue = true
        expressionPreview = expression
        addHistory(inputExpression: inputExpression, expression: expression, result: display)
    }

    private func backspace() {
        recoverFromErrorIfNeeded()
        if expressionInput != nil {
            expressionInput?.removeLast()
            if expressionInput?.isEmpty != false {
                reset()
            }
            return
        }
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
        updatePendingExpressionPreview()
    }

    private func toggleSign() {
        recoverFromErrorIfNeeded()
        guard commitExpressionInputIfNeeded(addToHistory: false) else { return }
        guard display != "0" else {
            display = "-0"
            isEnteringNewValue = false
            updatePendingExpressionPreview()
            return
        }
        if display.hasPrefix("-") {
            display.removeFirst()
        } else {
            display = "-\(display)"
        }
        isEnteringNewValue = false
        updatePendingExpressionPreview()
    }

    private func percent() {
        recoverFromErrorIfNeeded()
        guard commitExpressionInputIfNeeded(addToHistory: false) else { return }
        guard let current = currentDecimal else { return }
        let result = current / Decimal(100)
        let inputExpression = "\(Self.format(current))%"
        let expression = "\(inputExpression) = \(Self.format(result))"
        display = Self.format(result)
        isEnteringNewValue = false
        expressionPreview = expression
        addHistory(inputExpression: inputExpression, expression: expression, result: display)
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
        expressionPreview = nil
        expressionInput = nil
        accumulator = nil
        pendingOperation = nil
        isEnteringNewValue = true
        lastOperand = nil
        lastOperation = nil
    }

    private func expressionInputText(lhs: Decimal, rhs: Decimal, operation: Operation) -> String {
        "\(Self.format(lhs)) \(operation.displaySymbol) \(Self.format(rhs))"
    }

    private func expressionText(inputExpression: String, result: Decimal) -> String {
        "\(inputExpression) = \(Self.format(result))"
    }

    private func addHistory(inputExpression: String, expression: String, result: String) {
        let entry = HistoryEntry(
            id: UUID(),
            inputExpression: inputExpression,
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
            expressionPreview: expressionPreview,
            expressionInput: expressionInput,
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
        expressionPreview = state.expressionPreview
        expressionInput = state.expressionInput
        accumulator = state.accumulator
        pendingOperation = state.pendingOperation
        isEnteringNewValue = state.isEnteringNewValue
        lastOperand = state.lastOperand
        lastOperation = state.lastOperation
    }

    private func beginFreshInputIfShowingExpression() {
        guard expressionInput != nil else { return }
        expressionInput = nil
        expressionPreview = nil
        display = "0"
        hasError = false
        accumulator = nil
        pendingOperation = nil
        isEnteringNewValue = true
        lastOperand = nil
        lastOperation = nil
    }

    private func clearPreviewForFreshEntryIfNeeded() {
        guard isEnteringNewValue, pendingOperation == nil else { return }
        expressionPreview = nil
        lastOperand = nil
        lastOperation = nil
    }

    private func updatePendingExpressionPreview() {
        guard expressionInput == nil else { return }
        guard let accumulator, let pendingOperation else { return }
        let lhs = Self.format(accumulator)
        if isEnteringNewValue {
            expressionPreview = "\(lhs) \(pendingOperation.displaySymbol)"
        } else {
            expressionPreview = "\(lhs) \(pendingOperation.displaySymbol) \(display)"
        }
    }

    private func commitExpressionInputIfNeeded(addToHistory: Bool) -> Bool {
        guard let expressionInput else { return true }
        guard let evaluation = evaluateExpressionInput(expressionInput) else {
            showError()
            return false
        }

        display = Self.format(evaluation.result)
        hasError = false
        self.expressionInput = nil
        expressionPreview = evaluation.expression
        accumulator = nil
        pendingOperation = nil
        isEnteringNewValue = addToHistory
        lastOperand = nil
        lastOperation = nil

        if addToHistory {
            addHistory(
                inputExpression: evaluation.inputExpression,
                expression: evaluation.expression,
                result: display
            )
        }

        return true
    }

    private struct ExpressionEvaluation {
        let inputExpression: String
        let expression: String
        let result: Decimal
    }

    private func evaluateExpressionInput(_ input: String) -> ExpressionEvaluation? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed
            .replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: ",", with: ".")
            .filter { !$0.isWhitespace }

        if normalized.hasSuffix("%") {
            let numberText = String(normalized.dropLast())
            guard let value = Self.decimal(from: numberText) else { return nil }
            let result = value / Decimal(100)
            let inputExpression = "\(Self.format(value))%"
            return ExpressionEvaluation(
                inputExpression: inputExpression,
                expression: "\(inputExpression) = \(Self.format(result))",
                result: result
            )
        }

        guard let operationIndex = Self.binaryOperationIndex(in: normalized) else { return nil }
        let lhsText = String(normalized[..<operationIndex])
        let rhsStart = normalized.index(after: operationIndex)
        let rhsText = String(normalized[rhsStart...])
        guard
            let lhs = Self.decimal(from: lhsText),
            let rhs = Self.decimal(from: rhsText),
            let operation = Operation(inputSymbol: normalized[operationIndex]),
            let result = calculate(lhs, rhs, operation)
        else {
            return nil
        }

        let inputExpression = expressionInputText(lhs: lhs, rhs: rhs, operation: operation)
        return ExpressionEvaluation(
            inputExpression: inputExpression,
            expression: expressionText(inputExpression: inputExpression, result: result),
            result: result
        )
    }

    private static func binaryOperationIndex(in text: String) -> String.Index? {
        guard text.count >= 3 else { return nil }
        var index = text.index(after: text.startIndex)
        while index < text.endIndex {
            if Operation(inputSymbol: text[index]) != nil {
                return index
            }
            index = text.index(after: index)
        }
        return nil
    }

    private func recoverFromErrorIfNeeded() {
        if hasError {
            reset()
        }
    }

    private static func decimal(from text: String) -> Decimal? {
        Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
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
    init?(inputSymbol: Character) {
        switch inputSymbol {
        case "+":
            self = .add
        case "-":
            self = .subtract
        case "*":
            self = .multiply
        case "/":
            self = .divide
        default:
            return nil
        }
    }

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
