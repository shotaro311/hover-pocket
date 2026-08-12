using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using HoverPocket.Shell.Verification;
using Microsoft.Win32;
using Velopack.Locators;
using Velopack.Sources;

namespace HoverPocket.Shell.Services;

internal sealed class UpdaterVerifier
{
    private const string CurrentVersion = "0.2.6";
    private const string NextVersion = "0.2.7";
    private readonly List<string> _failures = [];
    private readonly UpdaterService _updaterService = new();

    public int Run()
    {
        VerifyAsync().GetAwaiter().GetResult();
        if (_failures.Count == 0)
        {
            VerifyConsole.WriteLine("PASS updater verify: local feed dry-run and ARP DisplayVersion repair cases");
            return 0;
        }

        VerifyConsole.WriteLine("FAIL updater verify:");
        foreach (var failure in _failures)
        {
            VerifyConsole.WriteLine($"- {failure}");
        }

        return 1;
    }

    private async Task VerifyAsync()
    {
        VerifyWindowsFeedMetadata();
        VerifyArpDisplayVersionRepair();
        await VerifyCaseAsync(
            "no-update",
            [CurrentVersion],
            expectUpdate: false);
        await VerifyCaseAsync(
            "update-available",
            [CurrentVersion, NextVersion],
            expectUpdate: true);
    }

    private void VerifyArpDisplayVersionRepair()
    {
        var testRoot = Path.Combine(
            "Software",
            "HoverPocket",
            "UpdaterVerify",
            Guid.NewGuid().ToString("N"));
        var testAppId = "HoverPocketWin.Verify";
        var installRoot = Path.Combine(Path.GetTempPath(), "HoverPocket", "Installed");
        var keyPath = $@"{testRoot}\{testAppId}";
        try
        {
            using (var currentUser = RegistryKey.OpenBaseKey(
                       RegistryHive.CurrentUser,
                       RegistryView.Registry64))
            using (var appKey = currentUser.CreateSubKey(keyPath, writable: true))
            {
                appKey.SetValue("DisplayVersion", CurrentVersion, RegistryValueKind.String);
                appKey.SetValue("InstallLocation", installRoot, RegistryValueKind.String);
                appKey.SetValue("PreservedValue", "keep", RegistryValueKind.String);
            }

            var repairResults = ArpDisplayVersionRepairService.Repair(
                testRoot,
                testAppId,
                installRoot,
                NextVersion);
            using (var currentUser = RegistryKey.OpenBaseKey(
                       RegistryHive.CurrentUser,
                       RegistryView.Registry64))
            using (var appKey = currentUser.OpenSubKey(keyPath, writable: true))
            {
                if (!string.Equals(appKey?.GetValue("DisplayVersion") as string, NextVersion, StringComparison.Ordinal)
                    || repairResults.All(result => result.Status != ArpDisplayVersionRepairStatus.Updated))
                {
                    _failures.Add("arp repair: stale DisplayVersion was not updated");
                }
                else
                {
                    VerifyConsole.WriteLine("updater_arp_repair_stale_to_current=ok");
                }

                if (!string.Equals(appKey?.GetValue("PreservedValue") as string, "keep", StringComparison.Ordinal)
                    || !string.Equals(appKey?.GetValue("InstallLocation") as string, installRoot, StringComparison.Ordinal))
                {
                    _failures.Add("arp repair: non-DisplayVersion values changed");
                }
                else
                {
                    VerifyConsole.WriteLine("updater_arp_repair_other_values_preserved=ok");
                }

                appKey?.SetValue("DisplayVersion", CurrentVersion, RegistryValueKind.String);
                appKey?.SetValue(
                    "InstallLocation",
                    Path.Combine(Path.GetTempPath(), "HoverPocket", "OtherInstall"),
                    RegistryValueKind.String);
            }

            _ = ArpDisplayVersionRepairService.Repair(
                testRoot,
                testAppId,
                installRoot,
                NextVersion);
            using (var currentUser = RegistryKey.OpenBaseKey(
                       RegistryHive.CurrentUser,
                       RegistryView.Registry64))
            using (var appKey = currentUser.OpenSubKey(keyPath))
            {
                if (!string.Equals(appKey?.GetValue("DisplayVersion") as string, CurrentVersion, StringComparison.Ordinal))
                {
                    _failures.Add("arp repair: path mismatch changed DisplayVersion");
                }
                else
                {
                    VerifyConsole.WriteLine("updater_arp_repair_path_mismatch_noop=ok");
                }
            }
        }
        catch (Exception ex)
        {
            _failures.Add($"arp repair: {ex.GetType().Name}");
        }
        finally
        {
            foreach (var view in new[] { RegistryView.Registry64, RegistryView.Registry32 })
            {
                try
                {
                    using var currentUser = RegistryKey.OpenBaseKey(RegistryHive.CurrentUser, view);
                    currentUser.DeleteSubKeyTree(testRoot, throwOnMissingSubKey: false);
                }
                catch (Exception ex)
                {
                    _failures.Add($"arp repair cleanup ({view}): {ex.GetType().Name}");
                }
            }

            if (_failures.All(failure => !failure.StartsWith("arp repair cleanup", StringComparison.Ordinal)))
            {
                VerifyConsole.WriteLine("updater_arp_repair_test_key_cleanup=ok");
            }
        }
    }

    private void VerifyWindowsFeedMetadata()
    {
        if (!string.Equals(UpdaterService.WindowsChannel, "win", StringComparison.Ordinal))
        {
            _failures.Add($"feed metadata: expected Windows channel win, got {UpdaterService.WindowsChannel}");
        }

        if (!string.Equals(UpdaterService.WindowsFeedFileName, "releases.win.json", StringComparison.Ordinal))
        {
            _failures.Add($"feed metadata: expected releases.win.json, got {UpdaterService.WindowsFeedFileName}");
        }

        if (UpdaterService.GitHubRepositoryUrl.Contains("/latest/", StringComparison.OrdinalIgnoreCase))
        {
            _failures.Add("feed metadata: updater repository URL must not use GitHub latest download URLs");
        }
    }

    private async Task VerifyCaseAsync(string label, IReadOnlyList<string> versions, bool expectUpdate)
    {
        var root = Path.Combine(Path.GetTempPath(), "HoverPocket", "UpdaterVerify", label, Guid.NewGuid().ToString("N"));
        var feed = Path.Combine(root, "feed");
        Directory.CreateDirectory(feed);
        WriteFeed(feed, versions);

        var locator = new TestVelopackLocator(
            UpdaterService.AppId,
            CurrentVersion,
            root,
            logger: null!);
        var result = await _updaterService.CheckDryRunAsync(
            new SimpleFileSource(new DirectoryInfo(feed)),
            locator);

        VerifyConsole.WriteLine($"updater_{label}_feed={feed}");
        VerifyConsole.WriteLine($"updater_{label}_status={result.Status}");
        if (result.UpdateAvailable != expectUpdate)
        {
            _failures.Add($"{label}: expected updateAvailable={expectUpdate}, got {result.UpdateAvailable}");
        }

        if (expectUpdate && result.Version != NextVersion)
        {
            _failures.Add($"{label}: expected version {NextVersion}, got {result.Version ?? "null"}");
        }
    }

    private static void WriteFeed(string feedDirectory, IReadOnlyList<string> versions)
    {
        var assets = new List<FeedAsset>();
        var releaseLines = new List<string>();
        foreach (var version in versions)
        {
            var fileName = $"{UpdaterService.AppId}-{version}-full.nupkg";
            var bytes = Encoding.UTF8.GetBytes($"{UpdaterService.AppId} {version}");
            File.WriteAllBytes(Path.Combine(feedDirectory, fileName), bytes);
            var sha1 = Convert.ToHexString(SHA1.HashData(bytes));
            var sha256 = Convert.ToHexString(SHA256.HashData(bytes));
            assets.Add(new FeedAsset(
                UpdaterService.AppId,
                version,
                "Full",
                fileName,
                sha1,
                sha256,
                bytes.Length));
            releaseLines.Add($"{sha1} {bytes.Length} {fileName}");
        }

        File.WriteAllText(
            Path.Combine(feedDirectory, UpdaterService.WindowsFeedFileName),
            JsonSerializer.Serialize(new Feed(assets), new JsonSerializerOptions { WriteIndented = false }));
        File.WriteAllLines(Path.Combine(feedDirectory, "RELEASES"), releaseLines);
    }

    private sealed record Feed(List<FeedAsset> Assets);

    private sealed record FeedAsset(
        string PackageId,
        string Version,
        string Type,
        string FileName,
        string SHA1,
        string SHA256,
        long Size);
}
