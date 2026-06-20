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
    @State private var newNoteColor: StickyNoteColor?
    @State private var draftTitle = ""
    @State private var draftBody = ""
    @State private var draftColor: StickyNoteColor?
    @State private var undoToast: StickyNoteUndoToast?

    private let gridSpacing: CGFloat = 10
    private let minimumCardWidth: CGFloat = 118

    var body: some View {
        VStack(spacing: 10) {
            header

            ZStack(alignment: .bottom) {
                notesGrid

                if let undoToast, actions.settings.showStickyNoteUndoToast {
                    undoToastView(undoToast)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .animation(.spring(response: 0.34, dampingFraction: 0.84), value: selectedNoteID)
        .animation(.easeOut(duration: 0.18), value: hoveredNoteID)
        .animation(.easeOut(duration: 0.18), value: draggingNoteID)
        .onAppear {
            if newNoteColor == nil {
                newNoteColor = StickyNoteColor.allCases.first
            }
        }
        .onChange(of: store.activeNotes.map(\.id)) { _, ids in
            guard let selectedNoteID, !ids.contains(selectedNoteID) else { return }
            self.selectedNoteID = nil
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("Notes", systemImage: "square.grid.2x2")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.64))

            Text("\(store.activeNotes.count)")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.38))

            if let message = store.lastErrorMessage {
                Text(message)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.yellow.opacity(0.86))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            colorSwatches(selectedColor: newNoteColor) { color in
                newNoteColor = color
            }

            Button {
                createNote()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(IconButtonStyle(selected: false))
            .help("New note")
        }
    }

    private var notesGrid: some View {
        Group {
            if store.activeNotes.isEmpty {
                emptyState
            } else {
                GeometryReader { geometry in
                    let metrics = gridMetrics(for: geometry.size.width)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: gridSpacing) {
                            ForEach(Array(noteRows(columnCount: metrics.columnCount).enumerated()), id: \.offset) { _, row in
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
                        }
                        .padding(.bottom, undoToast == nil ? 2 : 44)
                    }
                    .scrollIndicators(.never)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var emptyState: some View {
        VStack(spacing: 7) {
            Image(systemName: "note.text")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white.opacity(0.28))

            Text("No notes")
                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func noteCard(_ note: StickyNoteItem) -> some View {
        if selectedNoteID == note.id {
            editorCard(note)
        } else {
            previewCard(note)
        }
    }

    private func previewCard(_ note: StickyNoteItem) -> some View {
        let isHovered = hoveredNoteID == note.id
        let isDragging = draggingNoteID == note.id
        let isDropTarget = dropTargetNoteID == note.id
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Text(note.displayTitle)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.black.opacity(0.78))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                if isHovered || isDropTarget {
                    Button {
                        archive(note)
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.black.opacity(0.54))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.white.opacity(0.36)))
                    .help("Archive")
                    .transition(.scale.combined(with: .opacity))
                }
            }

            if !note.cardPreviewText.isEmpty {
                Text(note.cardPreviewText)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.black.opacity(0.58))
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Text(note.updatedAt.formatted(.dateTime.hour().minute()))
                .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.black.opacity(0.34))
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
        .background(cardBackground(note.color, isSelected: false, isDropTarget: isDropTarget))
        .opacity(isDragging ? 0.42 : 1)
        .scaleEffect(isHovered ? 1.015 : 1, anchor: .center)
        .shadow(color: paperShadow(for: note.color), radius: isHovered ? 12 : 7, y: isHovered ? 7 : 4)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture {
            beginEditing(note)
        }
        .onHover { inside in
            hoveredNoteID = inside ? note.id : (hoveredNoteID == note.id ? nil : hoveredNoteID)
        }
        .contextMenu {
            contextMenu(for: note)
        }
        .onDrag {
            draggingNoteID = note.id
            scheduleExternalDragNotification()
            return dragProvider(for: note)
        }
        .onDrop(
            of: [UTType.text.identifier],
            delegate: StickyNoteReorderDropDelegate(
                target: note,
                store: store,
                draggingNoteID: $draggingNoteID,
                dropTargetNoteID: $dropTargetNoteID,
                cancelExternalDrag: cancelExternalDragNotification
            )
        )
    }

    private func editorCard(_ note: StickyNoteItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                colorSwatches(selectedColor: draftColor) { color in
                    draftColor = color
                    updateSelectedDraft()
                }

                Spacer(minLength: 4)

                Button {
                    archive(note)
                } label: {
                    Image(systemName: "checkmark")
                }
                .buttonStyle(IconButtonStyle(selected: false))
                .help("Archive")

                Button(role: .destructive) {
                    delete(note)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(IconButtonStyle(selected: false))
                .help("Delete")

                Button {
                    finishEditing()
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                }
                .buttonStyle(IconButtonStyle(selected: true))
                .help("Done")
            }

            TextField("Title", text: $draftTitle)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.black.opacity(0.78))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.28))
                )
                .onChange(of: draftTitle) { _, _ in
                    updateSelectedDraft()
                }

            TextEditor(text: $draftBody)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.black.opacity(0.68))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 92)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.22))
                )
                .onChange(of: draftBody) { _, _ in
                    updateSelectedDraft()
                }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 192, alignment: .topLeading)
        .background(cardBackground(draftColor ?? note.color, isSelected: true, isDropTarget: false))
        .shadow(color: paperShadow(for: draftColor ?? note.color), radius: 16, y: 9)
        .contextMenu {
            contextMenu(for: note)
        }
        .transition(.scale(scale: 0.96).combined(with: .opacity))
    }

    @ViewBuilder
    private func contextMenu(for note: StickyNoteItem) -> some View {
        Button("Edit") {
            beginEditing(note)
        }

        Menu("Color") {
            ForEach(Array(StickyNoteColor.allCases)) { color in
                Button(colorName(for: color)) {
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

    private func colorSwatches(
        selectedColor: StickyNoteColor?,
        onSelect: @escaping (StickyNoteColor) -> Void
    ) -> some View {
        HStack(spacing: 5) {
            ForEach(Array(StickyNoteColor.allCases)) { color in
                Button {
                    onSelect(color)
                } label: {
                    Circle()
                        .fill(paperColor(for: color))
                        .frame(width: 13, height: 13)
                        .overlay {
                            Circle()
                                .stroke(Color.white.opacity(selectedColor?.id == color.id ? 0.72 : 0.18), lineWidth: selectedColor?.id == color.id ? 1.4 : 0.8)
                        }
                }
                .buttonStyle(.plain)
                .help(colorName(for: color))
            }
        }
    }

    private func undoToastView(_ toast: StickyNoteUndoToast) -> some View {
        HStack(spacing: 8) {
            Text(toast.message)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.76))
                .lineLimit(1)

            Spacer(minLength: 4)

            Button("Undo") {
                store.undoLastAction()
                withAnimation(.easeOut(duration: 0.16)) {
                    undoToast = nil
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)

            Button("Don't show") {
                actions.settings.showStickyNoteUndoToast = false
                withAnimation(.easeOut(duration: 0.16)) {
                    undoToast = nil
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(.white.opacity(0.48))
            .help("Hide undo toast from now on")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
        .padding(.horizontal, 6)
        .padding(.bottom, 2)
    }

    private func cardBackground(
        _ color: StickyNoteColor,
        isSelected: Bool,
        isDropTarget: Bool
    ) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        paperColor(for: color).opacity(isSelected ? 0.98 : 0.94),
                        paperColor(for: color).mix(with: .black, by: isSelected ? 0.07 : 0.11)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(isSelected || isDropTarget ? 0.34 : 0.12), lineWidth: isSelected || isDropTarget ? 1.2 : 0.8)
            )
    }

    private func createNote() {
        let beforeIDs = Set(store.activeNotes.map(\.id))
        store.createNote()
        guard let note = store.activeNotes.first(where: { !beforeIDs.contains($0.id) }) else {
            return
        }
        if let newNoteColor {
            store.updateNote(id: note.id, title: note.title, body: note.body, color: newNoteColor)
        }
        beginEditing(store.activeNotes.first(where: { $0.id == note.id }) ?? note)
    }

    private func beginEditing(_ note: StickyNoteItem) {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) {
            selectedNoteID = note.id
            draftTitle = note.title
            draftBody = note.body
            draftColor = note.color
        }
    }

    private func finishEditing() {
        updateSelectedDraft()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
            selectedNoteID = nil
        }
    }

    private func updateSelectedDraft() {
        guard let selectedNoteID, let draftColor else { return }
        store.updateNote(id: selectedNoteID, title: draftTitle, body: draftBody, color: draftColor)
    }

    private func archive(_ note: StickyNoteItem) {
        store.archiveNote(id: note.id)
        if selectedNoteID == note.id {
            selectedNoteID = nil
        }
        showUndoToast("Archived")
    }

    private func delete(_ note: StickyNoteItem) {
        store.deleteNote(id: note.id)
        if selectedNoteID == note.id {
            selectedNoteID = nil
        }
        showUndoToast("Deleted")
    }

    private func showUndoToast(_ message: String) {
        guard actions.settings.showStickyNoteUndoToast else { return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
            undoToast = StickyNoteUndoToast(message: message)
        }
    }

    private func gridMetrics(for availableWidth: CGFloat) -> StickyNoteGridMetrics {
        let columnCount = max(1, Int((availableWidth + gridSpacing) / (minimumCardWidth + gridSpacing)))
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

    private func scheduleExternalDragNotification() {
        externalDragWorkItem?.cancel()
        let workItem = DispatchWorkItem { [actions] in
            Task { @MainActor in
                actions.beginExternalDrag()
            }
        }
        externalDragWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: workItem)
    }

    private func cancelExternalDragNotification() {
        externalDragWorkItem?.cancel()
        externalDragWorkItem = nil
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

    private func paperColor(for color: StickyNoteColor) -> Color {
        let name = String(describing: color).lowercased()
        if name.contains("pink") {
            return Color(red: 1.0, green: 0.70, blue: 0.80)
        }
        if name.contains("mint") || name.contains("green") {
            return Color(red: 0.67, green: 0.91, blue: 0.76)
        }
        if name.contains("blue") {
            return Color(red: 0.66, green: 0.84, blue: 1.0)
        }
        if name.contains("lavender") || name.contains("purple") {
            return Color(red: 0.78, green: 0.73, blue: 1.0)
        }
        return Color(red: 1.0, green: 0.89, blue: 0.45)
    }

    private func paperShadow(for color: StickyNoteColor) -> Color {
        paperColor(for: color).opacity(0.17)
    }

    private func colorName(for color: StickyNoteColor) -> String {
        let raw = String(describing: color)
        return raw.prefix(1).uppercased() + raw.dropFirst()
    }
}

private struct StickyNoteUndoToast: Equatable {
    let id = UUID()
    let message: String
}

private struct StickyNoteGridMetrics {
    let columnCount: Int
    let cardWidth: CGFloat
}

private struct StickyNoteReorderDropDelegate: DropDelegate {
    let target: StickyNoteItem
    let store: StickyNotesStore
    @Binding var draggingNoteID: UUID?
    @Binding var dropTargetNoteID: UUID?
    let cancelExternalDrag: () -> Void

    func dropEntered(info: DropInfo) {
        guard let draggingNoteID, draggingNoteID != target.id else { return }
        cancelExternalDrag()
        dropTargetNoteID = target.id
        guard let targetIndex = store.activeNotes.firstIndex(where: { $0.id == target.id }) else { return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
            _ = store.moveNote(id: draggingNoteID, toIndex: targetIndex)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        cancelExternalDrag()
        draggingNoteID = nil
        dropTargetNoteID = nil
        return true
    }

    func dropExited(info: DropInfo) {
        if dropTargetNoteID == target.id {
            dropTargetNoteID = nil
        }
    }
}

private extension Color {
    func mix(with other: Color, by amount: Double) -> Color {
        let clamped = min(max(amount, 0), 1)
        let first = NSColor(self).usingColorSpace(.deviceRGB) ?? .clear
        let second = NSColor(other).usingColorSpace(.deviceRGB) ?? .clear
        return Color(
            red: first.redComponent + (second.redComponent - first.redComponent) * clamped,
            green: first.greenComponent + (second.greenComponent - first.greenComponent) * clamped,
            blue: first.blueComponent + (second.blueComponent - first.blueComponent) * clamped,
            opacity: first.alphaComponent + (second.alphaComponent - first.alphaComponent) * clamped
        )
    }
}
