namespace HoverPocket.Shell.Configuration;

internal static class PanelSizeCatalog
{
    public const double HeaderHeight = 54;

    // Existing callers remain on the stable, feature-disabled geometry until they
    // explicitly provide a VoiceLaneLayoutState.
    public const double AiLaneHeight = 0;

    public const double CompactVoiceLaneHeight = 64;

    public static PanelSizeMetrics Get(PanelSize panelSize)
    {
        return Get(panelSize, VoiceLaneLayoutState.Disabled);
    }

    public static PanelSizeMetrics Get(
        PanelSize panelSize,
        VoiceLaneLayoutState voiceLaneLayout)
    {
        var voiceLaneHeight = GetVoiceLaneHeight(panelSize, voiceLaneLayout);
        return panelSize switch
        {
            PanelSize.Small => new PanelSizeMetrics(
                "small",
                "S",
                520,
                372,
                HeaderHeight,
                voiceLaneHeight),
            PanelSize.Large => new PanelSizeMetrics(
                "large",
                "L",
                680,
                488,
                HeaderHeight,
                voiceLaneHeight),
            _ => new PanelSizeMetrics(
                "medium",
                "M",
                600,
                430,
                HeaderHeight,
                voiceLaneHeight)
        };
    }

    public static IReadOnlyList<PanelSizeMetrics> All { get; } =
        GetAll(VoiceLaneLayoutState.Disabled);

    public static IReadOnlyList<PanelSizeMetrics> GetAll(
        VoiceLaneLayoutState voiceLaneLayout)
    {
        return
        [
            Get(PanelSize.Small, voiceLaneLayout),
            Get(PanelSize.Medium, voiceLaneLayout),
            Get(PanelSize.Large, voiceLaneLayout)
        ];
    }

    private static double GetVoiceLaneHeight(
        PanelSize panelSize,
        VoiceLaneLayoutState voiceLaneLayout)
    {
        return voiceLaneLayout.Mode switch
        {
            VoiceLaneLayoutMode.Compact => CompactVoiceLaneHeight,
            VoiceLaneLayoutMode.Expanded => panelSize switch
            {
                PanelSize.Small => 190,
                PanelSize.Large => 250,
                _ => 220
            },
            _ => AiLaneHeight
        };
    }
}

internal sealed record PanelSizeMetrics(
    string Id,
    string Label,
    double Width,
    double ProviderHeight,
    double HeaderHeight,
    double AiLaneHeight)
{
    public double TotalHeight => ProviderHeight + AiLaneHeight;
}
