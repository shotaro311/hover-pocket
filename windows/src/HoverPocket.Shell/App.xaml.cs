using System.Windows;
using HoverPocket.Shell.Configuration;
using HoverPocket.Shell.Providers;
using HoverPocket.Shell.Providers.AiLane;
using HoverPocket.Shell.Providers.Calculator;
using HoverPocket.Shell.Providers.Calendar;
using HoverPocket.Shell.Providers.Clipboard;
using HoverPocket.Shell.Providers.Sticky;
using HoverPocket.Shell.Providers.Timer;
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

    protected override void OnStartup(StartupEventArgs e)
    {
        var options = StartupOptions.Parse(e.Args);
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
            Environment.ExitCode = new SettingsVerifier().Run();
            Shutdown();
            return;
        }

        if (options.VerifyAiLane)
        {
            VerifyConsole.AttachParent();
            Environment.ExitCode = new AiLaneVerifier().Run();
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

        if (options.VerifyUpdater)
        {
            VerifyConsole.AttachParent();
            Environment.ExitCode = new UpdaterVerifier().Run();
            Shutdown();
            return;
        }

        if (!SingleInstanceGate.TryAcquire(out var singleInstanceGate))
        {
            Environment.ExitCode = 0;
            Shutdown();
            return;
        }

        ArgumentNullException.ThrowIfNull(singleInstanceGate);
        _singleInstanceGate = singleInstanceGate;
        var providerRegistry = ProviderRegistry.CreateDefault();
        var settingsStore = options.VerifyShell || options.VerifyDisplay || options.VerifyUi
            ? UserSettingsStore.CreateTemporary("Verify")
            : new UserSettingsStore();
        var updaterService = new UpdaterService();
        _updaterService = updaterService;
        var enablePanelWebView = !options.VerifyShell && !options.VerifyDisplay;
        var shellController = new HoverShellController(
            Dispatcher,
            options.Settings,
            providerRegistry,
            settingsStore,
            enablePanelWebView,
            updaterService);
        _shellController = shellController;
        singleInstanceGate.ShowPanelRequested += (_, _) =>
            Dispatcher.BeginInvoke(shellController.ShowPanelFromUser);
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
        if (shellController.PanelBridgeController.CurrentSettings.AutoCheckForUpdates)
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
