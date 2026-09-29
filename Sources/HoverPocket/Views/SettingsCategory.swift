import Foundation

enum SettingsCategory: String, CaseIterable, Identifiable {
    case appearance, features, tools, voice, connections, data, general

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .appearance: "rectangle.topthird.inset.filled"
        case .features: "square.grid.2x2"
        case .tools: "sparkles.rectangle.stack"
        case .voice: "waveform"
        case .connections: "calendar"
        case .data: "externaldrive"
        case .general: "gearshape"
        }
    }

    func title(language: AppLanguage) -> String {
        let titles: (String, String) = switch self {
        case .appearance: ("表示と操作", "Appearance")
        case .features: ("機能", "Features")
        case .tools: ("自作ツール", "Personal Tools")
        case .voice: ("音声・AI", "Voice & AI")
        case .connections: ("カレンダー・天気", "Calendar & Weather")
        case .data: ("データと履歴", "Data & History")
        case .general: ("一般", "General")
        }
        return language == .japanese ? titles.0 : titles.1
    }

    func detail(language: AppLanguage) -> String {
        let descriptions: (String, String) = switch self {
        case .appearance: ("パネルの大きさ、文字、表示先と開き方を調整します。", "Adjust panel size, text, displays, and how the panel opens.")
        case .features: ("表示する機能と、各機能の動作を選びます。", "Choose visible features and how they behave.")
        case .tools: ("欲しい機能を言葉で伝えて、作成・修正・管理できます。", "Describe a tool to create, edit, and manage it.")
        case .voice: ("音声の接続先、アカウントと操作の確認方法を設定します。", "Set up voice providers, accounts, and action confirmations.")
        case .connections: ("Googleカレンダーの接続と天気の地域を設定します。", "Connect Google Calendar and choose your weather location.")
        case .data: ("AI操作の実行履歴と保存期間を管理します。ツールと記録のバックアップは「自作ツール」にあります。", "Manage AI action history and retention. Tool and record backups are in Personal Tools.")
        case .general: ("表示言語とアプリのアップデートを確認します。", "Choose a language and check for app updates.")
        }
        return language == .japanese ? descriptions.0 : descriptions.1
    }
}
