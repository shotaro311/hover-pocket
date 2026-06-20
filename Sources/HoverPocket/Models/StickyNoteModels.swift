import Foundation
import SwiftUI

struct StickyNoteItem: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var title: String
    var body: String
    var color: StickyNoteColor
    var createdAt: Date
    var updatedAt: Date
    var archivedAt: Date?
    var sortIndex: Double

    var displayTitle: String {
        displayTitle(language: .english)
    }

    func displayTitle(language: AppLanguage) -> String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            return trimmedTitle
        }

        if let firstBodyLine = body
            .components(separatedBy: .newlines)
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) {
            return firstBodyLine
        }

        return AppText.text(.stickyUntitledNote, language: language)
    }

    var previewText: String {
        body
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var cardPreviewText: String {
        let bodyLines = body
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return bodyLines.joined(separator: " ")
        }

        return bodyLines.dropFirst().joined(separator: " ")
    }
}

enum StickyNoteColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case yellow
    case pink
    case mint
    case blue
    case lavender

    var id: String {
        rawValue
    }

    var title: String {
        title(language: .english)
    }

    func title(language: AppLanguage) -> String {
        switch self {
        case .yellow:
            return AppText.text(.stickyYellow, language: language)
        case .pink:
            return AppText.text(.stickyPink, language: language)
        case .mint:
            return AppText.text(.stickyMint, language: language)
        case .blue:
            return AppText.text(.stickyBlue, language: language)
        case .lavender:
            return AppText.text(.stickyLavender, language: language)
        }
    }

    var color: Color {
        switch self {
        case .yellow:
            return Color(red: 1.0, green: 0.86, blue: 0.28)
        case .pink:
            return Color(red: 1.0, green: 0.55, blue: 0.70)
        case .mint:
            return Color(red: 0.48, green: 0.88, blue: 0.70)
        case .blue:
            return Color(red: 0.48, green: 0.72, blue: 1.0)
        case .lavender:
            return Color(red: 0.74, green: 0.62, blue: 1.0)
        }
    }
}

enum StickyNoteGridSize: String, Codable, CaseIterable, Identifiable, Sendable {
    case small
    case medium
    case large

    var id: String {
        rawValue
    }

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
        shortTitle(language: .english)
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

    var minimumCardWidth: CGFloat {
        switch self {
        case .small:
            return 96
        case .medium:
            return 118
        case .large:
            return 150
        }
    }

    var cardMinHeight: CGFloat {
        switch self {
        case .small:
            return 88
        case .medium:
            return 108
        case .large:
            return 132
        }
    }

    var titleFontSize: CGFloat {
        switch self {
        case .small:
            return 11
        case .medium:
            return 12
        case .large:
            return 13
        }
    }

    var bodyFontSize: CGFloat {
        switch self {
        case .small:
            return 9.5
        case .medium:
            return 10.5
        case .large:
            return 11.5
        }
    }

    var bodyLineLimit: Int {
        switch self {
        case .small:
            return 3
        case .medium:
            return 4
        case .large:
            return 5
        }
    }

    var editorMinHeight: CGFloat {
        switch self {
        case .small:
            return 168
        case .medium:
            return 192
        case .large:
            return 232
        }
    }

    var editorBodyMinHeight: CGFloat {
        switch self {
        case .small:
            return 78
        case .medium:
            return 92
        case .large:
            return 126
        }
    }
}

enum StickyNoteUndoActionKind: Equatable, Sendable {
    case archived
    case deleted
}

struct StickyNoteUndoAction: Identifiable, Equatable, Sendable {
    let id: UUID
    let kind: StickyNoteUndoActionKind
    let note: StickyNoteItem
    let previousIndex: Int

    init(kind: StickyNoteUndoActionKind, note: StickyNoteItem, previousIndex: Int) {
        self.id = UUID()
        self.kind = kind
        self.note = note
        self.previousIndex = previousIndex
    }

    var message: String {
        message(language: .english)
    }

    func message(language: AppLanguage) -> String {
        switch kind {
        case .archived:
            return AppText.text(.stickyArchived, language: language)
        case .deleted:
            return AppText.text(.stickyDeleted, language: language)
        }
    }
}
