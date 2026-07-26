namespace HoverPocket.Shell.Configuration;

internal sealed record ShellSettings(DisplayPlacement? DisplayPlacementOverride)
{
    public static ShellSettings Default { get; } = new((DisplayPlacement?)null);
}
