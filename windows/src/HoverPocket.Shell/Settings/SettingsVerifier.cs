using System.ComponentModel;
using System.Diagnostics;
using System.Text.Json;
using HoverPocket.CodexSandboxSetup.Contracts;
using HoverPocket.Shell.Bridge;
using HoverPocket.Shell.Capabilities;
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
        var codexSandbox = new InMemoryCodexGenerationSandboxProvisioner();
        using var controller = new PanelBridgeController(
            registry,
            store,
            store.Load(registry.ProviderIds),
            startup,
            codexGenerationSandboxProvisioner: codexSandbox);
        var dispatcher = new BridgeDispatcher();
        using var settingsAttachment = controller.Attach(
            dispatcher,
            BridgeSurface.Settings,
            aiNativeEnableDecision: () => true,
            voiceCalendarAccessDecision: () => true,
            capabilityHistoryDeleteDecision: () => true,
            codexSandboxExecutablePicker: () => @"C:\fixture\codex.exe",
            codexSandboxProvisionDecision: () => true);
        var deniedSettingsDispatcher = new BridgeDispatcher();
        using var deniedSettingsAttachment = controller.Attach(
            deniedSettingsDispatcher,
            BridgeSurface.Settings,
            aiNativeEnableDecision: () => false,
            voiceCalendarAccessDecision: () => false,
            capabilityHistoryDeleteDecision: () => false);
        var panelDispatcher = new BridgeDispatcher();
        using var panelAttachment = controller.Attach(panelDispatcher, BridgeSurface.Panel);

        VerifyDefaults(store, registry, startup);
        VerifyWebViewSecurityPolicy();
        await VerifyCodexSandboxFailClosedAsync(registry);
        VerifyVoiceAvailabilityWireValues();
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
            || !defaultState.Contains("\"capabilityDataRetentionPeriod\":\"ninetyDays\"", StringComparison.Ordinal)
            || !defaultState.Contains("\"capabilityDataGovernance\":{\"available\":true", StringComparison.Ordinal)
            || !defaultState.Contains("\"pocketAppGeneration\":null", StringComparison.Ordinal)
            || !defaultState.Contains("\"codexGenerationSandbox\":{\"status\":\"not_ready\",\"ready\":false", StringComparison.Ordinal)
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
        var panelRetention = await panelDispatcher.ProcessRawMessageAsync(
            """{"id":"0r","method":"settings.setCapabilityRetention","params":{"period":"sevenDays"}}""");
        var panelClearHistory = await panelDispatcher.ProcessRawMessageAsync(
            """{"id":"0h","method":"settings.clearCapabilityHistory"}""");
        var panelSandboxSetup = await panelDispatcher.ProcessRawMessageAsync(
            """{"id":"0s","method":"settings.setupCodexGenerationSandbox"}""");
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
        if (panelRetention?.Contains("\"code\":\"unknown_method\"", StringComparison.Ordinal) != true
            || panelClearHistory?.Contains("\"code\":\"unknown_method\"", StringComparison.Ordinal) != true)
        {
            _failures.Add("panel bridge exposed Settings-only capability history controls");
        }
        if (panelSandboxSetup?.Contains("\"code\":\"unknown_method\"", StringComparison.Ordinal) != true)
        {
            _failures.Add("panel bridge exposed Settings-only Codex sandbox setup");
        }
        _ = await Send(
            deniedSettingsDispatcher,
            """{"id":"0ds","method":"settings.setupCodexGenerationSandbox"}""");
        if (codexSandbox.ProvisionCount != 0)
        {
            _failures.Add("Codex sandbox setup ran without native picker and approval callbacks");
        }
        var deniedSandboxPickerCalls = 0;
        var deniedSandboxApprovalCalls = 0;
        var deniedSandboxDispatcher = new BridgeDispatcher();
        using var deniedSandboxAttachment = controller.Attach(
            deniedSandboxDispatcher,
            BridgeSurface.Settings,
            codexSandboxExecutablePicker: () =>
            {
                deniedSandboxPickerCalls += 1;
                return @"C:\fixture\codex.exe";
            },
            codexSandboxProvisionDecision: () =>
            {
                deniedSandboxApprovalCalls += 1;
                return false;
            });
        _ = await Send(
            deniedSandboxDispatcher,
            """{"id":"0dns","method":"settings.setupCodexGenerationSandbox"}""");
        if (deniedSandboxPickerCalls != 1
            || deniedSandboxApprovalCalls != 1
            || codexSandbox.ProvisionCount != 0)
        {
            _failures.Add("Codex sandbox native approval did not stop before the launch boundary");
        }
        var sandboxReadyState = await Send(
            dispatcher,
            """{"id":"0ss","method":"settings.setupCodexGenerationSandbox"}""");
        if (codexSandbox.ProvisionCount != 1
            || !sandboxReadyState.Contains("\"codexGenerationSandbox\":{\"status\":\"ready\",\"ready\":true", StringComparison.Ordinal)
            || !sandboxReadyState.Contains("\"restartRequired\":true", StringComparison.Ordinal))
        {
            _failures.Add("Codex sandbox setup did not return deterministic readiness readback");
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
        await Send(dispatcher, """{"id":"7r","method":"settings.setCapabilityRetention","params":{"period":"sevenDays"}}""");
        var clearedHistory = await Send(dispatcher, """{"id":"7h","method":"settings.clearCapabilityHistory"}""");
        if (!clearedHistory.Contains("\"capabilityDataGovernance\":{\"available\":true", StringComparison.Ordinal))
        {
            _failures.Add("capability history clear did not return governance readback");
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
            || !written.AiNativeEnabled
            || written.VoiceEnabled
            || written.VoiceProviderId != VoiceProviderIds.Off
            || !written.VoiceCalendarAccessGranted
            || written.VoiceLaneLayout != VoiceLaneLayoutPreference.Expanded
            || written.CapabilityDataRetentionPeriod != CapabilityDataRetentionPeriod.SevenDays)
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

    private void VerifyVoiceAvailabilityWireValues()
    {
        var expected = new Dictionary<CodexVoiceAvailability, string>
        {
            [CodexVoiceAvailability.Disabled] = "disabled",
            [CodexVoiceAvailability.Ready] = "ready",
            [CodexVoiceAvailability.Unavailable] = "unavailable",
            [CodexVoiceAvailability.SignedOut] = "signedOut",
            [CodexVoiceAvailability.SchemaMismatch] = "schemaMismatch",
            [CodexVoiceAvailability.CapabilityBlocked] = "capabilityBlocked"
        };
        if (expected.Any(pair =>
            PanelBridgeController.ToVoiceAvailabilityWireValue(pair.Key) != pair.Value))
        {
            _failures.Add("Voice availability wire values do not match the renderer contract");
        }
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
        enabled.VoiceProviderId = VoiceProviderIds.CodexAppServer;
        enabled.VoiceEnabled = true;
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
        enabled.VoiceProviderId = VoiceProviderIds.CodexAppServer;
        enabled.VoiceEnabled = true;
        store.Save(enabled);
        var voiceCoordinator = new CodexVoiceCoordinator(featureEnabled: true);
        voiceCoordinator.SetRootSessionId("root-private");
        voiceCoordinator.AppendTranscript(new VoiceTranscriptEvent(
            "event-private",
            "root-private",
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
                "https://example.com/",
                WebViewSecurityPolicy.PanelHostName,
                externalIntegrationsEnabled: false)
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

    private async Task VerifyCodexSandboxFailClosedAsync(ProviderRegistry registry)
    {
        await VerifyCodexSandboxHelperBoundaryAsync();
        VerifyCodexSandboxSetupRequestContract();
        if (File.Exists(Path.Combine(
            AppContext.BaseDirectory,
            "tools",
            "codex-sandbox-setup",
            "HoverPocket.CodexSandboxSetup.exe")))
        {
            _failures.Add("Shell still contains an app-local Codex sandbox setup helper");
        }
        var sandboxRoot = Path.Combine(
            Path.GetTempPath(),
            $"HoverPocketCodexSandboxDisabled-{Guid.NewGuid():N}");
        var home = Path.Combine(sandboxRoot, "codex-home");
        var executable = Path.Combine(sandboxRoot, "bin", "codex.exe");
        var provisioner = new CodexGenerationSandboxProvisioner(
            home,
            executable,
            setupAvailable: true);

        var initial = provisioner.Check();
        var direct = await provisioner.ProvisionAsync(
            Path.Combine(sandboxRoot, "untrusted-source", "codex.exe"),
            CancellationToken.None);
        var dormantRequestCount = 0;
        var guardedProvisioner = new CodexGenerationSandboxProvisioner(
            home,
            executable,
            true,
            new CodexSandboxSetupHelperResolver(
                () => throw new InvalidOperationException("dormant helper resolver was reached"),
                () => null,
                _ => new CodexSandboxSetupPublisherReadback(false, null)),
            new CodexSandboxSetupProcessLauncher(),
            (_, _) =>
            {
                dormantRequestCount += 1;
                throw new InvalidOperationException("dormant request factory was reached");
            });
        var guarded = await guardedProvisioner.ProvisionAsync(
            executable,
            CancellationToken.None);
        if (CodexGenerationSandboxSecurityPolicy.ProvisioningAvailable
            || CodexGenerationSandboxSecurityPolicy.ProductionRuntimeAvailable
            || initial.Ready
            || initial.SetupAvailable
            || initial.RepairAvailable
            || initial.RestartRequired
            || !string.Equals(
                initial.ErrorCode,
                CodexGenerationSandboxSecurityPolicy.SetupUnavailableCode,
                StringComparison.Ordinal)
            || direct.Ready
            || direct.SetupAvailable
            || guarded.Ready
            || guarded.SetupAvailable
            || dormantRequestCount != 0
            || !string.Equals(
                direct.ErrorCode,
                CodexGenerationSandboxSecurityPolicy.SetupUnavailableCode,
                StringComparison.Ordinal)
            || !string.Equals(
                guarded.ErrorCode,
                CodexGenerationSandboxSecurityPolicy.SetupUnavailableCode,
                StringComparison.Ordinal)
            || Directory.Exists(sandboxRoot)
            || CodexPocketAppGenerationAdapter.ResolveExecutable() is not null)
        {
            _failures.Add("Codex sandbox production setup or legacy runtime was not fail-closed");
        }

        var store = UserSettingsStore.CreateTemporary("SettingsCodexSandboxDisabled");
        var pickerCalls = 0;
        var approvalCalls = 0;
        using var controller = new PanelBridgeController(
            registry,
            store,
            store.Load(registry.ProviderIds),
            new InMemoryStartupRegistrationService(),
            externalIntegrationsEnabled: true,
            codexGenerationSandboxProvisioner: provisioner);
        var dispatcher = new BridgeDispatcher();
        using var attachment = controller.Attach(
            dispatcher,
            BridgeSurface.Settings,
            codexSandboxExecutablePicker: () =>
            {
                pickerCalls += 1;
                return executable;
            },
            codexSandboxProvisionDecision: () =>
            {
                approvalCalls += 1;
                return true;
            });
        var response = await Send(
            dispatcher,
            """{"id":"sandbox-disabled","method":"settings.setupCodexGenerationSandbox"}""");
        if (pickerCalls != 0
            || approvalCalls != 0
            || Directory.Exists(sandboxRoot)
            || !response.Contains("\"setupAvailable\":false", StringComparison.Ordinal)
            || !response.Contains("\"repairAvailable\":false", StringComparison.Ordinal)
            || !response.Contains(
                $"\"errorCode\":\"{CodexGenerationSandboxSecurityPolicy.SetupUnavailableCode}\"",
                StringComparison.Ordinal))
        {
            _failures.Add("forged Codex sandbox setup reached picker, approval, or filesystem work");
        }
    }

    private async Task VerifyCodexSandboxHelperBoundaryAsync()
    {
        var trustPolicy = CodexSandboxSetupHelperResolver.TrustPolicyForVerify;
        if (trustPolicy.RevocationChecks != 1
            || (trustPolicy.ProviderFlags & 0x00000080) == 0
            || (trustPolicy.ProviderFlags & 0x00001000) != 0)
        {
            _failures.Add("Codex sandbox helper trust policy did not require online chain revocation checks");
        }

        var root = Path.Combine(
            Path.GetTempPath(),
            $"HoverPocketSettingsHelperBoundary-{Guid.NewGuid():N}");
        var programFilesRoot = Path.Combine(root, "Program Files");
        var helperPath = CodexSandboxSetupHelperResolver.ResolveFixedPath(programFilesRoot);
        if (!string.Equals(
            Path.GetRelativePath(programFilesRoot, helperPath),
            CodexSandboxSetupHelperResolver.FixedRelativePath,
            StringComparison.OrdinalIgnoreCase))
        {
            _failures.Add("Codex sandbox helper fixed path contract drifted");
        }
        Directory.CreateDirectory(Path.GetDirectoryName(helperPath)!);
        File.WriteAllBytes(helperPath, [0x48, 0x50]);
        var expectedCertificate = new string('a', 64);
        try
        {
            var publisherReadCount = 0;
            var resolver = new CodexSandboxSetupHelperResolver(
                () => programFilesRoot,
                () => expectedCertificate,
                path =>
                {
                    publisherReadCount += 1;
                    return string.Equals(path, helperPath, StringComparison.OrdinalIgnoreCase)
                        ? new CodexSandboxSetupPublisherReadback(true, expectedCertificate)
                        : new CodexSandboxSetupPublisherReadback(false, null);
                });
            using (var lease = resolver.Resolve())
            {
                lease.ValidateIdentity();
                lease.ValidateProcessImage(helperPath);
                if (!string.Equals(lease.FullPath, helperPath, StringComparison.OrdinalIgnoreCase)
                    || publisherReadCount != 1)
                {
                    _failures.Add("fixed Codex sandbox helper origin or identity lease was not deterministic");
                }
            }

            ExpectHelperResolverFailure(
                new CodexSandboxSetupHelperResolver(
                    () => programFilesRoot,
                    () => null,
                    _ => new CodexSandboxSetupPublisherReadback(true, expectedCertificate)),
                CodexSandboxSetupHelperResolver.MetadataInvalidCode);
            ExpectHelperResolverFailure(
                new CodexSandboxSetupHelperResolver(
                    () => programFilesRoot,
                    () => "invalid",
                    _ => new CodexSandboxSetupPublisherReadback(true, expectedCertificate)),
                CodexSandboxSetupHelperResolver.MetadataInvalidCode);
            ExpectHelperResolverFailure(
                new CodexSandboxSetupHelperResolver(
                    () => programFilesRoot,
                    () => expectedCertificate,
                    _ => new CodexSandboxSetupPublisherReadback(false, null)),
                CodexSandboxSetupHelperResolver.PublisherInvalidCode);
            ExpectHelperResolverFailure(
                new CodexSandboxSetupHelperResolver(
                    () => programFilesRoot,
                    () => expectedCertificate,
                    _ => new CodexSandboxSetupPublisherReadback(true, new string('b', 64))),
                CodexSandboxSetupHelperResolver.PublisherInvalidCode);

            using var request = new PinnedCodexSandboxSetupRequest(
                new EncodedSetupRequest(
                    "fixture-request",
                    new string('c', 64),
                    new string('d', 64)),
                Array.Empty<FileStream>());
            var expectedArguments = new[]
            {
                "--setup-request",
                request.Encoded.Base64Json,
                "--request-sha256",
                request.Encoded.Sha256,
                "--nonce",
                request.Encoded.Nonce,
            };

            var successLease = new RecordingCodexSandboxSetupHelperLease(helperPath);
            var successFactory = new RecordingCodexSandboxSetupProcessFactory(
                RecordingCodexSandboxSetupProcessMode.Success);
            var successLauncher = CreateRecordingLauncher(successFactory, helperPath);
            var success = await successLauncher.LaunchAsync(
                successLease,
                request,
                CancellationToken.None);
            if (!success.Succeeded
                || success.ErrorCode is not null
                || successFactory.StartCount != 1
                || successFactory.LastStartInfo is null
                || !string.Equals(successFactory.LastStartInfo.FileName, helperPath, StringComparison.Ordinal)
                || !string.Equals(successFactory.LastStartInfo.Verb, "runas", StringComparison.Ordinal)
                || !successFactory.LastStartInfo.UseShellExecute
                || !successFactory.LastStartInfo.ArgumentList.SequenceEqual(expectedArguments, StringComparer.Ordinal)
                || successLease.ValidateCount != 3
                || successLease.ProcessImageValidationCount != 1)
            {
                _failures.Add("Codex sandbox helper launch did not use one exact runas dispatch");
            }

            await VerifyLauncherFailureAsync(
                helperPath,
                request,
                RecordingCodexSandboxSetupProcessMode.UacCancelled,
                CodexSandboxSetupProcessLauncher.UacCancelledCode);
            await VerifyLauncherFailureAsync(
                helperPath,
                request,
                RecordingCodexSandboxSetupProcessMode.StartFailure,
                CodexSandboxSetupProcessLauncher.StartFailedCode);
            await VerifyLauncherFailureAsync(
                helperPath,
                request,
                RecordingCodexSandboxSetupProcessMode.NonzeroExit,
                CodexSandboxSetupProcessLauncher.NonzeroExitCode);

            var timeoutFactory = new RecordingCodexSandboxSetupProcessFactory(
                RecordingCodexSandboxSetupProcessMode.NeverExits);
            var timeoutLauncher = CreateRecordingLauncher(
                timeoutFactory,
                helperPath,
                TimeSpan.FromMilliseconds(20));
            var timeout = await timeoutLauncher.LaunchAsync(
                new RecordingCodexSandboxSetupHelperLease(helperPath),
                request,
                CancellationToken.None);
            if (timeout.Succeeded
                || timeout.ErrorCode != CodexSandboxSetupProcessLauncher.TimeoutCode
                || timeoutFactory.StartCount != 1
                || timeoutFactory.LastProcess?.KillCount != 1)
            {
                _failures.Add("Codex sandbox helper timeout was not bounded and cleaned up");
            }

            var cancellationFactory = new RecordingCodexSandboxSetupProcessFactory(
                RecordingCodexSandboxSetupProcessMode.NeverExits);
            var cancellationLauncher = CreateRecordingLauncher(
                cancellationFactory,
                helperPath,
                TimeSpan.FromSeconds(1));
            using (var cancellation = new CancellationTokenSource(TimeSpan.FromMilliseconds(20)))
            {
                var cancelled = await cancellationLauncher.LaunchAsync(
                    new RecordingCodexSandboxSetupHelperLease(helperPath),
                    request,
                    cancellation.Token);
                if (cancelled.Succeeded
                    || cancelled.ErrorCode != CodexSandboxSetupProcessLauncher.CancelledCode
                    || cancellationFactory.LastProcess?.KillCount != 1)
                {
                    _failures.Add("Codex sandbox helper cancellation was not bounded and cleaned up");
                }
            }

            var preStartFactory = new RecordingCodexSandboxSetupProcessFactory(
                RecordingCodexSandboxSetupProcessMode.Success);
            var preStartLease = new RecordingCodexSandboxSetupHelperLease(
                helperPath,
                failValidationCall: 1);
            var preStart = await CreateRecordingLauncher(preStartFactory, helperPath).LaunchAsync(
                preStartLease,
                request,
                CancellationToken.None);
            if (preStart.Succeeded
                || preStart.ErrorCode != CodexSandboxSetupProcessLauncher.IdentityChangedCode
                || preStartFactory.StartCount != 0)
            {
                _failures.Add("Codex sandbox helper identity drift did not fail before UAC");
            }

            var postStartFactory = new RecordingCodexSandboxSetupProcessFactory(
                RecordingCodexSandboxSetupProcessMode.NeverExits);
            var postStartLease = new RecordingCodexSandboxSetupHelperLease(
                helperPath,
                failValidationCall: 2);
            var postStart = await CreateRecordingLauncher(postStartFactory, helperPath).LaunchAsync(
                postStartLease,
                request,
                CancellationToken.None);
            if (postStart.Succeeded
                || postStart.ErrorCode != CodexSandboxSetupProcessLauncher.IdentityChangedCode
                || postStartFactory.StartCount != 1
                || postStartFactory.LastProcess?.KillCount != 1)
            {
                _failures.Add("post-start Codex sandbox helper identity drift was not cleaned up");
            }

            var imageFactory = new RecordingCodexSandboxSetupProcessFactory(
                RecordingCodexSandboxSetupProcessMode.NeverExits);
            var imageLease = new RecordingCodexSandboxSetupHelperLease(
                helperPath,
                rejectProcessImage: true);
            var imageMismatch = await CreateRecordingLauncher(imageFactory, helperPath).LaunchAsync(
                imageLease,
                request,
                CancellationToken.None);
            if (imageMismatch.Succeeded
                || imageMismatch.ErrorCode != CodexSandboxSetupProcessLauncher.IdentityChangedCode
                || imageFactory.LastProcess?.KillCount != 1)
            {
                _failures.Add("Codex sandbox process image identity mismatch was not fail-closed");
            }

            var readbackFactory = new RecordingCodexSandboxSetupProcessFactory(
                RecordingCodexSandboxSetupProcessMode.ReadbackFailure);
            var readbackLauncher = CreateRecordingLauncher(
                readbackFactory,
                helperPath);
            var readback = await readbackLauncher.LaunchAsync(
                new RecordingCodexSandboxSetupHelperLease(helperPath),
                request,
                CancellationToken.None);
            if (readback.Succeeded
                || readback.ErrorCode != CodexSandboxSetupProcessLauncher.ReadbackFailedCode
                || readbackFactory.LastProcess?.KillCount != 1)
            {
                _failures.Add("Codex sandbox post-start readback did not fail closed");
            }
        }
        finally
        {
            try
            {
                Directory.Delete(root, recursive: true);
            }
            catch (DirectoryNotFoundException)
            {
            }
            catch (IOException)
            {
            }
            catch (UnauthorizedAccessException)
            {
            }
        }
    }

    private void ExpectHelperResolverFailure(
        ICodexSandboxSetupHelperResolver resolver,
        string expectedCode)
    {
        try
        {
            using var lease = resolver.Resolve();
        }
        catch (InvalidOperationException exception)
            when (string.Equals(exception.Message, expectedCode, StringComparison.Ordinal))
        {
            return;
        }
        _failures.Add("Codex sandbox helper resolver negative case did not fail closed");
    }

    private async Task VerifyLauncherFailureAsync(
        string helperPath,
        PinnedCodexSandboxSetupRequest request,
        RecordingCodexSandboxSetupProcessMode mode,
        string expectedCode)
    {
        var factory = new RecordingCodexSandboxSetupProcessFactory(mode);
        var result = await CreateRecordingLauncher(factory, helperPath).LaunchAsync(
            new RecordingCodexSandboxSetupHelperLease(helperPath),
            request,
            CancellationToken.None);
        if (result.Succeeded
            || !string.Equals(result.ErrorCode, expectedCode, StringComparison.Ordinal)
            || factory.StartCount != 1)
        {
            _failures.Add("Codex sandbox helper launch failure mapping was not deterministic");
        }
    }

    private static CodexSandboxSetupProcessLauncher CreateRecordingLauncher(
        RecordingCodexSandboxSetupProcessFactory factory,
        string helperPath,
        TimeSpan? timeout = null)
    {
        _ = helperPath;
        return new CodexSandboxSetupProcessLauncher(
            factory,
            timeout ?? TimeSpan.FromSeconds(1),
            TimeSpan.FromMilliseconds(100));
    }

    private void VerifyCodexSandboxSetupRequestContract()
    {
        var codexExecutable = Environment.GetEnvironmentVariable("HOVERPOCKET_CODEX_BIN");
        if (string.IsNullOrWhiteSpace(codexExecutable) || !File.Exists(codexExecutable))
        {
            return;
        }

        var now = DateTimeOffset.UtcNow;
        using var pinned = CodexSandboxSetupRequestBuilder.Create(codexExecutable, now);
        var decoded = HoverPocket.CodexSandboxSetup.Contracts.SetupRequestContract.DecodeAndValidate(
            pinned.Encoded.Base64Json,
            pinned.Encoded.Sha256,
            pinned.Encoded.Nonce,
            now.AddSeconds(1));
        if (decoded.HostProcessId != Environment.ProcessId
            || !pinned.HelperArguments.SequenceEqual(
                new[]
                {
                    "--setup-request",
                    pinned.Encoded.Base64Json,
                    "--request-sha256",
                    pinned.Encoded.Sha256,
                    "--nonce",
                    pinned.Encoded.Nonce,
                },
                StringComparer.Ordinal)
            || decoded.Artifacts.Count
                != HoverPocket.CodexSandboxSetup.Contracts.CodexVendorClosure.Artifacts.Count
            || decoded.Artifacts.Select(artifact => artifact.HandleValue).Distinct().Count()
                != decoded.Artifacts.Count)
        {
            _failures.Add("Codex sandbox setup request was not bound to pinned source handles");
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
            || defaults.CapabilityDataRetentionPeriod != CapabilityDataRetentionPeriod.NinetyDays
            || defaults.VoiceEnabled
            || defaults.VoiceProviderId != VoiceProviderIds.Off
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

internal enum RecordingCodexSandboxSetupProcessMode
{
    Success,
    NonzeroExit,
    NeverExits,
    ReadbackFailure,
    UacCancelled,
    StartFailure,
}

internal sealed class RecordingCodexSandboxSetupHelperLease : ICodexSandboxSetupHelperLease
{
    private readonly int? _failValidationCall;
    private readonly bool _rejectProcessImage;

    internal RecordingCodexSandboxSetupHelperLease(
        string fullPath,
        int? failValidationCall = null,
        bool rejectProcessImage = false)
    {
        FullPath = fullPath;
        _failValidationCall = failValidationCall;
        _rejectProcessImage = rejectProcessImage;
    }

    public string FullPath { get; }

    public CodexSandboxSetupFileIdentity Identity => new(1, 1);

    internal int ValidateCount { get; private set; }

    internal int ProcessImageValidationCount { get; private set; }

    public void ValidateIdentity()
    {
        ValidateCount += 1;
        if (_failValidationCall == ValidateCount)
        {
            throw new InvalidOperationException(CodexSandboxSetupHelperResolver.IdentityChangedCode);
        }
    }

    public void ValidateProcessImage(string processImagePath)
    {
        ProcessImageValidationCount += 1;
        if (_rejectProcessImage
            || !string.Equals(processImagePath, FullPath, StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException(CodexSandboxSetupHelperResolver.IdentityChangedCode);
        }
    }

    public void Dispose()
    {
    }
}

internal sealed class RecordingCodexSandboxSetupProcessFactory : ICodexSandboxSetupProcessFactory
{
    private readonly RecordingCodexSandboxSetupProcessMode _mode;

    internal RecordingCodexSandboxSetupProcessFactory(
        RecordingCodexSandboxSetupProcessMode mode)
    {
        _mode = mode;
    }

    internal int StartCount { get; private set; }

    internal ProcessStartInfo? LastStartInfo { get; private set; }

    internal RecordingCodexSandboxSetupProcess? LastProcess { get; private set; }

    public ICodexSandboxSetupProcess Start(ProcessStartInfo startInfo)
    {
        StartCount += 1;
        LastStartInfo = startInfo;
        if (_mode == RecordingCodexSandboxSetupProcessMode.UacCancelled)
        {
            throw new Win32Exception(1223);
        }
        if (_mode == RecordingCodexSandboxSetupProcessMode.StartFailure)
        {
            throw new Win32Exception(5);
        }

        LastProcess = new RecordingCodexSandboxSetupProcess(
            _mode,
            startInfo.FileName);
        return LastProcess;
    }
}

internal sealed class RecordingCodexSandboxSetupProcess : ICodexSandboxSetupProcess
{
    private readonly RecordingCodexSandboxSetupProcessMode _mode;
    private readonly string _imagePath;

    internal RecordingCodexSandboxSetupProcess(
        RecordingCodexSandboxSetupProcessMode mode,
        string imagePath)
    {
        _mode = mode;
        _imagePath = imagePath;
    }

    public bool HasExited { get; private set; }

    public int ExitCode => _mode == RecordingCodexSandboxSetupProcessMode.NonzeroExit ? 17 : 0;

    internal int KillCount { get; private set; }

    public async Task WaitForExitAsync(CancellationToken cancellationToken)
    {
        if (HasExited)
        {
            return;
        }
        if (_mode is RecordingCodexSandboxSetupProcessMode.NeverExits
            or RecordingCodexSandboxSetupProcessMode.ReadbackFailure)
        {
            await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
            return;
        }
        HasExited = true;
    }

    public string? ReadImagePath() =>
        _mode == RecordingCodexSandboxSetupProcessMode.ReadbackFailure
            ? null
            : _imagePath;

    public bool TryKill()
    {
        KillCount += 1;
        HasExited = true;
        return true;
    }

    public void Dispose()
    {
    }
}

internal sealed class InMemoryCodexGenerationSandboxProvisioner
    : ICodexGenerationSandboxProvisioner
{
    private bool _ready;

    public int ProvisionCount { get; private set; }

    public CodexGenerationSandboxProvisioningState Check() => new(
        _ready ? "ready" : "not_ready",
        _ready,
        TrustedExecutableInstalled: _ready,
        SetupAvailable: true,
        RepairAvailable: _ready,
        RestartRequired: _ready,
        ErrorCode: _ready ? null : "GENERATOR_CODEX_NOT_INSTALLED",
        CodexGenerationSandboxLease.SetupVersion,
        RuntimeElevationRequired: false);

    public CodexGenerationSandboxProvisioningState Refresh() => Check();

    public Task<CodexGenerationSandboxProvisioningState> ProvisionAsync(
        string sourceExecutable,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!string.Equals(sourceExecutable, @"C:\fixture\codex.exe", StringComparison.Ordinal))
        {
            throw new InvalidOperationException("Unexpected Codex fixture path.");
        }
        ProvisionCount += 1;
        _ready = true;
        return Task.FromResult(Check());
    }
}
