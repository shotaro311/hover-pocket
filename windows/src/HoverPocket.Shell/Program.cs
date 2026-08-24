using System.Windows;
using HoverPocket.Shell.Configuration;
using HoverPocket.Shell.Services;
using Velopack;

namespace HoverPocket.Shell;

internal static class Program
{
    [STAThread]
    public static void Main(string[] args)
    {
        var options = StartupOptions.Parse(args);
        var applicationData = HoverPocketApplicationData.Resolve(options);
        if (!options.IsVerify && !options.SecondInstanceProbe && !applicationData.IsIsolatedVoiceE2E)
        {
            VelopackApp.Build().Run();
            ArpDisplayVersionRepairService.TryRepairFromCurrentLocator();
        }

        var app = new App();
        app.ConfigureStartup(options, applicationData);
        app.Run();
    }
}
