enum PillHandleIconStyle: String, CaseIterable, Identifiable {
    case chevron
    case pocket
    case none

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .chevron:
            return "B"
        case .pocket:
            return "C"
        case .none:
            return "None"
        }
    }

    var detail: String {
        switch self {
        case .chevron:
            return "小さな下向きマークを表示します。"
        case .pocket:
            return "ポケット形状の小さなマークを表示します。"
        case .none:
            return "マークなしで、ノッチに合わせた形だけを表示します。"
        }
    }
}
