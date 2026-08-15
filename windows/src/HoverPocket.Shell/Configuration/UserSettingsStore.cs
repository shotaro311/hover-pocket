using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace HoverPocket.Shell.Configuration;

internal sealed class UserSettingsStore
{
    private readonly HoverPocketApplicationData _applicationData;
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) }
    };

    public UserSettingsStore()
        : this(HoverPocketApplicationData.ProductionDefault())
    {
    }

    public UserSettingsStore(string rootDirectory)
        : this(HoverPocketApplicationData.ForRoot(rootDirectory))
    {
    }

    public UserSettingsStore(HoverPocketApplicationData applicationData)
    {
        _applicationData = applicationData;
        RootDirectory = applicationData.RootDirectory;
        SettingsPath = applicationData.SettingsPath;
    }

    public string RootDirectory { get; }

    public string SettingsPath { get; }

    public static UserSettingsStore CreateTemporary(string name)
    {
        var root = Path.Combine(Path.GetTempPath(), "HoverPocket", name, Guid.NewGuid().ToString("N"));
        return new UserSettingsStore(root);
    }

    public UserSettings Load(IReadOnlyList<string> providerIds)
    {
        UserSettings? loaded = null;
        if (File.Exists(SettingsPath))
        {
            try
            {
                var json = File.ReadAllText(SettingsPath);
                loaded = JsonSerializer.Deserialize<UserSettings>(json, JsonOptions);
            }
            catch (JsonException)
            {
                loaded = null;
            }
            catch (IOException)
            {
                loaded = null;
            }
            catch (UnauthorizedAccessException)
            {
                loaded = null;
            }
        }

        var normalized = Normalize(loaded ?? CreateDefaultForContext(providerIds), providerIds);
        if (loaded is null)
        {
            TrySave(normalized);
        }

        return normalized;
    }

    public void Save(UserSettings settings)
    {
        Directory.CreateDirectory(RootDirectory);
        var json = JsonSerializer.Serialize(settings, JsonOptions);
        File.WriteAllText(SettingsPath, json);
    }

    private void TrySave(UserSettings settings)
    {
        try
        {
            Save(settings);
        }
        catch (IOException)
        {
        }
        catch (UnauthorizedAccessException)
        {
        }
    }

    public UserSettings ReloadOrDefault(IReadOnlyList<string> providerIds)
    {
        return Load(providerIds);
    }

    public UserSettings CreateDefaultForContext(IReadOnlyList<string> providerIds)
    {
        var settings = CreateDefault(providerIds);
        if (!_applicationData.IsIsolatedVoiceE2E)
        {
            return settings;
        }

        settings.AutoCheckForUpdates = false;
        settings.StartWithWindows = false;
        settings.AiNativeEnabled = true;
        settings.CodexVoiceEnabled = true;
        settings.CodexVoiceLayoutMode = VoiceLaneLayoutMode.Compact;
        settings.CodexVoiceAutoListen = false;
        settings.CodexVoiceCalendarReadEnabled = false;
        settings.ClipboardPrivateMode = true;
        return Normalize(settings, providerIds);
    }

    public static UserSettings CreateDefault(IReadOnlyList<string> providerIds)
    {
        var settings = new UserSettings
        {
            DisplayPlacement = DisplayPlacement.Main,
            PanelSize = PanelSize.Medium,
            TextSize = PanelTextSize.Medium,
            SwitchingMode = ProviderSwitchingMode.Click,
            Language = AppLanguage.Japanese,
            StartWithWindows = false,
            AutoCheckForUpdates = true,
            AiNativeEnabled = false,
            RememberLastSelectedProvider = true,
            PreferredProviderId = providerIds.FirstOrDefault(),
            HandleIconStyle = HandleIconStyle.B,
            ShowTopHandleSideArea = true,
            DisableTopEdgeInFullscreen = true,
            CodexVoiceEnabled = false,
            CodexVoiceLayoutMode = VoiceLaneLayoutMode.Compact,
            CodexVoiceAutoListen = false,
            CodexVoiceCalendarReadEnabled = false,
            ProviderOrder = [.. providerIds],
            ProviderVisibility = providerIds.ToDictionary(id => id, _ => true, StringComparer.OrdinalIgnoreCase)
        };
        return Normalize(settings, providerIds);
    }

    public static UserSettings Normalize(UserSettings settings, IReadOnlyList<string> providerIds)
    {
        var known = providerIds.ToHashSet(StringComparer.OrdinalIgnoreCase);
        var order = settings.ProviderOrder
            .Where(id => known.Contains(id))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();

        foreach (var providerId in providerIds)
        {
            if (!order.Contains(providerId, StringComparer.OrdinalIgnoreCase))
            {
                if (providerId.Equals("controls", StringComparison.OrdinalIgnoreCase))
                {
                    order.Insert(0, providerId);
                }
                else
                {
                    order.Add(providerId);
                }
            }
        }

        var visibility = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
        foreach (var providerId in providerIds)
        {
            visibility[providerId] = !settings.ProviderVisibility.TryGetValue(providerId, out var isVisible) || isVisible;
        }

        if (visibility.Count > 0 && visibility.Values.All(visible => !visible))
        {
            visibility[providerIds[0]] = true;
        }

        if (settings.CodexVoiceLayoutMode is not (VoiceLaneLayoutMode.Compact or VoiceLaneLayoutMode.Expanded))
        {
            settings.CodexVoiceLayoutMode = VoiceLaneLayoutMode.Compact;
        }

        settings.ProviderOrder = order;
        settings.ProviderVisibility = visibility;
        settings.PreferredProviderId = NormalizeProviderId(settings.PreferredProviderId, providerIds)
            ?? providerIds.FirstOrDefault();
        settings.LastSelectedProviderId = NormalizeProviderId(settings.LastSelectedProviderId, providerIds);
        return settings;
    }

    private static string? NormalizeProviderId(string? providerId, IReadOnlyList<string> providerIds)
    {
        return providerIds.FirstOrDefault(id => string.Equals(id, providerId, StringComparison.OrdinalIgnoreCase));
    }
}
