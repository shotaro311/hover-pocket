using Drawing = System.Drawing;
using WinForms = System.Windows.Forms;

namespace HoverPocket.Shell.Services;

internal sealed class TrayIconService : IDisposable
{
    private readonly WinForms.NotifyIcon _notifyIcon;
    private readonly UpdaterService _updaterService;
    private readonly WinForms.ToolStripMenuItem _checkForUpdatesItem;

    public TrayIconService(Windows.HoverShellController shellController, UpdaterService updaterService)
    {
        _updaterService = updaterService;
        var menu = new WinForms.ContextMenuStrip();
        menu.Items.Add("Open Panel", null, (_, _) => shellController.ShowPanelFromUser());
        menu.Items.Add("Settings", null, (_, _) => shellController.OpenSettingsFromUser());
        _checkForUpdatesItem = new WinForms.ToolStripMenuItem("Check for Updates");
        _checkForUpdatesItem.Click += async (_, _) => await CheckForUpdatesFromTrayAsync();
        menu.Items.Add(_checkForUpdatesItem);
        menu.Items.Add(new WinForms.ToolStripSeparator());
        menu.Items.Add("Quit", null, (_, _) => System.Windows.Application.Current.Shutdown());

        // WPF has no first-party tray component; Microsoft documents WinForms NotifyIcon
        // as the standard managed notification-area API, so W1 uses it instead of raw Shell_NotifyIcon.
        _notifyIcon = new WinForms.NotifyIcon
        {
            ContextMenuStrip = menu,
            Icon = Drawing.SystemIcons.Application,
            Text = "HoverPocket",
            Visible = true
        };
        _notifyIcon.DoubleClick += (_, _) => shellController.ShowPanelFromUser();
        _updaterService.StartupUpdateAvailable += OnStartupUpdateAvailable;
    }

    public void Dispose()
    {
        _updaterService.StartupUpdateAvailable -= OnStartupUpdateAvailable;
        _notifyIcon.Visible = false;
        _notifyIcon.Dispose();
    }

    private async Task CheckForUpdatesFromTrayAsync()
    {
        _checkForUpdatesItem.Enabled = false;
        try
        {
            await _updaterService.CheckWithPromptsAsync();
        }
        finally
        {
            _checkForUpdatesItem.Enabled = true;
        }
    }

    private void OnStartupUpdateAvailable(object? sender, UpdaterCheckResult result)
    {
        _ = sender;
        if (!result.UpdateAvailable)
        {
            return;
        }

        _notifyIcon.ShowBalloonTip(
            8000,
            result.Title,
            result.Message,
            WinForms.ToolTipIcon.Info);
    }
}
