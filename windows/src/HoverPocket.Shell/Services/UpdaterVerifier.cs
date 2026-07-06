using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using HoverPocket.Shell.Verification;
using Velopack.Locators;
using Velopack.Sources;

namespace HoverPocket.Shell.Services;

internal sealed class UpdaterVerifier
{
    private const string CurrentVersion = "0.2.0";
    private const string NextVersion = "0.2.1";
    private readonly List<string> _failures = [];
    private readonly UpdaterService _updaterService = new();

    public int Run()
    {
        VerifyAsync().GetAwaiter().GetResult();
        if (_failures.Count == 0)
        {
            VerifyConsole.WriteLine("PASS updater verify: local feed dry-run no-update and update-available cases");
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
        await VerifyCaseAsync(
            "no-update",
            [CurrentVersion],
            expectUpdate: false);
        await VerifyCaseAsync(
            "update-available",
            [CurrentVersion, NextVersion],
            expectUpdate: true);
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
            Path.Combine(feedDirectory, "releases.win.json"),
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
