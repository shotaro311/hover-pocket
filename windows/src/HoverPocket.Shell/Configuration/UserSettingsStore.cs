using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using HoverPocket.Shell.Capabilities;
using HoverPocket.Shell.Voice;

namespace HoverPocket.Shell.Configuration;

internal sealed class UserSettingsStore
{
    private const string GeneratedProviderPrefix = "generated-pocket-app:";
    private static readonly Regex GeneratedAppIdPattern = new(
        "^[a-z][a-z0-9]*(?:\\.[a-z0-9][a-z0-9-]*){2,}$",
        RegexOptions.CultureInvariant);
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
        return LoadCore(providerIds, preserveGeneratedProviders: false);
    }

    public UserSettings LoadForBootstrap(IReadOnlyList<string> providerIds)
    {
        return LoadCore(providerIds, preserveGeneratedProviders: true);
    }

    private UserSettings LoadCore(
        IReadOnlyList<string> providerIds,
        bool preserveGeneratedProviders)
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

        var normalizationIds = preserveGeneratedProviders
            ? BootstrapProviderIds(loaded, providerIds)
            : providerIds;
        var normalized = Normalize(loaded ?? CreateDefault(providerIds), normalizationIds);
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
        var temporaryPath = $"{SettingsPath}.{Guid.NewGuid():N}.tmp";
        try
        {
            File.WriteAllText(temporaryPath, json);
            File.Move(temporaryPath, SettingsPath, overwrite: true);
        }
        finally
        {
            try
            {
                if (File.Exists(temporaryPath))
                {
                    File.Delete(temporaryPath);
                }
            }
            catch
            {
            }
        }
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
            DisplayPlacement = DisplayPlacement.Main,
            PanelSize = PanelSize.Medium,
            TextSize = PanelTextSize.Medium,
            SwitchingMode = ProviderSwitchingMode.Click,
            Language = AppLanguage.Japanese,
            StartWithWindows = false,
            AutoCheckForUpdates = true,
            AiNativeEnabled = false,
            CapabilityDataRetentionPeriod = CapabilityDataRetentionPeriod.NinetyDays,
            VoiceEnabled = false,
            VoiceProviderId = VoiceProviderIds.Off,
            VoiceCalendarAccessGranted = false,
            VoiceLaneLayout = VoiceLaneLayoutPreference.Compact,
            RememberLastSelectedProvider = true,
            PreferredProviderId = providerIds.FirstOrDefault(),
            HandleIconStyle = HandleIconStyle.B,
            ShowTopHandleSideArea = true,
            DisableTopEdgeInFullscreen = true,
            ProviderOrder = [.. providerIds],
            ProviderVisibility = providerIds.ToDictionary(id => id, _ => true, StringComparer.OrdinalIgnoreCase)
        };
        return Normalize(settings, providerIds);
    }

    public static UserSettings Normalize(UserSettings settings, IReadOnlyList<string> providerIds)
    {
        if (!Enum.IsDefined(settings.CapabilityDataRetentionPeriod))
        {
            settings.CapabilityDataRetentionPeriod = CapabilityDataRetentionPeriod.NinetyDays;
        }
        settings.VoiceProviderId = VoiceProviderIds.Normalize(settings.VoiceProviderId);
        if (settings.VoiceProviderId == VoiceProviderIds.Off)
        {
            settings.VoiceEnabled = false;
        }
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

        settings.ProviderOrder = order;
        settings.ProviderVisibility = visibility;
        settings.PreferredProviderId = NormalizeProviderId(settings.PreferredProviderId, providerIds)
            ?? providerIds.FirstOrDefault();
        settings.LastSelectedProviderId = NormalizeProviderId(settings.LastSelectedProviderId, providerIds);
        return settings;
    }

    public static UserSettings NormalizeForBootstrap(
        UserSettings settings,
        IReadOnlyList<string> providerIds)
    {
        return Normalize(settings, BootstrapProviderIds(settings, providerIds));
    }

    private static IReadOnlyList<string> BootstrapProviderIds(
        UserSettings? settings,
        IReadOnlyList<string> providerIds)
    {
        var result = providerIds
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();
        if (settings is null)
        {
            return result;
        }

        var candidates = settings.ProviderOrder
            .Concat(settings.ProviderVisibility.Keys)
            .ToList();
        if (settings.PreferredProviderId is { } preferredProviderId)
        {
            candidates.Add(preferredProviderId);
        }
        if (settings.LastSelectedProviderId is { } lastSelectedProviderId)
        {
            candidates.Add(lastSelectedProviderId);
        }
        foreach (var candidate in candidates)
        {
            if (IsValidGeneratedProviderId(candidate)
                && !result.Contains(candidate, StringComparer.OrdinalIgnoreCase))
            {
                result.Add(candidate);
            }
        }
        return result;
    }

    private static bool IsValidGeneratedProviderId(string? providerId)
    {
        if (providerId is null
            || !providerId.StartsWith(GeneratedProviderPrefix, StringComparison.Ordinal))
        {
            return false;
        }
        var appId = providerId[GeneratedProviderPrefix.Length..];
        return appId.Length is >= 1 and <= 160
            && GeneratedAppIdPattern.IsMatch(appId);
    }

    private static string? NormalizeProviderId(string? providerId, IReadOnlyList<string> providerIds)
    {
        return providerIds.FirstOrDefault(id => string.Equals(id, providerId, StringComparison.OrdinalIgnoreCase));
    }
}
