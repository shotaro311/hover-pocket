import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ClipboardHistoryView: View {
    @ObservedObject var settings: AppSettings
    let onExternalDragStarted: @MainActor () -> Void

    @ObservedObject private var store = ClipboardHistoryStore.shared

    var body: some View {
        VStack(spacing: 10) {
            header

            HStack(alignment: .top, spacing: 12) {
                textColumn

                Divider()
                    .overlay(Color.white.opacity(0.08))

                imageColumn
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .onAppear {
            store.startMonitoring()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label(store.isMonitoring ? text(.clipboardWatching) : text(.clipboardPaused), systemImage: "doc.on.clipboard")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.64))

            Spacer()

            if let message = store.lastErrorMessage {
                Text(message)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.yellow.opacity(0.86))
                    .lineLimit(1)
            }

            Button {
                store.clear()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(IconButtonStyle(selected: false))
            .disabled(store.textItems.isEmpty && store.imageItems.isEmpty)
            .help(text(.clipboardClearHistory))
        }
    }

    private var textColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            columnTitle(text(.clipboardText), count: store.textItems.count)

            if store.textItems.isEmpty {
                emptyState(symbol: "text.alignleft", title: text(.clipboardNoText))
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(store.textItems) { item in
                            textItemRow(item)
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var imageColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            columnTitle(text(.clipboardImages), count: store.imageItems.count)

            if store.imageItems.isEmpty {
                emptyState(symbol: "photo", title: text(.clipboardNoImages))
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: 8),
                            GridItem(.flexible(), spacing: 8)
                        ],
                        spacing: 8
                    ) {
                        ForEach(store.imageItems) { item in
                            imageItemTile(item)
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func columnTitle(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)

            Text("\(count)")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.42))

            Spacer(minLength: 0)
        }
    }

    private func textItemRow(_ item: ClipboardTextHistoryItem) -> some View {
        HStack(alignment: .top, spacing: 7) {
            VStack(alignment: .leading, spacing: 4) {
                Text(previewText(for: item))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.86))
                    .lineLimit(3)

                Text(item.createdAt.formatted(.dateTime.hour().minute()))
                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.34))
            }

            Spacer(minLength: 4)

            Button {
                store.copyText(item)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(IconButtonStyle(selected: false))
            .help(text(.copyText))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.white.opacity(0.055), lineWidth: 1)
        )
        .onDrag {
            onExternalDragStarted()
            return NSItemProvider(object: item.text as NSString)
        }
        .help(text(.clipboardDragText))
    }

    private func imageItemTile(_ item: ClipboardImageHistoryItem) -> some View {
        let fileURL = store.fileURL(for: item)
        return VStack(alignment: .leading, spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(0.05))

                if let image = NSImage(contentsOf: fileURL) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(5)
                } else {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.34))
                }
            }
            .frame(height: 78)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            HStack(spacing: 4) {
                Text("\(item.width)x\(item.height)")
                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.38))
                    .lineLimit(1)

                Spacer(minLength: 0)

                Button {
                    store.copyImage(item)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(IconButtonStyle(selected: false))
                .help(text(.copyImage))
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.055), lineWidth: 1)
        )
        .onDrag {
            onExternalDragStarted()
            return imageDragProvider(fileURL: fileURL)
        }
        .help(text(.clipboardDragImage))
    }

    private func previewText(for item: ClipboardTextHistoryItem) -> String {
        let collapsed = item.text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? text(.clipboardEmptyText) : collapsed
    }

    private func text(_ key: AppTextKey) -> String {
        settings.text(key)
    }

    private func emptyState(symbol: String, title: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white.opacity(0.28))
            Text(title)
                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func imageDragProvider(fileURL: URL) -> NSItemProvider {
        let provider = NSItemProvider(contentsOf: fileURL) ?? NSItemProvider(object: fileURL as NSURL)
        provider.suggestedName = fileURL.deletingPathExtension().lastPathComponent
        if let data = try? Data(contentsOf: fileURL) {
            provider.registerDataRepresentation(
                forTypeIdentifier: UTType.png.identifier,
                visibility: .all
            ) { completion in
                completion(data, nil)
                return nil
            }
        }
        return provider
    }
}
