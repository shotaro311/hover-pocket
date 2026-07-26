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

    public List<string> ProviderOrder { get; set; } = [];

    public Dictionary<string, bool> ProviderVisibility { get; set; } = new(StringComparer.OrdinalIgnoreCase);

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
            ProviderOrder = [.. ProviderOrder],
            ProviderVisibility = new Dictionary<string, bool>(ProviderVisibility, StringComparer.OrdinalIgnoreCase)
        };
    }
}
