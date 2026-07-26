using HoverPocket.Shell.Configuration;

namespace HoverPocket.Shell;

internal sealed record StartupOptions(
    bool VerifyShell,
    bool VerifyDisplay,
    bool VerifyUi,
    bool VerifyUiModel,
    bool VerifySticky,
    bool VerifyClipboard,
    bool VerifyControls,
    bool VerifyCalc,
    bool VerifyTimer,
    bool VerifyCalendar,
    bool VerifyCalendarLive,
    bool VerifySettings,
    bool VerifyAiLane,
    bool VerifyUpdater,
    bool VerifyReleaseConfig,
    bool SecondInstanceProbe,
    bool EnableDevTools,
    bool ChangeBrightnessForVerify,
    bool TogglePlaybackForVerify,
    bool VerifyLivePreview,
    bool VerifyLivePreviewFallback,
    ShellSettings Settings)
{
    public bool IsVerify =>
        VerifyShell
        || VerifyDisplay
        || VerifyUi
        || VerifyUiModel
        || VerifySticky
        || VerifyClipboard
        || VerifyControls
        || VerifyCalc
        || VerifyTimer
        || VerifyCalendar
        || VerifyCalendarLive
        || VerifySettings
        || VerifyAiLane
        || VerifyUpdater
        || VerifyReleaseConfig;

    public static StartupOptions Parse(string[] args)
    {
        var verifyShell = false;
        var verifyDisplay = false;
        var verifyUi = false;
        var verifyUiModel = false;
        var verifySticky = false;
        var verifyClipboard = false;
        var verifyControls = false;
        var verifyCalc = false;
        var verifyTimer = false;
        var verifyCalendar = false;
        var verifyCalendarLive = false;
        var verifySettings = false;
        var verifyAiLane = false;
        var verifyUpdater = false;
        var verifyReleaseConfig = false;
        var secondInstanceProbe = false;
        var enableDevTools = false;
        var changeBrightnessForVerify = false;
        var togglePlaybackForVerify = false;
        var verifyLivePreview = false;
        var verifyLivePreviewFallback = false;
        DisplayPlacement? displayPlacement = null;

        for (var index = 0; index < args.Length; index++)
        {
            if (string.Equals(args[index], "--verify", StringComparison.OrdinalIgnoreCase)
                && index + 1 < args.Length)
            {
                var verifyTarget = args[++index];
                verifyShell = string.Equals(verifyTarget, "shell", StringComparison.OrdinalIgnoreCase);
                verifyDisplay = string.Equals(verifyTarget, "display", StringComparison.OrdinalIgnoreCase);
                verifyUi = string.Equals(verifyTarget, "ui", StringComparison.OrdinalIgnoreCase);
                verifyUiModel = string.Equals(verifyTarget, "ui-model", StringComparison.OrdinalIgnoreCase);
                verifySticky = string.Equals(verifyTarget, "sticky", StringComparison.OrdinalIgnoreCase);
                verifyClipboard = string.Equals(verifyTarget, "clipboard", StringComparison.OrdinalIgnoreCase);
                verifyControls = string.Equals(verifyTarget, "controls", StringComparison.OrdinalIgnoreCase);
                verifyCalc = string.Equals(verifyTarget, "calc", StringComparison.OrdinalIgnoreCase);
                verifyTimer = string.Equals(verifyTarget, "timer", StringComparison.OrdinalIgnoreCase);
                verifyCalendar = string.Equals(verifyTarget, "calendar", StringComparison.OrdinalIgnoreCase);
                verifyCalendarLive = string.Equals(verifyTarget, "calendar-live", StringComparison.OrdinalIgnoreCase);
                verifySettings = string.Equals(verifyTarget, "settings", StringComparison.OrdinalIgnoreCase);
                verifyAiLane = string.Equals(verifyTarget, "ailane", StringComparison.OrdinalIgnoreCase);
                verifyUpdater = string.Equals(verifyTarget, "updater", StringComparison.OrdinalIgnoreCase);
                verifyReleaseConfig = string.Equals(verifyTarget, "release-config", StringComparison.OrdinalIgnoreCase);
                continue;
            }

            if (string.Equals(args[index], "--second-instance-probe", StringComparison.OrdinalIgnoreCase))
            {
                secondInstanceProbe = true;
                continue;
            }

            if (string.Equals(args[index], "--devtools", StringComparison.OrdinalIgnoreCase))
            {
                enableDevTools = true;
                continue;
            }

            if (string.Equals(args[index], "--change-brightness", StringComparison.OrdinalIgnoreCase))
            {
                changeBrightnessForVerify = true;
                continue;
            }

            if (string.Equals(args[index], "--toggle-playback", StringComparison.OrdinalIgnoreCase))
            {
                togglePlaybackForVerify = true;
                continue;
            }

            if (string.Equals(args[index], "--verify-live-preview", StringComparison.OrdinalIgnoreCase))
            {
                verifyLivePreview = true;
                continue;
            }

            if (string.Equals(args[index], "--verify-live-preview-fallback", StringComparison.OrdinalIgnoreCase))
            {
                verifyLivePreviewFallback = true;
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
            verifyUi,
            verifyUiModel,
            verifySticky,
            verifyClipboard,
            verifyControls,
            verifyCalc,
            verifyTimer,
            verifyCalendar,
            verifyCalendarLive,
            verifySettings,
            verifyAiLane,
            verifyUpdater,
            verifyReleaseConfig,
            secondInstanceProbe,
            enableDevTools,
            changeBrightnessForVerify,
            togglePlaybackForVerify,
            verifyLivePreview,
            verifyLivePreviewFallback,
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
