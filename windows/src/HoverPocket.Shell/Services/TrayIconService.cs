using Drawing = System.Drawing;
using WinForms = System.Windows.Forms;
using HoverPocket.Shell.Bridge;
using HoverPocket.Shell.Configuration;

namespace HoverPocket.Shell.Services;

internal sealed class TrayIconService : IDisposable
{
    private readonly WinForms.NotifyIcon _notifyIcon;
    private readonly UpdaterService _updaterService;
    private readonly PanelBridgeController _bridgeController;
    private readonly WinForms.ToolStripMenuItem _openPanelItem;
    private readonly WinForms.ToolStripMenuItem _settingsItem;
    private readonly WinForms.ToolStripMenuItem _checkForUpdatesItem;
    private readonly WinForms.ToolStripMenuItem _quitItem;

    public TrayIconService(Windows.HoverShellController shellController, UpdaterService updaterService)
    {
        _updaterService = updaterService;
        _bridgeController = shellController.PanelBridgeController;
        var menu = new WinForms.ContextMenuStrip();
        _openPanelItem = new WinForms.ToolStripMenuItem();
        _openPanelItem.Click += (_, _) => shellController.ShowPanelFromUser();
        menu.Items.Add(_openPanelItem);
        _settingsItem = new WinForms.ToolStripMenuItem();
        _settingsItem.Click += (_, _) => shellController.OpenSettingsFromUser();
        menu.Items.Add(_settingsItem);
        _checkForUpdatesItem = new WinForms.ToolStripMenuItem();
        _checkForUpdatesItem.Click += async (_, _) => await CheckForUpdatesFromTrayAsync();
        menu.Items.Add(_checkForUpdatesItem);
        menu.Items.Add(new WinForms.ToolStripSeparator());
        _quitItem = new WinForms.ToolStripMenuItem();
        _quitItem.Click += (_, _) => System.Windows.Application.Current.Shutdown();
        menu.Items.Add(_quitItem);

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
        _bridgeController.SettingsChanged += OnSettingsChanged;
        ApplyLanguage(_bridgeController.CurrentSettings.Language);
    }

    public void Dispose()
    {
        _updaterService.StartupUpdateAvailable -= OnStartupUpdateAvailable;
        _bridgeController.SettingsChanged -= OnSettingsChanged;
        _notifyIcon.Visible = false;
        _notifyIcon.Dispose();
    }

    private void OnSettingsChanged(object? sender, UserSettings settings)
    {
        _ = sender;
        ApplyLanguage(settings.Language);
    }

    private void ApplyLanguage(AppLanguage language)
    {
        var japanese = language != AppLanguage.English;
        _openPanelItem.Text = japanese ? "パネルを開く" : "Open Panel";
        _settingsItem.Text = japanese ? "設定" : "Settings";
        _checkForUpdatesItem.Text = japanese ? "更新を確認" : "Check for Updates";
        _quitItem.Text = japanese ? "終了" : "Quit";
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
