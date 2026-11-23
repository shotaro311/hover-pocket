using System.Text.Json;
using HoverPocket.Shell.Providers.Controls;

namespace HoverPocket.Shell.Bridge;

internal sealed partial class PanelBridgeController
{
    private bool _controlsContrastSettingsSubscribed;

    private void RegisterControls(
        Action<string, Func<JsonElement?, CancellationToken, Task<object?>>> register,
        BridgeSurface surface)
    {
        if (surface == BridgeSurface.Panel)
        {
            RegisterControlsMethods(register, _controlsBridgeController);
        }
    }

    internal void RegisterControlsMethods(
        Action<string, Func<JsonElement?, CancellationToken, Task<object?>>> register,
        ControlsBridgeController controls)
    {
        if (!_controlsContrastSettingsSubscribed)
        {
            _controlsContrastSettingsSubscribed = true;
            SettingsChanged += (_, settings) => controls.SetContrastVisible(settings.ControlsContrastVisible);
            controls.SetContrastVisible(CurrentSettings.ControlsContrastVisible);
        }

        register("controls.getContrastVisible", (_, _) =>
            Task.FromResult<object?>(new { visible = CurrentSettings.ControlsContrastVisible }));
        register("controls.setContrastVisible", async (parameters, token) =>
        {
            var visible = ReadRequiredBool(parameters, "visible");
            token.ThrowIfCancellationRequested();
            var previous = CurrentSettings.ControlsContrastVisible;
            if (visible != previous)
            {
                var updated = CurrentSettings.Clone();
                updated.ControlsContrastVisible = visible;
                controls.SetContrastVisible(visible);
                try
                {
                    SaveSettings(updated);
                }
                catch
                {
                    controls.SetContrastVisible(previous);
                    throw;
                }

                if (visible && _externalIntegrationsEnabled)
                {
                    await controls.RefreshContrastAsync(token);
                }
            }

            return new { visible = CurrentSettings.ControlsContrastVisible };
        });
    }
}
