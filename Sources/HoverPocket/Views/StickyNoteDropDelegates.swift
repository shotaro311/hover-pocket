import SwiftUI

struct StickyNoteGridMetrics {
    let columnCount: Int
    let cardWidth: CGFloat
}

struct StickyNoteGridDropResetDelegate: DropDelegate {
    @Binding var draggingNoteID: UUID?
    @Binding var dropTargetNoteID: UUID?
    let resetDragState: () -> Void

    func validateDrop(info: DropInfo) -> Bool {
        draggingNoteID != nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard draggingNoteID != nil else { return nil }
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard draggingNoteID != nil else { return false }
        resetDragState()
        return true
    }

    func dropExited(info: DropInfo) {
        if draggingNoteID == nil {
            dropTargetNoteID = nil
        }
    }
}

struct StickyNoteArchiveDropDelegate: DropDelegate {
    let store: StickyNotesStore
    @Binding var draggingNoteID: UUID?
    @Binding var isTargeted: Bool
    let resetDragState: () -> Void
    let showUndoToast: (String) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        draggingNoteID != nil
    }

    func dropEntered(info: DropInfo) {
        isTargeted = draggingNoteID != nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard draggingNoteID != nil else { return nil }
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let draggingNoteID else { return false }
        let didArchive = store.archiveNote(id: draggingNoteID)
        resetDragState()
        if didArchive {
            showUndoToast("Archived")
        }
        return didArchive
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }
}

struct StickyNoteReorderDropDelegate: DropDelegate {
    let target: StickyNoteItem
    let store: StickyNotesStore
    @Binding var draggingNoteID: UUID?
    @Binding var dropTargetNoteID: UUID?
    let resetDragState: () -> Void

    func dropEntered(info: DropInfo) {
        guard let draggingNoteID, draggingNoteID != target.id else { return }
        dropTargetNoteID = target.id
        guard let sourceIndex = store.activeNotes.firstIndex(where: { $0.id == draggingNoteID }),
              let targetIndex = store.activeNotes.firstIndex(where: { $0.id == target.id }),
              sourceIndex != targetIndex
        else {
            return
        }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
            _ = store.moveNote(id: draggingNoteID, toIndex: targetIndex, saveImmediately: false)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        resetDragState()
        return true
    }

    func dropExited(info: DropInfo) {
        if dropTargetNoteID == target.id {
            dropTargetNoteID = nil
        }
    }
}
