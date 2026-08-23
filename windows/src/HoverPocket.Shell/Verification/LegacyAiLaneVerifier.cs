using System.Text.Json;
using HoverPocket.Shell.Bridge;
using HoverPocket.Shell.Configuration;
using HoverPocket.Shell.Providers;

namespace HoverPocket.Shell.Verification;

internal sealed class LegacyAiLaneVerifier
{
    private readonly List<string> _failures = [];

    public int Run()
    {
        VerifyAsync().GetAwaiter().GetResult();

        if (_failures.Count == 0)
        {
            VerifyConsole.WriteLine("PASS ailane verify: legacy AI command state and bridge routes are absent");
            return 0;
        }

        VerifyConsole.WriteLine("FAIL ailane verify:");
        foreach (var failure in _failures)
        {
            VerifyConsole.WriteLine($"- {failure}");
        }
        return 1;
    }

    private async Task VerifyAsync()
    {
        var registry = ProviderRegistry.CreateDefault();
        var store = UserSettingsStore.CreateTemporary("LegacyAiLaneVerify");
        using var controller = new PanelBridgeController(registry, store, store.Load(registry.ProviderIds));
        var dispatcher = new BridgeDispatcher();
        using var attachment = controller.Attach(dispatcher);

        var state = await dispatcher.ProcessRawMessageAsync(
            """{"id":"state","method":"app.getState"}""");
        using (var stateDocument = JsonDocument.Parse(state ?? "null"))
        {
            if (!stateDocument.RootElement.TryGetProperty("result", out var result)
                || result.ValueKind != JsonValueKind.Object)
            {
                _failures.Add("app.getState did not return an object");
            }
            else if (result.TryGetProperty("aiLane", out _))
            {
                _failures.Add("legacy aiLane state is still exposed");
            }
        }

        foreach (var method in new[] { "ailane.submit", "ailane.approve", "ailane.reject" })
        {
            var response = await dispatcher.ProcessRawMessageAsync(
                JsonSerializer.Serialize(new { id = method, method, @params = new { } }));
            using var document = JsonDocument.Parse(response ?? "null");
            if (!document.RootElement.TryGetProperty("error", out var error)
                || error.ValueKind != JsonValueKind.Object
                || !error.TryGetProperty("code", out var code)
                || !string.Equals(code.GetString(), "unknown_method", StringComparison.Ordinal))
            {
                _failures.Add($"{method} was not rejected as unknown_method");
            }
        }

        if (registry.ProviderIds.Any(id =>
                string.Equals(id, "ai", StringComparison.OrdinalIgnoreCase)
                || string.Equals(id, "ailane", StringComparison.OrdinalIgnoreCase)))
        {
            _failures.Add("legacy AI command provider remains registered");
        }
    }
}
