using System.Windows;
using Size = System.Windows.Size;

namespace HoverPocket.Shell.Windows;

internal sealed partial class HoverShellController
{
    private bool _manualResizing;
    private Size? _interactivePanelSize;
    private void OnUserResize(double dx, double dy, bool complete)
    {
        if (_activeLayout is not { } layout || _panel.AssetLayout.Fullscreen) return;
        if (!_manualResizing)
        {
            _manualResizing = true;
            var frame = EffectivePanelTarget(layout).DipRect;
            _interactivePanelSize = new(frame.Width, frame.Height);
            _closeDelayTimer.Stop();
        }
        if (_interactivePanelSize is { } size)
        {
            _interactivePanelSize = ResizeLimits(layout).Clamp(new(size.Width + dx * 2, size.Height + dy));
            var target = EffectivePanelTarget(layout);
            _interactivePanelSize = target.DipRect.Size;
            _panel.ResizeLive(target);
            if (complete)
            {
                _manualResizing = false;
                try { _panelBridgeController.SavePanelBounds(target.DipRect.Width, target.DipRect.Height); }
                catch (Exception ex) when (ex is System.IO.IOException or UnauthorizedAccessException) { Services.AppDiagnostics.Record("panel.resize.save.failed", ex); }
                finally { _interactivePanelSize = null; }
            }
        }
    }
    private Configuration.PanelResizeLimits ResizeLimits(Display.DisplaySurfaceLayout layout) =>
        Configuration.PanelSizeCatalog.ResizeLimits(layout.AccessSurface.DipRect.Height + _panelBridgeController.ChatHeight
            + Voice.VoicePanelGeometry.Height(_panelBridgeController.CurrentSettings.PanelSize, _panelBridgeController.ResolvedVoiceLaneMode));
    internal async void RunShortcut(string key)
    {
        try
        {
            switch (key)
            {
                case "panel": if (_panel.IsVisible) await HidePanelAsync(); else await ShowPanelAsync(ResolveLayoutForPointer()); break;
                case "settings": OpenSettingsFromUser(); break;
                case "library": OpenAssetLibraryFromUser(); break;
                case "chat": case "voice": await OpenChatAsync(); await _panelBridgeController.InvokeChatShortcutAsync(key); break;
            }
        }
        catch (Exception ex) { Services.AppDiagnostics.Record("shortcuts.action.failed", ex); }
    }
}
