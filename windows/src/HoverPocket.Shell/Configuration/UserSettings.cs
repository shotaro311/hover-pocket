namespace HoverPocket.Shell.Configuration;

internal sealed class UserSettings
{
    public DisplayPlacement DisplayPlacement { get; set; } = DisplayPlacement.Main;

    public PanelSize PanelSize { get; set; } = PanelSize.Medium;

    public PanelTextSize TextSize { get; set; } = PanelTextSize.Medium;

    public ProviderSwitchingMode SwitchingMode { get; set; } = ProviderSwitchingMode.Click;

    public AppLanguage Language { get; set; } = AppLanguage.Japanese;

    public bool StartWithWindows { get; set; }

    public bool AutoCheckForUpdates { get; set; } = true;

    public bool ClipboardPrivateMode { get; set; }

    public bool RememberLastSelectedProvider { get; set; } = true;

    public string? PreferredProviderId { get; set; }

    public string? LastSelectedProviderId { get; set; }

    public HandleIconStyle HandleIconStyle { get; set; } = HandleIconStyle.B;

    public bool ShowTopHandleSideArea { get; set; } = true;

    public bool DisableTopEdgeInFullscreen { get; set; } = true;

    // Voice Lane stays completely inert until an explicit future UI or controlled
    // test path enables it. Merely upgrading an existing settings file never starts
    // Codex, requests microphone permission, registers a hotkey, or changes geometry.
    public bool CodexVoiceEnabled { get; set; }

    public VoiceLaneLayoutMode CodexVoiceLayoutMode { get; set; } = VoiceLaneLayoutMode.Compact;

    public List<string> ProviderOrder { get; set; } = [];

    public Dictionary<string, bool> ProviderVisibility { get; set; } = new(StringComparer.OrdinalIgnoreCase);

    public VoiceLaneLayoutState EffectiveVoiceLaneLayout => CodexVoiceEnabled
        ? CodexVoiceLayoutMode switch
        {
            VoiceLaneLayoutMode.Expanded => VoiceLaneLayoutState.Expanded,
            _ => VoiceLaneLayoutState.Compact
        }
        : VoiceLaneLayoutState.Disabled;

    public UserSettings Clone()
    {
        return new UserSettings
        {
            DisplayPlacement = DisplayPlacement,
            PanelSize = PanelSize,
            TextSize = TextSize,
            SwitchingMode = SwitchingMode,
            Language = Language,
            StartWithWindows = StartWithWindows,
            AutoCheckForUpdates = AutoCheckForUpdates,
            ClipboardPrivateMode = ClipboardPrivateMode,
            RememberLastSelectedProvider = RememberLastSelectedProvider,
            PreferredProviderId = PreferredProviderId,
            LastSelectedProviderId = LastSelectedProviderId,
            HandleIconStyle = HandleIconStyle,
            ShowTopHandleSideArea = ShowTopHandleSideArea,
            DisableTopEdgeInFullscreen = DisableTopEdgeInFullscreen,
            CodexVoiceEnabled = CodexVoiceEnabled,
            CodexVoiceLayoutMode = CodexVoiceLayoutMode,
            ProviderOrder = [.. ProviderOrder],
            ProviderVisibility = new Dictionary<string, bool>(ProviderVisibility, StringComparer.OrdinalIgnoreCase)
        };
    }
}
