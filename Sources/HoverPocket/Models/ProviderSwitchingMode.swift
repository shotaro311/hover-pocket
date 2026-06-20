enum ProviderSwitchingMode: String, CaseIterable, Identifiable {
    case click
    case hover

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .click:
            return "Click"
        case .hover:
            return "Hover"
        }
    }

    var detail: String {
        switch self {
        case .click:
            return "アイコンをクリックしたときにパネルを切り替えます。"
        case .hover:
            return "アイコンにポインタを重ねるだけでパネルを切り替えます。"
        }
    }
}
