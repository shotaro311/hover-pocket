namespace HoverPocket.Shell.Configuration;

internal static class PanelSizeCatalog
{
    public const double HeaderHeight = 54;
    public const double AiLaneHeight = 0;

    public static PanelSizeMetrics Get(PanelSize panelSize)
    {
        return panelSize switch
        {
            PanelSize.Small => new PanelSizeMetrics("small", "S", 520, 372, HeaderHeight, AiLaneHeight),
            PanelSize.Large => new PanelSizeMetrics("large", "L", 680, 488, HeaderHeight, AiLaneHeight),
            _ => new PanelSizeMetrics("medium", "M", 600, 430, HeaderHeight, AiLaneHeight)
        };
    }

    public static IReadOnlyList<PanelSizeMetrics> All { get; } =
    [
        Get(PanelSize.Small),
        Get(PanelSize.Medium),
        Get(PanelSize.Large)
    ];
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
