using System.Windows;
using HoverPocket.Shell.PocketApps;
using HoverPocket.Shell.Services;
using Velopack;

namespace HoverPocket.Shell;

internal static class Program
{
    [STAThread]
    public static void Main(string[] args)
    {
        if (args.Contains(CodexCredentialBrokerHelper.Argument, StringComparer.Ordinal))
        {
            Environment.ExitCode = CodexCredentialBrokerHelper.Run();
            return;
        }

        var options = StartupOptions.Parse(args);
        if (!options.IsVerify && !options.SecondInstanceProbe)
        {
            VelopackApp.Build().Run();
            ArpDisplayVersionRepairService.TryRepairFromCurrentLocator();
        }

        var app = new App();
        app.Run();
    }
}
