using System.Windows;
using HoverPocket.Shell.Capabilities;
using HoverPocket.Shell.Configuration;
using HoverPocket.Shell.Providers;
using HoverPocket.Shell.Providers.AiLane;
using HoverPocket.Shell.Providers.Calculator;
using HoverPocket.Shell.Providers.Calendar;
using HoverPocket.Shell.Providers.Clipboard;
using HoverPocket.Shell.Providers.Controls;
using HoverPocket.Shell.Providers.Sticky;
using HoverPocket.Shell.Providers.Timer;
using HoverPocket.Shell.Providers.CodexVoice;
using HoverPocket.Shell.Services;
using HoverPocket.Shell.Settings;
using HoverPocket.Shell.Verification;
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
    private int _voiceE2EShutdownState;

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
        if (FakeCodexAppServer.ShouldRun(e.Args))
        {
            Environment.ExitCode = FakeCodexAppServer.Run();
            Shutdown();
            return;
        }

        if (options.VerifyUiModel)
        {
            VerifyConsole.AttachParent();
            _ = RunUiModelVerificationAsync();
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
            Environment.ExitCode = new AiLaneVerifier().Run();
            Shutdown();
            return;
        }

        if (options.VerifyVoiceLaneLayout)
        {
            VerifyConsole.AttachParent();
            Environment.ExitCode = new VoiceLaneLayoutVerifier().Run();
            Shutdown();
            return;
        }

        if (options.VerifyCodexAppServer)
        {
            VerifyConsole.AttachParent();
            _ = RunCodexAppServerVerificationAsync();
            return;
        }

        if (options.VerifyCodexAppServerProtocol)
        {
            VerifyConsole.AttachParent();
            _ = RunCodexAppServerProtocolVerificationAsync();
            return;
        }

        if (options.VerifyCodexVoiceCoordinator)
        {
            VerifyConsole.AttachParent();
            _ = RunCodexVoiceCoordinatorVerificationAsync();
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
        var settingsStore = new UserSettingsStore(effectiveApplicationData);
        var updaterService = new UpdaterService(
            effectiveApplicationData.ExternalIntegrationsEnabled && !options.IsVerify);
        _updaterService = updaterService;
        var voiceE2EReceipt = CodexVoiceE2EReceiptStore.Create(effectiveApplicationData);
        var enablePanelWebView = !options.VerifyShell && !options.VerifyDisplay;
        var shellController = new HoverShellController(
            Dispatcher,
            options.Settings,
            providerRegistry,
            effectiveApplicationData,
            settingsStore,
            enablePanelWebView,
            options.EnableDevTools,
            options.IsVerify,
            updaterService,
            voiceE2EReceipt);
        _shellController = shellController;
        singleInstanceGate.ShowPanelRequested += (_, _) =>
            Dispatcher.BeginInvoke(shellController.ShowPanelFromUser);
        singleInstanceGate.StopRequested += (_, _) =>
            Dispatcher.BeginInvoke(BeginVoiceE2EShutdown);
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

        _trayIconService = new TrayIconService(shellController, updaterService);
        if (updaterService.IsEnabled
            && shellController.PanelBridgeController.CurrentSettings.AutoCheckForUpdates)
        {
            _ = updaterService.CheckOnStartupAsync();
        }
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _trayIconService?.Dispose();
        _shellController?.Dispose();
        _singleInstanceGate?.Dispose();
        base.OnExit(e);
    }

    private void BeginVoiceE2EShutdown()
    {
        if (Interlocked.Exchange(ref _voiceE2EShutdownState, 1) != 0)
        {
            return;
        }

        _ = CompleteVoiceE2EShutdownAsync();
    }

    private async Task CompleteVoiceE2EShutdownAsync()
    {
        try
        {
            if (_shellController is not null)
            {
                await _shellController.PrepareForApplicationShutdownAsync();
            }
        }
        catch (Exception)
        {
            Environment.ExitCode = 1;
        }
        finally
        {
            Shutdown();
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
        await RunVerificationSafelyAsync(() => verifier.RunAsync());
    }

    private Task RunSettingsVerificationAsync() =>
        RunVerificationSafelyAsync(() => new SettingsVerifier().RunAsync());

    private Task RunUiModelVerificationAsync() =>
        RunVerificationSafelyAsync(() => new UiModelVerifier().RunAsync());

    private Task RunCodexAppServerVerificationAsync() =>
        RunVerificationSafelyAsync(() => new CodexAppServerVerifier().RunAsync());

    private Task RunCodexAppServerProtocolVerificationAsync() =>
        RunVerificationSafelyAsync(() => new CodexAppServerProtocolVerifier().RunAsync());

    private Task RunCodexVoiceCoordinatorVerificationAsync() =>
        RunVerificationSafelyAsync(() => new CodexVoiceCoordinatorVerifier().RunAsync());

    private Task RunCalendarLiveVerificationAsync() =>
        RunVerificationSafelyAsync(() => new CalendarLiveVerifier().RunAsync());

    private async Task RunDisplayVerificationAsync()
    {
        if (_shellController is null)
        {
            Environment.ExitCode = 1;
            Shutdown();
            return;
        }

        var verifier = new DisplayVerifier(_shellController);
        await RunVerificationSafelyAsync(() => verifier.RunAsync());
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
        await RunVerificationSafelyAsync(() => verifier.RunAsync());
    }

    private async Task RunVerificationSafelyAsync(Func<Task<int>> verification)
    {
        try
        {
            Environment.ExitCode = await verification();
        }
        catch (Exception error)
        {
            VerifyConsole.WriteLine($"FAIL verifier exception: {error.GetType().Name}");
            Environment.ExitCode = 1;
        }
        finally
        {
            Shutdown();
        }
    }
}
