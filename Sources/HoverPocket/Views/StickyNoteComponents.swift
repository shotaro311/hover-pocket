import AppKit
import SwiftUI

struct StickyNoteHeaderView: View {
    let count: Int
    let errorMessage: String?
    let selectedNewNoteColor: StickyNoteColor?
    let gridSize: StickyNoteGridSize
    let language: AppLanguage
    let onSelectGridSize: (StickyNoteGridSize) -> Void
    let onSelectNewNoteColor: (StickyNoteColor) -> Void
    let onCreateWithColor: (StickyNoteColor) -> Void
    let onCreate: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Label(AppText.text(.stickyNotes, language: language), systemImage: "square.grid.2x2")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.64))

            Text("\(count)")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.38))

            StickyNoteGridSizeControl(selectedSize: gridSize, language: language, onSelect: onSelectGridSize)

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.yellow.opacity(0.86))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            StickyNoteColorSwatches(
                selectedColor: selectedNewNoteColor,
                language: language,
                onDoubleClick: onCreateWithColor,
                onSelect: onSelectNewNoteColor
            )

            Button(action: onCreate) {
                Image(systemName: "plus")
            }
            .buttonStyle(IconButtonStyle(selected: false))
            .help(AppText.text(.stickyNewNote, language: language))
        }
    }
}

struct StickyNotePreviewCard<ContextMenu: View>: View {
    let note: StickyNoteItem
    let gridSize: StickyNoteGridSize
    let isHovered: Bool
    let isDragging: Bool
    let isDropTarget: Bool
    let language: AppLanguage
    let onArchive: () -> Void
    @ViewBuilder let contextMenu: () -> ContextMenu

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Text(note.displayTitle(language: language))
                    .font(.system(size: gridSize.titleFontSize, weight: .bold))
                    .foregroundStyle(Color.black.opacity(0.78))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                if isHovered || isDropTarget {
                    Button(action: onArchive) {
                        Image(systemName: "checkmark")
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.black.opacity(0.54))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.white.opacity(0.36)))
                    .help(AppText.text(.stickyArchive, language: language))
                    .transition(.scale.combined(with: .opacity))
                }
            }

            if !note.cardPreviewText.isEmpty {
                Text(note.cardPreviewText)
                    .font(.system(size: gridSize.bodyFontSize, weight: .medium))
                    .foregroundStyle(Color.black.opacity(0.58))
                    .lineLimit(gridSize.bodyLineLimit)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Text(note.updatedAt.formatted(.dateTime.hour().minute()))
                .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.black.opacity(0.34))
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: gridSize.cardMinHeight, alignment: .topLeading)
        .background(StickyNoteStyle.cardBackground(note.color, isSelected: false, isDropTarget: isDropTarget))
        .opacity(isDragging ? 0.86 : 1)
        .scaleEffect(isDragging ? 1.02 : (isHovered ? 1.015 : 1), anchor: .center)
        .shadow(
            color: StickyNoteStyle.paperShadow(for: note.color),
            radius: isDragging || isHovered ? 13 : 7,
            y: isDragging || isHovered ? 8 : 4
        )
        .zIndex(isDragging ? 2 : (isDropTarget ? 1 : 0))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contextMenu(menuItems: contextMenu)
    }
}

struct StickyNoteEditorCard<ContextMenu: View>: View {
    let note: StickyNoteItem
    let gridSize: StickyNoteGridSize
    let language: AppLanguage
    @Binding var draftTitle: String
    @Binding var draftBody: String
    @Binding var draftColor: StickyNoteColor?
    let onDraftChanged: () -> Void
    let onArchive: () -> Void
    let onDelete: () -> Void
    let onDone: () -> Void
    @ViewBuilder let contextMenu: () -> ContextMenu

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            toolbar
            titleField
            bodyEditor
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: gridSize.editorMinHeight, alignment: .topLeading)
        .background(StickyNoteStyle.cardBackground(draftColor ?? note.color, isSelected: true, isDropTarget: false))
        .shadow(color: StickyNoteStyle.paperShadow(for: draftColor ?? note.color), radius: 16, y: 9)
        .contextMenu(menuItems: contextMenu)
        .transition(.scale(scale: 0.96).combined(with: .opacity))
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            StickyNoteColorSwatches(selectedColor: draftColor, language: language) { color in
                draftColor = color
                onDraftChanged()
            }

            Spacer(minLength: 4)

            Button(action: onArchive) {
                Image(systemName: "checkmark")
            }
            .buttonStyle(IconButtonStyle(selected: false))
            .help(AppText.text(.stickyArchive, language: language))

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(IconButtonStyle(selected: false))
            .help(AppText.text(.delete, language: language))

            Button(action: onDone) {
                Image(systemName: "checkmark.circle.fill")
            }
            .buttonStyle(IconButtonStyle(selected: true))
            .keyboardShortcut(.return, modifiers: [.control])
            .help(AppText.text(.stickyDone, language: language))
        }
    }

    private var titleField: some View {
        TextField(AppText.text(.title, language: language), text: $draftTitle)
            .textFieldStyle(.plain)
            .font(.system(size: gridSize.titleFontSize + 1, weight: .bold))
            .foregroundStyle(Color.black.opacity(0.78))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.28))
            )
    }

    private var bodyEditor: some View {
        TextEditor(text: $draftBody)
            .font(.system(size: gridSize.bodyFontSize + 1, weight: .medium))
            .foregroundStyle(Color.black.opacity(0.68))
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(minHeight: gridSize.editorBodyMinHeight)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.22))
            )
    }
}

struct StickyNoteColorSwatches: View {
    let selectedColor: StickyNoteColor?
    let language: AppLanguage
    var onDoubleClick: ((StickyNoteColor) -> Void)?
    let onSelect: (StickyNoteColor) -> Void

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(StickyNoteColor.allCases)) { color in
                Button {
                    onSelect(color)
                } label: {
                    Circle()
                        .fill(StickyNoteStyle.paperColor(for: color))
                        .frame(width: 13, height: 13)
                        .overlay {
                            Circle()
                                .stroke(
                                    Color.white.opacity(selectedColor?.id == color.id ? 0.72 : 0.18),
                                    lineWidth: selectedColor?.id == color.id ? 1.4 : 0.8
                                )
                        }
                }
                .buttonStyle(.plain)
                .simultaneousGesture(
                    TapGesture(count: 2)
                        .onEnded {
                            onDoubleClick?(color)
                        }
                )
                .help(swatchHelp(for: color))
            }
        }
    }

    private func swatchHelp(for color: StickyNoteColor) -> String {
        let colorTitle = StickyNoteStyle.colorName(for: color, language: language)
        guard onDoubleClick != nil else {
            return colorTitle
        }
        return "\(colorTitle) / \(AppText.text(.stickyDoubleClickCreate, language: language))"
    }
}

struct StickyNoteGridSizeControl: View {
    let selectedSize: StickyNoteGridSize
    let language: AppLanguage
    let onSelect: (StickyNoteGridSize) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(StickyNoteGridSize.allCases) { size in
                Button {
                    onSelect(size)
                } label: {
                    Text(size.shortTitle(language: language))
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(selectedSize == size ? .white : .white.opacity(0.42))
                        .frame(width: 16, height: 16)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(selectedSize == size ? Color.white.opacity(0.14) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .help("\(size.title(language: language)) \(AppText.text(.stickyNotes, language: language))")
            }
        }
    }
}

struct StickyNoteUndoToast: Equatable {
    let id = UUID()
    let message: String
}

struct StickyNoteUndoToastView: View {
    let toast: StickyNoteUndoToast
    let language: AppLanguage
    let onUndo: () -> Void
    let onHideFutureToasts: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(toast.message)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.76))
                .lineLimit(1)

            Spacer(minLength: 4)

            Button(AppText.text(.stickyUndo, language: language), action: onUndo)
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)

            Button(AppText.text(.stickyDontShow, language: language), action: onHideFutureToasts)
                .buttonStyle(.plain)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.48))
                .help(AppText.text(.stickyHideUndoToast, language: language))
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
}

struct StickyNoteArchiveDropZone: View {
    let isTargeted: Bool
    let language: AppLanguage

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "trash.fill")
                .font(.system(size: 13, weight: .bold))

            Text(AppText.text(.stickyArchive, language: language))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
        }
        .foregroundStyle(foregroundColor)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(dropZoneBackground)
        .overlay(dropZoneBorder)
        .scaleEffect(isTargeted ? 1.015 : 1)
        .shadow(color: Color.black.opacity(isTargeted ? 0.28 : 0.14), radius: isTargeted ? 14 : 8, y: 6)
    }

    private var foregroundColor: Color {
        isTargeted ? Color.black.opacity(0.72) : Color.white.opacity(0.78)
    }

    private var dropZoneBackground: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(isTargeted ? Color.white.opacity(0.72) : Color.black.opacity(0.72))
    }

    private var dropZoneBorder: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .stroke(isTargeted ? Color.white.opacity(0.82) : Color.white.opacity(0.12), lineWidth: 1)
    }
}

struct StickyNoteEmptyStateView: View {
    let language: AppLanguage

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: "note.text")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white.opacity(0.28))

            Text(AppText.text(.stickyNoNotes, language: language))
                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum StickyNoteStyle {
    static func cardBackground(
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
                    .stroke(
                        Color.white.opacity(isSelected || isDropTarget ? 0.34 : 0.12),
                        lineWidth: isSelected || isDropTarget ? 1.2 : 0.8
                    )
            )
    }

    static func paperColor(for color: StickyNoteColor) -> Color {
        switch color {
        case .pink:
            return Color(red: 1.0, green: 0.70, blue: 0.80)
        case .mint:
            return Color(red: 0.67, green: 0.91, blue: 0.76)
        case .blue:
            return Color(red: 0.66, green: 0.84, blue: 1.0)
        case .lavender:
            return Color(red: 0.78, green: 0.73, blue: 1.0)
        case .yellow:
            return Color(red: 1.0, green: 0.89, blue: 0.45)
        }
    }

    static func paperShadow(for color: StickyNoteColor) -> Color {
        paperColor(for: color).opacity(0.17)
    }

    static func colorName(for color: StickyNoteColor, language: AppLanguage = .english) -> String {
        color.title(language: language)
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
