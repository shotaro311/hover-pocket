using System.Windows;

namespace S3.WebView2Camera;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        Dispatcher.InvokeAsync(async () =>
        {
            var verify = e.Args.Any(arg => arg.Equals("--verify", StringComparison.OrdinalIgnoreCase));

            if (verify)
            {
                var code = await SpikeVerifier.RunAsync();
                Environment.ExitCode = code;
                Shutdown(code);
                return;
            }

            var window = new MainWindow();
            MainWindow = window;
            window.Closed += (_, _) => Shutdown(0);
            window.Show();
            await window.InitializeWebViewAsync();
        });
    }
}
