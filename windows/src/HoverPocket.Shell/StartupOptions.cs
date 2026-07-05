using HoverPocket.Shell.Configuration;

namespace HoverPocket.Shell;

internal sealed record StartupOptions(bool VerifyShell, bool VerifyDisplay, ShellSettings Settings)
{
    public static StartupOptions Parse(string[] args)
    {
        var verifyShell = false;
        var verifyDisplay = false;
        var displayPlacement = DisplayPlacement.Main;

        for (var index = 0; index < args.Length; index++)
        {
            if (string.Equals(args[index], "--verify", StringComparison.OrdinalIgnoreCase)
                && index + 1 < args.Length)
            {
                var verifyTarget = args[++index];
                verifyShell = string.Equals(verifyTarget, "shell", StringComparison.OrdinalIgnoreCase);
                verifyDisplay = string.Equals(verifyTarget, "display", StringComparison.OrdinalIgnoreCase);
                continue;
            }

            if (string.Equals(args[index], "--display-placement", StringComparison.OrdinalIgnoreCase)
                && index + 1 < args.Length
                && TryParseDisplayPlacement(args[++index], out var parsedPlacement))
            {
                displayPlacement = parsedPlacement;
            }
        }

        return new StartupOptions(
            verifyShell,
            verifyDisplay,
            new ShellSettings(displayPlacement));
    }

    private static bool TryParseDisplayPlacement(string value, out DisplayPlacement placement)
    {
        if (string.Equals(value, "main", StringComparison.OrdinalIgnoreCase))
        {
            placement = DisplayPlacement.Main;
            return true;
        }

        if (string.Equals(value, "sub", StringComparison.OrdinalIgnoreCase))
        {
            placement = DisplayPlacement.Sub;
            return true;
        }

        if (string.Equals(value, "all", StringComparison.OrdinalIgnoreCase))
        {
            placement = DisplayPlacement.All;
            return true;
        }

        placement = DisplayPlacement.Main;
        return false;
    }
}
