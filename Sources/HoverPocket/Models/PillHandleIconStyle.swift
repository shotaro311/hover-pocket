enum PillHandleIconStyle: String, CaseIterable, Identifiable {
    case chevron
    case pocket
    case none

    var id: String {
        rawValue
    }

    var title: String {
        title(language: .english)
    }

    func title(language: AppLanguage) -> String {
        switch self {
        case .chevron:
            return "B"
        case .pocket:
            return "C"
        case .none:
            return AppText.text(.handleNone, language: language)
        }
    }

    var detail: String {
        detail(language: .japanese)
    }

    func detail(language: AppLanguage) -> String {
        switch self {
        case .chevron:
            return AppText.text(.handleChevronDetail, language: language)
        case .pocket:
            return AppText.text(.handlePocketDetail, language: language)
        case .none:
            return AppText.text(.handleNoneDetail, language: language)
        }
    }
}
