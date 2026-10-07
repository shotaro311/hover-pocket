using System.Text.Json;
using HoverPocket.Shell.Capture;

namespace HoverPocket.Shell.Bridge;

internal sealed partial class PanelBridgeController
{
    internal void SavePanelBounds(double width, double height)
    {
        if (!double.IsFinite(width) || !double.IsFinite(height)) return;
        var updated = CurrentSettings.Clone();
        var limits = Configuration.PanelSizeCatalog.ResizeLimits(0);
        updated.PanelWidthDips = Math.Clamp(width, limits.MinWidth, limits.MaxWidth);
        updated.PanelHeightDips = Math.Max(limits.MinHeight, height);
        SaveSettings(updated);
    }
    internal Task InvokeChatShortcutAsync(string kind) => PostPanelEventOnUiThreadAsync(kind == "voice" ? "chat.toggleVoice" : "chat.focusInput", new { });
    private void RegisterUx(Action<string, Func<JsonElement?, CancellationToken, Task<object?>>> register, BridgeSurface surface)
    {
        if (surface != BridgeSurface.Settings) return;
        register("settings.captureShortcut", (p, _) => { VoiceCapture?.SuspendShortcuts(ReadRequiredBool(p, "active")); return Task.FromResult<object?>(new { ok = true }); });
        register("settings.getShortcuts", (_, _) => Task.FromResult<object?>(new Dictionary<string, string>(CurrentSettings.Shortcuts)
        {
            ["screenshot"] = VoiceCapture?.Preferences.ScreenshotKey ?? "Ctrl+Alt+S",
            ["recording"] = VoiceCapture?.Preferences.RecordingKey ?? "Ctrl+Alt+R"
        }));
        register("settings.setShortcuts", (p, _) =>
        {
            var bindings = p?.GetProperty("shortcuts").Deserialize<Dictionary<string, string>>() ?? throw new ArgumentException("ショートカットを指定してください。");
            var allowed = new Configuration.UserSettings().Shortcuts.Keys.Append("screenshot").Append("recording").ToHashSet();
            if (bindings.Count != allowed.Count || bindings.Keys.Any(key => !allowed.Contains(key)) || bindings.Values.Any(value => value is null || value.Length > 80)) throw new ArgumentException("操作またはキーが不正です。");
            CaptureHotkeys.ValidateBindings(bindings);
            var capture = VoiceCapture; var prior = CurrentSettings.Clone(); var preferences = capture?.Preferences;
            var additional = bindings.Where(pair => pair.Key is not ("screenshot" or "recording")).ToDictionary();
            try
            {
                if (preferences is not null) capture!.SaveShortcutBindings(additional, preferences with { ScreenshotKey = bindings["screenshot"], RecordingKey = bindings["recording"] });
                var updated = CurrentSettings.Clone(); updated.Shortcuts = additional; SaveSettings(updated);
            }
            catch
            {
                if (preferences is not null) capture!.SaveShortcutBindings(prior.Shortcuts, preferences);
                throw;
            }
            return Task.FromResult<object?>(new { ok = true });
        });
    }
}
