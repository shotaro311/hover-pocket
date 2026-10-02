namespace HoverPocket.Shell.Configuration;

internal enum PanelAttachmentStyle { PreserveMenu, CoverMenu }

internal static class PanelAttachment
{
    // Windows monitor enumeration exposes no physical notch; resolve per destination.
    public static PanelAttachmentStyle Resolve(UserSettings settings, bool hasNotch = false) =>
        settings.AutomaticScreenEdgeAttachment && !hasNotch
            ? PanelAttachmentStyle.CoverMenu : settings.PanelAttachmentStyle;

    public static string WireValue(PanelAttachmentStyle style) =>
        style == PanelAttachmentStyle.CoverMenu ? "coverMenu" : "preserveMenu";
}
