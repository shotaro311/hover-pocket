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

        return "Untitled note"
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
        switch self {
        case .yellow:
            return "Yellow"
        case .pink:
            return "Pink"
        case .mint:
            return "Mint"
        case .blue:
            return "Blue"
        case .lavender:
            return "Lavender"
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
        switch kind {
        case .archived:
            return "Note archived"
        case .deleted:
            return "Note deleted"
        }
    }
}
