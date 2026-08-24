using System.Windows;
using HoverPocket.Shell.Capabilities;
using HoverPocket.Shell.Configuration;
using HoverPocket.Shell.Providers;
using HoverPocket.Shell.Providers.Calculator;
using HoverPocket.Shell.Providers.Calendar;
using HoverPocket.Shell.Providers.Clipboard;
using HoverPocket.Shell.Providers.Controls;
using HoverPocket.Shell.Providers.Sticky;
using HoverPocket.Shell.Providers.Timer;
using HoverPocket.Shell.PocketApps;
using HoverPocket.Shell.Services;
using HoverPocket.Shell.Settings;
using HoverPocket.Shell.Verification;
using HoverPocket.Shell.Voice;
using HoverPocket.Shell.Windows;

namespace HoverPocket.Shell;

public partial class App : System.Windows.Application
{
    private SingleInstanceGate? _singleInstanceGate;
    private HoverShellController? _shellController;
    private TrayIconService? _trayIconService;
    private UpdaterService? _updaterService;
    private StartupOptions? _startupOptions;
    private HoverPocketApplicationData? _applicationData;
    private IOpenAIRealtimeCredentialStore? _openAIRealtimeCredentialStore;
    private GoogleOAuthCredentialStore? _googleOAuthCredentialStore;
    private VoiceE2EReceiptStore? _voiceE2EReceiptStore;

    internal void ConfigureStartup(
        StartupOptions options,
        HoverPocketApplicationData applicationData)
    {
        _startupOptions = options;
        _applicationData = applicationData;
    }

    protected override void OnStartup(StartupEventArgs e)
    {
        var options = _startupOptions ?? StartupOptions.Parse(e.Args);
        var applicationData = _applicationData ?? HoverPocketApplicationData.Resolve(options);
        base.OnStartup(e);

        ShutdownMode = ShutdownMode.OnExplicitShutdown;
        if (options.VerifyUiModel)
        {
            VerifyConsole.AttachParent();
            Environment.ExitCode = new UiModelVerifier().Run();
            Shutdown();
            return;
        }

        if (options.VerifySettings)
        {
            VerifyConsole.AttachParent();
            _ = RunSettingsVerificationAsync();
            return;
        }

        if (options.VerifyAiLane)
        {
            VerifyConsole.AttachParent();
            Environment.ExitCode = new LegacyAiLaneVerifier().Run();
            Shutdown();
            return;
        }

        if (options.VerifyVoice)
        {
            VerifyConsole.AttachParent();
            var foundationResult = new VoiceFoundationVerifier().Run();
            var realtimeResult = new OpenAIRealtimeVoiceVerifier().Run();
            Environment.ExitCode = foundationResult == 0 && realtimeResult == 0 ? 0 : 1;
            Shutdown();
            return;
        }

        if (options.VerifyVoiceE2EIsolation)
        {
            VerifyConsole.AttachParent();
            Environment.ExitCode = new VoiceE2EIsolationVerifier().Run();
            Shutdown();
            return;
        }

        if (options.VerifySticky)
        {
            VerifyConsole.AttachParent();
            Environment.ExitCode = new StickyVerifier().Run();
            Shutdown();
            return;
        }

        if (options.VerifyClipboard)
        {
            VerifyConsole.AttachParent();
            Environment.ExitCode = new ClipboardVerifier().Run();
            Shutdown();
            return;
        }

        if (options.VerifyControls)
        {
            VerifyConsole.AttachParent();
            Environment.ExitCode = new ControlsVerifier(
                options.ChangeBrightnessForVerify,
                options.TogglePlaybackForVerify,
                options.VerifyLivePreview,
                options.VerifyLivePreviewFallback).Run();
            Shutdown();
            return;
        }

        if (options.VerifyCalc || options.VerifyTimer || options.VerifyCalendar)
        {
            VerifyConsole.AttachParent();
            Environment.ExitCode = options.VerifyCalc
                ? new CalculatorVerifier().Run()
                : options.VerifyTimer
                    ? new TimerVerifier().Run()
                    : new CalendarVerifier().Run();
            Shutdown();
            return;
        }

        if (options.VerifyCalendarLive)
        {
            VerifyConsole.AttachParent();
            _ = RunCalendarLiveVerificationAsync();
            return;
        }

        if (options.VerifyCapabilities)
        {
            VerifyConsole.AttachParent();
            Environment.ExitCode = new CapabilityVerifier().Run();
            Shutdown();
            return;
        }

        if (options.VerifyPocketSurface)
        {
            VerifyConsole.AttachParent();
            var surfaceResult = new PocketSurfaceVerifier().Run();
            var packageResult = new PocketAppPackageVerifier().Run();
            var activationResult = PocketAppRuntimeActivationVerifier.Verify();
            Environment.ExitCode = surfaceResult == 0 && packageResult == 0 && activationResult == 0 ? 0 : 1;
            Shutdown();
            return;
        }

        if (options.VerifyBroker)
        {
            VerifyConsole.AttachParent();
            Environment.ExitCode = new CapabilityBrokerVerifier().Run();
            Shutdown();
            return;
        }

        if (options.VerifyUpdater)
        {
            VerifyConsole.AttachParent();
            Environment.ExitCode = new UpdaterVerifier().Run();
            Shutdown();
            return;
        }

        if (options.VerifyReleaseConfig)
        {
            VerifyConsole.AttachParent();
            Environment.ExitCode = new ReleaseConfigVerifier().Run();
            Shutdown();
            return;
        }

        var singleInstanceNames = applicationData.IsIsolatedVoiceE2E
            ? SingleInstanceNames.VoiceE2E
            : options.IsVerify
                ? SingleInstanceNames.Verification
                : SingleInstanceNames.Production;
        if (!SingleInstanceGate.TryAcquire(singleInstanceNames, out var singleInstanceGate))
        {
            Environment.ExitCode = 0;
            Shutdown();
            return;
        }

        ArgumentNullException.ThrowIfNull(singleInstanceGate);
        _singleInstanceGate = singleInstanceGate;
        var providerRegistry = ProviderRegistry.CreateDefault();
        var effectiveApplicationData = options.VerifyShell || options.VerifyDisplay || options.VerifyUi
            ? HoverPocketApplicationData.CreateTemporaryVerifier("Shell")
            : applicationData;
        _applicationData = effectiveApplicationData;
        var settingsStore = new UserSettingsStore(effectiveApplicationData.RootDirectory);
        EnsureVoiceE2EDefaults(settingsStore, providerRegistry, effectiveApplicationData);
        var isolatedVoiceE2EDefaults = effectiveApplicationData.IsIsolatedVoiceE2E
            ? effectiveApplicationData.CreateVoiceE2EDefaultSettings(providerRegistry.ProviderIds)
            : null;
        var updaterService = new UpdaterService();
        _updaterService = updaterService;
        _openAIRealtimeCredentialStore = new OpenAIRealtimeCredentialStore(
            effectiveApplicationData.OpenAIRealtimeCredentialTarget);
        _googleOAuthCredentialStore = new GoogleOAuthCredentialStore(
            effectiveApplicationData.GoogleOAuthCredentialTarget);
        _voiceE2EReceiptStore = effectiveApplicationData.IsIsolatedVoiceE2E
            ? new VoiceE2EReceiptStore(effectiveApplicationData.VoiceE2EReceiptPath)
            : null;
        var calendarStore = new CalendarStore(new GoogleOAuthService(_googleOAuthCredentialStore));
        IStartupRegistrationService startupRegistration = effectiveApplicationData.ExternalIntegrationsEnabled
            ? new RunKeyStartupRegistrationService()
            : new InMemoryStartupRegistrationService();
        var enablePanelWebView = !options.VerifyShell && !options.VerifyDisplay;
        var shellController = new HoverShellController(
            Dispatcher,
            options.Settings,
            providerRegistry,
            effectiveApplicationData,
            settingsStore,
            enablePanelWebView,
            options.EnableDevTools,
            updaterService,
            _openAIRealtimeCredentialStore,
            calendarStore,
            startupRegistration,
            _voiceE2EReceiptStore,
            isolatedVoiceE2EDefaults);
        _shellController = shellController;
        singleInstanceGate.ShowPanelRequested += (_, _) =>
            Dispatcher.BeginInvoke(shellController.ShowPanelFromUser);
        singleInstanceGate.StopRequested += (_, _) =>
            Dispatcher.BeginInvoke(new Action(Shutdown));
        shellController.Start();

        if (options.VerifyShell || options.VerifyDisplay || options.VerifyUi)
        {
            VerifyConsole.AttachParent();
            _ = options.VerifyDisplay
                ? RunDisplayVerificationAsync()
                : options.VerifyUi
                    ? RunUiVerificationAsync()
                    : RunShellVerificationAsync();
            return;
        }

        if (effectiveApplicationData.ExternalIntegrationsEnabled)
        {
            _trayIconService = new TrayIconService(shellController, updaterService);
            if (shellController.PanelBridgeController.CurrentSettings.AutoCheckForUpdates)
            {
                _ = updaterService.CheckOnStartupAsync();
            }
        }
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _trayIconService?.Dispose();
        _shellController?.Dispose();
        CleanupVoiceE2ECredentials();
        _singleInstanceGate?.Dispose();
        base.OnExit(e);
    }

    private static void EnsureVoiceE2EDefaults(
        UserSettingsStore settingsStore,
        ProviderRegistry providerRegistry,
        HoverPocketApplicationData applicationData)
    {
        if (!applicationData.IsIsolatedVoiceE2E || File.Exists(settingsStore.SettingsPath))
        {
            return;
        }
        settingsStore.Save(
            applicationData.CreateVoiceE2EDefaultSettings(providerRegistry.ProviderIds));
    }

    private void CleanupVoiceE2ECredentials()
    {
        if (_applicationData?.IsIsolatedVoiceE2E != true)
        {
            return;
        }
        var credentialCurrent = true;
        var googleCredentialCurrent = true;
        try
        {
            _openAIRealtimeCredentialStore?.Delete();
            _googleOAuthCredentialStore?.Delete();
            credentialCurrent = _openAIRealtimeCredentialStore?.HasCredential() == true;
            googleCredentialCurrent = _googleOAuthCredentialStore?.Load() is not null;
        }
        catch (InvalidOperationException)
        {
        }
        _voiceE2EReceiptStore?.RecordShutdown(credentialCurrent);
        if (credentialCurrent || googleCredentialCurrent)
        {
            Environment.ExitCode = 1;
        }
    }

    private async Task RunShellVerificationAsync()
    {
        if (_shellController is null)
        {
            Environment.ExitCode = 1;
            Shutdown();
            return;
        }

        var verifier = new ShellVerifier(_shellController);
        Environment.ExitCode = await verifier.RunAsync();
        Shutdown();
    }

    private async Task RunSettingsVerificationAsync()
    {
        Environment.ExitCode = await new SettingsVerifier().RunAsync();
        Shutdown();
    }

    private async Task RunCalendarLiveVerificationAsync()
    {
        Environment.ExitCode = await new CalendarLiveVerifier().RunAsync();
        Shutdown();
    }

    private async Task RunDisplayVerificationAsync()
    {
        if (_shellController is null)
        {
            Environment.ExitCode = 1;
            Shutdown();
            return;
        }

        var verifier = new DisplayVerifier(_shellController);
        Environment.ExitCode = await verifier.RunAsync();
        Shutdown();
    }

    private async Task RunUiVerificationAsync()
    {
        if (_shellController is null)
        {
            Environment.ExitCode = 1;
            Shutdown();
            return;
        }

        var verifier = new UiVerifier(_shellController);
        Environment.ExitCode = await verifier.RunAsync();
        Shutdown();
    }
}
