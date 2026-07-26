using Microsoft.Win32;
using Velopack.Locators;
using Velopack.Logging;

namespace HoverPocket.Shell.Services;

internal static class ArpDisplayVersionRepairService
{
    internal const string UninstallRegistryBasePath =
        @"Software\Microsoft\Windows\CurrentVersion\Uninstall";

    internal static void TryRepairFromCurrentLocator()
    {
        if (!VelopackLocator.IsCurrentSet)
        {
            return;
        }

        var locator = VelopackLocator.Current;
        try
        {
            if (locator.IsPortable)
            {
                Log(locator, VelopackLogLevel.Debug, "ARP DisplayVersion self-heal skipped: portable package.");
                return;
            }

            if (!string.Equals(locator.AppId, UpdaterService.AppId, StringComparison.Ordinal)
                || string.IsNullOrWhiteSpace(locator.RootAppDir)
                || locator.CurrentlyInstalledVersion is null)
            {
                Log(locator, VelopackLogLevel.Debug, "ARP DisplayVersion self-heal skipped: not an installed HoverPocket package.");
                return;
            }

            var results = Repair(
                UninstallRegistryBasePath,
                UpdaterService.AppId,
                locator.RootAppDir,
                locator.CurrentlyInstalledVersion.ToString());
            foreach (var result in results)
            {
                var level = result.Status == ArpDisplayVersionRepairStatus.Failed
                    ? VelopackLogLevel.Warning
                    : VelopackLogLevel.Information;
                Log(
                    locator,
                    level,
                    $"ARP DisplayVersion self-heal: view={result.View}, status={result.Status}.",
                    result.Exception);
            }
        }
        catch (Exception ex)
        {
            Log(locator, VelopackLogLevel.Warning, "ARP DisplayVersion self-heal failed without blocking startup.", ex);
        }
    }

    internal static IReadOnlyList<ArpDisplayVersionRepairResult> Repair(
        string basePath,
        string appId,
        string installRoot,
        string version)
    {
        if (string.IsNullOrWhiteSpace(basePath)
            || string.IsNullOrWhiteSpace(appId)
            || string.IsNullOrWhiteSpace(installRoot)
            || string.IsNullOrWhiteSpace(version))
        {
            return
            [
                new ArpDisplayVersionRepairResult(
                    RegistryView.Default,
                    ArpDisplayVersionRepairStatus.InvalidInput)
            ];
        }

        return
        [
            RepairView(RegistryView.Registry64, basePath, appId, installRoot, version),
            RepairView(RegistryView.Registry32, basePath, appId, installRoot, version)
        ];
    }

    private static ArpDisplayVersionRepairResult RepairView(
        RegistryView view,
        string basePath,
        string appId,
        string installRoot,
        string version)
    {
        try
        {
            using var currentUser = RegistryKey.OpenBaseKey(RegistryHive.CurrentUser, view);
            using var appKey = currentUser.OpenSubKey($@"{basePath}\{appId}", writable: true);
            if (appKey is null)
            {
                return new ArpDisplayVersionRepairResult(
                    view,
                    ArpDisplayVersionRepairStatus.KeyMissing);
            }

            var registeredLocation = appKey.GetValue("InstallLocation") as string;
            if (!PathsMatch(registeredLocation, installRoot))
            {
                return new ArpDisplayVersionRepairResult(
                    view,
                    ArpDisplayVersionRepairStatus.InstallLocationMismatch);
            }

            var registeredVersion = appKey.GetValue("DisplayVersion") as string;
            if (string.Equals(registeredVersion, version, StringComparison.Ordinal))
            {
                return new ArpDisplayVersionRepairResult(
                    view,
                    ArpDisplayVersionRepairStatus.AlreadyCurrent);
            }

            appKey.SetValue("DisplayVersion", version, RegistryValueKind.String);
            return new ArpDisplayVersionRepairResult(
                view,
                ArpDisplayVersionRepairStatus.Updated);
        }
        catch (Exception ex)
        {
            return new ArpDisplayVersionRepairResult(
                view,
                ArpDisplayVersionRepairStatus.Failed,
                ex);
        }
    }

    private static bool PathsMatch(string? registeredLocation, string installRoot)
    {
        if (string.IsNullOrWhiteSpace(registeredLocation))
        {
            return false;
        }

        try
        {
            var registered = Path.TrimEndingDirectorySeparator(Path.GetFullPath(registeredLocation));
            var expected = Path.TrimEndingDirectorySeparator(Path.GetFullPath(installRoot));
            return string.Equals(registered, expected, StringComparison.OrdinalIgnoreCase);
        }
        catch (Exception) when (
            registeredLocation.IndexOfAny(Path.GetInvalidPathChars()) >= 0
            || installRoot.IndexOfAny(Path.GetInvalidPathChars()) >= 0)
        {
            return false;
        }
    }

    private static void Log(
        IVelopackLocator locator,
        VelopackLogLevel level,
        string message,
        Exception? exception = null)
    {
        try
        {
            locator.Log.Log(level, message, exception);
        }
        catch
        {
            // Registry repair and its diagnostics must never stop normal startup.
        }
    }
}

internal enum ArpDisplayVersionRepairStatus
{
    Updated,
    AlreadyCurrent,
    KeyMissing,
    InstallLocationMismatch,
    InvalidInput,
    Failed
}

internal sealed record ArpDisplayVersionRepairResult(
    RegistryView View,
    ArpDisplayVersionRepairStatus Status,
    Exception? Exception = null);
