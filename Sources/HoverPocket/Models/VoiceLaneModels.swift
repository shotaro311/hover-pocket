import Foundation

enum VoiceLaneLayoutMode: String, CaseIterable, Identifiable {
    case compact
    case expanded

    var id: String { rawValue }

    func title(language: AppLanguage) -> String {
        switch (self, language) {
        case (.compact, .japanese):
            return "コンパクト"
        case (.compact, .english):
            return "Compact"
        case (.expanded, .japanese):
            return "拡張"
        case (.expanded, .english):
            return "Expanded"
        }
    }
}

enum VoiceLaneDisplayMode: String, CaseIterable {
    case disabled
    case compact
    case expanded
}

enum VoiceLaneSpeaker: String {
    case user
    case assistant
}

struct VoiceLaneTranscriptLine: Identifiable, Equatable {
    let id: String
    let speaker: VoiceLaneSpeaker
    let text: String
    let timestamp: Date
}

enum VoiceLaneSessionState: String {
    case running
    case completed
    case failed
}

struct VoiceLaneSessionCard: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let state: VoiceLaneSessionState
    let elapsedSeconds: Int
}
