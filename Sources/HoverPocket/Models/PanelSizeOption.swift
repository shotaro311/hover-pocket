enum PanelSizeOption: String, CaseIterable, Identifiable {
    case small
    case medium
    case large

    var id: String { rawValue }

    var title: String {
        title(language: .english)
    }

    func title(language: AppLanguage) -> String {
        switch self {
        case .small:
            return AppText.text(.panelSizeSmall, language: language)
        case .medium:
            return AppText.text(.panelSizeMedium, language: language)
        case .large:
            return AppText.text(.panelSizeLarge, language: language)
        }
    }

    var shortTitle: String {
        shortTitle(language: .japanese)
    }

    func shortTitle(language: AppLanguage) -> String {
        switch self {
        case .small:
            return language == .japanese ? "小" : "S"
        case .medium:
            return language == .japanese ? "中" : "M"
        case .large:
            return language == .japanese ? "大" : "L"
        }
    }

    var detail: String {
        detail(language: .japanese)
    }

    func detail(language: AppLanguage) -> String {
        switch self {
        case .small:
            return AppText.text(.panelSizeSmallDetail, language: language)
        case .medium:
            return AppText.text(.panelSizeMediumDetail, language: language)
        case .large:
            return AppText.text(.panelSizeLargeDetail, language: language)
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
