using Drawing = System.Drawing;
using WinForms = System.Windows.Forms;

namespace HoverPocket.Shell.Services;

internal sealed class TrayIconService : IDisposable
{
    private readonly WinForms.NotifyIcon _notifyIcon;

    public TrayIconService(Windows.HoverShellController shellController)
    {
        var menu = new WinForms.ContextMenuStrip();
        menu.Items.Add("Open Panel", null, (_, _) => shellController.ShowPanelFromUser());
        menu.Items.Add(new WinForms.ToolStripMenuItem("Settings") { Enabled = false });
        menu.Items.Add(new WinForms.ToolStripMenuItem("Check for Updates") { Enabled = false });
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
    }

    public void Dispose()
    {
        _notifyIcon.Visible = false;
        _notifyIcon.Dispose();
    }
}
