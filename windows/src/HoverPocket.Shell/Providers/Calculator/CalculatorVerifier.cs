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
        Verify("decimal", ["0", ".", "1", "+", "0", ".", "2", "="], "0.3");
        Verify("percent", ["2", "0", "%"], "0.2");
        Verify("sign", ["1", "2", ".", "5", "+/-"], "-12.5");
        Verify("zero division", ["7", "/", "0", "="], "Error");
        VerifyCopyDisabledOnError();
        Verify("error recovery", ["7", "/", "0", "=", "9"], "9");
        Verify("backspace", ["1", "2", "BS"], "1");
        Verify("all clear", ["1", "2", "3", "AC"], "0");

        if (_failures.Count == 0)
        {
            VerifyConsole.WriteLine("PASS calc verify: arithmetic, decimal, percent, sign, error, recovery, backspace, AC");
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
}
