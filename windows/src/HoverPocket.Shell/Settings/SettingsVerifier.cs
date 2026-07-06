using System.Text.Json;
using HoverPocket.Shell.Bridge;
using HoverPocket.Shell.Configuration;
using HoverPocket.Shell.Providers;
using HoverPocket.Shell.Verification;

namespace HoverPocket.Shell.Settings;

internal sealed class SettingsVerifier
{
    private readonly List<string> _failures = [];

    public int Run()
    {
        VerifyAsync().GetAwaiter().GetResult();
        if (_failures.Count == 0)
        {
            VerifyConsole.WriteLine("PASS settings verify: settings read/write, defaults, HKCU Run dry-run registration, update auto-check");
            return 0;
        }

        VerifyConsole.WriteLine("FAIL settings verify:");
        foreach (var failure in _failures)
        {
            VerifyConsole.WriteLine($"- {failure}");
        }

        return 1;
    }

    private async Task VerifyAsync()
    {
        var registry = ProviderRegistry.CreateDefault();
        var store = UserSettingsStore.CreateTemporary("SettingsVerify");
        var startup = new InMemoryStartupRegistrationService();
        var controller = new PanelBridgeController(registry, store, store.Load(registry.ProviderIds), startup);
        var dispatcher = new BridgeDispatcher();
        using var _ = controller.Attach(dispatcher);

        VerifyDefaults(store, registry, startup);

        await Send(dispatcher, """{"id":"1","method":"settings.setLanguage","params":{"language":"en"}}""");
        await Send(dispatcher, """{"id":"2","method":"settings.setTextSize","params":{"textSize":"large"}}""");
        await Send(dispatcher, """{"id":"3","method":"settings.setPanelSize","params":{"panelSize":"small"}}""");
        await Send(dispatcher, """{"id":"4","method":"settings.setSwitchingMode","params":{"switchingMode":"hover"}}""");
        await Send(dispatcher, """{"id":"5","method":"settings.setProviderVisibility","params":{"id":"timer","visible":false}}""");
        await Send(dispatcher, """{"id":"6","method":"settings.setProviderOrder","params":{"providerOrder":["sticky","calculator","timer"]}}""");
        await Send(dispatcher, """{"id":"7","method":"settings.setStartWithWindows","params":{"enabled":true}}""");
        await Send(dispatcher, """{"id":"7u","method":"settings.setAutoCheckForUpdates","params":{"enabled":false}}""");
        await Send(dispatcher, """{"id":"7s","method":"sticky.setUndoToastVisible","params":{"visible":false}}""");

        var written = store.ReloadOrDefault(registry.ProviderIds);
        if (written.Language != AppLanguage.English
            || written.TextSize != PanelTextSize.Large
            || written.PanelSize != PanelSize.Small
            || written.SwitchingMode != ProviderSwitchingMode.Hover
            || !written.StartWithWindows
            || written.AutoCheckForUpdates)
        {
            _failures.Add("settings write/read did not preserve scalar values");
        }

        if (!HasExpectedOrderPrefix(written.ProviderOrder, ["sticky", "calculator", "timer"])
            || written.ProviderOrder.Count != registry.ProviderIds.Count)
        {
            _failures.Add("settings write/read did not preserve provider order");
        }

        if (!written.ProviderVisibility.TryGetValue("timer", out var timerVisible) || timerVisible)
        {
            _failures.Add("settings write/read did not preserve provider visibility");
        }

        if (!startup.IsRegistered())
        {
            _failures.Add("start with Windows dry-run registration did not register");
        }

        var stickyHidden = await Send(dispatcher, """{"id":"7g","method":"sticky.getState"}""");
        if (!stickyHidden.Contains("\"showUndoToast\":false", StringComparison.Ordinal))
        {
            _failures.Add("sticky undo toast visibility was not disabled through settings bridge");
        }

        await Send(dispatcher, """{"id":"7t","method":"sticky.setUndoToastVisible","params":{"visible":true}}""");
        var stickyVisible = await Send(dispatcher, """{"id":"7h","method":"sticky.getState"}""");
        if (!stickyVisible.Contains("\"showUndoToast\":true", StringComparison.Ordinal))
        {
            _failures.Add("sticky undo toast visibility was not enabled through settings bridge");
        }

        await Send(dispatcher, """{"id":"8","method":"settings.setStartWithWindows","params":{"enabled":false}}""");
        if (startup.IsRegistered())
        {
            _failures.Add("start with Windows dry-run registration did not unregister");
        }

        await Send(dispatcher, """{"id":"9","method":"settings.resetDefaults"}""");
        VerifyDefaults(store, registry, startup);
    }

    private void VerifyDefaults(UserSettingsStore store, ProviderRegistry registry, InMemoryStartupRegistrationService startup)
    {
        var defaults = store.ReloadOrDefault(registry.ProviderIds);
        if (defaults.Language != AppLanguage.Japanese
            || defaults.TextSize != PanelTextSize.Medium
            || defaults.PanelSize != PanelSize.Medium
            || defaults.SwitchingMode != ProviderSwitchingMode.Click
            || defaults.StartWithWindows
            || !defaults.AutoCheckForUpdates)
        {
            _failures.Add("defaults were not restored");
        }

        if (startup.IsRegistered())
        {
            _failures.Add("default startup registration was not off");
        }
    }

    private static async Task<string> Send(BridgeDispatcher dispatcher, string request)
    {
        var response = await dispatcher.ProcessRawMessageAsync(request);
        if (string.IsNullOrWhiteSpace(response))
        {
            throw new InvalidOperationException("Bridge did not return a response.");
        }

        using var document = JsonDocument.Parse(response);
        if (document.RootElement.TryGetProperty("error", out var error)
            && error.ValueKind != JsonValueKind.Null)
        {
            throw new InvalidOperationException(error.GetRawText());
        }

        return response;
    }

    private static bool HasExpectedOrderPrefix(IReadOnlyList<string> actual, IReadOnlyList<string> expectedPrefix)
    {
        return actual.Count >= expectedPrefix.Count
            && actual.Take(expectedPrefix.Count).SequenceEqual(expectedPrefix, StringComparer.OrdinalIgnoreCase);
    }
}
