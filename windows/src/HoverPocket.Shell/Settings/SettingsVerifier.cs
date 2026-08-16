using System.Text.Json;
using HoverPocket.Shell.Bridge;
using HoverPocket.Shell.Configuration;
using HoverPocket.Shell.Providers;
using HoverPocket.Shell.Verification;
using HoverPocket.Shell.Windows;

namespace HoverPocket.Shell.Settings;

internal sealed class SettingsVerifier
{
    private readonly List<string> _failures = [];

    public async Task<int> RunAsync()
    {
        try
        {
            await VerifyAsync();
        }
        catch (Exception ex)
        {
            _failures.Add($"unexpected exception: {ex.GetType().Name}: {ex.Message}");
        }

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
        using var controller = new PanelBridgeController(registry, store, store.Load(registry.ProviderIds), startup);
        var dispatcher = new BridgeDispatcher();
        using var _ = controller.Attach(
            dispatcher,
            BridgeSurface.Settings,
            aiNativeEnableDecision: () => true);
        var deniedSettingsDispatcher = new BridgeDispatcher();
        using var deniedSettingsAttachment = controller.Attach(
            deniedSettingsDispatcher,
            BridgeSurface.Settings,
            aiNativeEnableDecision: () => false);
        var panelDispatcher = new BridgeDispatcher();
        using var panelAttachment = controller.Attach(panelDispatcher, BridgeSurface.Panel);

        VerifyDefaults(store, registry, startup);
        VerifyWebViewSecurityPolicy();
        var defaultState = await Send(dispatcher, """{"id":"0","method":"app.getState"}""");
        if (!defaultState.Contains("\"aiNativeEnabled\":false", StringComparison.Ordinal)
            || !defaultState.Contains("\"pocketAppGeneration\":null", StringComparison.Ordinal)
            || Directory.Exists(Path.Combine(store.RootDirectory, "PocketApps", "Generation")))
        {
            _failures.Add("AI-native default-off started generation runtime or workspace");
        }
        var panelEnable = await panelDispatcher.ProcessRawMessageAsync(
            """{"id":"0p","method":"settings.setAiNativeEnabled","params":{"enabled":true}}""");
        if (panelEnable?.Contains("\"code\":\"unknown_method\"", StringComparison.Ordinal) != true)
        {
            _failures.Add("panel bridge exposed the Settings-only AI-native toggle");
        }
        var deniedEnable = await Send(
            deniedSettingsDispatcher,
            """{"id":"0d","method":"settings.setAiNativeEnabled","params":{"enabled":true}}""");
        if (!deniedEnable.Contains("\"aiNativeEnabled\":false", StringComparison.Ordinal)
            || store.ReloadOrDefault(registry.ProviderIds).AiNativeEnabled)
        {
            _failures.Add("native default-No AI-native approval was bypassed");
        }

        await Send(dispatcher, """{"id":"1","method":"settings.setLanguage","params":{"language":"en"}}""");
        await Send(dispatcher, """{"id":"2","method":"settings.setTextSize","params":{"textSize":"large"}}""");
        await Send(dispatcher, """{"id":"3","method":"settings.setPanelSize","params":{"panelSize":"small"}}""");
        await Send(dispatcher, """{"id":"4","method":"settings.setSwitchingMode","params":{"switchingMode":"hover"}}""");
        await Send(dispatcher, """{"id":"5","method":"settings.setProviderVisibility","params":{"id":"timer","visible":false}}""");
        await Send(dispatcher, """{"id":"6","method":"settings.setProviderOrder","params":{"providerOrder":["sticky","calculator","timer"]}}""");
        await Send(dispatcher, """{"id":"7","method":"settings.setStartWithWindows","params":{"enabled":true}}""");
        await Send(dispatcher, """{"id":"7u","method":"settings.setAutoCheckForUpdates","params":{"enabled":false}}""");
        var aiEnabledState = await Send(dispatcher, """{"id":"7n","method":"settings.setAiNativeEnabled","params":{"enabled":true}}""");
        if (!aiEnabledState.Contains("\"aiNativeEnabled\":true", StringComparison.Ordinal)
            || !aiEnabledState.Contains("\"pocketAppGeneration\":null", StringComparison.Ordinal)
            || Directory.Exists(Path.Combine(store.RootDirectory, "PocketApps", "Generation")))
        {
            _failures.Add("AI-native enable setting hot-started generation runtime or workspace");
        }
        await Send(dispatcher, """{"id":"7s","method":"sticky.setUndoToastVisible","params":{"visible":false}}""");
        await Send(dispatcher, """{"id":"7d","method":"settings.setDisplayPlacement","params":{"displayPlacement":"all"}}""");
        await Send(dispatcher, """{"id":"7p","method":"settings.setProviderSelection","params":{"rememberLast":false}}""");
        await Send(dispatcher, """{"id":"7f","method":"settings.setPreferredProvider","params":{"id":"sticky"}}""");
        await Send(dispatcher, """{"id":"7i","method":"settings.setHandleIcon","params":{"handleIcon":"c"}}""");
        await Send(dispatcher, """{"id":"7a","method":"settings.setShowTopHandleSideArea","params":{"visible":false}}""");
        await Send(dispatcher, """{"id":"7x","method":"settings.setDisableTopEdgeInFullscreen","params":{"disabled":false}}""");
        await Send(dispatcher, """{"id":"7z","method":"sticky.setGridSize","params":{"gridSize":"large"}}""");

        var written = store.ReloadOrDefault(registry.ProviderIds);
        if (written.Language != AppLanguage.English
            || written.TextSize != PanelTextSize.Large
            || written.PanelSize != PanelSize.Small
            || written.SwitchingMode != ProviderSwitchingMode.Hover
            || written.DisplayPlacement != DisplayPlacement.All
            || written.RememberLastSelectedProvider
            || written.PreferredProviderId != "sticky"
            || written.HandleIconStyle != HandleIconStyle.C
            || written.ShowTopHandleSideArea
            || written.DisableTopEdgeInFullscreen
            || !written.StartWithWindows
            || written.AutoCheckForUpdates
            || !written.AiNativeEnabled)
        {
            _failures.Add("settings write/read did not preserve scalar values");
        }

        if (!HasExpectedOrderPrefix(written.ProviderOrder, ["controls", "sticky", "calculator", "timer"])
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
        if (!stickyHidden.Contains("\"showUndoToast\":false", StringComparison.Ordinal)
            || !stickyHidden.Contains("\"gridSize\":\"large\"", StringComparison.Ordinal))
        {
            _failures.Add("sticky preferences were not updated through settings bridge");
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
        await VerifyResetDisablesGenerationAsync(registry);
    }

    private async Task VerifyResetDisablesGenerationAsync(ProviderRegistry registry)
    {
        var store = UserSettingsStore.CreateTemporary("SettingsResetGenerationVerify");
        var enabled = UserSettingsStore.CreateDefault(registry.ProviderIds);
        enabled.AiNativeEnabled = true;
        store.Save(enabled);
        using var controller = new PanelBridgeController(
            registry,
            store,
            store.Load(registry.ProviderIds),
            new InMemoryStartupRegistrationService());
        var dispatcher = new BridgeDispatcher();
        using var attachment = controller.Attach(
            dispatcher,
            BridgeSurface.Settings,
            aiNativeEnableDecision: () => true);

        var before = await Send(dispatcher, """{"id":"reset-before","method":"pocketApps.generationState"}""");
        await Send(dispatcher, """{"id":"reset","method":"settings.resetDefaults"}""");
        var after = await Send(dispatcher, """{"id":"reset-after","method":"pocketApps.generationState"}""");
        var blocked = await Send(
            dispatcher,
            """{"id":"reset-disabled","method":"pocketApps.disable","params":{"appId":"local.example.reset"}}""");
        var reenabled = await Send(
            dispatcher,
            """{"id":"reset-reenabled","method":"settings.setAiNativeEnabled","params":{"enabled":true}}""");
        if (!before.Contains("\"enabled\":true", StringComparison.Ordinal)
            || !after.Contains("\"enabled\":false", StringComparison.Ordinal)
            || !blocked.Contains("GENERATION_DISABLED", StringComparison.Ordinal)
            || !reenabled.Contains("\"pocketSurface\":null", StringComparison.Ordinal)
            || !reenabled.Contains("\"enabled\":false", StringComparison.Ordinal))
        {
            _failures.Add("settings reset did not revoke AI-native runtimes until restart");
        }
    }

    private void VerifyWebViewSecurityPolicy()
    {
        if (WebViewSecurityPolicy.ShouldEnableBrowserDebugFeatures(devToolsFlag: false, isDebugBuild: false))
        {
            _failures.Add("webview security: release without --devtools enabled debug browser features");
        }

        if (!WebViewSecurityPolicy.ShouldEnableBrowserDebugFeatures(devToolsFlag: true, isDebugBuild: false)
            || !WebViewSecurityPolicy.ShouldEnableBrowserDebugFeatures(devToolsFlag: false, isDebugBuild: true))
        {
            _failures.Add("webview security: debug build or --devtools did not enable browser debug features");
        }

        if (!StartupOptions.Parse(["--devtools"]).EnableDevTools)
        {
            _failures.Add("webview security: --devtools flag was not parsed");
        }

        if (!WebViewSecurityPolicy.IsAllowedVirtualHostNavigation(
                "https://app.hoverpocket.local/index.html",
                WebViewSecurityPolicy.PanelHostName)
            || !WebViewSecurityPolicy.IsAllowedVirtualHostNavigation(
                "https://settings.hoverpocket.local/settings/index.html",
                WebViewSecurityPolicy.SettingsHostName))
        {
            _failures.Add("webview security: virtual-host URLs were not allowed");
        }

        if (WebViewSecurityPolicy.IsAllowedVirtualHostNavigation(
                "https://example.com/",
                WebViewSecurityPolicy.PanelHostName)
            || WebViewSecurityPolicy.IsAllowedVirtualHostNavigation(
                "http://app.hoverpocket.local/",
                WebViewSecurityPolicy.PanelHostName))
        {
            _failures.Add("webview security: non-virtual-host URL was allowed");
        }

        if (!WebViewSecurityPolicy.ShouldOpenExternalBrowser(
                "https://example.com/",
                WebViewSecurityPolicy.PanelHostName)
            || WebViewSecurityPolicy.ShouldOpenExternalBrowser(
                "https://app.hoverpocket.local/index.html",
                WebViewSecurityPolicy.PanelHostName)
            || WebViewSecurityPolicy.ShouldOpenExternalBrowser(
                "file:///C:/temp/test.html",
                WebViewSecurityPolicy.PanelHostName))
        {
            _failures.Add("webview security: external browser routing did not match policy");
        }
    }

    private void VerifyDefaults(UserSettingsStore store, ProviderRegistry registry, InMemoryStartupRegistrationService startup)
    {
        var defaults = store.ReloadOrDefault(registry.ProviderIds);
        if (defaults.Language != AppLanguage.Japanese
            || defaults.DisplayPlacement != DisplayPlacement.Main
            || defaults.TextSize != PanelTextSize.Medium
            || defaults.PanelSize != PanelSize.Medium
            || defaults.SwitchingMode != ProviderSwitchingMode.Click
            || defaults.StartWithWindows
            || !defaults.AutoCheckForUpdates
            || defaults.AiNativeEnabled
            || !defaults.RememberLastSelectedProvider
            || defaults.PreferredProviderId != "controls"
            || defaults.HandleIconStyle != HandleIconStyle.B
            || !defaults.ShowTopHandleSideArea
            || !defaults.DisableTopEdgeInFullscreen)
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
