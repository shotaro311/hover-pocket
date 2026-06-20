enum PanelSizeOption: String, CaseIterable, Identifiable {
    case small
    case medium
    case large

    var id: String { rawValue }

    var title: String {
        switch self {
        case .small:
            return "Small"
        case .medium:
            return "Medium"
        case .large:
            return "Large"
        }
    }

    var shortTitle: String {
        switch self {
        case .small:
            return "小"
        case .medium:
            return "中"
        case .large:
            return "大"
        }
    }

    var detail: String {
        switch self {
        case .small:
            return "コンパクトに表示します。"
        case .medium:
            return "現在の標準サイズです。"
        case .large:
            return "予定やクリップ履歴を少し広く表示します。"
        }
    }

    var next: PanelSizeOption {
        switch self {
        case .small:
            return .medium
        case .medium:
            return .large
        case .large:
            return .small
        }
    }
}
