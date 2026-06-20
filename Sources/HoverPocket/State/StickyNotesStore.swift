import Combine
import Foundation

@MainActor
final class StickyNotesStore: ObservableObject {
    static let shared = StickyNotesStore()

    @Published private(set) var notes: [StickyNoteItem] = []
    @Published private(set) var lastAction: StickyNoteUndoAction?
    @Published private(set) var lastErrorMessage: String?

    private let fileManager: FileManager

    private lazy var storageDirectory: URL = {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base
            .appendingPathComponent("HoverPocket", isDirectory: true)
            .appendingPathComponent("StickyNotes", isDirectory: true)
    }()

    private var notesURL: URL {
        storageDirectory.appendingPathComponent("notes.json", isDirectory: false)
    }

    var activeNotes: [StickyNoteItem] {
        notes
            .filter { $0.archivedAt == nil }
            .sorted { lhs, rhs in
                if lhs.sortIndex == rhs.sortIndex {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.sortIndex < rhs.sortIndex
            }
    }

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        load()
    }

    @discardableResult
    func createNote(default color: StickyNoteColor = .yellow) -> StickyNoteItem {
        let now = Date()
        let note = StickyNoteItem(
            id: UUID(),
            title: "",
            body: "",
            color: color,
            createdAt: now,
            updatedAt: now,
            archivedAt: nil,
            sortIndex: nextSortIndexForNewNote()
        )
        notes.append(note)
        lastAction = nil
        save()
        return note
    }

    @discardableResult
    func updateNote(id: UUID, title: String, body: String, color: StickyNoteColor) -> Bool {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return false }
        notes[index].title = title
        notes[index].body = body
        notes[index].color = color
        notes[index].updatedAt = Date()
        save()
        return true
    }

    @discardableResult
    func archiveNote(id: UUID) -> Bool {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return false }
        let previous = notes[index]
        notes[index].archivedAt = Date()
        notes[index].updatedAt = Date()
        lastAction = StickyNoteUndoAction(kind: .archived, note: previous, previousIndex: index)
        save()
        return true
    }

    @discardableResult
    func deleteNote(id: UUID) -> Bool {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return false }
        let removed = notes.remove(at: index)
        lastAction = StickyNoteUndoAction(kind: .deleted, note: removed, previousIndex: index)
        save()
        return true
    }

    @discardableResult
    func discardNote(id: UUID) -> Bool {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return false }
        notes.remove(at: index)
        save()
        return true
    }

    @discardableResult
    func undoLastAction() -> Bool {
        guard let action = lastAction else { return false }

        switch action.kind {
        case .archived:
            if let index = notes.firstIndex(where: { $0.id == action.note.id }) {
                notes[index] = action.note
            } else {
                notes.insert(action.note, at: insertionIndex(for: action.previousIndex))
            }
        case .deleted:
            if notes.contains(where: { $0.id == action.note.id }) {
                return false
            }
            notes.insert(action.note, at: insertionIndex(for: action.previousIndex))
        }

        lastAction = nil
        save()
        return true
    }

    @discardableResult
    func moveNote(id: UUID, toIndex destinationIndex: Int, saveImmediately: Bool = true) -> Bool {
        var active = activeNotes
        guard let currentIndex = active.firstIndex(where: { $0.id == id }) else { return false }

        let note = active.remove(at: currentIndex)
        let boundedDestination = min(max(destinationIndex, 0), active.count)
        active.insert(note, at: boundedDestination)

        let now = Date()
        for (index, activeNote) in active.enumerated() {
            guard let noteIndex = notes.firstIndex(where: { $0.id == activeNote.id }) else { continue }
            notes[noteIndex].sortIndex = Double(index)
            if activeNote.id == id {
                notes[noteIndex].updatedAt = now
            }
        }
        if saveImmediately {
            save()
        }
        return true
    }

    @discardableResult
    func saveNoteOrder() -> Bool {
        save()
        return true
    }

    private func nextSortIndexForNewNote() -> Double {
        guard let firstSortIndex = activeNotes.first?.sortIndex else { return 0 }
        return firstSortIndex - 1
    }

    private func insertionIndex(for preferredIndex: Int) -> Int {
        min(max(preferredIndex, 0), notes.count)
    }

    private func load() {
        guard let data = try? Data(contentsOf: notesURL) else { return }

        do {
            notes = try JSONDecoder().decode([StickyNoteItem].self, from: data)
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = "Sticky notes could not be loaded."
        }
    }

    private func save() {
        do {
            try ensureStorageDirectory()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(notes)
            try data.write(to: notesURL, options: .atomic)
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = "Sticky notes could not be saved."
        }
    }

    private func ensureStorageDirectory() throws {
        try fileManager.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
    }
}
