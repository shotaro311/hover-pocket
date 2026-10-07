using System.Text.Json;

namespace HoverPocket.Shell.Bridge;

internal sealed partial class PanelBridgeController
{
    private void RegisterToolSettings(Action<string, Func<JsonElement?, CancellationToken, Task<object?>>> register)
    {
        register("settings.loadGenerationModels", async (_, token) =>
        {
            await InlineChat.LoadModelsAsync(token);
            if (InlineChat.Models.Count == 0) throw new InvalidOperationException("generation_models_unavailable");
            return await PublishStateAsync(token);
        });
        register("settings.setGenerationOptions", async (parameters, token) =>
        {
            var model = ReadRequiredString(parameters, "model");
            var effort = ReadRequiredString(parameters, "effort");
            var choice = InlineChat.Models.FirstOrDefault(item => item.Model == model);
            if (choice is null || !choice.Efforts.Contains(effort)) throw new InvalidOperationException("generation_model_or_effort_unavailable");
            var settings = CurrentSettings.Clone();
            settings.PocketToolModel = model;
            settings.PocketToolReasoningEffort = effort;
            SaveSettings(settings);
            return await PublishStateAsync(token);
        });
        register("settings.removeTodayFocus", (_, token) => SetTodayFocusRemovedAsync(true, token));
        register("settings.restoreTodayFocus", (_, token) => SetTodayFocusRemovedAsync(false, token));
    }

    private async Task<object?> SetTodayFocusRemovedAsync(bool removed, CancellationToken token)
    {
        var transition = removed && _selectedProviderId == "today-focus"
            ? await BeginSelectedPocketAppStateTransitionAsync(token) : null;
        try
        {
            if (transition is { Saved: false }) return await PublishStateAsync(token);
            var settings = CurrentSettings.Clone();
            settings.TodayFocusRemoved = removed;
            SaveSettings(settings);
            if (removed && _selectedProviderId == "today-focus") _selectedProviderId = "timer";
            return await PublishStateAsync(token);
        }
        finally { await CompletePocketAppStateTransitionAsync(transition); }
    }
}
