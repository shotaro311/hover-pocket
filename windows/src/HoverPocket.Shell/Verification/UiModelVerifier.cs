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
        settings.DisplayPlacement = DisplayPlacement.All;
        settings.TextSize = PanelTextSize.Large;
        settings.SwitchingMode = ProviderSwitchingMode.Hover;
        settings.Language = AppLanguage.English;
        settings.AutoCheckForUpdates = false;
        settings.ClipboardPrivateMode = true;
        settings.RememberLastSelectedProvider = false;
        settings.PreferredProviderId = "sticky";
        settings.HandleIconStyle = HandleIconStyle.C;
        settings.ShowTopHandleSideArea = false;
        settings.DisableTopEdgeInFullscreen = false;
        settings.ProviderOrder = ["sticky", "calculator", "timer"];
        settings.ProviderVisibility["timer"] = false;
        store.Save(settings);

        var reloaded = store.ReloadOrDefault(registry.ProviderIds);
        if (reloaded.PanelSize != PanelSize.Large
            || reloaded.DisplayPlacement != DisplayPlacement.All
            || reloaded.TextSize != PanelTextSize.Large
            || reloaded.SwitchingMode != ProviderSwitchingMode.Hover
            || reloaded.Language != AppLanguage.English
            || reloaded.AutoCheckForUpdates
            || !reloaded.ClipboardPrivateMode
            || reloaded.RememberLastSelectedProvider
            || reloaded.PreferredProviderId != "sticky"
            || reloaded.HandleIconStyle != HandleIconStyle.C
            || reloaded.ShowTopHandleSideArea
            || reloaded.DisableTopEdgeInFullscreen)
        {
            _failures.Add("settings round-trip: scalar values were not preserved");
        }

        if (!HasExpectedOrderPrefix(reloaded.ProviderOrder, ["controls", "sticky", "calculator", "timer"])
            || reloaded.ProviderOrder.Count != registry.ProviderIds.Count)
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
            || settings.ProviderVisibility.Values.Any(visible => !visible)
            || !settings.AutoCheckForUpdates)
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
        if (!ResponseContains(timerResponse, "\"draftStopwatch\"") || !ResponseContains(timerResponse, "\"runningStopwatches\""))
        {
            _failures.Add("bridge dispatcher: timer.getState did not return timer state");
        }

        var stopwatchStartResponse = await dispatcher.ProcessRawMessageAsync(
            """{"id":"5a","method":"timer.startStopwatch","params":{"preset":{"title":"Verify","color":"pink"}}}""");
        if (!ResponseContains(stopwatchStartResponse, "\"runningStopwatches\":[{")
            || !ResponseContains(stopwatchStartResponse, "\"title\":\"Verify\""))
        {
            _failures.Add("bridge dispatcher: timer.startStopwatch did not start the stopwatch");
        }

        using var stopwatchDocument = JsonDocument.Parse(stopwatchStartResponse!);
        var stopwatchId = stopwatchDocument.RootElement
            .GetProperty("result")
            .GetProperty("runningStopwatches")[0]
            .GetProperty("id")
            .GetString();
        var stopwatchStopResponse = await dispatcher.ProcessRawMessageAsync(
            "{\"id\":\"5b\",\"method\":\"timer.stopStopwatch\",\"params\":{\"id\":\""
                + stopwatchId
                + "\"}}");
        if (!ResponseContains(stopwatchStopResponse, "\"runningStopwatches\":[]"))
        {
            _failures.Add("bridge dispatcher: timer.stopStopwatch did not stop the selected stopwatch");
        }

        var clipboardResponse = await dispatcher.ProcessRawMessageAsync(
            """{"id":"6","method":"clipboard.getState"}""");
        if (!ResponseContains(clipboardResponse, "\"textItems\""))
        {
            _failures.Add("bridge dispatcher: clipboard.getState did not return clipboard state");
        }

        var clipboardPrivateResponse = await dispatcher.ProcessRawMessageAsync(
            """{"id":"7","method":"settings.setClipboardPrivateMode","params":{"enabled":true}}""");
        if (!ResponseContains(clipboardPrivateResponse, "\"clipboardPrivateMode\":true"))
        {
            _failures.Add("bridge dispatcher: clipboard private mode did not persist");
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

    private static bool HasExpectedOrderPrefix(IReadOnlyList<string> actual, IReadOnlyList<string> expectedPrefix)
    {
        return actual.Count >= expectedPrefix.Count
            && actual.Take(expectedPrefix.Count).SequenceEqual(expectedPrefix, StringComparer.OrdinalIgnoreCase);
    }
}
