using System.Windows;
using HoverPocket.Shell.Services;
using HoverPocket.Shell.Verification;
using HoverPocket.Shell.Windows;

namespace HoverPocket.Shell;

public partial class App : System.Windows.Application
{
    private SingleInstanceGate? _singleInstanceGate;
    private HoverShellController? _shellController;
    private TrayIconService? _trayIconService;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        ShutdownMode = ShutdownMode.OnExplicitShutdown;
        var options = StartupOptions.Parse(e.Args);

        if (!SingleInstanceGate.TryAcquire(out var singleInstanceGate))
        {
            Environment.ExitCode = 0;
            Shutdown();
            return;
        }

        ArgumentNullException.ThrowIfNull(singleInstanceGate);
        _singleInstanceGate = singleInstanceGate;
        var shellController = new HoverShellController(Dispatcher, options.Settings);
        _shellController = shellController;
        singleInstanceGate.ShowPanelRequested += (_, _) =>
            Dispatcher.BeginInvoke(shellController.ShowPanelFromUser);
        shellController.Start();

        if (options.VerifyShell || options.VerifyDisplay)
        {
            VerifyConsole.AttachParent();
            _ = options.VerifyDisplay
                ? RunDisplayVerificationAsync()
                : RunShellVerificationAsync();
            return;
        }

        _trayIconService = new TrayIconService(shellController);
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
}
