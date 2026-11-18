using System.Text.Json;
using HoverPocket.Shell.Configuration;
using HoverPocket.Shell.Providers.AiUsage;

namespace HoverPocket.Shell.Bridge;

internal sealed partial class PanelBridgeController
{
    private AiUsageService? _aiUsage;
    private string? _pendingSettingsCategory;
    private readonly HashSet<BridgeDispatcher> _readySettingsDispatchers = [];

    internal AiUsageService? AiUsageForVerify => _aiUsage;

    private void InitializeAiUsage(Func<string, CancellationToken, Task<AiUsageResult>>? readerOverride)
    {
        if (!_externalIntegrationsEnabled && readerOverride is null) return;
        _aiUsage = new AiUsageService(
            Path.Combine(_settingsStore.RootDirectory, "CodexVoice"),
            Path.Combine(_settingsStore.RootDirectory, "AiUsageWebView2"),
            readerOverride);
        _aiUsage.Changed += (_, _) => _ = PostEventOnUiThreadAsync("aiUsage.changed", BuildAiUsageState());
    }

    private object BuildAiUsageState() =>
        _aiUsage?.BuildState(CurrentSettings.AiUsageHiddenServices) ?? new { refreshing = false, services = Array.Empty<object>() };

    private IReadOnlyCollection<string> VisibleAiUsageServices() =>
        AiUsageServiceIds.All.Where(id => !CurrentSettings.AiUsageHiddenServices.Contains(id, StringComparer.Ordinal)).ToArray();

    /// <summary>
    /// Read once by a newly opened Settings page (its first <c>app.getState</c>) so "sign in" from the
    /// panel lands on the AI category. An already loaded Settings page gets <c>settings.focusCategory</c>.
    /// </summary>
    private string? TakePendingSettingsCategory()
    {
        var category = _pendingSettingsCategory;
        _pendingSettingsCategory = null;
        return category;
    }

    private void RegisterAiUsage(
        Action<string, Func<JsonElement?, CancellationToken, Task<object?>>> register,
        BridgeSurface surface,
        Func<System.Windows.Window?>? owner)
    {
        if (_aiUsage is not { } usage) return;

        register("aiUsage.getState", (parameters, token) =>
        {
            if (parameters is { ValueKind: JsonValueKind.Object } value
                && value.TryGetProperty("refresh", out var refresh) && refresh.ValueKind == JsonValueKind.True)
                _ = RefreshAiUsageInBackground(VisibleAiUsageServices(), force: false);
            return Task.FromResult<object?>(BuildAiUsageState());
        });
        register("aiUsage.refresh", (parameters, token) =>
        {
            var services = parameters is { ValueKind: JsonValueKind.Object } value
                && value.TryGetProperty("service", out var service) && service.ValueKind == JsonValueKind.String
                && AiUsageServiceIds.IsKnown(service.GetString())
                    ? [service.GetString()!]
                    : VisibleAiUsageServices();
            _ = RefreshAiUsageInBackground(services, force: true);
            return Task.FromResult<object?>(BuildAiUsageState());
        });

        if (surface == BridgeSurface.Panel)
        {
            register("aiUsage.openSettings", async (_, token) =>
            {
                var loaded = _readySettingsDispatchers.ToArray();
                if (loaded.Length == 0) _pendingSettingsCategory = "ai";
                SettingsOpenRequested?.Invoke(this, EventArgs.Empty);
                foreach (var settings in loaded) await settings.PostEventAsync("settings.focusCategory", new { category = "ai" });
                token.ThrowIfCancellationRequested();
                return new { opened = true };
            });
            return;
        }

        register("aiUsage.signIn", async (parameters, token) =>
        {
            var service = ReadAiUsageService(parameters);
            if (service == AiUsageServiceIds.Codex)
            {
                // Codex usage is read through the chat's ChatGPT sign-in, so this is the same login.
                await LoginChatAsync(token);
                await usage.RefreshAsync([service], force: true, token);
            }
            else
            {
                await usage.SignInAsync(service, owner?.Invoke(), CurrentSettings.Language == AppLanguage.English, token);
            }
            return BuildAiUsageState();
        });
        register("aiUsage.signOut", async (parameters, token) =>
        {
            var service = ReadAiUsageService(parameters);
            if (service == AiUsageServiceIds.Codex) throw new InvalidOperationException("codex_sign_out_unsupported");
            await usage.SignOutAsync(service, token);
            return BuildAiUsageState();
        });
        register("aiUsage.setVisible", async (parameters, token) =>
        {
            var service = ReadAiUsageService(parameters);
            var visible = ReadRequiredBool(parameters, "visible");
            var updated = CurrentSettings.Clone();
            updated.AiUsageHiddenServices.RemoveAll(id => id == service);
            if (!visible) updated.AiUsageHiddenServices.Add(service);
            SaveSettings(updated);
            await PostEventAsync("aiUsage.changed", BuildAiUsageState());
            if (visible) _ = RefreshAiUsageInBackground([service], force: false);
            token.ThrowIfCancellationRequested();
            return BuildAiUsageState();
        });
    }

    private static string ReadAiUsageService(JsonElement? parameters)
    {
        var service = ReadRequiredString(parameters, "service");
        return AiUsageServiceIds.IsKnown(service) ? service : throw new ArgumentException("ai_usage_service_invalid");
    }

    private async Task RefreshAiUsageInBackground(IReadOnlyCollection<string> services, bool force)
    {
        if (_aiUsage is null || services.Count == 0) return;
        try
        {
            await _aiUsage.RefreshAsync(services, force);
        }
        catch (OperationCanceledException)
        {
        }
        catch (ObjectDisposedException)
        {
        }
        catch (Exception exception)
        {
            Services.AppDiagnostics.Record("aiUsage.refresh.failed", exception);
        }
    }
}
