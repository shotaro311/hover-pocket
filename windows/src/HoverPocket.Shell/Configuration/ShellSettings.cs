namespace HoverPocket.Shell.Configuration;

internal sealed record ShellSettings(DisplayPlacement DisplayPlacement)
{
    public static ShellSettings Default { get; } = new(DisplayPlacement.Main);
}
