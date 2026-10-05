import Foundation

enum SettingsCategory: String, CaseIterable, Identifiable {
    case general, appearance, library, capture, ai, advanced

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "rectangle.topthird.inset.filled"
        case .library: "photo.stack"
        case .capture: "camera"
        case .ai: "sparkles"
        case .advanced: "slider.horizontal.3"
        }
    }

    func title(language: AppLanguage) -> String {
        let titles: (String, String) = switch self {
        case .general: ("一般", "General")
        case .appearance: ("表示", "Appearance")
        case .library: ("素材と同期", "Library & Sync")
        case .capture: ("撮影", "Capture")
        case .ai: ("AI", "AI")
        case .advanced: ("詳細", "Advanced")
        }
        return language == .japanese ? titles.0 : titles.1
    }

    static func available(externalIntegrationsEnabled: Bool) -> [Self] {
        allCases.filter { externalIntegrationsEnabled || ($0 != .library && $0 != .capture) }
    }
}
