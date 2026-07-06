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
    private readonly List<CalculatorHistoryEntry> _history = [];

    public string Display { get; private set; } = "0";

    public bool HasError { get; private set; }

    public CalculatorSnapshot Snapshot => new(
        Display,
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
        _isEnteringNewValue = false;
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

    public void Reset()
    {
        Display = "0";
        HasError = false;
        _accumulator = null;
        _pendingOperation = null;
        _isEnteringNewValue = true;
        _lastOperand = null;
        _lastOperation = null;
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

        CalculatorOperation? historyOperation = null;
        decimal historyLhs = 0m;
        decimal historyRhs = 0m;
        decimal historyResult = 0m;
        if (_pendingOperation is not null && _accumulator is not null && !_isEnteringNewValue)
        {
            var lhs = _accumulator.Value;
            var operationToRecord = _pendingOperation.Value;
            if (!TryCalculate(lhs, current, operationToRecord, out var result))
            {
                ShowError();
                return;
            }

            _accumulator = result;
            Display = Format(result);
            historyOperation = operationToRecord;
            historyLhs = lhs;
            historyRhs = current;
            historyResult = result;
        }
        else
        {
            _accumulator = current;
        }

        _pendingOperation = operation;
        _lastOperand = null;
        _lastOperation = null;
        _isEnteringNewValue = true;
        if (historyOperation is not null)
        {
            AddHistory(historyOperation.Value, historyLhs, historyRhs, historyResult);
        }
    }

    private void InputEquals()
    {
        RecoverFromErrorIfNeeded();
        if (!TryCurrentDecimal(out var current))
        {
            return;
        }

        CalculatorOperation? operation = null;
        decimal rhs = current;
        decimal? lhs = null;
        if (_pendingOperation is not null && _accumulator is not null)
        {
            operation = _pendingOperation;
            lhs = _accumulator.Value;
            rhs = current;
        }
        else if (_lastOperation is not null && _lastOperand is not null)
        {
            operation = _lastOperation;
            rhs = _lastOperand.Value;
            lhs = current;
            _accumulator = current;
        }
        else
        {
            _isEnteringNewValue = true;
            return;
        }

        if (operation is null || _accumulator is null)
        {
            return;
        }

        lhs ??= _accumulator.Value;
        if (!TryCalculate(_accumulator.Value, rhs, operation.Value, out var result))
        {
            ShowError();
            return;
        }

        Display = Format(result);
        _accumulator = result;
        _pendingOperation = null;
        _lastOperation = operation;
        _lastOperand = rhs;
        _isEnteringNewValue = true;
        AddHistory(operation.Value, lhs.Value, rhs, result);
    }

    private void Backspace()
    {
        RecoverFromErrorIfNeeded();
        if (_isEnteringNewValue)
        {
            Display = "0";
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

        var result = current / 100m;
        Display = Format(result);
        _isEnteringNewValue = false;
    }

    private bool TryCurrentDecimal(out decimal current)
    {
        return decimal.TryParse(Display, NumberStyles.Number, CultureInfo.InvariantCulture, out current);
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
    }

    private CalculatorHistoryEntry? FindHistoryEntry(string historyId)
    {
        return _history.FirstOrDefault(entry =>
            string.Equals(entry.Item.Id, historyId, StringComparison.Ordinal));
    }

    private void AddHistory(CalculatorOperation operation, decimal lhs, decimal rhs, decimal result)
    {
        var item = new CalculatorHistoryItem(
            Guid.NewGuid().ToString("N"),
            $"{Format(lhs)} {OperationSymbol(operation)} {Format(rhs)}",
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
            _lastOperation);
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
    }

    private void RecoverFromErrorIfNeeded()
    {
        if (HasError)
        {
            Reset();
        }
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
            "×" or "x" or "X" => "*",
            "−" => "-",
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
        CalculatorOperation? LastOperation);
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
    bool HasError,
    bool CanCopy,
    IReadOnlyList<CalculatorHistoryItem> History);

internal sealed record CalculatorHistoryItem(string Id, string Expression, string Result);
