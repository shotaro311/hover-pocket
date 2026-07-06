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
        self.expressionInput = nil
    }

    func clearHistory() {
        history.removeAll()
    }

    func useHistoryResult(_ entry: HistoryEntry) {
        guard !entry.result.isEmpty, entry.result != "Error" else { return }
        display = entry.result
        hasError = false
        expressionPreview = nil
        self.expressionInput = nil
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
        if expressionInput != nil {
            appendDigitToExpression(digit)
            return
        }
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
        if expressionInput != nil {
            appendDecimalSeparatorToExpression()
            return
        }
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
        guard let current = currentDecimal else { return }

        if let expressionInput {
            let expression = expressionInput.trimmingCharacters(in: .whitespacesAndNewlines)
            if expression.isEmpty {
                self.expressionInput = "\(Self.format(current)) \(operation.displaySymbol)"
            } else if Self.expressionEndsWithOperator(expression) {
                self.expressionInput = Self.replacingTrailingOperator(in: expression, with: operation)
            } else {
                self.expressionInput = "\(expression) \(operation.displaySymbol)"
            }
        } else {
            expressionInput = "\(Self.format(current)) \(operation.displaySymbol)"
        }

        accumulator = nil
        pendingOperation = nil
        lastOperand = nil
        lastOperation = nil
        isEnteringNewValue = true
        expressionPreview = expressionInput
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
        if let expressionInput {
            var expression = expressionInput.trimmingCharacters(in: .whitespacesAndNewlines)
            if !expression.isEmpty {
                expression.removeLast()
            }
            expression = expression.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !expression.isEmpty else {
                reset()
                return
            }
            self.expressionInput = expression
            expressionPreview = expression
            if Self.expressionEndsWithOperator(expression) {
                isEnteringNewValue = true
                display = Self.trailingOperand(in: Self.removingTrailingOperator(from: expression)) ?? "0"
            } else {
                isEnteringNewValue = false
                display = Self.trailingOperand(in: expression) ?? display
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
        if let expressionInput {
            let expression = expressionInput.trimmingCharacters(in: .whitespacesAndNewlines)
            if isEnteringNewValue, Self.expressionEndsWithOperator(expression) {
                display = "-0"
                self.expressionInput = "\(expression) -0"
                expressionPreview = self.expressionInput
                isEnteringNewValue = false
                return
            }
            guard display != "0" else {
                display = "-0"
                self.expressionInput = Self.replaceTrailingOperand(in: expressionInput, with: display)
                expressionPreview = self.expressionInput
                isEnteringNewValue = false
                return
            }
            if display.hasPrefix("-") {
                display.removeFirst()
            } else {
                display = "-\(display)"
            }
            self.expressionInput = Self.replaceTrailingOperand(in: expressionInput, with: display)
            expressionPreview = self.expressionInput
            isEnteringNewValue = false
            return
        }
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
        if let expressionInput {
            guard let current = currentDecimal else { return }
            let result = current / Decimal(100)
            display = Self.format(result)
            self.expressionInput = Self.replaceTrailingOperand(in: expressionInput, with: display)
            expressionPreview = self.expressionInput
            isEnteringNewValue = false
            return
        }
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
        guard
            let expressionInput,
            isEnteringNewValue,
            !Self.expressionEndsWithOperator(expressionInput)
        else { return }
        self.expressionInput = nil
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
        if expressionInput != nil {
            expressionPreview = expressionInput
            return
        }
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

    private enum ExpressionToken {
        case number(Decimal)
        case operation(Operation)
    }

    private func evaluateExpressionInput(_ input: String) -> ExpressionEvaluation? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let normalized = Self.normalizedExpression(trimmed)
        guard let tokens = Self.expressionTokens(from: normalized) else { return nil }
        guard let result = evaluate(tokens: tokens) else { return nil }

        let inputExpression = Self.displayExpression(from: tokens)
        return ExpressionEvaluation(
            inputExpression: inputExpression,
            expression: expressionText(inputExpression: inputExpression, result: result),
            result: result
        )
    }

    private func evaluate(tokens: [ExpressionToken]) -> Decimal? {
        var values: [Decimal] = []
        var operations: [Operation] = []
        var expectsNumber = true

        for token in tokens {
            switch token {
            case .number(let value):
                guard expectsNumber else { return nil }
                values.append(value)
                expectsNumber = false
            case .operation(let operation):
                guard !expectsNumber else { return nil }
                operations.append(operation)
                expectsNumber = true
            }
        }

        guard !expectsNumber, values.count == operations.count + 1, let firstValue = values.first else {
            return nil
        }

        var reducedValues = [firstValue]
        var reducedOperations: [Operation] = []

        for (index, operation) in operations.enumerated() {
            let rhs = values[index + 1]
            switch operation {
            case .multiply, .divide:
                guard let lhs = reducedValues.popLast(),
                      let result = calculate(lhs, rhs, operation)
                else { return nil }
                reducedValues.append(result)
            case .add, .subtract:
                reducedOperations.append(operation)
                reducedValues.append(rhs)
            }
        }

        guard var result = reducedValues.first else { return nil }
        for (index, operation) in reducedOperations.enumerated() {
            guard index + 1 < reducedValues.count,
                  let value = calculate(result, reducedValues[index + 1], operation)
            else { return nil }
            result = value
        }
        return result
    }

    private func recoverFromErrorIfNeeded() {
        if hasError {
            reset()
        }
    }

    private func appendDigitToExpression(_ digit: Int) {
        guard let expressionInput else { return }
        let digitText = String(digit)
        if isEnteringNewValue {
            let expression = expressionInput.trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.expressionEndsWithOperator(expression) {
                self.expressionInput = "\(expression) \(digitText)"
            } else {
                self.expressionInput = digitText
            }
            display = digitText
            isEnteringNewValue = false
            expressionPreview = self.expressionInput
            return
        }

        if display == "0" {
            display = digitText
        } else if display == "-0" {
            display = "-\(digitText)"
        } else {
            display += digitText
        }
        self.expressionInput = Self.replaceTrailingOperand(in: expressionInput, with: display)
        expressionPreview = self.expressionInput
    }

    private func appendDecimalSeparatorToExpression() {
        guard let expressionInput else { return }
        if isEnteringNewValue {
            let expression = expressionInput.trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.expressionEndsWithOperator(expression) {
                self.expressionInput = "\(expression) 0."
            } else {
                self.expressionInput = "0."
            }
            display = "0."
            isEnteringNewValue = false
            expressionPreview = self.expressionInput
            return
        }

        guard !display.contains(".") else { return }
        display += "."
        self.expressionInput = Self.replaceTrailingOperand(in: expressionInput, with: display)
        expressionPreview = self.expressionInput
    }

    private static func normalizedExpression(_ text: String) -> String {
        text
            .replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: ",", with: ".")
            .filter { !$0.isWhitespace }
    }

    private static func expressionTokens(from text: String) -> [ExpressionToken]? {
        var tokens: [ExpressionToken] = []
        var numberText = ""
        var expectsNumber = true

        for character in text {
            if character == "%" {
                guard let value = decimal(from: numberText) else { return nil }
                numberText = format(value / Decimal(100))
                expectsNumber = false
                continue
            }

            if let operation = Operation(inputSymbol: character) {
                if expectsNumber {
                    if (character == "-" || character == "−"), numberText.isEmpty {
                        numberText = "-"
                        continue
                    }
                    if character == "+", numberText.isEmpty {
                        continue
                    }
                    return nil
                }
                guard let value = decimal(from: numberText) else { return nil }
                tokens.append(.number(value))
                tokens.append(.operation(operation))
                numberText = ""
                expectsNumber = true
                continue
            }

            guard character.isNumber || character == "." else { return nil }
            numberText.append(character)
            expectsNumber = false
        }

        guard !expectsNumber, let value = decimal(from: numberText) else { return nil }
        tokens.append(.number(value))
        return tokens
    }

    private static func displayExpression(from tokens: [ExpressionToken]) -> String {
        tokens.map { token in
            switch token {
            case .number(let value):
                return format(value)
            case .operation(let operation):
                return operation.displaySymbol
            }
        }
        .joined(separator: " ")
    }

    private static func expressionEndsWithOperator(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
        return Operation(inputSymbol: last) != nil
    }

    private static func replacingTrailingOperator(in text: String, with operation: Operation) -> String {
        var expression = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard expressionEndsWithOperator(expression) else {
            return "\(expression) \(operation.displaySymbol)"
        }
        expression.removeLast()
        expression = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(expression) \(operation.displaySymbol)"
    }

    private static func removingTrailingOperator(from text: String) -> String {
        var expression = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if expressionEndsWithOperator(expression) {
            expression.removeLast()
        }
        return expression.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replaceTrailingOperand(in text: String, with operand: String) -> String {
        let expression = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expression.isEmpty else { return operand }
        if expressionEndsWithOperator(expression) {
            return "\(expression) \(operand)"
        }
        var parts = expression.split(separator: " ").map(String.init)
        guard !parts.isEmpty else { return operand }
        parts[parts.count - 1] = operand
        return parts.joined(separator: " ")
    }

    private static func trailingOperand(in text: String) -> String? {
        let expression = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expression.isEmpty else { return nil }
        if expressionEndsWithOperator(expression) {
            return trailingOperand(in: removingTrailingOperator(from: expression))
        }
        return expression.split(separator: " ").last.map(String.init)
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
        case "+", "＋", ";":
            self = .add
        case "-", "−":
            self = .subtract
        case "*", "＊", "×", "x", "X", ":":
            self = .multiply
        case "/", "÷":
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
