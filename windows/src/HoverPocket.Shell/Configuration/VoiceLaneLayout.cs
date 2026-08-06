namespace HoverPocket.Shell.Configuration;

internal enum VoiceLaneLayoutMode
{
    Disabled,
    Compact,
    Expanded
}

internal readonly record struct VoiceLaneLayoutState(VoiceLaneLayoutMode Mode)
{
    public static VoiceLaneLayoutState Disabled { get; } = new(VoiceLaneLayoutMode.Disabled);

    public static VoiceLaneLayoutState Compact { get; } = new(VoiceLaneLayoutMode.Compact);

    public static VoiceLaneLayoutState Expanded { get; } = new(VoiceLaneLayoutMode.Expanded);

    public bool IsVisible => Mode != VoiceLaneLayoutMode.Disabled;

    public bool IsExpanded => Mode == VoiceLaneLayoutMode.Expanded;
}
