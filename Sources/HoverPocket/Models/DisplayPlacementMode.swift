enum DisplayPlacementMode: String, CaseIterable, Identifiable {
    case mainDisplay
    case secondaryDisplay
    case allDisplays

    var id: String {
        rawValue
    }

    var title: String {
        title(language: .english)
    }

    func title(language: AppLanguage) -> String {
        switch self {
        case .mainDisplay:
            AppText.text(.displayMain, language: language)
        case .secondaryDisplay:
            AppText.text(.displaySecondary, language: language)
        case .allDisplays:
            AppText.text(.displayAll, language: language)
        }
    }

    var detail: String {
        detail(language: .english)
    }

    func detail(language: AppLanguage) -> String {
        switch self {
        case .mainDisplay:
            AppText.text(.displayMainDetail, language: language)
        case .secondaryDisplay:
            AppText.text(.displaySecondaryDetail, language: language)
        case .allDisplays:
            AppText.text(.displayAllDetail, language: language)
        }
    }
}
