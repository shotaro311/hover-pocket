using System.Windows;
using HoverPocket.Shell.Interop;
using HoverPocket.Shell.Providers.Controls;

namespace HoverPocket.Shell.Capture;

internal sealed partial class CaptureController
{
    internal async Task ToggleRegionRecordingAsync(string? folder = null, bool useCurrentFolder = false)
    {
        if (_disposed) return;
        if (Recording) { await StopRecordingAsync(); return; }
        if (Busy) return;
        _busy = true; CloseToast(); _window?.Hide();
        try
        {
            await _hideShell(); await Task.Delay(160);
            var desktop = System.Windows.Forms.SystemInformation.VirtualScreen;
            var image = await Task.Run(() => ScreenshotSelectionWindow.CaptureDesktop(desktop));
            var selection = new ScreenshotSelectionWindow(image, desktop, selectionOnly: true);
            if (selection.ShowDialog() != true) { Report("範囲収録をキャンセルしました。"); return; }
            var rect = selection.Region;
            var left = desktop.Left + rect.X; var top = desktop.Top + rect.Y;
            var monitor = NativeMethods.EnumerateDisplayMonitors().FirstOrDefault(m => left >= m.MonitorBounds.Left && top >= m.MonitorBounds.Top && left + rect.Width <= m.MonitorBounds.Right && top + rect.Height <= m.MonitorBounds.Bottom);
            if (monitor is null) throw new ArgumentException("一つの画面内で収録範囲を選択してください。");
            var crop = new Int32Rect(left - monitor.MonitorBounds.Left, top - monitor.MonitorBounds.Top, rect.Width, rect.Height);
            var item = WindowsGraphicsCapturePreviewService.CreateCaptureItemForMonitor(monitor.Handle);
            await BeginRecordingAsync(item, _preferences with { FolderId = useCurrentFolder ? folder : _preferences.FolderId }, null, CancellationToken.None, crop);
        }
        catch (Exception ex) { Report("範囲収録を開始できません: " + ex.Message); RecordingError?.Invoke(_status); }
        finally { _restoreShell(); _busy = false; Report(_status); }
    }
}
