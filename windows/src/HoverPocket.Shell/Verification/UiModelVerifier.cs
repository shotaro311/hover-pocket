using System.IO;
using System.Text.Json;
using HoverPocket.Shell.Bridge;
using HoverPocket.Shell.Configuration;
using HoverPocket.Shell.Providers;

namespace HoverPocket.Shell.Verification;

internal sealed class UiModelVerifier
{
    private readonly List<string> _failures = [];

    public int Run()
    {
        var registry = ProviderRegistry.CreateDefault();
        var store = UserSettingsStore.CreateTemporary("UiModelVerify");

        VerifySettingsRoundTrip(registry, store);
        VerifyCorruptSettingsFallback(registry, store);
        VerifyBridgeDispatch(registry, store).GetAwaiter().GetResult();

        if (_failures.Count == 0)
        {
            VerifyConsole.WriteLine("PASS ui-model verify: settings, provider registry, bridge dispatcher");
            VerifyConsole.WriteLine($"settings_path={store.SettingsPath}");
            return 0;
        }

        VerifyConsole.WriteLine("FAIL ui-model verify:");
        foreach (var failure in _failures)
        {
            VerifyConsole.WriteLine($"- {failure}");
        }

        return 1;
    }

    private void VerifySettingsRoundTrip(ProviderRegistry registry, UserSettingsStore store)
    {
        var settings = store.Load(registry.ProviderIds);
        settings.PanelSize = PanelSize.Large;
        settings.TextSize = PanelTextSize.Large;
        settings.SwitchingMode = ProviderSwitchingMode.Hover;
        settings.Language = AppLanguage.English;
        settings.ProviderOrder = ["sticky", "calculator", "timer"];
        settings.ProviderVisibility["timer"] = false;
        store.Save(settings);

        var reloaded = store.ReloadOrDefault(registry.ProviderIds);
        if (reloaded.PanelSize != PanelSize.Large
            || reloaded.TextSize != PanelTextSize.Large
            || reloaded.SwitchingMode != ProviderSwitchingMode.Hover
            || reloaded.Language != AppLanguage.English)
        {
            _failures.Add("settings round-trip: scalar values were not preserved");
        }

        if (!reloaded.ProviderOrder.SequenceEqual(["sticky", "calculator", "timer"]))
        {
            _failures.Add("settings round-trip: provider order was not preserved");
        }

        if (!reloaded.ProviderVisibility.TryGetValue("timer", out var timerVisible) || timerVisible)
        {
            _failures.Add("settings round-trip: provider visibility was not preserved");
        }
    }

    private void VerifyCorruptSettingsFallback(ProviderRegistry registry, UserSettingsStore store)
    {
        File.WriteAllText(store.SettingsPath, "{ not valid json");
        var settings = store.Load(registry.ProviderIds);
        if (settings.PanelSize != PanelSize.Medium
            || settings.ProviderOrder.Count != registry.ProviderIds.Count
            || settings.ProviderVisibility.Values.Any(visible => !visible))
        {
            _failures.Add("settings corrupt fallback: defaults were not restored");
        }
    }

    private async Task VerifyBridgeDispatch(ProviderRegistry registry, UserSettingsStore store)
    {
        var settings = store.Load(registry.ProviderIds);
        using var controller = new PanelBridgeController(registry, store, settings);
        var postedEvents = new List<string>();
        var dispatcher = new BridgeDispatcher(json =>
        {
            postedEvents.Add(json);
            return Task.CompletedTask;
        });
        controller.Attach(dispatcher);

        var echoResponse = await dispatcher.ProcessRawMessageAsync(
            """{"id":"1","method":"diagnostics.echo","params":{"value":"model-round-trip"}}""");
        if (!ResponseContains(echoResponse, "model-round-trip"))
        {
            _failures.Add("bridge dispatcher: diagnostics.echo did not round-trip params");
        }

        var selectResponse = await dispatcher.ProcessRawMessageAsync(
            """{"id":"2","method":"provider.select","params":{"id":"timer"}}""");
        if (!ResponseContains(selectResponse, "\"id\":\"timer\""))
        {
            _failures.Add("bridge dispatcher: provider.select did not return selected provider");
        }

        if (!postedEvents.Any(message => message.Contains("state.changed", StringComparison.Ordinal)))
        {
            _failures.Add("bridge dispatcher: provider.select did not emit state.changed event");
        }

        var sizeResponse = await dispatcher.ProcessRawMessageAsync(
            """{"id":"3","method":"settings.setPanelSize","params":{"panelSize":"small"}}""");
        var reloaded = store.Load(registry.ProviderIds);
        if (reloaded.PanelSize != PanelSize.Small || !ResponseContains(sizeResponse, "\"panelSize\":\"small\""))
        {
            _failures.Add("bridge dispatcher: settings.setPanelSize did not persist small size");
        }

        var calculatorResponse = await dispatcher.ProcessRawMessageAsync(
            """{"id":"4","method":"calculator.press","params":{"input":"7"}}""");
        if (!ResponseContains(calculatorResponse, "\"display\":\"7\""))
        {
            _failures.Add("bridge dispatcher: calculator.press did not return calculator state");
        }

        var timerResponse = await dispatcher.ProcessRawMessageAsync(
            """{"id":"5","method":"timer.getState"}""");
        if (!ResponseContains(timerResponse, "\"draftTimer\""))
        {
            _failures.Add("bridge dispatcher: timer.getState did not return timer state");
        }
    }

    private static bool ResponseContains(string? response, string expected)
    {
        if (string.IsNullOrWhiteSpace(response))
        {
            return false;
        }

        using var _ = JsonDocument.Parse(response);
        return response.Contains(expected, StringComparison.Ordinal);
    }
}
