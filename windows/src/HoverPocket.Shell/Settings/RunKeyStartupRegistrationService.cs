using System.Diagnostics;
using System.IO;
using Microsoft.Win32;

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
            Environment.ProcessPath
            ?? Process.GetCurrentProcess().MainModule?.FileName
            ?? Path.Combine(AppContext.BaseDirectory, "HoverPocket.Shell.exe");

        return $"\"{executablePath}\"";
    }
}
