using System.Text.Json;
using HoverPocket.Shell.Bridge;
using HoverPocket.Shell.Configuration;
using HoverPocket.Shell.PocketApps;
using HoverPocket.Shell.Providers;
using HoverPocket.Shell.Verification;
using HoverPocket.Shell.Voice;
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
            aiNativeEnableDecision: () => true,
            voiceCalendarAccessDecision: () => true);
        var deniedSettingsDispatcher = new BridgeDispatcher();
        using var deniedSettingsAttachment = controller.Attach(
            deniedSettingsDispatcher,
            BridgeSurface.Settings,
            aiNativeEnableDecision: () => false,
            voiceCalendarAccessDecision: () => false);
        var panelDispatcher = new BridgeDispatcher();
        using var panelAttachment = controller.Attach(panelDispatcher, BridgeSurface.Panel);

        VerifyDefaults(store, registry, startup);
        VerifyWebViewSecurityPolicy();
        await RunCaseAsync(
            "surface-isolation",
            () => VerifyPocketAppBridgeSurfaceIsolationAsync(registry));
        await RunCaseAsync(
            "generated-provider-lifecycle",
            () => VerifyGeneratedProviderLifecyclePublicationAsync(registry));
        await RunCaseAsync(
            "ai-native-disable-flush",
            () => VerifyAiNativeDisableFlushBoundaryAsync(registry));
        var defaultState = await Send(dispatcher, """{"id":"0","method":"app.getState"}""");
        if (!defaultState.Contains("\"aiNativeEnabled\":false", StringComparison.Ordinal)
            || !defaultState.Contains("\"pocketAppGeneration\":null", StringComparison.Ordinal)
            || Directory.Exists(Path.Combine(store.RootDirectory, "PocketApps", "Generation")))
        {
            _failures.Add("AI-native default-off started generation runtime or workspace");
        }
        var panelEnable = await panelDispatcher.ProcessRawMessageAsync(
            """{"id":"0p","method":"settings.setAiNativeEnabled","params":{"enabled":true}}""");
        var panelVoiceEnable = await panelDispatcher.ProcessRawMessageAsync(
            """{"id":"0v","method":"settings.setVoiceEnabled","params":{"enabled":true}}""");
        var panelVoiceCalendar = await panelDispatcher.ProcessRawMessageAsync(
            """{"id":"0c","method":"settings.setVoiceCalendarAccess","params":{"enabled":true}}""");
        if (panelEnable?.Contains("\"code\":\"unknown_method\"", StringComparison.Ordinal) != true)
        {
            _failures.Add("panel bridge exposed the Settings-only AI-native toggle");
        }
        if (panelVoiceEnable?.Contains("\"code\":\"unknown_method\"", StringComparison.Ordinal) != true)
        {
            _failures.Add("panel bridge exposed the Settings-only Voice enable toggle");
        }
        if (panelVoiceCalendar?.Contains("\"code\":\"unknown_method\"", StringComparison.Ordinal) != true)
        {
            _failures.Add("panel bridge exposed the Settings-only Voice Calendar grant");
        }
        var deniedEnable = await Send(
            deniedSettingsDispatcher,
            """{"id":"0d","method":"settings.setAiNativeEnabled","params":{"enabled":true}}""");
        if (!deniedEnable.Contains("\"aiNativeEnabled\":false", StringComparison.Ordinal)
            || store.ReloadOrDefault(registry.ProviderIds).AiNativeEnabled)
        {
            _failures.Add("native default-No AI-native approval was bypassed");
        }
        var deniedCalendar = await Send(
            deniedSettingsDispatcher,
            """{"id":"0dc","method":"settings.setVoiceCalendarAccess","params":{"enabled":true}}""");
        if (!deniedCalendar.Contains("\"voiceCalendarAccessGranted\":false", StringComparison.Ordinal)
            || store.ReloadOrDefault(registry.ProviderIds).VoiceCalendarAccessGranted)
        {
            _failures.Add("native default-No Voice Calendar approval was bypassed");
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
        await Send(dispatcher, """{"id":"7vc","method":"settings.setVoiceCalendarAccess","params":{"enabled":true}}""");
        await Send(dispatcher, """{"id":"7v","method":"settings.setVoiceEnabled","params":{"enabled":true}}""");
        await Send(dispatcher, """{"id":"7vl","method":"settings.setVoiceLayout","params":{"layout":"expanded"}}""");
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
            || !written.AiNativeEnabled
            || !written.VoiceEnabled
            || !written.VoiceCalendarAccessGranted
            || written.VoiceLaneLayout != VoiceLaneLayoutPreference.Expanded)
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

    private static async Task RunCaseAsync(string label, Func<Task> verification)
    {
        VerifyConsole.WriteLine($"SETTINGS_CASE_BEGIN {label}");
        await verification();
        VerifyConsole.WriteLine($"SETTINGS_CASE_PASS {label}");
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

    private async Task VerifyAiNativeDisableFlushBoundaryAsync(ProviderRegistry registry)
    {
        var store = UserSettingsStore.CreateTemporary("SettingsAiNativeFlushVerify");
        var enabled = UserSettingsStore.CreateDefault(registry.ProviderIds);
        enabled.AiNativeEnabled = true;
        store.Save(enabled);
        using var controller = new PanelBridgeController(
            registry,
            store,
            store.Load(registry.ProviderIds),
            new InMemoryStartupRegistrationService());
        await controller.SelectProviderFromShellAsync("today-focus");
        var allowFlush = false;
        var flushCalls = 0;
        controller.SetPocketAppStateFlush((appId, cancellationToken) =>
        {
            cancellationToken.ThrowIfCancellationRequested();
            flushCalls += 1;
            return Task.FromResult(new PocketAppStateTransitionLease(
                appId,
                $"settings-flush-{flushCalls}",
                allowFlush && !string.IsNullOrWhiteSpace(appId)));
        });
        var dispatcher = new BridgeDispatcher();
        using var attachment = controller.Attach(dispatcher, BridgeSurface.Settings);

        var blocked = await Send(
            dispatcher,
            """{"id":"ai-flush-blocked","method":"settings.setAiNativeEnabled","params":{"enabled":false}}""");
        allowFlush = true;
        var disabled = await Send(
            dispatcher,
            """{"id":"ai-flush-disabled","method":"settings.setAiNativeEnabled","params":{"enabled":false}}""");
        if (flushCalls != 2
            || !blocked.Contains("\"aiNativeEnabled\":true", StringComparison.Ordinal)
            || !disabled.Contains("\"aiNativeEnabled\":false", StringComparison.Ordinal)
            || store.ReloadOrDefault(registry.ProviderIds).AiNativeEnabled)
        {
            _failures.Add("AI-native disable did not await and honor the active Pocket App state flush");
        }
    }

    private async Task VerifyPocketAppBridgeSurfaceIsolationAsync(ProviderRegistry registry)
    {
        var store = UserSettingsStore.CreateTemporary("SettingsPocketBridgeVerify");
        var enabled = UserSettingsStore.CreateDefault(registry.ProviderIds);
        enabled.AiNativeEnabled = true;
        store.Save(enabled);
        var voiceCoordinator = new CodexVoiceCoordinator(featureEnabled: true);
        voiceCoordinator.SetRootSessionId("root-private");
        voiceCoordinator.AppendTranscript(new VoiceTranscriptEvent(
            "event-private",
            "user",
            "settings-must-not-see-transcript",
            true,
            DateTimeOffset.UnixEpoch));
        voiceCoordinator.UpsertSession(new AgentSessionSummary(
            "root-private",
            "root-private",
            null,
            "settings-must-not-see-session",
            AgentSessionStatus.Running,
            "settings-must-not-see-summary",
            null,
            DateTimeOffset.UnixEpoch));
        using var controller = new PanelBridgeController(
            registry,
            store,
            store.Load(registry.ProviderIds),
            new InMemoryStartupRegistrationService(),
            voiceCoordinator: voiceCoordinator);
        var settingsDispatcher = new BridgeDispatcher();
        using var settingsAttachment = controller.Attach(settingsDispatcher, BridgeSurface.Settings);
        var panelDispatcher = new BridgeDispatcher();
        using var panelAttachment = controller.Attach(panelDispatcher, BridgeSurface.Panel);

        var settingsSelect = await settingsDispatcher.ProcessRawMessageAsync(
            """{"id":"surface-settings-select","method":"provider.select","params":{"id":"today-focus"}}""");
        var settingsLoad = await settingsDispatcher.ProcessRawMessageAsync(
            """{"id":"surface-settings-load","method":"pocketApp.load","params":{"appId":"local.example.today-focus","surfaceId":"main"}}""");
        var panelSelect = await Send(
            panelDispatcher,
            """{"id":"surface-panel-select","method":"provider.select","params":{"id":"today-focus"}}""");
        var panelState = await Send(
            panelDispatcher,
            """{"id":"surface-panel-state","method":"app.getState"}""");
        var settingsState = await Send(
            settingsDispatcher,
            """{"id":"surface-settings-state","method":"app.getState"}""");
        var settingsMutation = await Send(
            settingsDispatcher,
            """{"id":"surface-settings-mutation","method":"settings.setLanguage","params":{"language":"en"}}""");

        if (settingsSelect?.Contains("\"code\":\"unknown_method\"", StringComparison.Ordinal) != true
            || settingsLoad?.Contains("\"code\":\"unknown_method\"", StringComparison.Ordinal) != true
            || !panelSelect.Contains("\"pocketSurface\":{", StringComparison.Ordinal)
            || !panelState.Contains("settings-must-not-see-transcript", StringComparison.Ordinal)
            || !settingsState.Contains("\"voiceLane\":null", StringComparison.Ordinal)
            || settingsState.Contains("settings-must-not-see", StringComparison.Ordinal)
            || settingsMutation.Contains("settings-must-not-see", StringComparison.Ordinal)
            || settingsState.Contains("\"pocketSurface\":{", StringComparison.Ordinal)
            || settingsMutation.Contains("\"pocketSurface\":{", StringComparison.Ordinal))
        {
            _failures.Add("Pocket App bridge authority or state crossed the Panel/Settings surface boundary");
        }
    }

    private async Task VerifyGeneratedProviderLifecyclePublicationAsync(ProviderRegistry registry)
    {
        const string appId = "local.generated.settings-fixture";
        var generatedProviderId = PocketSurfaceRegistry.GeneratedProviderId(appId);
        var store = UserSettingsStore.CreateTemporary("SettingsGeneratedProviderLifecycleVerify");
        var pocketAppsRoot = Path.Combine(store.RootDirectory, "PocketApps");
        var generatedHostRoot = Path.Combine(pocketAppsRoot, "GeneratedHost");
        var userDataRoot = Path.Combine(pocketAppsRoot, "UserData");
        var sourcePackageRoot = Path.Combine(AppContext.BaseDirectory, "PocketApps", "local.example.today-focus");
        var packageRoot = Path.Combine(store.RootDirectory, "GeneratedProviderFixture");
        CopyDirectory(sourcePackageRoot, packageRoot);
        var manifestPath = Path.Combine(packageRoot, "manifest.json");
        File.WriteAllText(
            manifestPath,
            File.ReadAllText(manifestPath).Replace("local.example.today-focus", appId, StringComparison.Ordinal));
        using (var lifecycle = new PocketAppLifecycleManager(generatedHostRoot, userDataRoot))
        {
            var now = DateTimeOffset.FromUnixTimeSeconds(1_800_000_000);
            var proposal = lifecycle.Stage(packageRoot, now);
            var grant = lifecycle.Approve(proposal.RequestId, proposal.BindingDigest, now);
            var receipt = lifecycle.Install(proposal, grant, now);
            if (!receipt.ReadbackVerified || receipt.State != PocketAppLifecycleState.Enabled)
            {
                _failures.Add("generated provider lifecycle fixture did not install");
                return;
            }
        }

        var enabled = UserSettingsStore.CreateDefault(registry.ProviderIds);
        enabled.AiNativeEnabled = true;
        enabled.ProviderOrder.Insert(1, generatedProviderId);
        enabled.ProviderVisibility[generatedProviderId] = true;
        enabled.PreferredProviderId = generatedProviderId;
        enabled.LastSelectedProviderId = generatedProviderId;
        store.Save(enabled);

        using var controller = new PanelBridgeController(
            registry,
            store,
            store.LoadForBootstrap(registry.ProviderIds),
            new InMemoryStartupRegistrationService());
        var panelEvents = new List<string>();
        var panelDispatcher = new BridgeDispatcher(json =>
        {
            panelEvents.Add(json);
            return Task.CompletedTask;
        });
        using var panelAttachment = controller.Attach(panelDispatcher, BridgeSurface.Panel);
        var settingsDispatcher = new BridgeDispatcher();
        using var settingsAttachment = controller.Attach(settingsDispatcher, BridgeSurface.Settings);

        var before = await Send(
            panelDispatcher,
            """{"id":"generated-before","method":"app.getState"}""");
        var disabled = await Send(
            settingsDispatcher,
            JsonSerializer.Serialize(new { id = "generated-disable", method = "pocketApps.disable", @params = new { appId } }));
        for (var attempt = 0; attempt < 20
             && !panelEvents.Any(item => item.Contains("\"event\":\"state.changed\"", StringComparison.Ordinal));
             attempt++)
        {
            await Task.Delay(10);
        }

        var publishedProviders = panelEvents
            .Select(item => JsonDocument.Parse(item))
            .Where(document => document.RootElement.GetProperty("event").GetString() == "state.changed")
            .SelectMany(document => document.RootElement.GetProperty("payload").GetProperty("providers").EnumerateArray())
            .Select(provider => provider.GetProperty("id").GetString() ?? string.Empty)
            .ToArray();
        if (!before.Contains($"\"id\":\"{generatedProviderId}\"", StringComparison.Ordinal)
            || !disabled.Contains("\"state\":\"disabled\"", StringComparison.Ordinal)
            || publishedProviders.Length == 0
            || publishedProviders.Contains(generatedProviderId, StringComparer.OrdinalIgnoreCase))
        {
            _failures.Add("generated provider lifecycle commit did not publish the refreshed Panel provider state");
        }

        _ = await Send(
            settingsDispatcher,
            """{"id":"generated-disabled-setting","method":"settings.setTextSize","params":{"textSize":"large"}}""");
        var preserved = controller.CurrentSettings;
        if (!preserved.ProviderOrder.Contains(generatedProviderId, StringComparer.OrdinalIgnoreCase)
            || !preserved.ProviderVisibility.TryGetValue(generatedProviderId, out var generatedVisible)
            || !generatedVisible
            || preserved.PreferredProviderId != generatedProviderId
            || preserved.LastSelectedProviderId != generatedProviderId)
        {
            _failures.Add("disabled generated provider preferences were pruned by an unrelated settings write");
        }

        var reenabled = await Send(
            settingsDispatcher,
            JsonSerializer.Serialize(new { id = "generated-enable", method = "pocketApps.enable", @params = new { appId } }));
        var afterEnable = await Send(panelDispatcher, """{"id":"generated-after-enable","method":"app.getState"}""");
        if (!reenabled.Contains("\"state\":\"enabled\"", StringComparison.Ordinal)
            || !afterEnable.Contains($"\"id\":\"{generatedProviderId}\"", StringComparison.Ordinal)
            || controller.CurrentSettings.PreferredProviderId != generatedProviderId)
        {
            _failures.Add("re-enabled generated provider did not restore its retained preferences");
        }

        var removed = await Send(
            settingsDispatcher,
            JsonSerializer.Serialize(new { id = "generated-remove", method = "pocketApps.removePreservingData", @params = new { appId } }));
        _ = await Send(
            settingsDispatcher,
            """{"id":"generated-removed-setting","method":"settings.setTextSize","params":{"textSize":"medium"}}""");
        var pruned = controller.CurrentSettings;
        if (!removed.Contains("\"state\":\"removed\"", StringComparison.Ordinal)
            || pruned.ProviderOrder.Contains(generatedProviderId, StringComparer.OrdinalIgnoreCase)
            || pruned.ProviderVisibility.ContainsKey(generatedProviderId)
            || pruned.PreferredProviderId == generatedProviderId
            || pruned.LastSelectedProviderId == generatedProviderId)
        {
            _failures.Add("removed generated provider preferences were not pruned");
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
            || defaults.VoiceEnabled
            || defaults.VoiceCalendarAccessGranted
            || defaults.VoiceLaneLayout != VoiceLaneLayoutPreference.Compact
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

    private static void CopyDirectory(string source, string destination)
    {
        foreach (var file in Directory.GetFiles(source, "*", SearchOption.AllDirectories))
        {
            var relative = Path.GetRelativePath(source, file);
            var target = Path.Combine(destination, relative);
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            File.Copy(file, target, overwrite: false);
        }
    }
}
