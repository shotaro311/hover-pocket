import Combine
import Foundation

@MainActor
final class StickyNotesStore: ObservableObject {
    static let shared = StickyNotesStore()

    @Published private(set) var notes: [StickyNoteItem] = []
    @Published private(set) var lastAction: StickyNoteUndoAction?
    @Published private(set) var lastErrorMessage: String?

    private let fileManager: FileManager
    private let storageDirectory: URL
    private var persistedNotes: [StickyNoteItem] = []

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

    init(storageDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.storageDirectory = storageDirectory
            ?? HoverPocketRuntimeEnvironment.shared.storageDirectory("StickyNotes")
        load()
    }

    func note(id: UUID) -> StickyNoteItem? {
        notes.first { $0.id == id }
    }

    func dueReminders(at date: Date = Date()) -> [StickyNoteItem] {
        notes.filter {
            $0.archivedAt == nil && $0.reminder?.acknowledgedAt == nil
                && ($0.reminder.map { $0.scheduledAt <= date } ?? false)
        }.sorted {
            if $0.reminder!.scheduledAt == $1.reminder!.scheduledAt {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.reminder!.scheduledAt < $1.reminder!.scheduledAt
        }
    }

    @discardableResult
    func acknowledgeReminder(noteID: UUID, scheduledAt: Date, at date: Date = Date()) throws -> Bool {
        guard let index = notes.firstIndex(where: { $0.id == noteID && $0.archivedAt == nil }),
              let reminder = notes[index].reminder,
              reminder.scheduledAt == scheduledAt, reminder.scheduledAt <= date,
              reminder.acknowledgedAt == nil else { return false }
        var candidate = notes
        candidate[index].reminder?.acknowledgedAt = date
        candidate[index].updatedAt = date
        try commit(candidate, lastAction: lastAction)
        return true
    }

    @discardableResult
    func upsertNote(
        stableKey: String,
        title: String,
        body: String,
        color: StickyNoteColor,
        reminderChange: StickyNoteReminderChange = .unchanged,
        id: UUID = UUID(),
        at date: Date = Date()
    ) throws -> StickyNoteItem {
        var candidate = notes
        let note: StickyNoteItem
        if let index = candidate.firstIndex(where: { $0.stableKey == stableKey }) {
            candidate[index].title = title
            candidate[index].body = body
            candidate[index].color = color
            candidate[index].updatedAt = date
            candidate[index].archivedAt = nil
            try apply(reminderChange, to: &candidate[index], at: date)
            note = candidate[index]
        } else {
            var created = StickyNoteItem(
                id: id, stableKey: stableKey, title: title, body: body, color: color,
                createdAt: date, updatedAt: date, archivedAt: nil,
                sortIndex: nextSortIndexForNewNote()
            )
            try apply(reminderChange, to: &created, at: date)
            note = created
            candidate.append(created)
        }
        try commit(candidate, lastAction: nil)
        return note
    }

    func editForCapability(id: UUID, title: String?, body: String?, color: StickyNoteColor?, at date: Date) throws {
        guard let index = notes.firstIndex(where: { $0.id == id && $0.archivedAt == nil }) else {
            throw CapabilityHandlerError.unavailable("note_not_found")
        }
        var candidate = notes
        if let title { candidate[index].title = title }
        if let body { candidate[index].body = body }
        if let color { candidate[index].color = color }
        candidate[index].updatedAt = date
        try commit(candidate, lastAction: lastAction)
    }

    @discardableResult
    func createNote(default color: StickyNoteColor = .yellow) -> StickyNoteItem {
        let now = Date()
        let note = StickyNoteItem(
            id: UUID(), title: "", body: "", color: color,
            createdAt: now, updatedAt: now, archivedAt: nil,
            sortIndex: nextSortIndexForNewNote()
        )
        _ = commitOrReport(notes + [note], lastAction: nil)
        return note
    }

    @discardableResult
    func updateNote(
        id: UUID, title: String, body: String, color: StickyNoteColor,
        reminderChange: StickyNoteReminderChange = .unchanged, at date: Date = Date()
    ) -> Bool {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return false }
        var candidate = notes
        candidate[index].title = title
        candidate[index].body = body
        candidate[index].color = color
        candidate[index].updatedAt = date
        do {
            try apply(reminderChange, to: &candidate[index], at: date)
            try commit(candidate, lastAction: lastAction)
            return true
        } catch {
            report(error)
            return false
        }
    }

    @discardableResult
    func updateReminder(id: UUID, reminderChange: StickyNoteReminderChange, at date: Date = Date()) -> Bool {
        guard let index = notes.firstIndex(where: { $0.id == id && $0.archivedAt == nil }) else { return false }
        var candidate = notes
        do {
            try apply(reminderChange, to: &candidate[index], at: date)
            candidate[index].updatedAt = date
            try commit(candidate, lastAction: lastAction)
            return true
        } catch {
            report(error)
            return false
        }
    }

    @discardableResult
    func archiveNote(id: UUID) -> Bool {
        do { return try archiveNoteAtomically(id: id) != nil }
        catch { return false }
    }

    @discardableResult
    func archiveNoteAtomically(id: UUID, at date: Date = Date()) throws -> StickyNoteItem? {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return nil }
        if notes[index].archivedAt != nil { return notes[index] }
        var candidate = notes
        let previous = candidate[index]
        candidate[index].archivedAt = date
        candidate[index].updatedAt = date
        try commit(candidate, lastAction: StickyNoteUndoAction(kind: .archived, note: previous, previousIndex: index))
        return candidate[index]
    }

    @discardableResult
    func deleteNote(id: UUID) -> Bool {
        do { return try deleteNoteAtomically(id: id) }
        catch { return false }
    }

    @discardableResult
    func deleteNoteAtomically(id: UUID) throws -> Bool {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return false }
        var candidate = notes
        let removed = candidate.remove(at: index)
        try commit(candidate, lastAction: StickyNoteUndoAction(kind: .deleted, note: removed, previousIndex: index))
        return true
    }

    @discardableResult
    func discardNote(id: UUID) -> Bool {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return false }
        var candidate = notes
        candidate.remove(at: index)
        return commitOrReport(candidate, lastAction: lastAction)
    }

    @discardableResult
    func undoLastAction() -> Bool {
        guard let action = lastAction else { return false }
        var candidate = notes
        switch action.kind {
        case .archived:
            if let index = candidate.firstIndex(where: { $0.id == action.note.id }) {
                candidate[index] = action.note
            } else {
                candidate.insert(action.note, at: min(max(action.previousIndex, 0), candidate.count))
            }
        case .deleted:
            if candidate.contains(where: { $0.id == action.note.id }) { return false }
            candidate.insert(action.note, at: min(max(action.previousIndex, 0), candidate.count))
        }
        return commitOrReport(candidate, lastAction: nil)
    }

    @discardableResult
    func moveNote(id: UUID, toIndex destinationIndex: Int, saveImmediately: Bool = true) -> Bool {
        var active = activeNotes
        guard let currentIndex = active.firstIndex(where: { $0.id == id }) else { return false }
        let note = active.remove(at: currentIndex)
        active.insert(note, at: min(max(destinationIndex, 0), active.count))
        var candidate = notes
        let now = Date()
        for (index, activeNote) in active.enumerated() {
            guard let noteIndex = candidate.firstIndex(where: { $0.id == activeNote.id }) else { continue }
            candidate[noteIndex].sortIndex = Double(index)
            if activeNote.id == id { candidate[noteIndex].updatedAt = now }
        }
        if saveImmediately { return commitOrReport(candidate, lastAction: lastAction) }
        notes = candidate
        return true
    }

    @discardableResult
    func saveNoteOrder() -> Bool {
        if commitOrReport(notes, lastAction: lastAction) { return true }
        notes = persistedNotes
        return false
    }

    private func nextSortIndexForNewNote() -> Double {
        guard let firstSortIndex = activeNotes.first?.sortIndex else { return 0 }
        return firstSortIndex - 1
    }

    private func apply(_ change: StickyNoteReminderChange, to note: inout StickyNoteItem, at date: Date) throws {
        switch change {
        case .unchanged: break
        case .clear: note.reminder = nil
        case .set(let scheduledAt, let timeZone):
            guard scheduledAt.timeIntervalSinceReferenceDate.isFinite, scheduledAt > date else {
                throw StickyNoteReminderError.invalidSchedule
            }
            guard TimeZone(identifier: timeZone) != nil else { throw StickyNoteReminderError.invalidTimeZone }
            note.reminder = StickyNoteReminder(scheduledAt: scheduledAt, timeZone: timeZone)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: notesURL) else { return }
        do {
            notes = try JSONDecoder().decode([StickyNoteItem].self, from: data)
            persistedNotes = notes
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = "Sticky notes could not be loaded."
        }
    }

    private func commitOrReport(_ candidate: [StickyNoteItem], lastAction action: StickyNoteUndoAction?) -> Bool {
        do {
            try commit(candidate, lastAction: action)
            return true
        } catch { return false }
    }

    private func commit(_ candidate: [StickyNoteItem], lastAction action: StickyNoteUndoAction?) throws {
        do {
            try fileManager.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(candidate)
            try prepareReminderBackupIfNeeded(candidate)
            try data.write(to: notesURL, options: .atomic)
            persistedNotes = candidate
            lastAction = action
            lastErrorMessage = nil
            notes = candidate
        } catch {
            report(error)
            throw error
        }
    }

    private func report(_ error: Error) {
        lastErrorMessage = (error as? StickyNoteReminderError)?.errorDescription
            ?? "Sticky notes could not be saved. / 付箋を保存できませんでした。"
    }

    private func prepareReminderBackupIfNeeded(_ candidate: [StickyNoteItem]) throws {
        guard candidate.contains(where: { $0.reminder != nil }),
              fileManager.fileExists(atPath: notesURL.path) else { return }
        let prefix = "notes.before-reminders-"
        let files = try fileManager.contentsOfDirectory(
            at: storageDirectory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        for file in files where file.lastPathComponent.hasPrefix(prefix) && file.pathExtension == "json" {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isRegularFile == true && values.isSymbolicLink != true { return }
        }
        let previousData = try Data(contentsOf: notesURL)
        let previous = try JSONDecoder().decode([StickyNoteItem].self, from: previousData)
        // A newly created store may already contain reminders without any legacy file to preserve.
        guard previous.allSatisfy({ $0.reminder == nil }) else { return }
        let backupURL = storageDirectory.appendingPathComponent("\(prefix)\(UUID().uuidString).json")
        try fileManager.copyItem(at: notesURL, to: backupURL)
    }
}
