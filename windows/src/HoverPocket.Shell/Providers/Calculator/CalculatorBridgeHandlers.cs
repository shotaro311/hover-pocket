using System.Text.Json;
using System.Windows;
using HoverPocket.Shell.Bridge;

namespace HoverPocket.Shell.Providers.Calculator;

internal sealed class CalculatorBridgeHandlers
{
    private readonly CalculatorEngine _engine = new();

    public void Register(BridgeDispatcher dispatcher)
    {
        dispatcher.Register("calculator.getState", (_, _) => Task.FromResult<object?>(_engine.Snapshot));
        dispatcher.Register("calculator.press", PressAsync);
        dispatcher.Register("calculator.useHistoryValue", UseHistoryValueAsync);
        dispatcher.Register("calculator.restoreHistory", RestoreHistoryAsync);
        dispatcher.Register("calculator.copy", CopyAsync);
    }

    private Task<object?> PressAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var input = ReadRequiredString(parameters, "input");
        return Task.FromResult<object?>(_engine.PressToken(input));
    }

    private Task<object?> UseHistoryValueAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var id = ReadRequiredString(parameters, "id");
        return Task.FromResult<object?>(_engine.UseHistoryValue(id));
    }

    private Task<object?> RestoreHistoryAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var id = ReadRequiredString(parameters, "id");
        return Task.FromResult<object?>(_engine.RestoreHistory(id));
    }

    private Task<object?> CopyAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        _ = parameters;
        cancellationToken.ThrowIfCancellationRequested();
        if (_engine.HasError)
        {
            return Task.FromResult<object?>(new { copied = false, _engine.Display });
        }

        System.Windows.Clipboard.SetText(_engine.Display);
        return Task.FromResult<object?>(new { copied = true, _engine.Display });
    }

    private static string ReadRequiredString(JsonElement? parameters, string propertyName)
    {
        if (parameters is null
            || !parameters.Value.TryGetProperty(propertyName, out var property)
            || property.ValueKind != JsonValueKind.String)
        {
            throw new InvalidOperationException($"Missing string parameter: {propertyName}");
        }

        return property.GetString() ?? string.Empty;
    }
}
