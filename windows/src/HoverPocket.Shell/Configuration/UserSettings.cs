using HoverPocket.Shell.Voice;
using HoverPocket.Shell.Capabilities;
using HoverPocket.Shell.Providers.Weather;

namespace HoverPocket.Shell.Configuration;

internal sealed class UserSettings
{
    public DisplayPlacement DisplayPlacement { get; set; } = DisplayPlacement.Main;

    public PanelSize PanelSize { get; set; } = PanelSize.Medium;

    public double? PanelWidthDips { get; set; }
    public double? PanelHeightDips { get; set; }
    public bool TodayFocusRemoved { get; set; }
    public string PocketToolModel { get; set; } = PocketApps.CodexPocketAppGenerationModelCatalog.ModelId;
    public string PocketToolReasoningEffort { get; set; } = "medium";
    public bool CodexAllowAllAppActions { get; set; }
    public double? ChatSplitRatio { get; set; }
    public string? ChatModel { get; set; }
    public string? ChatEffort { get; set; }
    public Dictionary<string, string> Shortcuts { get; set; } = new() { ["panel"] = "Ctrl+Alt+H", ["chat"] = "Ctrl+Alt+C", ["library"] = "Ctrl+Alt+L", ["settings"] = "Ctrl+Alt+O", ["voice"] = "Ctrl+Alt+V", ["regionRecording"] = "Ctrl+Alt+Shift+G" };

    public PanelTextSize TextSize { get; set; } = PanelTextSize.Medium;

    public ProviderSwitchingMode SwitchingMode { get; set; } = ProviderSwitchingMode.Click;

    public AppLanguage Language { get; set; } = AppLanguage.Japanese;

    public WeatherLocation WeatherLocation { get; set; } = WeatherLocation.Default;

    public string WeatherTemperatureUnit { get; set; } = "automatic";

    public bool StartWithWindows { get; set; }

    public bool AutoCheckForUpdates { get; set; } = true;

    public bool AiNativeEnabled { get; set; }

    public CapabilityDataRetentionPeriod CapabilityDataRetentionPeriod { get; set; } = CapabilityDataRetentionPeriod.NinetyDays;

    public bool VoiceEnabled { get; set; }

    public string VoiceProviderId { get; set; } = VoiceProviderIds.Off;

    public bool VoiceCalendarAccessGranted { get; set; }

    public VoiceLaneLayoutPreference VoiceLaneLayout { get; set; } = VoiceLaneLayoutPreference.Compact;

    public bool ClipboardPrivateMode { get; set; }
    public bool LibraryAutoImportClipboardImages { get; set; }

    public bool RememberLastSelectedProvider { get; set; } = true;

    public string? PreferredProviderId { get; set; }

    public string? LastSelectedProviderId { get; set; }


    public PanelAttachmentStyle PanelAttachmentStyle { get; set; } = PanelAttachmentStyle.PreserveMenu;

    public bool AutomaticScreenEdgeAttachment { get; set; }

    public bool ReduceMotion { get; set; }


    public bool AutoHideTopHandle { get; set; }

    public bool DisableTopEdgeInFullscreen { get; set; } = true;

    public List<string> ProviderOrder { get; set; } = [];

    public Dictionary<string, bool> ProviderVisibility { get; set; } = new(StringComparer.OrdinalIgnoreCase);

    public UserSettings Clone()
    {
        return new UserSettings
        {
            CodexAllowAllAppActions = CodexAllowAllAppActions, ChatSplitRatio = ChatSplitRatio,
            TodayFocusRemoved = TodayFocusRemoved, PocketToolModel = PocketToolModel, PocketToolReasoningEffort = PocketToolReasoningEffort,
            DisplayPlacement = DisplayPlacement,
            PanelWidthDips = PanelWidthDips, PanelHeightDips = PanelHeightDips, ChatModel = ChatModel, ChatEffort = ChatEffort, Shortcuts = new(Shortcuts),
            PanelSize = PanelSize,
            TextSize = TextSize,
            WeatherLocation = WeatherLocation,
            WeatherTemperatureUnit = WeatherTemperatureUnit,
            SwitchingMode = SwitchingMode,
            Language = Language,
            StartWithWindows = StartWithWindows,
            AutoCheckForUpdates = AutoCheckForUpdates,
            AiNativeEnabled = AiNativeEnabled,
            CapabilityDataRetentionPeriod = CapabilityDataRetentionPeriod,
            VoiceEnabled = VoiceEnabled,
            VoiceProviderId = VoiceProviderId,
            VoiceCalendarAccessGranted = VoiceCalendarAccessGranted,
            VoiceLaneLayout = VoiceLaneLayout,
            ClipboardPrivateMode = ClipboardPrivateMode,
            LibraryAutoImportClipboardImages = LibraryAutoImportClipboardImages,
            RememberLastSelectedProvider = RememberLastSelectedProvider,
            PreferredProviderId = PreferredProviderId,
            LastSelectedProviderId = LastSelectedProviderId,
            PanelAttachmentStyle = PanelAttachmentStyle,
            AutomaticScreenEdgeAttachment = AutomaticScreenEdgeAttachment,
            ReduceMotion = ReduceMotion,
            AutoHideTopHandle = AutoHideTopHandle,
            DisableTopEdgeInFullscreen = DisableTopEdgeInFullscreen,
            ProviderOrder = [.. ProviderOrder],
            ProviderVisibility = new Dictionary<string, bool>(ProviderVisibility, StringComparer.OrdinalIgnoreCase)
        };
    }
}
