using System.Windows;
using Velopack;
using Velopack.Sources;

namespace HoverPocket.Shell.Services;

internal sealed class UpdaterService
{
    public const string AppId = "HoverPocketWin";
    public const string WindowsChannel = "win";
    public const string WindowsFeedFileName = "releases.win.json";
    public const string GitHubRepositoryUrl = "https://github.com/shotaro311/hover-pocket";

    private readonly SemaphoreSlim _gate = new(1, 1);
    private UpdaterStatusSnapshot _snapshot = UpdaterStatusSnapshot.Idle();

    public event EventHandler<UpdaterCheckResult>? StartupUpdateAvailable;

    public UpdaterStatusSnapshot Snapshot => _snapshot;

    public async Task<UpdaterCheckResult> CheckWithPromptsAsync(Window? owner = null, CancellationToken cancellationToken = default)
    {
        if (!await _gate.WaitAsync(0, cancellationToken))
        {
            var busy = UpdaterCheckResult.Busy();
            ShowInfo(owner, busy.Title, busy.Message);
            return busy;
        }

        try
        {
            SetSnapshot("checking", "Checking for updates...");
            var manager = CreateGitHubUpdateManager();
            if (!manager.IsInstalled)
            {
                var notInstalled = UpdaterCheckResult.NotInstalled();
                SetSnapshot("idle", notInstalled.Message);
                ShowInfo(owner, notInstalled.Title, notInstalled.Message);
                return notInstalled;
            }

            var update = await manager.CheckForUpdatesAsync();
            if (update is null)
            {
                var noUpdate = UpdaterCheckResult.NoUpdate();
                SetSnapshot("idle", noUpdate.Message);
                ShowInfo(owner, noUpdate.Title, noUpdate.Message);
                return noUpdate;
            }

            var version = update.TargetFullRelease.Version.ToString();
            var download = ShowQuestion(
                owner,
                "HoverPocket Update",
                $"HoverPocket {version} is available. Download this update now?");
            if (!download)
            {
                var cancelled = UpdaterCheckResult.Available(version, "Update download was cancelled.");
                SetSnapshot("available", cancelled.Message);
                return cancelled;
            }

            SetSnapshot("downloading", $"Downloading HoverPocket {version}...");
            await manager.DownloadUpdatesAsync(update, progress =>
            {
                SetSnapshot("downloading", $"Downloading HoverPocket {version}... {progress}%");
            }, cancellationToken);

            var restart = ShowQuestion(
                owner,
                "Restart HoverPocket",
                "The update has been downloaded. Apply it and restart HoverPocket now?");
            if (!restart)
            {
                var downloaded = UpdaterCheckResult.DownloadedUpdate(version);
                SetSnapshot("downloaded", downloaded.Message);
                ShowInfo(owner, downloaded.Title, downloaded.Message);
                return downloaded;
            }

            SetSnapshot("applying", $"Applying HoverPocket {version}...");
            manager.ApplyUpdatesAndRestart(update.TargetFullRelease);
            return UpdaterCheckResult.ApplyingUpdate(version);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            var failed = UpdaterCheckResult.Failed(SanitizeMessage(ex.Message));
            SetSnapshot("failed", failed.Message);
            ShowInfo(owner, failed.Title, failed.Message);
            return failed;
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task CheckOnStartupAsync(CancellationToken cancellationToken = default)
    {
        if (!await _gate.WaitAsync(0, cancellationToken))
        {
            return;
        }

        try
        {
            await Task.Delay(TimeSpan.FromSeconds(2), cancellationToken);
            var manager = CreateGitHubUpdateManager();
            if (!manager.IsInstalled)
            {
                SetSnapshot("idle", "Velopack install not detected.");
                return;
            }

            SetSnapshot("checking", "Checking for updates...");
            var update = await manager.CheckForUpdatesAsync();
            if (update is null)
            {
                SetSnapshot("idle", "HoverPocket is up to date.");
                return;
            }

            var result = UpdaterCheckResult.Available(
                update.TargetFullRelease.Version.ToString(),
                $"HoverPocket {update.TargetFullRelease.Version} is available.");
            SetSnapshot("available", result.Message);
            StartupUpdateAvailable?.Invoke(this, result);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            SetSnapshot("failed", SanitizeMessage(ex.Message));
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task<UpdaterCheckResult> CheckDryRunAsync(
        IUpdateSource source,
        Velopack.Locators.IVelopackLocator locator,
        CancellationToken cancellationToken = default)
    {
        var manager = new UpdateManager(source, options: CreateWindowsUpdateOptions(), locator: locator);
        if (!manager.IsInstalled)
        {
            return UpdaterCheckResult.NotInstalled();
        }

        var update = await manager.CheckForUpdatesAsync();
        cancellationToken.ThrowIfCancellationRequested();
        return update is null
            ? UpdaterCheckResult.NoUpdate()
            : UpdaterCheckResult.Available(
                update.TargetFullRelease.Version.ToString(),
                $"HoverPocket {update.TargetFullRelease.Version} is available.");
    }

    private static UpdateManager CreateGitHubUpdateManager()
    {
        return new UpdateManager(
            new GithubSource(GitHubRepositoryUrl, string.Empty, prerelease: false),
            options: CreateWindowsUpdateOptions());
    }

    private static UpdateOptions CreateWindowsUpdateOptions()
    {
        return new UpdateOptions { ExplicitChannel = WindowsChannel };
    }

    private static void ShowInfo(Window? owner, string title, string message)
    {
        if (owner is null)
        {
            System.Windows.MessageBox.Show(message, title, MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }

        System.Windows.MessageBox.Show(owner, message, title, MessageBoxButton.OK, MessageBoxImage.Information);
    }

    private static bool ShowQuestion(Window? owner, string title, string message)
    {
        var result = owner is null
            ? System.Windows.MessageBox.Show(message, title, MessageBoxButton.YesNo, MessageBoxImage.Question)
            : System.Windows.MessageBox.Show(owner, message, title, MessageBoxButton.YesNo, MessageBoxImage.Question);
        return result == MessageBoxResult.Yes;
    }

    private static string SanitizeMessage(string message)
    {
        return string.IsNullOrWhiteSpace(message) ? "Update check failed." : message;
    }

    private void SetSnapshot(string status, string message)
    {
        _snapshot = new UpdaterStatusSnapshot(status, message);
    }
}

internal sealed record UpdaterStatusSnapshot(string Status, string Message)
{
    public static UpdaterStatusSnapshot Idle() => new("idle", "Ready.");
}

internal sealed record UpdaterCheckResult(
    string Status,
    bool UpdateAvailable,
    string? Version,
    string Title,
    string Message,
    bool Downloaded = false,
    bool Applying = false)
{
    public static UpdaterCheckResult Busy() =>
        new("busy", false, null, "Update Check", "An update check is already running.");

    public static UpdaterCheckResult NotInstalled() =>
        new(
            "not-installed",
            false,
            null,
            "Updater Unavailable",
            "Install HoverPocket with the Velopack setup package before checking for updates.");

    public static UpdaterCheckResult NoUpdate() =>
        new("no-update", false, null, "No Update", "HoverPocket is up to date.");

    public static UpdaterCheckResult Available(string version, string message) =>
        new("update-available", true, version, "Update Available", message);

    public static UpdaterCheckResult DownloadedUpdate(string version) =>
        new(
            "downloaded",
            true,
            version,
            "Update Downloaded",
            "The update was downloaded. It will not be applied until you choose to restart from the update prompt.");

    public static UpdaterCheckResult ApplyingUpdate(string version) =>
        new("applying", true, version, "Applying Update", "HoverPocket is applying the update and restarting.", Applying: true);

    public static UpdaterCheckResult Failed(string message) =>
        new("failed", false, null, "Update Failed", message);
}
