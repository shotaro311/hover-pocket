using System.Windows;
using HoverPocket.Shell.Configuration;
using HoverPocket.Shell.PocketApps;
using HoverPocket.Shell.Services;
using Velopack;

namespace HoverPocket.Shell;

internal static class Program
{
    [STAThread]
    public static void Main(string[] args)
    {
        if (args.Length == 1 && args[0] == Providers.Assets.PdfRenderWorker.Argument)
        {
            Providers.Assets.PdfRenderWorker.Run();
            return;
        }
        if (args.Contains(CodexCredentialBrokerHelper.Argument, StringComparer.Ordinal))
        {
            Environment.ExitCode = CodexCredentialBrokerHelper.Run();
            return;
        }
        if (args.Contains(CodexCredentialBrokerHelper.GenerationArgument, StringComparer.Ordinal))
        {
            Environment.ExitCode = CodexCredentialBrokerHelper.RunForGeneration();
            return;
        }
        if (args.Contains(CodexCredentialBrokerGenerationProbe.Argument, StringComparer.Ordinal))
        {
            Environment.ExitCode = CodexCredentialBrokerGenerationProbe.Run();
            return;
        }

        var options = StartupOptions.Parse(args);
        var applicationData = HoverPocketApplicationData.Resolve(options);
        if (!options.IsVerify && !options.SecondInstanceProbe && !applicationData.IsIsolatedVoiceE2E)
        {
            VelopackApp.Build().Run();
            ArpDisplayVersionRepairService.TryRepairFromCurrentLocator();
        }

        if (!options.IsVerify && !options.SecondInstanceProbe && !applicationData.IsIsolatedVoiceE2E) AppDiagnostics.Start(applicationData.RootDirectory);
        var app = new App();
        app.DispatcherUnhandledException += (_, eventArgs) => AppDiagnostics.Record("dispatcher.unhandled", eventArgs.Exception);
        app.SessionEnding += (_, _) => AppDiagnostics.Record("windows.sessionEnding");
        app.ConfigureStartup(options, applicationData);
        app.Run();
    }
}
