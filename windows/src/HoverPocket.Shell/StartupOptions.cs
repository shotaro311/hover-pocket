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
    bool VerifyCapabilities,
    bool VerifyBroker,
    bool VerifyCalendarLive,
    bool VerifySettings,
    bool VerifyAiLane,
    bool VerifyVoiceLaneLayout,
    bool VerifyCodexAppServer,
    bool VerifyCodexAppServerProtocol,
    bool VerifyCodexVoiceCoordinator,
    bool VerifyVoiceE2EIsolation,
    bool VerifyUpdater,
    bool VerifyReleaseConfig,
    bool SecondInstanceProbe,
    bool VoiceE2ERequested,
    string? VoiceE2ERoot,
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
        || VerifyCapabilities
        || VerifyBroker
        || VerifyCalendarLive
        || VerifySettings
        || VerifyAiLane
        || VerifyVoiceLaneLayout
        || VerifyCodexAppServer
        || VerifyCodexAppServerProtocol
        || VerifyCodexVoiceCoordinator
        || VerifyVoiceE2EIsolation
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
        var verifyCapabilities = false;
        var verifyBroker = false;
        var verifyCalendarLive = false;
        var verifySettings = false;
        var verifyAiLane = false;
        var verifyVoiceLaneLayout = false;
        var verifyCodexAppServer = false;
        var verifyCodexAppServerProtocol = false;
        var verifyCodexVoiceCoordinator = false;
        var verifyVoiceE2EIsolation = false;
        var verifyUpdater = false;
        var verifyReleaseConfig = false;
        var secondInstanceProbe = false;
        var voiceE2ERequested = false;
        string? voiceE2ERoot = null;
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
                verifyCapabilities = string.Equals(verifyTarget, "capabilities", StringComparison.OrdinalIgnoreCase);
                verifyBroker = string.Equals(verifyTarget, "broker", StringComparison.OrdinalIgnoreCase);
                verifyCalendarLive = string.Equals(verifyTarget, "calendar-live", StringComparison.OrdinalIgnoreCase);
                verifySettings = string.Equals(verifyTarget, "settings", StringComparison.OrdinalIgnoreCase);
                verifyAiLane = string.Equals(verifyTarget, "ailane", StringComparison.OrdinalIgnoreCase);
                verifyVoiceLaneLayout = string.Equals(
                    verifyTarget,
                    "voice-lane-layout",
                    StringComparison.OrdinalIgnoreCase);
                verifyCodexAppServer = string.Equals(verifyTarget, "codex-app-server", StringComparison.OrdinalIgnoreCase);
                verifyCodexAppServerProtocol = string.Equals(
                    verifyTarget,
                    "codex-app-server-protocol",
                    StringComparison.OrdinalIgnoreCase);
                verifyCodexVoiceCoordinator = string.Equals(
                    verifyTarget,
                    "codex-voice-coordinator",
                    StringComparison.OrdinalIgnoreCase);
                verifyVoiceE2EIsolation = string.Equals(
                    verifyTarget,
                    "voice-e2e-isolation",
                    StringComparison.OrdinalIgnoreCase);
                verifyUpdater = string.Equals(verifyTarget, "updater", StringComparison.OrdinalIgnoreCase);
                verifyReleaseConfig = string.Equals(verifyTarget, "release-config", StringComparison.OrdinalIgnoreCase);
                continue;
            }

            if (string.Equals(args[index], "--second-instance-probe", StringComparison.OrdinalIgnoreCase))
            {
                secondInstanceProbe = true;
                continue;
            }

            if (string.Equals(args[index], HoverPocketApplicationData.VoiceE2EFlag, StringComparison.OrdinalIgnoreCase))
            {
                voiceE2ERequested = true;
                continue;
            }

            if (string.Equals(args[index], HoverPocketApplicationData.VoiceE2ERootFlag, StringComparison.OrdinalIgnoreCase))
            {
                voiceE2ERoot = index + 1 < args.Length
                    ? args[++index]
                    : string.Empty;
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
            verifyCapabilities,
            verifyBroker,
            verifyCalendarLive,
            verifySettings,
            verifyAiLane,
            verifyVoiceLaneLayout,
            verifyCodexAppServer,
            verifyCodexAppServerProtocol,
            verifyCodexVoiceCoordinator,
            verifyVoiceE2EIsolation,
            verifyUpdater,
            verifyReleaseConfig,
            secondInstanceProbe,
            voiceE2ERequested,
            voiceE2ERoot,
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
