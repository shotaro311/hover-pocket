using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace HoverPocket.Shell.Configuration;

internal sealed class UserSettingsStore
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) }
    };

    public UserSettingsStore()
        : this(Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "HoverPocket"))
    {
    }

    public UserSettingsStore(string rootDirectory)
    {
        RootDirectory = rootDirectory;
        SettingsPath = Path.Combine(rootDirectory, "settings.json");
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

        var normalized = Normalize(loaded ?? CreateDefault(providerIds), providerIds);
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

    public static UserSettings CreateDefault(IReadOnlyList<string> providerIds)
    {
        var settings = new UserSettings
        {
            PanelSize = PanelSize.Medium,
            TextSize = PanelTextSize.Medium,
            SwitchingMode = ProviderSwitchingMode.Click,
            Language = AppLanguage.Japanese,
            StartWithWindows = false,
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
                order.Add(providerId);
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

        settings.ProviderOrder = order;
        settings.ProviderVisibility = visibility;
        return settings;
    }
}
