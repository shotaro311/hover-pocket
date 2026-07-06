using System.IO;
using System.Text.Json;
using HoverPocket.Shell.Configuration;
using HoverPocket.Shell.Providers;
using HoverPocket.Shell.Providers.AiLane;
using HoverPocket.Shell.Providers.Calculator;
using HoverPocket.Shell.Providers.Calendar;
using HoverPocket.Shell.Providers.Clipboard;
using HoverPocket.Shell.Providers.Sticky;
using HoverPocket.Shell.Providers.Timer;
using HoverPocket.Shell.Services;
using HoverPocket.Shell.Settings;

namespace HoverPocket.Shell.Bridge;

internal sealed class PanelBridgeController : IDisposable
{
    private readonly ProviderRegistry _providerRegistry;
    private readonly UserSettingsStore _settingsStore;
    private readonly IStartupRegistrationService _startupRegistration;
    private readonly UpdaterService _updaterService;
    private readonly AiLaneController _aiLaneController;
    private readonly CalculatorBridgeHandlers _calculatorBridgeHandlers = new();
    private readonly CalendarBridgeController _calendarBridgeController;
    private readonly ClipboardBridgeController _clipboardBridgeController;
    private readonly StickyBridgeController _stickyBridgeController;
    private readonly TimerBridgeHandlers _timerBridgeHandlers;
    private readonly List<BridgeDispatcher> _dispatchers = [];
    private string _selectedProviderId;
    private bool _disposed;

    public PanelBridgeController(
        ProviderRegistry providerRegistry,
        UserSettingsStore settingsStore,
        UserSettings settings,
        IStartupRegistrationService? startupRegistration = null,
        AiLaneController? aiLaneController = null,
        UpdaterService? updaterService = null)
    {
        _providerRegistry = providerRegistry;
        _settingsStore = settingsStore;
        _startupRegistration = startupRegistration ?? new RunKeyStartupRegistrationService();
        _updaterService = updaterService ?? new UpdaterService();
        _calendarBridgeController = new CalendarBridgeController();
        _aiLaneController = aiLaneController ?? new AiLaneController(
            new AiLaneAuditLog(settingsStore.RootDirectory),
            new CalendarAiLaneConnector(_calendarBridgeController.Store));
        _stickyBridgeController = new StickyBridgeController(new StickyNotesStore(Path.Combine(settingsStore.RootDirectory, "sticky")));
        _timerBridgeHandlers = new TimerBridgeHandlers(new TimerStore(Path.Combine(settingsStore.RootDirectory, "timer")));
        _timerBridgeHandlers.AlertFired += OnTimerAlertFired;
        _timerBridgeHandlers.AlertChanged += OnTimerAlertChanged;
        CurrentSettings = UserSettingsStore.Normalize(settings, providerRegistry.ProviderIds);
        _clipboardBridgeController = new ClipboardBridgeController(
            new ClipboardHistoryStore(Path.Combine(settingsStore.RootDirectory, "clipboard")),
            new ClipboardNativeListener(System.Windows.Application.Current?.Dispatcher ?? System.Windows.Threading.Dispatcher.CurrentDispatcher),
            () => CurrentSettings,
            SetClipboardPrivateModeAsync,
            () => IsVisible("clipboard"));
        _clipboardBridgeController.ExternalDragStarted += OnClipboardExternalDragStarted;
        _clipboardBridgeController.ApplySettings(CurrentSettings, IsVisible("clipboard"));
        _selectedProviderId = ResolveInitialProviderId();
    }

    public event EventHandler<UserSettings>? SettingsChanged;

    public event EventHandler? SettingsOpenRequested;

    public event EventHandler<TimerAlert>? TimerAlertFired;

    public event EventHandler<TimerAlert?>? TimerAlertChanged;

    public event EventHandler? ExternalDragStarted;

    public UserSettings CurrentSettings { get; private set; }

    public string SelectedProviderId => _selectedProviderId;

    public IDisposable Attach(BridgeDispatcher dispatcher)
    {
        _dispatchers.Add(dispatcher);
        dispatcher.Register("app.getState", (_, _) => Task.FromResult<object?>(BuildState()));
        dispatcher.Register("app.ready", (_, _) => Task.FromResult<object?>(new { ok = true }));
        dispatcher.Register("diagnostics.echo", (parameters, _) => Task.FromResult<object?>(DeserializeObject(parameters)));
        dispatcher.Register("provider.select", SelectProviderAsync);
        dispatcher.Register("provider.refreshPlaceholder", RefreshPlaceholderAsync);
        dispatcher.Register("settings.setPanelSize", SetPanelSizeAsync);
        dispatcher.Register("settings.setTextSize", SetTextSizeAsync);
        dispatcher.Register("settings.setSwitchingMode", SetSwitchingModeAsync);
        dispatcher.Register("settings.setLanguage", SetLanguageAsync);
        dispatcher.Register("settings.setProviderVisibility", SetProviderVisibilityAsync);
        dispatcher.Register("settings.moveProvider", MoveProviderAsync);
        dispatcher.Register("settings.setProviderOrder", SetProviderOrderAsync);
        dispatcher.Register("settings.setStartWithWindows", SetStartWithWindowsAsync);
        dispatcher.Register("settings.setAutoCheckForUpdates", SetAutoCheckForUpdatesAsync);
        dispatcher.Register("settings.setClipboardPrivateMode", SetClipboardPrivateModeAsync);
        dispatcher.Register("settings.resetDefaults", ResetDefaultsAsync);
        dispatcher.Register("settings.open", OpenSettingsAsync);
        dispatcher.Register("settings.openPlaceholder", OpenSettingsAsync);
        dispatcher.Register("updates.check", CheckForUpdatesAsync);
        dispatcher.Register("ailane.submit", SubmitAiLaneAsync);
        dispatcher.Register("ailane.approve", ApproveAiLaneAsync);
        dispatcher.Register("ailane.reject", RejectAiLaneAsync);
        _calculatorBridgeHandlers.Register(dispatcher);
        _calendarBridgeController.Attach(dispatcher);
        _clipboardBridgeController.Attach(dispatcher);
        _stickyBridgeController.Attach(dispatcher);
        _timerBridgeHandlers.Register(dispatcher);
        return new BridgeAttachment(() => _dispatchers.Remove(dispatcher));
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _timerBridgeHandlers.AlertFired -= OnTimerAlertFired;
        _timerBridgeHandlers.AlertChanged -= OnTimerAlertChanged;
        _timerBridgeHandlers.Dispose();
        _clipboardBridgeController.ExternalDragStarted -= OnClipboardExternalDragStarted;
        _clipboardBridgeController.Dispose();
    }

    public object BuildState()
    {
        var orderedProviders = OrderedProviders().ToArray();
        var selected = orderedProviders.FirstOrDefault(provider => string.Equals(provider.Id, _selectedProviderId, StringComparison.OrdinalIgnoreCase))
            ?? orderedProviders.FirstOrDefault();

        if (selected is not null)
        {
            _selectedProviderId = selected.Id;
        }

        var metrics = PanelSizeCatalog.Get(CurrentSettings.PanelSize);
        return new
        {
            settings = new
            {
                panelSize = ToWireValue(CurrentSettings.PanelSize),
                textSize = ToWireValue(CurrentSettings.TextSize),
                switchingMode = ToWireValue(CurrentSettings.SwitchingMode),
                language = ToWireValue(CurrentSettings.Language),
                startWithWindows = CurrentSettings.StartWithWindows,
                startWithWindowsRegistered = IsStartupRegistered(),
                autoCheckForUpdates = CurrentSettings.AutoCheckForUpdates,
                clipboardPrivateMode = CurrentSettings.ClipboardPrivateMode,
                providerOrder = CurrentSettings.ProviderOrder,
                providerVisibility = CurrentSettings.ProviderVisibility
            },
            updater = _updaterService.Snapshot,
            panel = new
            {
                headerHeight = PanelSizeCatalog.HeaderHeight,
                aiLaneHeight = PanelSizeCatalog.AiLaneHeight,
                width = metrics.Width,
                providerHeight = metrics.ProviderHeight,
                totalHeight = metrics.TotalHeight,
                sizes = PanelSizeCatalog.All.Select(size => new
                {
                    id = size.Id,
                    label = size.Label,
                    width = size.Width,
                    providerHeight = size.ProviderHeight,
                    totalHeight = size.TotalHeight
                })
            },
            providers = orderedProviders.Select(provider => new
            {
                id = provider.Id,
                title = provider.Title,
                icon = provider.Icon,
                summary = provider.Summary,
                body = provider.Body,
                selected = selected is not null && string.Equals(provider.Id, selected.Id, StringComparison.OrdinalIgnoreCase)
            }),
            allProviders = _providerRegistry.Providers.Select(provider => new
            {
                id = provider.Id,
                title = provider.Title,
                icon = provider.Icon,
                summary = provider.Summary,
                body = provider.Body
            }),
            selectedProvider = selected is null
                ? null
                : new
                {
                    id = selected.Id,
                    title = selected.Title,
                    icon = selected.Icon,
                    summary = selected.Summary,
                    body = selected.Body
                }
            ,
            aiLane = _aiLaneController.CurrentState
        };
    }

    private async Task<object?> SelectProviderAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        var providerId = ReadRequiredString(parameters, "id");
        var provider = _providerRegistry.Find(providerId);
        if (provider is null || !IsVisible(provider.Id))
        {
            throw new InvalidOperationException($"Provider is not visible: {providerId}");
        }

        _selectedProviderId = provider.Id;
        return await PublishStateAsync(cancellationToken);
    }

    private async Task<object?> RefreshPlaceholderAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        _ = parameters;
        return await PublishStateAsync(cancellationToken);
    }

    private async Task<object?> SetPanelSizeAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        var panelSize = ParsePanelSize(ReadRequiredString(parameters, "panelSize"));
        if (CurrentSettings.PanelSize != panelSize)
        {
            var updated = CurrentSettings.Clone();
            updated.PanelSize = panelSize;
            SaveSettings(updated);
        }

        return await PublishStateAsync(cancellationToken);
    }

    private async Task<object?> SetTextSizeAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        var textSize = ParseTextSize(ReadRequiredString(parameters, "textSize"));
        if (CurrentSettings.TextSize != textSize)
        {
            var updated = CurrentSettings.Clone();
            updated.TextSize = textSize;
            SaveSettings(updated);
        }

        return await PublishStateAsync(cancellationToken);
    }

    private async Task<object?> SetSwitchingModeAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        var switchingMode = ParseSwitchingMode(ReadRequiredString(parameters, "switchingMode"));
        if (CurrentSettings.SwitchingMode != switchingMode)
        {
            var updated = CurrentSettings.Clone();
            updated.SwitchingMode = switchingMode;
            SaveSettings(updated);
        }

        return await PublishStateAsync(cancellationToken);
    }

    private async Task<object?> SetLanguageAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        var language = ParseLanguage(ReadRequiredString(parameters, "language"));
        if (CurrentSettings.Language != language)
        {
            var updated = CurrentSettings.Clone();
            updated.Language = language;
            SaveSettings(updated);
        }

        return await PublishStateAsync(cancellationToken);
    }

    private async Task<object?> SetProviderVisibilityAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        var providerId = ReadRequiredString(parameters, "id");
        var visible = ReadRequiredBool(parameters, "visible");
        if (_providerRegistry.Find(providerId) is null)
        {
            throw new InvalidOperationException($"Unknown provider: {providerId}");
        }

        var updated = CurrentSettings.Clone();
        updated.ProviderVisibility[providerId] = visible;
        if (updated.ProviderVisibility.Count > 0 && updated.ProviderVisibility.Values.All(value => !value))
        {
            updated.ProviderVisibility[providerId] = true;
        }

        SaveSettings(updated);
        return await PublishStateAsync(cancellationToken);
    }

    private async Task<object?> MoveProviderAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        var providerId = ReadRequiredString(parameters, "id");
        var direction = ReadRequiredString(parameters, "direction");
        var updated = CurrentSettings.Clone();
        var index = updated.ProviderOrder.FindIndex(id => string.Equals(id, providerId, StringComparison.OrdinalIgnoreCase));
        if (index < 0)
        {
            throw new InvalidOperationException($"Unknown provider: {providerId}");
        }

        var nextIndex = direction.Equals("up", StringComparison.OrdinalIgnoreCase)
            ? Math.Max(0, index - 1)
            : Math.Min(updated.ProviderOrder.Count - 1, index + 1);
        if (nextIndex != index)
        {
            (updated.ProviderOrder[index], updated.ProviderOrder[nextIndex]) =
                (updated.ProviderOrder[nextIndex], updated.ProviderOrder[index]);
            SaveSettings(updated);
        }

        return await PublishStateAsync(cancellationToken);
    }

    private async Task<object?> SetProviderOrderAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        var order = ReadRequiredStringArray(parameters, "providerOrder");
        var updated = CurrentSettings.Clone();
        updated.ProviderOrder = order;
        SaveSettings(updated);
        return await PublishStateAsync(cancellationToken);
    }

    private async Task<object?> SetStartWithWindowsAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        var enabled = ReadRequiredBool(parameters, "enabled");
        if (CurrentSettings.StartWithWindows != enabled || IsStartupRegistered() != enabled)
        {
            _startupRegistration.SetRegistered(enabled);
            var updated = CurrentSettings.Clone();
            updated.StartWithWindows = enabled;
            SaveSettings(updated);
        }

        return await PublishStateAsync(cancellationToken);
    }

    private async Task<object?> SetAutoCheckForUpdatesAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        var enabled = ReadRequiredBool(parameters, "enabled");
        if (CurrentSettings.AutoCheckForUpdates != enabled)
        {
            var updated = CurrentSettings.Clone();
            updated.AutoCheckForUpdates = enabled;
            SaveSettings(updated);
        }

        return await PublishStateAsync(cancellationToken);
    }

    private async Task<object?> SetClipboardPrivateModeAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        return await SetClipboardPrivateModeAsync(ReadRequiredBool(parameters, "enabled"), cancellationToken);
    }

    private async Task<object?> SetClipboardPrivateModeAsync(bool enabled, CancellationToken cancellationToken)
    {
        if (CurrentSettings.ClipboardPrivateMode != enabled)
        {
            var updated = CurrentSettings.Clone();
            updated.ClipboardPrivateMode = enabled;
            SaveSettings(updated);
        }

        return await PublishStateAsync(cancellationToken);
    }

    private async Task<object?> ResetDefaultsAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        _ = parameters;
        _startupRegistration.SetRegistered(false);
        SaveSettings(UserSettingsStore.CreateDefault(_providerRegistry.ProviderIds));
        return await PublishStateAsync(cancellationToken);
    }

    private async Task<object?> OpenSettingsAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        _ = parameters;
        cancellationToken.ThrowIfCancellationRequested();
        SettingsOpenRequested?.Invoke(this, EventArgs.Empty);
        return await Task.FromResult<object?>(new { opened = true });
    }

    private async Task<object?> CheckForUpdatesAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        _ = parameters;
        cancellationToken.ThrowIfCancellationRequested();
        return await _updaterService.CheckWithPromptsAsync(cancellationToken: cancellationToken);
    }

    private async Task<object?> SubmitAiLaneAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        await _aiLaneController.SubmitAsync(ReadRequiredString(parameters, "text"), cancellationToken);
        return await PublishStateAsync(cancellationToken);
    }

    private async Task<object?> ApproveAiLaneAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        await _aiLaneController.ApproveAsync(ReadRequiredString(parameters, "actionId"), cancellationToken);
        return await PublishStateAsync(cancellationToken);
    }

    private async Task<object?> RejectAiLaneAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        _aiLaneController.Reject(ReadRequiredString(parameters, "actionId"));
        return await PublishStateAsync(cancellationToken);
    }

    public Task NotifyPanelOpenedAsync()
    {
        return PostEventAsync("panel.opened", BuildState());
    }

    public async Task SelectProviderFromShellAsync(string providerId, CancellationToken cancellationToken = default)
    {
        var provider = _providerRegistry.Find(providerId);
        if (provider is null || !IsVisible(provider.Id))
        {
            return;
        }

        _selectedProviderId = provider.Id;
        await PublishStateAsync(cancellationToken);
    }

    private void SaveSettings(UserSettings settings)
    {
        CurrentSettings = UserSettingsStore.Normalize(settings, _providerRegistry.ProviderIds);
        _clipboardBridgeController.ApplySettings(CurrentSettings, IsVisible("clipboard"));
        _settingsStore.Save(CurrentSettings);
        SettingsChanged?.Invoke(this, CurrentSettings);
    }

    private async Task<object> PublishStateAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var state = BuildState();
        await PostEventAsync("state.changed", state);
        return state;
    }

    private async Task PostEventAsync(string eventName, object? payload)
    {
        foreach (var dispatcher in _dispatchers.ToArray())
        {
            await dispatcher.PostEventAsync(eventName, payload);
        }
    }

    private string ResolveInitialProviderId()
    {
        return OrderedProviders().FirstOrDefault()?.Id
            ?? _providerRegistry.Providers.FirstOrDefault()?.Id
            ?? string.Empty;
    }

    private IEnumerable<ProviderDescriptor> OrderedProviders()
    {
        foreach (var providerId in CurrentSettings.ProviderOrder)
        {
            var provider = _providerRegistry.Find(providerId);
            if (provider is not null && IsVisible(provider.Id))
            {
                yield return provider;
            }
        }
    }

    private bool IsVisible(string providerId)
    {
        return !CurrentSettings.ProviderVisibility.TryGetValue(providerId, out var visible) || visible;
    }

    private static object? DeserializeObject(JsonElement? parameters)
    {
        if (parameters is null)
        {
            return null;
        }

        return JsonSerializer.Deserialize<object>(parameters.Value.GetRawText(), BridgeJson.Options);
    }

    private static string ReadRequiredString(JsonElement? parameters, string propertyName)
    {
        if (parameters is null
            || !parameters.Value.TryGetProperty(propertyName, out var property)
            || property.ValueKind != JsonValueKind.String)
        {
            throw new InvalidOperationException($"Missing string parameter: {propertyName}");
        }

        return property.GetString() ?? string.Empty;
    }

    private static bool ReadRequiredBool(JsonElement? parameters, string propertyName)
    {
        if (parameters is null
            || !parameters.Value.TryGetProperty(propertyName, out var property)
            || property.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
        {
            throw new InvalidOperationException($"Missing bool parameter: {propertyName}");
        }

        return property.GetBoolean();
    }

    private static List<string> ReadRequiredStringArray(JsonElement? parameters, string propertyName)
    {
        if (parameters is null
            || !parameters.Value.TryGetProperty(propertyName, out var property)
            || property.ValueKind != JsonValueKind.Array)
        {
            throw new InvalidOperationException($"Missing string array parameter: {propertyName}");
        }

        return property.EnumerateArray()
            .Where(item => item.ValueKind == JsonValueKind.String)
            .Select(item => item.GetString() ?? string.Empty)
            .Where(value => !string.IsNullOrWhiteSpace(value))
            .ToList();
    }

    private static PanelSize ParsePanelSize(string value)
    {
        return value.ToLowerInvariant() switch
        {
            "small" => PanelSize.Small,
            "large" => PanelSize.Large,
            _ => PanelSize.Medium
        };
    }

    private static ProviderSwitchingMode ParseSwitchingMode(string value)
    {
        return value.Equals("hover", StringComparison.OrdinalIgnoreCase)
            ? ProviderSwitchingMode.Hover
            : ProviderSwitchingMode.Click;
    }

    private static PanelTextSize ParseTextSize(string value)
    {
        return value.ToLowerInvariant() switch
        {
            "small" => PanelTextSize.Small,
            "large" => PanelTextSize.Large,
            _ => PanelTextSize.Medium
        };
    }

    private static AppLanguage ParseLanguage(string value)
    {
        return value.Equals("en", StringComparison.OrdinalIgnoreCase)
            ? AppLanguage.English
            : AppLanguage.Japanese;
    }

    private bool IsStartupRegistered()
    {
        try
        {
            return _startupRegistration.IsRegistered();
        }
        catch (UnauthorizedAccessException)
        {
            return CurrentSettings.StartWithWindows;
        }
        catch (InvalidOperationException)
        {
            return CurrentSettings.StartWithWindows;
        }
    }

    private void OnTimerAlertFired(object? sender, TimerAlert alert)
    {
        _ = sender;
        TimerAlertFired?.Invoke(this, alert);
    }

    private void OnTimerAlertChanged(object? sender, TimerAlert? alert)
    {
        _ = sender;
        TimerAlertChanged?.Invoke(this, alert);
    }

    private void OnClipboardExternalDragStarted(object? sender, EventArgs e)
    {
        _ = sender;
        _ = e;
        ExternalDragStarted?.Invoke(this, EventArgs.Empty);
    }

    private static string ToWireValue(PanelSize panelSize)
    {
        return panelSize switch
        {
            PanelSize.Small => "small",
            PanelSize.Large => "large",
            _ => "medium"
        };
    }

    private static string ToWireValue(PanelTextSize textSize)
    {
        return textSize switch
        {
            PanelTextSize.Small => "small",
            PanelTextSize.Large => "large",
            _ => "medium"
        };
    }

    private static string ToWireValue(ProviderSwitchingMode switchingMode)
    {
        return switchingMode == ProviderSwitchingMode.Hover ? "hover" : "click";
    }

    private static string ToWireValue(AppLanguage language)
    {
        return language == AppLanguage.English ? "en" : "ja";
    }

    private sealed class BridgeAttachment : IDisposable
    {
        private readonly Action _dispose;
        private bool _disposed;

        public BridgeAttachment(Action dispose)
        {
            _dispose = dispose;
        }

        public void Dispose()
        {
            if (_disposed)
            {
                return;
            }

            _disposed = true;
            _dispose();
        }
    }
}
