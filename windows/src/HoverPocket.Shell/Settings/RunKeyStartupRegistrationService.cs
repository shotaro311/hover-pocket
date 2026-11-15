using System.Diagnostics;
using System.IO;
using HoverPocket.Shell.Services;
using Microsoft.Win32;
using Velopack.Locators;

namespace HoverPocket.Shell.Settings;

internal sealed class RunKeyStartupRegistrationService : IStartupRegistrationService
{
    internal const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    internal const string ValueName = "HoverPocket";

    private readonly Func<string> _commandFactory;

    public RunKeyStartupRegistrationService()
        : this(BuildStartupCommand)
    {
    }

    internal RunKeyStartupRegistrationService(Func<string> commandFactory)
    {
        _commandFactory = commandFactory;
    }

    public bool IsRegistered()
    {
        using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath, writable: false);
        var value = key?.GetValue(ValueName) as string;
        return string.Equals(value, _commandFactory(), StringComparison.OrdinalIgnoreCase);
    }

    public void SetRegistered(bool enabled)
    {
        using var key = Registry.CurrentUser.CreateSubKey(RunKeyPath, writable: true)
            ?? throw new InvalidOperationException("HKCU Run key could not be opened.");

        if (enabled)
        {
            key.SetValue(ValueName, _commandFactory(), RegistryValueKind.String);
            return;
        }

        key.DeleteValue(ValueName, throwOnMissingValue: false);
    }

    private static string BuildStartupCommand()
    {
        var executablePath =
            InstalledLauncherPath()
            ?? Environment.ProcessPath
            ?? Process.GetCurrentProcess().MainModule?.FileName
            ?? Path.Combine(AppContext.BaseDirectory, "HoverPocket.Shell.exe");

        return $"\"{executablePath}\"";
    }

    // The installed app lives in <root>\current, the same target Velopack uses for Start Menu shortcuts; the
    // folder keeps its path across updates. When an installation exists, development builds register it too
    // instead of their own bin folder, which disappears when the build output changes.
    internal static string? InstalledLauncherPath()
    {
        try
        {
            if (VelopackLocator.IsCurrentSet)
            {
                var locator = VelopackLocator.Current;
                if (!locator.IsPortable
                    && string.Equals(locator.AppId, UpdaterService.AppId, StringComparison.Ordinal)
                    && !string.IsNullOrWhiteSpace(locator.RootAppDir)
                    && locator.CurrentlyInstalledVersion is not null)
                {
                    var launcher = Path.Combine(locator.RootAppDir, "current", "HoverPocket.Shell.exe");
                    if (File.Exists(launcher))
                    {
                        return launcher;
                    }
                }
            }
        }
        catch (Exception ex) when (ex is InvalidOperationException or IOException or UnauthorizedAccessException)
        {
        }

        var defaultLauncher = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            UpdaterService.AppId,
            "current",
            "HoverPocket.Shell.exe");
        return File.Exists(defaultLauncher) ? defaultLauncher : null;
    }
}
