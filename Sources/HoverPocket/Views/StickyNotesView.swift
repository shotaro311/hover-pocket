import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct StickyNotesView: View {
    let actions: ProviderActions

    @ObservedObject private var store = StickyNotesStore.shared
    @Namespace private var cardNamespace
    @State private var selectedNoteID: UUID?
    @State private var hoveredNoteID: UUID?
    @State private var draggingNoteID: UUID?
    @State private var dropTargetNoteID: UUID?
    @State private var externalDragWorkItem: DispatchWorkItem?
    @State private var didBeginExternalDrag = false
    @State private var newNoteColor: StickyNoteColor?
    @State private var draftTitle = ""
    @State private var draftBody = ""
    @State private var draftColor: StickyNoteColor?
    @State private var undoToast: StickyNoteUndoToast?
    @State private var pendingNewNoteIDs = Set<UUID>()
    @State private var isArchiveDropTargeted = false

    private let gridSpacing: CGFloat = 10

    private var gridSize: StickyNoteGridSize {
        actions.settings.stickyNoteGridSize
    }

    var body: some View {
        VStack(spacing: 10) {
            StickyNoteHeaderView(
                count: store.activeNotes.count,
                errorMessage: store.lastErrorMessage,
                selectedNewNoteColor: newNoteColor,
                gridSize: actions.settings.stickyNoteGridSize,
                onSelectGridSize: { actions.settings.stickyNoteGridSize = $0 },
                onSelectNewNoteColor: { newNoteColor = $0 },
                onCreateWithColor: { createNote(color: $0) },
                onCreate: { createNote() }
            )

            ZStack(alignment: .bottom) {
                notesGrid

                if draggingNoteID != nil {
                    StickyNoteArchiveDropZone(isTargeted: isArchiveDropTargeted)
                        .padding(.horizontal, 4)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .onDrop(
                            of: [UTType.text.identifier],
                            delegate: StickyNoteArchiveDropDelegate(
                                store: store,
                                draggingNoteID: $draggingNoteID,
                                isTargeted: $isArchiveDropTargeted,
                                resetDragState: resetDragState,
                                showUndoToast: showUndoToast
                            )
                        )
                }

                if let undoToast, actions.settings.showStickyNoteUndoToast {
                    StickyNoteUndoToastView(
                        toast: undoToast,
                        onUndo: undoLastAction,
                        onHideFutureToasts: hideFutureUndoToasts
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .animation(.spring(response: 0.34, dampingFraction: 0.84), value: selectedNoteID)
        .animation(.easeOut(duration: 0.18), value: hoveredNoteID)
        .animation(.spring(response: 0.24, dampingFraction: 0.88), value: draggingNoteID)
        .animation(.spring(response: 0.24, dampingFraction: 0.88), value: isArchiveDropTargeted)
        .onAppear {
            if newNoteColor == nil {
                newNoteColor = StickyNoteColor.allCases.first
            }
        }
        .onChange(of: store.activeNotes.map(\.id)) { _, ids in
            if let selectedNoteID, !ids.contains(selectedNoteID) {
                self.selectedNoteID = nil
            }
            if let draggingNoteID, !ids.contains(draggingNoteID) {
                resetDragState()
            }
        }
    }

    @ViewBuilder
    private var notesGrid: some View {
        if store.activeNotes.isEmpty {
            StickyNoteEmptyStateView()
        } else {
            GeometryReader { geometry in
                let metrics = gridMetrics(for: geometry.size.width)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: gridSpacing) {
                        ForEach(Array(noteRows(columnCount: metrics.columnCount).enumerated()), id: \.offset) { _, row in
                            noteRow(row, metrics: metrics)
                        }
                    }
                    .animation(.spring(response: 0.24, dampingFraction: 0.88), value: store.activeNotes.map(\.id))
                    .frame(minHeight: geometry.size.height, alignment: .topLeading)
                    .padding(.bottom, bottomGridPadding)
                    .background(gridTapTarget)
                    .onDrop(
                        of: [UTType.text.identifier],
                        delegate: StickyNoteGridDropResetDelegate(
                            draggingNoteID: $draggingNoteID,
                            dropTargetNoteID: $dropTargetNoteID,
                            resetDragState: resetDragState
                        )
                    )
                }
                .scrollIndicators(.never)
            }
        }
    }

    @ViewBuilder
    private func noteRow(_ row: [StickyNoteItem], metrics: StickyNoteGridMetrics) -> some View {
        if row.count == 1, row[0].id == selectedNoteID {
            noteCard(row[0])
                .matchedGeometryEffect(id: row[0].id, in: cardNamespace)
                .frame(maxWidth: .infinity)
        } else {
            HStack(alignment: .top, spacing: gridSpacing) {
                ForEach(row) { note in
                    noteCard(note)
                        .matchedGeometryEffect(id: note.id, in: cardNamespace)
                        .frame(width: metrics.cardWidth)
                }

                if row.count < metrics.columnCount {
                    Spacer(minLength: 0)
                }
            }
        }
    }

    @ViewBuilder
    private func noteCard(_ note: StickyNoteItem) -> some View {
        if selectedNoteID == note.id {
            StickyNoteEditorCard(
                note: note,
                gridSize: gridSize,
                draftTitle: $draftTitle,
                draftBody: $draftBody,
                draftColor: $draftColor,
                onDraftChanged: updateSelectedDraft,
                onArchive: { archive(note) },
                onDelete: { delete(note) },
                onDone: finishEditing,
                contextMenu: { contextMenu(for: note) }
            )
        } else {
            StickyNotePreviewCard(
                note: note,
                gridSize: gridSize,
                isHovered: hoveredNoteID == note.id,
                isDragging: draggingNoteID == note.id,
                isDropTarget: dropTargetNoteID == note.id,
                onArchive: { archive(note) },
                contextMenu: { contextMenu(for: note) }
            )
            .onTapGesture {
                beginEditing(note)
            }
            .onHover { inside in
                hoveredNoteID = inside ? note.id : (hoveredNoteID == note.id ? nil : hoveredNoteID)
            }
            .onDrag {
                draggingNoteID = note.id
                didBeginExternalDrag = false
                scheduleExternalDragCheck()
                return dragProvider(for: note)
            }
            .onDrop(
                of: [UTType.text.identifier],
                delegate: StickyNoteReorderDropDelegate(
                    target: note,
                    store: store,
                    draggingNoteID: $draggingNoteID,
                    dropTargetNoteID: $dropTargetNoteID,
                    resetDragState: resetDragState
                )
            )
        }
    }

    @ViewBuilder
    private func contextMenu(for note: StickyNoteItem) -> some View {
        Button("Edit") {
            beginEditing(note)
        }

        Menu("Color") {
            ForEach(Array(StickyNoteColor.allCases)) { color in
                Button(StickyNoteStyle.colorName(for: color)) {
                    store.updateNote(id: note.id, title: note.title, body: note.body, color: color)
                    if selectedNoteID == note.id {
                        draftColor = color
                    }
                }
            }
        }

        Button("Archive") {
            archive(note)
        }

        Button("Delete", role: .destructive) {
            delete(note)
        }
    }

    private var gridTapTarget: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture {
                finishEditing()
            }
    }

    private func createNote(color: StickyNoteColor? = nil) {
        let beforeIDs = Set(store.activeNotes.map(\.id))
        store.createNote()
        guard let note = store.activeNotes.first(where: { !beforeIDs.contains($0.id) }) else {
            return
        }
        pendingNewNoteIDs.insert(note.id)
        let selectedColor = color ?? newNoteColor
        if let selectedColor {
            store.updateNote(id: note.id, title: note.title, body: note.body, color: selectedColor)
        }
        beginEditing(store.activeNotes.first(where: { $0.id == note.id }) ?? note)
    }

    private func beginEditing(_ note: StickyNoteItem) {
        if selectedNoteID != note.id {
            closeCurrentEditor()
        }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) {
            selectedNoteID = note.id
            draftTitle = note.title
            draftBody = note.body
            draftColor = note.color
        }
    }

    private func finishEditing() {
        guard selectedNoteID != nil else { return }
        closeCurrentEditor()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
            selectedNoteID = nil
        }
    }

    private func updateSelectedDraft() {
        guard let selectedNoteID, let draftColor else { return }
        store.updateNote(id: selectedNoteID, title: draftTitle, body: draftBody, color: draftColor)
    }

    private func closeCurrentEditor() {
        guard let selectedNoteID else { return }
        let isBlank = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            draftBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if pendingNewNoteIDs.contains(selectedNoteID), isBlank {
            store.discardNote(id: selectedNoteID)
            pendingNewNoteIDs.remove(selectedNoteID)
            return
        }

        updateSelectedDraft()
        pendingNewNoteIDs.remove(selectedNoteID)
    }

    private func archive(_ note: StickyNoteItem) {
        store.archiveNote(id: note.id)
        if selectedNoteID == note.id {
            selectedNoteID = nil
        }
        pendingNewNoteIDs.remove(note.id)
        showUndoToast("Archived")
    }

    private func delete(_ note: StickyNoteItem) {
        store.deleteNote(id: note.id)
        if selectedNoteID == note.id {
            selectedNoteID = nil
        }
        pendingNewNoteIDs.remove(note.id)
        showUndoToast("Deleted")
    }

    private func undoLastAction() {
        store.undoLastAction()
        withAnimation(.easeOut(duration: 0.16)) {
            undoToast = nil
        }
    }

    private func hideFutureUndoToasts() {
        actions.settings.showStickyNoteUndoToast = false
        withAnimation(.easeOut(duration: 0.16)) {
            undoToast = nil
        }
    }

    private func showUndoToast(_ message: String) {
        guard actions.settings.showStickyNoteUndoToast else { return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
            undoToast = StickyNoteUndoToast(message: message)
        }
    }

    private func gridMetrics(for availableWidth: CGFloat) -> StickyNoteGridMetrics {
        let columnCount = max(1, Int((availableWidth + gridSpacing) / (gridSize.minimumCardWidth + gridSpacing)))
        let spacingTotal = gridSpacing * CGFloat(columnCount - 1)
        let cardWidth = floor((availableWidth - spacingTotal) / CGFloat(columnCount))
        return StickyNoteGridMetrics(columnCount: columnCount, cardWidth: cardWidth)
    }

    private func noteRows(columnCount: Int) -> [[StickyNoteItem]] {
        var rows: [[StickyNoteItem]] = []
        var currentRow: [StickyNoteItem] = []

        for note in store.activeNotes {
            if note.id == selectedNoteID {
                if !currentRow.isEmpty {
                    rows.append(currentRow)
                    currentRow = []
                }
                rows.append([note])
                continue
            }

            currentRow.append(note)
            if currentRow.count == columnCount {
                rows.append(currentRow)
                currentRow = []
            }
        }

        if !currentRow.isEmpty {
            rows.append(currentRow)
        }

        return rows
    }

    private var bottomGridPadding: CGFloat {
        var padding: CGFloat = 2
        if undoToast != nil {
            padding += 44
        }
        if draggingNoteID != nil {
            padding += 54
        }
        return padding
    }

    private func scheduleExternalDragCheck(after delay: TimeInterval = 0.12) {
        externalDragWorkItem?.cancel()
        let workItem = DispatchWorkItem { [actions] in
            Task { @MainActor in
                guard draggingNoteID != nil, !didBeginExternalDrag else { return }
                guard isPointerOutsideActivePanel() else {
                    scheduleExternalDragCheck(after: 0.08)
                    return
                }
                didBeginExternalDrag = true
                actions.beginExternalDrag()
                resetDragState()
            }
        }
        externalDragWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func cancelExternalDragNotification() {
        externalDragWorkItem?.cancel()
        externalDragWorkItem = nil
    }

    private func resetDragState() {
        cancelExternalDragNotification()
        withAnimation(.easeOut(duration: 0.14)) {
            draggingNoteID = nil
            dropTargetNoteID = nil
            isArchiveDropTargeted = false
        }
        didBeginExternalDrag = false
        store.saveNoteOrder()
    }

    private func isPointerOutsideActivePanel() -> Bool {
        let location = NSEvent.mouseLocation
        let candidateWindows = NSApp.windows.filter { window in
            window.isVisible && window.level == .statusBar
        }
        guard !candidateWindows.isEmpty else { return false }
        return !candidateWindows.contains { window in
            window.frame.insetBy(dx: -2, dy: -2).contains(location)
        }
    }

    private func dragProvider(for note: StickyNoteItem) -> NSItemProvider {
        let parts = [note.displayTitle, note.body]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let text = parts.joined(separator: "\n\n")
        let provider = NSItemProvider(object: text as NSString)
        provider.suggestedName = note.displayTitle.isEmpty ? "Sticky Note" : note.displayTitle
        return provider
    }
}
