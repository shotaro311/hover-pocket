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
        _aiUsage.Changed += (_, _) => _ = PublishAiUsageStateAsync();
    }

    private Task PublishAiUsageStateAsync()
    {
        var dispatcher = System.Windows.Application.Current?.Dispatcher;
        return dispatcher is null || dispatcher.CheckAccess()
            ? PostEventAsync("aiUsage.changed", BuildAiUsageState())
            : dispatcher.InvokeAsync(() => PostEventAsync("aiUsage.changed", BuildAiUsageState())).Task.Unwrap();
    }

    private object BuildAiUsageState()
    {
        var settings = CurrentSettings;
        var usage = _aiUsage?.BuildState(settings.AiUsageHiddenServices);
        return new
        {
            refreshing = usage?.Refreshing ?? false,
            services = usage?.Services ?? [],
            view = settings.AiUsageView,
            order = settings.AiUsageServiceOrder,
            sort = settings.AiUsageSort
        };
    }

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

    /// <summary>
    /// The chat, the voice lane and AI Usage share one ChatGPT login (the CodexVoice profile). After a
    /// sign-in from any of them, clear the chat's stale sign-in prompt and re-read Codex usage for the
    /// new login.
    /// </summary>
    private void OnChatGptSignedIn()
    {
        if (System.Windows.Application.Current?.Dispatcher is { } dispatcher && !dispatcher.CheckAccess())
        {
            dispatcher.BeginInvoke(OnChatGptSignedIn);
            return;
        }
        if (_disposed) return;
        _inlineChat?.SignedIn();
        if (_aiUsage is null) return;
        _aiUsage.BeginAccountChange(AiUsageServiceIds.Codex);
        if (VisibleAiUsageServices().Contains(AiUsageServiceIds.Codex))
            _ = RefreshAiUsageInBackground([AiUsageServiceIds.Codex], force: true);
    }

    /// <summary>Remembers loaded Settings pages so the panel can switch them to the AI category.</summary>
    private object MarkSurfaceReady(BridgeDispatcher dispatcher, BridgeSurface surface)
    {
        if (surface is BridgeSurface.Settings) _readySettingsDispatchers.Add(dispatcher);
        return new { ok = true };
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

        register("aiUsage.setPresentation", async (parameters, token) =>
        {
            if (parameters is not { ValueKind: JsonValueKind.Object } value)
                throw new ArgumentException("ai_usage_presentation_invalid");
            var updated = CurrentSettings.Clone();
            if (value.TryGetProperty("view", out var view))
                updated.AiUsageView = view.ValueKind == JsonValueKind.String ? view.GetString()! : "list";
            if (value.TryGetProperty("order", out var order))
                updated.AiUsageServiceOrder = order.ValueKind == JsonValueKind.Array
                    ? order.EnumerateArray().Where(item => item.ValueKind == JsonValueKind.String).Select(item => item.GetString()!).ToList()
                    : [];
            if (value.TryGetProperty("sort", out var sort))
            {
                updated.AiUsageSort = sort.ValueKind == JsonValueKind.Object
                    && sort.TryGetProperty("column", out var column) && column.ValueKind == JsonValueKind.String
                    && sort.TryGetProperty("direction", out var direction) && direction.ValueKind == JsonValueKind.String
                    ? new AiUsageListSort(column.GetString()!, direction.GetString()!) : null;
            }
            token.ThrowIfCancellationRequested();
            SaveSettings(updated);
            await PostEventAsync("aiUsage.changed", BuildAiUsageState());
            return BuildAiUsageState();
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
            if (!AiUsageServiceIds.SignIn.Contains(service, StringComparer.Ordinal)) throw new InvalidOperationException("ai_usage_sign_out_unsupported");
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
