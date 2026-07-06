using System.Globalization;

namespace HoverPocket.Shell.Providers.Calculator;

internal sealed class CalculatorEngine
{
    private const int MaxHistoryItems = 24;

    private decimal? _accumulator;
    private CalculatorOperation? _pendingOperation;
    private bool _isEnteringNewValue = true;
    private decimal? _lastOperand;
    private CalculatorOperation? _lastOperation;
    private bool _justEvaluated;
    private string? _completedExpressionDisplay;
    private readonly List<CalculatorExpressionPart> _expressionParts = [];
    private readonly List<CalculatorHistoryEntry> _history = [];

    public string Display { get; private set; } = "0";

    public string ExpressionDisplay => BuildExpressionDisplay();

    public bool HasError { get; private set; }

    public CalculatorSnapshot Snapshot => new(
        Display,
        ExpressionDisplay,
        HasError,
        !HasError,
        _history.Select(entry => entry.Item).ToArray());

    public CalculatorSnapshot PressToken(string token)
    {
        var normalizedToken = NormalizeToken(token);
        switch (normalizedToken)
        {
            case "0":
            case "1":
            case "2":
            case "3":
            case "4":
            case "5":
            case "6":
            case "7":
            case "8":
            case "9":
                InputDigit(normalizedToken[0] - '0');
                break;
            case ".":
                InputDecimalSeparator();
                break;
            case "+":
                InputOperation(CalculatorOperation.Add);
                break;
            case "-":
                InputOperation(CalculatorOperation.Subtract);
                break;
            case "*":
                InputOperation(CalculatorOperation.Multiply);
                break;
            case "/":
                InputOperation(CalculatorOperation.Divide);
                break;
            case "=":
                InputEquals();
                break;
            case "AC":
                Reset();
                break;
            case "BS":
                Backspace();
                break;
            case "+/-":
                ToggleSign();
                break;
            case "%":
                Percent();
                break;
        }

        return Snapshot;
    }

    public CalculatorSnapshot UseHistoryValue(string historyId)
    {
        var entry = FindHistoryEntry(historyId);
        if (entry is null)
        {
            return Snapshot;
        }

        RecoverFromErrorIfNeeded();
        Display = entry.Item.Result;
        HasError = false;
        _accumulator = null;
        _pendingOperation = null;
        _isEnteringNewValue = false;
        _lastOperand = null;
        _lastOperation = null;
        _justEvaluated = false;
        _completedExpressionDisplay = null;
        _expressionParts.Clear();
        return Snapshot;
    }

    public CalculatorSnapshot RestoreHistory(string historyId)
    {
        var entry = FindHistoryEntry(historyId);
        if (entry is null)
        {
            return Snapshot;
        }

        RestoreState(entry.State);
        return Snapshot;
    }

    public CalculatorSnapshot ClearHistory()
    {
        _history.Clear();
        return Snapshot;
    }

    public void Reset()
    {
        Display = "0";
        HasError = false;
        _accumulator = null;
        _pendingOperation = null;
        _isEnteringNewValue = true;
        _lastOperand = null;
        _lastOperation = null;
        _justEvaluated = false;
        _completedExpressionDisplay = null;
        _expressionParts.Clear();
    }

    private void InputDigit(int digit)
    {
        if (digit is < 0 or > 9)
        {
            return;
        }

        RecoverFromErrorIfNeeded();
        if (_isEnteringNewValue)
        {
            if (_justEvaluated)
            {
                ClearExpressionForFreshInput();
            }

            Display = digit.ToString(CultureInfo.InvariantCulture);
            _isEnteringNewValue = false;
            return;
        }

        Display = Display switch
        {
            "0" => digit.ToString(CultureInfo.InvariantCulture),
            "-0" => $"-{digit}",
            _ => Display + digit.ToString(CultureInfo.InvariantCulture)
        };
    }

    private void InputDecimalSeparator()
    {
        RecoverFromErrorIfNeeded();
        if (_isEnteringNewValue)
        {
            if (_justEvaluated)
            {
                ClearExpressionForFreshInput();
            }

            Display = "0.";
            _isEnteringNewValue = false;
            return;
        }

        if (!Display.Contains('.', StringComparison.Ordinal))
        {
            Display += ".";
        }
    }

    private void InputOperation(CalculatorOperation operation)
    {
        RecoverFromErrorIfNeeded();
        if (!TryCurrentDecimal(out var current))
        {
            return;
        }

        if (_justEvaluated)
        {
            _expressionParts.Clear();
            _completedExpressionDisplay = null;
            _justEvaluated = false;
        }

        if (_expressionParts.Count == 0)
        {
            _expressionParts.Add(CalculatorExpressionPart.FromNumber(current));
        }
        else if (_expressionParts[^1].IsOperation && _isEnteringNewValue)
        {
            _expressionParts[^1] = CalculatorExpressionPart.FromOperation(operation);
            _pendingOperation = operation;
            _accumulator = current;
            _lastOperand = null;
            _lastOperation = null;
            return;
        }
        else if (!_isEnteringNewValue)
        {
            _expressionParts.Add(CalculatorExpressionPart.FromNumber(current));
        }

        if (_expressionParts.Count == 0 || !_expressionParts[^1].IsOperation)
        {
            _expressionParts.Add(CalculatorExpressionPart.FromOperation(operation));
        }
        else
        {
            _expressionParts[^1] = CalculatorExpressionPart.FromOperation(operation);
        }

        _pendingOperation = operation;
        _accumulator = current;
        _lastOperand = null;
        _lastOperation = null;
        _isEnteringNewValue = true;
    }

    private void InputEquals()
    {
        RecoverFromErrorIfNeeded();
        if (!TryCurrentDecimal(out var current))
        {
            return;
        }

        if (_expressionParts.Count == 0)
        {
            RepeatLastOperation(current);
            return;
        }

        var parts = _expressionParts.ToList();
        if (parts[^1].IsOperation)
        {
            parts.Add(CalculatorExpressionPart.FromNumber(current));
        }
        else if (!_isEnteringNewValue)
        {
            parts.Add(CalculatorExpressionPart.FromNumber(current));
        }

        if (!TryEvaluate(parts, out var result))
        {
            ShowError();
            return;
        }

        var expression = FormatExpression(parts);
        Display = Format(result);
        _expressionParts.Clear();
        _completedExpressionDisplay = expression;
        _accumulator = result;
        _pendingOperation = null;
        (_lastOperation, _lastOperand) = LastOperationAndOperand(parts);
        _isEnteringNewValue = true;
        _justEvaluated = true;
        AddHistory(expression, result);
    }

    private void RepeatLastOperation(decimal current)
    {
        if (_lastOperation is null || _lastOperand is null)
        {
            _isEnteringNewValue = true;
            return;
        }

        if (!TryCalculate(current, _lastOperand.Value, _lastOperation.Value, out var result))
        {
            ShowError();
            return;
        }

        var expression = $"{Format(current)} {OperationSymbol(_lastOperation.Value)} {Format(_lastOperand.Value)}";
        Display = Format(result);
        _accumulator = result;
        _pendingOperation = null;
        _completedExpressionDisplay = expression;
        _isEnteringNewValue = true;
        _justEvaluated = true;
        AddHistory(expression, result);
    }

    private void Backspace()
    {
        RecoverFromErrorIfNeeded();
        if (_isEnteringNewValue)
        {
            Display = "0";
            _completedExpressionDisplay = null;
            _justEvaluated = false;
            return;
        }

        if (Display.Length <= 1 || (Display.StartsWith("-", StringComparison.Ordinal) && Display.Length <= 2))
        {
            Display = "0";
            _isEnteringNewValue = true;
            return;
        }

        Display = Display[..^1];
        if (Display is "-0" or "-")
        {
            Display = "0";
            _isEnteringNewValue = true;
        }
    }

    private void ToggleSign()
    {
        RecoverFromErrorIfNeeded();
        _completedExpressionDisplay = null;
        _justEvaluated = false;
        if (Display == "0")
        {
            Display = "-0";
            _isEnteringNewValue = false;
            return;
        }

        Display = Display.StartsWith("-", StringComparison.Ordinal)
            ? Display[1..]
            : $"-{Display}";
        _isEnteringNewValue = false;
    }

    private void Percent()
    {
        RecoverFromErrorIfNeeded();
        if (!TryCurrentDecimal(out var current))
        {
            return;
        }

        _completedExpressionDisplay = null;
        _justEvaluated = false;
        var result = current / 100m;
        Display = Format(result);
        _isEnteringNewValue = false;
    }

    private bool TryCurrentDecimal(out decimal current)
    {
        return decimal.TryParse(Display, NumberStyles.Number, CultureInfo.InvariantCulture, out current);
    }

    private static bool TryEvaluate(IReadOnlyList<CalculatorExpressionPart> parts, out decimal result)
    {
        var values = new List<decimal>();
        var operations = new List<CalculatorOperation>();
        var expectNumber = true;
        foreach (var part in parts)
        {
            if (expectNumber)
            {
                if (!part.IsNumber)
                {
                    result = 0m;
                    return false;
                }

                values.Add(part.Number!.Value);
                expectNumber = false;
                continue;
            }

            if (!part.IsOperation)
            {
                result = 0m;
                return false;
            }

            operations.Add(part.Operation!.Value);
            expectNumber = true;
        }

        if (expectNumber || values.Count == 0 || values.Count != operations.Count + 1)
        {
            result = 0m;
            return false;
        }

        for (var index = 0; index < operations.Count;)
        {
            var operation = operations[index];
            if (operation is not (CalculatorOperation.Multiply or CalculatorOperation.Divide))
            {
                index++;
                continue;
            }

            if (!TryCalculate(values[index], values[index + 1], operation, out var partial))
            {
                result = 0m;
                return false;
            }

            values[index] = partial;
            values.RemoveAt(index + 1);
            operations.RemoveAt(index);
        }

        result = values[0];
        for (var index = 0; index < operations.Count; index++)
        {
            if (!TryCalculate(result, values[index + 1], operations[index], out result))
            {
                return false;
            }
        }

        return true;
    }

    private static bool TryCalculate(
        decimal lhs,
        decimal rhs,
        CalculatorOperation operation,
        out decimal result)
    {
        switch (operation)
        {
            case CalculatorOperation.Add:
                result = lhs + rhs;
                return true;
            case CalculatorOperation.Subtract:
                result = lhs - rhs;
                return true;
            case CalculatorOperation.Multiply:
                result = lhs * rhs;
                return true;
            case CalculatorOperation.Divide:
                if (rhs == 0m)
                {
                    result = 0m;
                    return false;
                }

                result = lhs / rhs;
                return true;
            default:
                result = 0m;
                return false;
        }
    }

    private void ShowError()
    {
        Display = "Error";
        HasError = true;
        _accumulator = null;
        _pendingOperation = null;
        _isEnteringNewValue = true;
        _lastOperand = null;
        _lastOperation = null;
        _justEvaluated = false;
        _completedExpressionDisplay = null;
        _expressionParts.Clear();
    }

    private CalculatorHistoryEntry? FindHistoryEntry(string historyId)
    {
        return _history.FirstOrDefault(entry =>
            string.Equals(entry.Item.Id, historyId, StringComparison.Ordinal));
    }

    private void AddHistory(string expression, decimal result)
    {
        var item = new CalculatorHistoryItem(
            Guid.NewGuid().ToString("N"),
            expression,
            Format(result));
        _history.Add(new CalculatorHistoryEntry(item, CaptureState()));
        if (_history.Count > MaxHistoryItems)
        {
            _history.RemoveAt(0);
        }
    }

    private CalculatorInternalState CaptureState()
    {
        return new CalculatorInternalState(
            Display,
            HasError,
            _accumulator,
            _pendingOperation,
            _isEnteringNewValue,
            _lastOperand,
            _lastOperation,
            _justEvaluated,
            _completedExpressionDisplay,
            _expressionParts.ToArray());
    }

    private void RestoreState(CalculatorInternalState state)
    {
        Display = state.Display;
        HasError = state.HasError;
        _accumulator = state.Accumulator;
        _pendingOperation = state.PendingOperation;
        _isEnteringNewValue = state.IsEnteringNewValue;
        _lastOperand = state.LastOperand;
        _lastOperation = state.LastOperation;
        _justEvaluated = state.JustEvaluated;
        _completedExpressionDisplay = state.CompletedExpressionDisplay;
        _expressionParts.Clear();
        _expressionParts.AddRange(state.ExpressionParts);
    }

    private void RecoverFromErrorIfNeeded()
    {
        if (HasError)
        {
            Reset();
        }
    }

    private void ClearExpressionForFreshInput()
    {
        _accumulator = null;
        _pendingOperation = null;
        _lastOperand = null;
        _lastOperation = null;
        _justEvaluated = false;
        _completedExpressionDisplay = null;
        _expressionParts.Clear();
    }

    private string BuildExpressionDisplay()
    {
        if (HasError)
        {
            return string.Empty;
        }

        if (!string.IsNullOrWhiteSpace(_completedExpressionDisplay))
        {
            return _completedExpressionDisplay;
        }

        if (_expressionParts.Count == 0)
        {
            return string.Empty;
        }

        var parts = _expressionParts.ToList();
        if (!_isEnteringNewValue && parts[^1].IsOperation && TryCurrentDecimal(out var current))
        {
            parts.Add(CalculatorExpressionPart.FromNumber(current));
        }

        return FormatExpression(parts);
    }

    private static string NormalizeToken(string token)
    {
        var trimmed = token.Trim();
        if (trimmed.Length == "Numpad0".Length
            && trimmed.StartsWith("Numpad", StringComparison.Ordinal)
            && char.IsDigit(trimmed[^1]))
        {
            return trimmed[^1].ToString();
        }

        return trimmed switch
        {
            "÷" => "/",
            "×" or "x" or "X" or ":" => "*",
            "−" => "-",
            ";" => "+",
            "\r" or "\n" or "Enter" or "NumpadEnter" or "NumpadEqual" => "=",
            "Escape" or "Esc" or "C" => "AC",
            "Backspace" or "Delete" => "BS",
            "NumpadDecimal" => ".",
            "NumpadAdd" => "+",
            "NumpadSubtract" => "-",
            "NumpadMultiply" => "*",
            "NumpadDivide" => "/",
            "±" => "+/-",
            var normalized => normalized
        };
    }

    private static (CalculatorOperation? Operation, decimal? Operand) LastOperationAndOperand(
        IReadOnlyList<CalculatorExpressionPart> parts)
    {
        for (var index = parts.Count - 2; index >= 0; index--)
        {
            if (parts[index].IsOperation && index + 1 < parts.Count && parts[index + 1].IsNumber)
            {
                return (parts[index].Operation, parts[index + 1].Number);
            }
        }

        return (null, null);
    }

    private static string FormatExpression(IEnumerable<CalculatorExpressionPart> parts)
    {
        return string.Join(" ", parts.Select(part =>
            part.IsNumber
                ? Format(part.Number!.Value)
                : OperationSymbol(part.Operation!.Value)));
    }

    private static string OperationSymbol(CalculatorOperation operation)
    {
        return operation switch
        {
            CalculatorOperation.Add => "+",
            CalculatorOperation.Subtract => "−",
            CalculatorOperation.Multiply => "×",
            CalculatorOperation.Divide => "÷",
            _ => "?"
        };
    }

    private static string Format(decimal value)
    {
        var rounded = Math.Round(value, 12, MidpointRounding.AwayFromZero);
        return rounded.ToString("0.############", CultureInfo.InvariantCulture);
    }

    private sealed record CalculatorHistoryEntry(CalculatorHistoryItem Item, CalculatorInternalState State);

    private sealed record CalculatorInternalState(
        string Display,
        bool HasError,
        decimal? Accumulator,
        CalculatorOperation? PendingOperation,
        bool IsEnteringNewValue,
        decimal? LastOperand,
        CalculatorOperation? LastOperation,
        bool JustEvaluated,
        string? CompletedExpressionDisplay,
        IReadOnlyList<CalculatorExpressionPart> ExpressionParts);

    private readonly record struct CalculatorExpressionPart(
        decimal? Number,
        CalculatorOperation? Operation)
    {
        public bool IsNumber => Number is not null;

        public bool IsOperation => Operation is not null;

        public static CalculatorExpressionPart FromNumber(decimal value)
        {
            return new CalculatorExpressionPart(value, null);
        }

        public static CalculatorExpressionPart FromOperation(CalculatorOperation operation)
        {
            return new CalculatorExpressionPart(null, operation);
        }
    }
}

internal enum CalculatorOperation
{
    Add,
    Subtract,
    Multiply,
    Divide
}

internal sealed record CalculatorSnapshot(
    string Display,
    string ExpressionDisplay,
    bool HasError,
    bool CanCopy,
    IReadOnlyList<CalculatorHistoryItem> History);

internal sealed record CalculatorHistoryItem(string Id, string Expression, string Result);
