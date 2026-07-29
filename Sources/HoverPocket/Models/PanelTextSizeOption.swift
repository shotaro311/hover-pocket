import CoreGraphics

enum PanelTextSizeOption: String, CaseIterable, Identifiable {
    case small = "small"
    case medium = "medium"
    case large = "large"
    case extraLarge = "extraLarge"

    var id: String { rawValue }

    func title(language: AppLanguage) -> String {
        switch self {
        case .small:
            return AppText.text(.panelTextSizeSmall, language: language)
        case .medium:
            return AppText.text(.panelTextSizeMedium, language: language)
        case .large:
            return AppText.text(.panelTextSizeLarge, language: language)
        case .extraLarge:
            return AppText.text(.panelTextSizeExtraLarge, language: language)
        }
    }

    func detail(language: AppLanguage) -> String {
        switch self {
        case .small:
            return AppText.text(.panelTextSizeSmallDetail, language: language)
        case .medium:
            return AppText.text(.panelTextSizeMediumDetail, language: language)
        case .large:
            return AppText.text(.panelTextSizeLargeDetail, language: language)
        case .extraLarge:
            return AppText.text(.panelTextSizeExtraLargeDetail, language: language)
        }
    }

    func scaled(_ size: CGFloat) -> CGFloat {
        switch self {
        case .small:
            return size
        case .medium:
            return size + 1
        case .large:
            return size + 2
        case .extraLarge:
            return size + 3
        }
    }
}
