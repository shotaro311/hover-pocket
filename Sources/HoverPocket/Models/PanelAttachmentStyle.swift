enum PanelAttachmentStyle: String, CaseIterable, Identifiable {
    case preserveMenu
    case coverMenu

    var id: String { rawValue }
    var blend: Double { self == .coverMenu ? 1 : 0 }

    func title(language: AppLanguage) -> String {
        switch self {
        case .preserveMenu: language == .japanese ? "メニューを残す" : "Keep menu visible"
        case .coverMenu: language == .japanese ? "上端まで覆う" : "Cover menu area"
        }
    }

    func detail(language: AppLanguage) -> String {
        switch self {
        case .preserveMenu:
            language == .japanese
                ? "ノッチから滑らかにつなぎ、左右のメニューバーを残します。"
                : "Connect smoothly to the notch while keeping the menu bar visible."
        case .coverMenu:
            language == .japanese
                ? "上端まで広げ、ノッチの左右にパネルの情報を表示します。重なるメニューは、開いている間だけ隠れます。"
                : "Extend to the top edge and show panel information beside the notch. Covered menus are hidden while the panel is open."
        }
    }
}
