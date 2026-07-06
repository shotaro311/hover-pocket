using HoverPocket.Shell.Verification;

namespace HoverPocket.Shell.Providers.Calculator;

internal sealed class CalculatorVerifier
{
    private readonly List<string> _failures = [];

    public int Run()
    {
        Verify("add", ["1", "+", "2", "="], "3");
        Verify("subtract", ["7", "-", "5", "="], "2");
        Verify("multiply", ["6", "*", "7", "="], "42");
        Verify("divide", ["8", "/", "4", "="], "2");
        Verify("operator glyphs", ["8", "÷", "4", "Enter"], "2");
        Verify("numpad tokens", ["Numpad9", "NumpadAdd", "Numpad3", "NumpadEnter"], "12");
        Verify("JIS keyboard operators", ["5", ";", "6", ":", "2", "="], "17");
        Verify("continuous expression precedence", ["6", "+", "5", "+", "9", "/", "2", "+", "3", "-", "5", "="], "13.5");
        Verify("decimal", ["0", ".", "1", "+", "0", ".", "2", "="], "0.3");
        Verify("percent", ["2", "0", "%"], "0.2");
        Verify("sign", ["1", "2", ".", "5", "+/-"], "-12.5");
        Verify("zero division", ["7", "/", "0", "="], "Error");
        VerifyCopyDisabledOnError();
        Verify("error recovery", ["7", "/", "0", "=", "9"], "9");
        Verify("backspace", ["1", "2", "BS"], "1");
        Verify("all clear", ["1", "2", "3", "AC"], "0");
        VerifyExpressionDisplay();
        VerifyHistoryValueInput();
        VerifyHistoryRestore();
        VerifyHistoryClear();

        if (_failures.Count == 0)
        {
            VerifyConsole.WriteLine("PASS calc verify: arithmetic, precedence, JIS keyboard tokens, expression display, history value input, restore, clear, error, recovery, backspace, AC");
            return 0;
        }

        VerifyConsole.WriteLine("FAIL calc verify:");
        foreach (var failure in _failures)
        {
            VerifyConsole.WriteLine($"- {failure}");
        }

        return 1;
    }

    private void Verify(string label, IReadOnlyList<string> inputs, string expected)
    {
        var engine = new CalculatorEngine();
        CalculatorSnapshot snapshot = engine.Snapshot;
        foreach (var input in inputs)
        {
            snapshot = engine.PressToken(input);
        }

        if (!string.Equals(snapshot.Display, expected, StringComparison.Ordinal))
        {
            _failures.Add($"{label}: expected {expected}, got {snapshot.Display}");
        }
    }

    private void VerifyCopyDisabledOnError()
    {
        var engine = new CalculatorEngine();
        CalculatorSnapshot snapshot = engine.Snapshot;
        foreach (var input in new[] { "7", "/", "0", "=" })
        {
            snapshot = engine.PressToken(input);
        }

        if (snapshot.CanCopy || !snapshot.HasError)
        {
            _failures.Add("copy disabled: Error state allowed copy");
        }
    }

    private void VerifyHistoryValueInput()
    {
        var engine = new CalculatorEngine();
        var snapshot = PressAll(engine, ["6", "*", "7", "="]);
        var historyItem = snapshot.History.LastOrDefault();
        if (historyItem is null || historyItem.Result != "42")
        {
            _failures.Add("history value: expected 42 in history");
            return;
        }

        snapshot = engine.UseHistoryValue(historyItem.Id);
        if (snapshot.Display != "42" || snapshot.History.Count == 0)
        {
            _failures.Add($"history value: expected display 42 with history preserved, got {snapshot.Display}");
        }
    }

    private void VerifyHistoryRestore()
    {
        var engine = new CalculatorEngine();
        var snapshot = PressAll(engine, ["1", "+", "2", "="]);
        var historyItem = snapshot.History.LastOrDefault();
        if (historyItem is null || historyItem.Result != "3")
        {
            _failures.Add("history restore: expected result 3 in history");
            return;
        }

        snapshot = PressAll(engine, ["9", "+", "1", "="]);
        if (snapshot.Display != "10")
        {
            _failures.Add($"history restore setup: expected 10 before restore, got {snapshot.Display}");
            return;
        }

        snapshot = engine.RestoreHistory(historyItem.Id);
        if (snapshot.Display != "3" || snapshot.ExpressionDisplay != "1 + 2")
        {
            _failures.Add($"history restore: expected restored display 3 with expression 1 + 2, got {snapshot.Display} / {snapshot.ExpressionDisplay}");
            return;
        }

        snapshot = PressAll(engine, ["+", "4", "="]);
        if (snapshot.Display != "7")
        {
            _failures.Add($"history restore: expected restored result to continue with +4 and produce 7, got {snapshot.Display}");
        }
    }

    private void VerifyHistoryClear()
    {
        var engine = new CalculatorEngine();
        var snapshot = PressAll(engine, ["1", "+", "2", "="]);
        if (snapshot.History.Count == 0)
        {
            _failures.Add("history clear setup: expected at least one history entry");
            return;
        }

        snapshot = engine.ClearHistory();
        if (snapshot.History.Count != 0 || snapshot.Display != "3")
        {
            _failures.Add($"history clear: expected empty history with display preserved at 3, got {snapshot.History.Count} / {snapshot.Display}");
        }
    }

    private void VerifyExpressionDisplay()
    {
        var engine = new CalculatorEngine();
        var snapshot = PressAll(engine, ["5", "+"]);
        if (snapshot.ExpressionDisplay != "5 +")
        {
            _failures.Add($"expression display: expected '5 +', got '{snapshot.ExpressionDisplay}'");
            return;
        }

        snapshot = PressAll(engine, ["6"]);
        if (snapshot.ExpressionDisplay != "5 + 6")
        {
            _failures.Add($"expression display: expected '5 + 6', got '{snapshot.ExpressionDisplay}'");
        }
    }

    private static CalculatorSnapshot PressAll(CalculatorEngine engine, IReadOnlyList<string> inputs)
    {
        CalculatorSnapshot snapshot = engine.Snapshot;
        foreach (var input in inputs)
        {
            snapshot = engine.PressToken(input);
        }

        return snapshot;
    }
}
