using System.Globalization;
using System.Text;
using System.Text.Json;

namespace HoverPocket.Shell.Capabilities;

internal sealed record CalculatorCapabilityEvaluation(string NormalizedExpression, string Result);

internal static class CalculatorCapabilityEvaluator
{
    private const int MaximumValues = 64;
    private const decimal MaximumMagnitude = 999999999999999999m;

    public static CalculatorCapabilityEvaluation Evaluate(string expression)
    {
        var normalized = string.Concat(expression
            .Replace('−', '-')
            .Replace('×', '*')
            .Replace('÷', '/')
            .Replace(',', '.')
            .Where(character => !char.IsWhiteSpace(character)));
        if (normalized.Length is 0 or > 256 || normalized.Any(character => character > 0x7f))
        {
            throw CapabilityJson.Invalid("expression");
        }

        var values = new List<decimal>();
        var operations = new List<char>();
        var index = 0;
        while (index < normalized.Length)
        {
            if (values.Count >= MaximumValues)
            {
                throw CapabilityJson.Invalid("expression");
            }
            var start = index;
            if (normalized[index] is '+' or '-')
            {
                index += 1;
            }
            var integerDigits = 0;
            var fractionDigits = 0;
            var sawDecimal = false;
            while (index < normalized.Length)
            {
                var character = normalized[index];
                if (character is >= '0' and <= '9')
                {
                    if (sawDecimal)
                    {
                        fractionDigits += 1;
                    }
                    else
                    {
                        integerDigits += 1;
                    }
                    index += 1;
                    continue;
                }
                if (character == '.' && !sawDecimal)
                {
                    sawDecimal = true;
                    index += 1;
                    continue;
                }
                break;
            }
            if (integerDigits + fractionDigits == 0
                || integerDigits > 18
                || fractionDigits > 12
                || index - start > 32
                || !decimal.TryParse(
                    normalized.AsSpan(start, index - start),
                    NumberStyles.AllowLeadingSign | NumberStyles.AllowDecimalPoint,
                    CultureInfo.InvariantCulture,
                    out var value)
                || Math.Abs(value) > MaximumMagnitude)
            {
                throw CapabilityJson.Invalid("expression");
            }
            values.Add(value);
            if (index == normalized.Length)
            {
                break;
            }
            var operation = normalized[index];
            if (operation is not ('+' or '-' or '*' or '/'))
            {
                throw CapabilityJson.Invalid("expression");
            }
            operations.Add(operation);
            index += 1;
            if (index == normalized.Length)
            {
                throw CapabilityJson.Invalid("expression");
            }
        }
        if (values.Count != operations.Count + 1)
        {
            throw CapabilityJson.Invalid("expression");
        }

        var reducedValues = new List<decimal> { values[0] };
        var reducedOperations = new List<char>();
        for (var operationIndex = 0; operationIndex < operations.Count; operationIndex++)
        {
            var operation = operations[operationIndex];
            var rhs = values[operationIndex + 1];
            if (operation is '*' or '/')
            {
                var lhs = reducedValues[^1];
                reducedValues[^1] = Calculate(lhs, rhs, operation);
            }
            else
            {
                reducedOperations.Add(operation);
                reducedValues.Add(rhs);
            }
        }
        var result = reducedValues[0];
        for (var operationIndex = 0; operationIndex < reducedOperations.Count; operationIndex++)
        {
            result = Calculate(result, reducedValues[operationIndex + 1], reducedOperations[operationIndex]);
        }

        var builder = new StringBuilder();
        for (var valueIndex = 0; valueIndex < values.Count; valueIndex++)
        {
            if (valueIndex > 0)
            {
                builder.Append(' ').Append(operations[valueIndex - 1]).Append(' ');
            }
            builder.Append(Format(values[valueIndex]));
        }
        return new CalculatorCapabilityEvaluation(builder.ToString(), Format(result));
    }

    private static decimal Calculate(decimal lhs, decimal rhs, char operation)
    {
        if (operation == '/' && rhs == 0m)
        {
            throw CapabilityJson.Invalid("expression");
        }
        try
        {
            var raw = operation switch
            {
                '+' => checked(lhs + rhs),
                '-' => checked(lhs - rhs),
                '*' => checked(lhs * rhs),
                '/' => checked(lhs / rhs),
                _ => throw CapabilityJson.Invalid("expression")
            };
            if (Math.Abs(raw) > MaximumMagnitude)
            {
                throw CapabilityJson.Invalid("expression");
            }
            return Math.Round(raw, 12, MidpointRounding.AwayFromZero);
        }
        catch (OverflowException)
        {
            throw CapabilityJson.Invalid("expression");
        }
    }

    private static string Format(decimal value) =>
        value.ToString("0.############", CultureInfo.InvariantCulture);
}

internal sealed class CalculatorEvaluateCapabilityHandler : IPocketCapabilityHandler
{
    public PocketCapabilityKey Key => CapabilityIds.CalculatorEvaluate;

    public Task<JsonElement> HandleAsync(
        JsonElement arguments,
        CapabilityHandlerContext context,
        CancellationToken cancellationToken = default)
    {
        _ = context;
        cancellationToken.ThrowIfCancellationRequested();
        CapabilitySchemaValidation.ExactKeys(arguments, ["expression"]);
        var evaluation = CalculatorCapabilityEvaluator.Evaluate(
            CapabilityJson.RequiredString(arguments, "expression", 256));
        return Task.FromResult(CapabilityJson.From(new
        {
            evaluation.NormalizedExpression,
            evaluation.Result
        }));
    }
}
