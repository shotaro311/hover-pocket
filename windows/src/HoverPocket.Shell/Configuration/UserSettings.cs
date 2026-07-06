namespace HoverPocket.Shell.Configuration;

internal sealed class UserSettings
{
    public PanelSize PanelSize { get; set; } = PanelSize.Medium;

    public PanelTextSize TextSize { get; set; } = PanelTextSize.Medium;

    public ProviderSwitchingMode SwitchingMode { get; set; } = ProviderSwitchingMode.Click;

    public AppLanguage Language { get; set; } = AppLanguage.Japanese;

    public bool StartWithWindows { get; set; }

    public bool AutoCheckForUpdates { get; set; } = true;

    public bool ClipboardPrivateMode { get; set; }

    public List<string> ProviderOrder { get; set; } = [];

    public Dictionary<string, bool> ProviderVisibility { get; set; } = new(StringComparer.OrdinalIgnoreCase);

    public UserSettings Clone()
    {
        return new UserSettings
        {
            PanelSize = PanelSize,
            TextSize = TextSize,
            SwitchingMode = SwitchingMode,
            Language = Language,
            StartWithWindows = StartWithWindows,
            AutoCheckForUpdates = AutoCheckForUpdates,
            ClipboardPrivateMode = ClipboardPrivateMode,
            ProviderOrder = [.. ProviderOrder],
            ProviderVisibility = new Dictionary<string, bool>(ProviderVisibility, StringComparer.OrdinalIgnoreCase)
        };
    }
}
