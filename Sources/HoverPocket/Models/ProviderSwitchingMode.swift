enum ProviderSwitchingMode: String, CaseIterable, Identifiable {
    case click
    case hover

    var id: String {
        rawValue
    }

    var title: String {
        title(language: .english)
    }

    func title(language: AppLanguage) -> String {
        switch self {
        case .click:
            return AppText.text(.click, language: language)
        case .hover:
            return AppText.text(.hover, language: language)
        }
    }

    var detail: String {
        detail(language: .japanese)
    }

    func detail(language: AppLanguage) -> String {
        switch self {
        case .click:
            return AppText.text(.iconSwitchingClickDetail, language: language)
        case .hover:
            return AppText.text(.iconSwitchingHoverDetail, language: language)
        }
    }
}
