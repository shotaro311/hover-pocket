using System.Windows;
using HoverPocket.Shell.Configuration;
using HoverPocket.Shell.Display;
using HoverPocket.Shell.Interop;

namespace HoverPocket.Shell.Voice;

internal static class VoicePanelGeometry
{
    public const double CompactHeight = 64;

    public static double ExpandedHeight(PanelSize panelSize) => panelSize switch
    {
        PanelSize.Small => 190,
        PanelSize.Large => 250,
        _ => 220
    };

    public static VoiceLaneMode PreferredMode(UserSettings settings)
    {
        if (!settings.VoiceEnabled)
        {
            return VoiceLaneMode.Disabled;
        }
        return settings.VoiceLaneLayout == VoiceLaneLayoutPreference.Expanded
            ? VoiceLaneMode.Expanded
            : VoiceLaneMode.Compact;
    }

    public static VoiceLaneMode ResolveMode(
        UserSettings settings,
        double availableExtraHeightDips)
    {
        var preferred = PreferredMode(settings);
        if (preferred != VoiceLaneMode.Expanded)
        {
            return preferred;
        }
        return availableExtraHeightDips >= ExpandedHeight(settings.PanelSize)
            ? VoiceLaneMode.Expanded
            : VoiceLaneMode.Compact;
    }

    public static double Height(PanelSize panelSize, VoiceLaneMode mode) => mode switch
    {
        VoiceLaneMode.Compact => CompactHeight,
        VoiceLaneMode.Expanded => ExpandedHeight(panelSize),
        _ => 0
    };

    public static double TotalHeight(
        double baselinePanelHeight,
        PanelSize panelSize,
        VoiceLaneMode mode) =>
        baselinePanelHeight + Height(panelSize, mode);

    public static WindowPlacement ExtendDownward(
        WindowPlacement baseline,
        DisplayMonitor monitor,
        UserSettings settings,
        out VoiceLaneMode resolvedMode)
    {
        var scaleY = Math.Max(0.01, monitor.ScaleY);
        var monitorBottom = monitor.Bounds.Top + monitor.Bounds.Height;
        var baselineBottom = baseline.PhysicalRect.Top + baseline.PhysicalRect.Height;
        var availableExtraDips = Math.Max(0, monitorBottom - baselineBottom) / scaleY;
        resolvedMode = ResolveMode(settings, availableExtraDips);
        var extraDips = Height(settings.PanelSize, resolvedMode);
        var extraPhysical = (int)Math.Round(
            extraDips * scaleY,
            MidpointRounding.AwayFromZero);
        return new WindowPlacement(
            new Rect(
                baseline.DipRect.Left,
                baseline.DipRect.Top,
                baseline.DipRect.Width,
                baseline.DipRect.Height + extraDips),
            new PhysicalRect(
                baseline.PhysicalRect.Left,
                baseline.PhysicalRect.Top,
                baseline.PhysicalRect.Width,
                baseline.PhysicalRect.Height + extraPhysical));
    }
}
