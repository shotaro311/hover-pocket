using System.Text.Json;
using HoverPocket.Shell.Configuration;
using HoverPocket.Shell.Providers;

namespace HoverPocket.Shell.Bridge;

internal sealed class PanelBridgeController
{
    private readonly ProviderRegistry _providerRegistry;
    private readonly UserSettingsStore _settingsStore;
    private BridgeDispatcher? _dispatcher;
    private string _selectedProviderId;

    public PanelBridgeController(ProviderRegistry providerRegistry, UserSettingsStore settingsStore, UserSettings settings)
    {
        _providerRegistry = providerRegistry;
        _settingsStore = settingsStore;
        CurrentSettings = UserSettingsStore.Normalize(settings, providerRegistry.ProviderIds);
        _selectedProviderId = ResolveInitialProviderId();
    }

    public event EventHandler<UserSettings>? SettingsChanged;

    public UserSettings CurrentSettings { get; private set; }

    public string SelectedProviderId => _selectedProviderId;

    public void Attach(BridgeDispatcher dispatcher)
    {
        _dispatcher = dispatcher;
        dispatcher.Register("app.getState", (_, _) => Task.FromResult<object?>(BuildState()));
        dispatcher.Register("app.ready", (_, _) => Task.FromResult<object?>(new { ok = true }));
        dispatcher.Register("diagnostics.echo", (parameters, _) => Task.FromResult<object?>(DeserializeObject(parameters)));
        dispatcher.Register("provider.select", SelectProviderAsync);
        dispatcher.Register("provider.refreshPlaceholder", RefreshPlaceholderAsync);
        dispatcher.Register("settings.setPanelSize", SetPanelSizeAsync);
        dispatcher.Register("settings.setSwitchingMode", SetSwitchingModeAsync);
        dispatcher.Register("settings.openPlaceholder", (_, _) => Task.FromResult<object?>(new { opened = false, reason = "settings-ui-w7" }));
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
                providerOrder = CurrentSettings.ProviderOrder,
                providerVisibility = CurrentSettings.ProviderVisibility
            },
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

    private void SaveSettings(UserSettings settings)
    {
        CurrentSettings = UserSettingsStore.Normalize(settings, _providerRegistry.ProviderIds);
        _settingsStore.Save(CurrentSettings);
        SettingsChanged?.Invoke(this, CurrentSettings);
    }

    private async Task<object> PublishStateAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var state = BuildState();
        if (_dispatcher is not null)
        {
            await _dispatcher.PostEventAsync("state.changed", state);
        }

        return state;
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
}
