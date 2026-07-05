using System.Globalization;

namespace HoverPocket.Shell.Providers.Calculator;

internal sealed class CalculatorEngine
{
    private decimal? _accumulator;
    private CalculatorOperation? _pendingOperation;
    private bool _isEnteringNewValue = true;
    private decimal? _lastOperand;
    private CalculatorOperation? _lastOperation;

    public string Display { get; private set; } = "0";

    public bool HasError { get; private set; }

    public CalculatorSnapshot Snapshot => new(Display, HasError, !HasError);

    public CalculatorSnapshot PressToken(string token)
    {
        switch (NormalizeToken(token))
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
                InputDigit(token[0] - '0');
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

        if (_pendingOperation is not null && _accumulator is not null && !_isEnteringNewValue)
        {
            if (!TryCalculate(_accumulator.Value, current, _pendingOperation.Value, out var result))
            {
                ShowError();
                return;
            }

            _accumulator = result;
            Display = Format(result);
        }
        else
        {
            _accumulator = current;
        }

        _pendingOperation = operation;
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

        CalculatorOperation? operation = null;
        decimal rhs = current;
        if (_pendingOperation is not null && _accumulator is not null)
        {
            operation = _pendingOperation;
            rhs = current;
        }
        else if (_lastOperation is not null && _lastOperand is not null)
        {
            operation = _lastOperation;
            rhs = _lastOperand.Value;
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

    private void RecoverFromErrorIfNeeded()
    {
        if (HasError)
        {
            Reset();
        }
    }

    private static string NormalizeToken(string token)
    {
        return token.Trim() switch
        {
            "÷" => "/",
            "×" or "x" or "X" => "*",
            "−" => "-",
            "\r" or "\n" or "Enter" => "=",
            "Escape" or "Esc" or "C" => "AC",
            "Backspace" => "BS",
            "±" => "+/-",
            var normalized => normalized
        };
    }

    private static string Format(decimal value)
    {
        var rounded = Math.Round(value, 12, MidpointRounding.AwayFromZero);
        return rounded.ToString("0.############", CultureInfo.InvariantCulture);
    }
}

internal enum CalculatorOperation
{
    Add,
    Subtract,
    Multiply,
    Divide
}

internal sealed record CalculatorSnapshot(string Display, bool HasError, bool CanCopy);
