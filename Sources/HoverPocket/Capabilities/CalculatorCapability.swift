import Foundation

struct CalculatorCapabilityEvaluation: Equatable, Sendable {
    let normalizedExpression: String
    let result: String
}

enum CalculatorCapabilityEvaluator {
    private enum Operation: Character {
        case add = "+"
        case subtract = "-"
        case multiply = "*"
        case divide = "/"
    }

    private static let maximumMagnitude = Decimal(string: "999999999999999999", locale: posixLocale)!
    private static let posixLocale = Locale(identifier: "en_US_POSIX")
    private static let maximumValues = 64

    static func evaluate(_ expression: String) throws -> CalculatorCapabilityEvaluation {
        let normalized = expression
            .replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: ",", with: ".")
            .unicodeScalars
            .filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
            .map(String.init)
            .joined()
        guard !normalized.isEmpty,
              normalized.unicodeScalars.count <= 256,
              normalized.unicodeScalars.allSatisfy({ $0.isASCII }) else {
            throw CapabilityHandlerError.invalidArgument("expression")
        }

        let characters = Array(normalized)
        var values: [Decimal] = []
        var operations: [Operation] = []
        var index = 0
        while index < characters.count {
            guard values.count < maximumValues else {
                throw CapabilityHandlerError.invalidArgument("expression")
            }
            let start = index
            if characters[index] == "+" || characters[index] == "-" {
                index += 1
            }
            var integerDigits = 0
            var fractionDigits = 0
            var sawDecimal = false
            while index < characters.count {
                let character = characters[index]
                if character.isNumber {
                    if sawDecimal {
                        fractionDigits += 1
                    } else {
                        integerDigits += 1
                    }
                    index += 1
                    continue
                }
                if character == ".", !sawDecimal {
                    sawDecimal = true
                    index += 1
                    continue
                }
                break
            }
            guard integerDigits + fractionDigits > 0,
                  integerDigits <= 18,
                  fractionDigits <= 12,
                  index - start <= 32,
                  let value = Decimal(
                    string: String(characters[start..<index]),
                    locale: posixLocale
                  ),
                  !value.isNaN,
                  value.magnitude <= maximumMagnitude else {
                throw CapabilityHandlerError.invalidArgument("expression")
            }
            values.append(value)
            if index == characters.count {
                break
            }
            guard let operation = Operation(rawValue: characters[index]) else {
                throw CapabilityHandlerError.invalidArgument("expression")
            }
            operations.append(operation)
            index += 1
            guard index < characters.count else {
                throw CapabilityHandlerError.invalidArgument("expression")
            }
        }
        guard values.count == operations.count + 1 else {
            throw CapabilityHandlerError.invalidArgument("expression")
        }

        var reducedValues = [values[0]]
        var reducedOperations: [Operation] = []
        for (operationIndex, operation) in operations.enumerated() {
            let rhs = values[operationIndex + 1]
            switch operation {
            case .multiply, .divide:
                guard let lhs = reducedValues.popLast() else {
                    throw CapabilityHandlerError.invalidArgument("expression")
                }
                reducedValues.append(try calculate(lhs, rhs, operation))
            case .add, .subtract:
                reducedOperations.append(operation)
                reducedValues.append(rhs)
            }
        }
        var result = reducedValues[0]
        for (operationIndex, operation) in reducedOperations.enumerated() {
            result = try calculate(result, reducedValues[operationIndex + 1], operation)
        }
        var normalizedParts: [String] = []
        for valueIndex in values.indices {
            normalizedParts.append(format(values[valueIndex]))
            if valueIndex < operations.count {
                normalizedParts.append(String(operations[valueIndex].rawValue))
            }
        }
        return CalculatorCapabilityEvaluation(
            normalizedExpression: normalizedParts.joined(separator: " "),
            result: format(result)
        )
    }

    private static func calculate(
        _ lhs: Decimal,
        _ rhs: Decimal,
        _ operation: Operation
    ) throws -> Decimal {
        if operation == .divide, rhs == 0 {
            throw CapabilityHandlerError.invalidArgument("expression")
        }
        let raw: Decimal
        switch operation {
        case .add: raw = lhs + rhs
        case .subtract: raw = lhs - rhs
        case .multiply: raw = lhs * rhs
        case .divide: raw = lhs / rhs
        }
        guard !raw.isNaN, raw.magnitude <= maximumMagnitude else {
            throw CapabilityHandlerError.invalidArgument("expression")
        }
        var input = raw
        var rounded = Decimal()
        NSDecimalRound(&rounded, &input, 12, .plain)
        guard !rounded.isNaN, rounded.magnitude <= maximumMagnitude else {
            throw CapabilityHandlerError.invalidArgument("expression")
        }
        return rounded
    }

    private static func format(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.locale = posixLocale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 12
        formatter.roundingMode = .halfUp
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? "0"
    }
}

@MainActor
final class CalculatorEvaluateCapabilityHandler: PocketCapabilityHandler {
    let key = PocketCapabilityKeys.calculatorEvaluate

    func handle(
        arguments: CapabilityObject,
        context: CapabilityHandlerContext
    ) async throws -> CapabilityObject {
        _ = context
        guard Set(arguments.keys) == ["expression"] else {
            throw CapabilityHandlerError.invalidArgument("expression")
        }
        let evaluation = try CalculatorCapabilityEvaluator.evaluate(
            arguments.requiredString("expression", maxLength: 256)
        )
        return [
            "normalizedExpression": .string(evaluation.normalizedExpression),
            "result": .string(evaluation.result)
        ]
    }
}
