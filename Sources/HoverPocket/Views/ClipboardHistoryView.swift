import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum ClipboardHistoryTab: CaseIterable {
    case text
    case images
    case favorites
}

private enum ClipboardExpandedItem: Identifiable, Equatable {
    case text(ClipboardTextHistoryItem)
    case image(ClipboardImageHistoryItem)

    var id: String {
        switch self {
        case .text(let item):
            return "text-\(item.id.uuidString)"
        case .image(let item):
            return "image-\(item.id.uuidString)"
        }
    }
}

struct ClipboardHistoryView: View {
    @ObservedObject var settings: AppSettings
    let onExternalDragStarted: @MainActor () -> Void

    @ObservedObject private var store = ClipboardHistoryStore.shared
    @State private var selectedTab: ClipboardHistoryTab = .text
    @State private var expandedItem: ClipboardExpandedItem?

    var body: some View {
        ZStack {
            VStack(spacing: 10) {
                header
                tabBar
                content
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if let expandedItem {
                expandedPreview(expandedItem)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(.easeOut(duration: 0.16), value: expandedItem)
        .onAppear {
            store.startMonitoring()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label(store.isMonitoring ? text(.clipboardWatching) : text(.clipboardPaused), systemImage: "doc.on.clipboard")
                .panelTextFont(size: 10, weight: .bold, design: .monospaced)
                .foregroundStyle(.white.opacity(0.64))

            Spacer()

            if let message = store.lastErrorMessage {
                Text(message)
                    .panelTextFont(size: 9, weight: .medium)
                    .foregroundStyle(.yellow.opacity(0.86))
                    .lineLimit(1)
            }

            Button {
                store.clear()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(IconButtonStyle(selected: false))
            .disabled(store.nonFavoriteItemCount == 0)
            .help(text(.clipboardClearHistory))
        }
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            ForEach(ClipboardHistoryTab.allCases, id: \.self) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tabIcon(tab))
                            .font(.system(size: 10, weight: .bold))
                        Text(tabTitle(tab))
                            .panelTextFont(size: 10.5, weight: .bold, design: .monospaced)
                        Text("\(tabCount(tab))")
                            .panelTextFont(size: 9, weight: .bold, design: .monospaced)
                            .foregroundStyle(tab == selectedTab ? .white.opacity(0.58) : .white.opacity(0.34))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .foregroundStyle(tab == selectedTab ? .white : .white.opacity(0.5))
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(tab == selectedTab ? Color.white.opacity(0.11) : Color.white.opacity(0.035))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(tab == selectedTab ? Color.white.opacity(0.11) : Color.white.opacity(0.045), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case .text:
            textList(store.textItems, emptyTitle: text(.clipboardNoText), showDelete: false)
        case .images:
            imageGrid(store.imageItems, emptyTitle: text(.clipboardNoImages), showDelete: false)
        case .favorites:
            favoritesContent
        }
    }

    private func textList(
        _ items: [ClipboardTextHistoryItem],
        emptyTitle: String,
        showDelete: Bool
    ) -> some View {
        Group {
            if items.isEmpty {
                emptyState(symbol: "text.alignleft", title: emptyTitle)
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(items) { item in
                            textItemRow(item, showDelete: showDelete)
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func imageGrid(
        _ items: [ClipboardImageHistoryItem],
        emptyTitle: String,
        showDelete: Bool
    ) -> some View {
        Group {
            if items.isEmpty {
                emptyState(symbol: "photo", title: emptyTitle)
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 112), spacing: 8)],
                        spacing: 8
                    ) {
                        ForEach(items) { item in
                            imageItemTile(item, showDelete: showDelete)
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var favoritesContent: some View {
        let favoriteTextItems = store.favoriteTextItems
        let favoriteImageItems = store.favoriteImageItems
        return Group {
            if favoriteTextItems.isEmpty && favoriteImageItems.isEmpty {
                emptyState(symbol: "star", title: text(.clipboardNoFavorites))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if !favoriteTextItems.isEmpty {
                            sectionTitle(text(.clipboardText), count: favoriteTextItems.count)
                            ForEach(favoriteTextItems) { item in
                                textItemRow(item, showDelete: true)
                            }
                        }

                        if !favoriteImageItems.isEmpty {
                            sectionTitle(text(.clipboardImages), count: favoriteImageItems.count)
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 112), spacing: 8)],
                                spacing: 8
                            ) {
                                ForEach(favoriteImageItems) { item in
                                    imageItemTile(item, showDelete: true)
                                }
                            }
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func sectionTitle(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .panelTextFont(size: 10.5, weight: .bold, design: .monospaced)
                .foregroundStyle(.white.opacity(0.76))

            Text("\(count)")
                .panelTextFont(size: 9, weight: .bold, design: .monospaced)
                .foregroundStyle(.white.opacity(0.38))

            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    private func textItemRow(_ item: ClipboardTextHistoryItem, showDelete: Bool) -> some View {
        HStack(alignment: .top, spacing: 7) {
            VStack(alignment: .leading, spacing: 4) {
                Text(previewText(for: item))
                    .panelTextFont(size: 10.5, weight: .semibold)
                    .foregroundStyle(.white.opacity(0.86))
                    .lineLimit(3)

                Text(item.createdAt.formatted(.dateTime.hour().minute()))
                    .panelTextFont(size: 8.5, weight: .medium, design: .monospaced)
                    .foregroundStyle(.white.opacity(0.34))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                expandedItem = .text(item)
            }

            HStack(spacing: 2) {
                favoriteButton(
                    isFavorite: item.isFavorite,
                    action: { store.toggleTextFavorite(item) }
                )

                Button {
                    store.copyText(item)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(IconButtonStyle(selected: false))
                .help(text(.copyText))

                if showDelete {
                    deleteButton {
                        store.deleteText(item)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(item.isFavorite ? Color.yellow.opacity(0.22) : Color.white.opacity(0.055), lineWidth: 1)
        )
        .onDrag {
            onExternalDragStarted()
            return NSItemProvider(object: item.text as NSString)
        }
        .help(text(.clipboardDragText))
    }

    private func imageItemTile(_ item: ClipboardImageHistoryItem, showDelete: Bool) -> some View {
        let fileURL = store.fileURL(for: item)
        return VStack(alignment: .leading, spacing: 5) {
            ZStack(alignment: .topTrailing) {
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

                favoriteButton(
                    isFavorite: item.isFavorite,
                    action: { store.toggleImageFavorite(item) }
                )
                .padding(4)
            }
            .frame(height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture {
                expandedItem = .image(item)
            }

            HStack(spacing: 4) {
                Text("\(item.width)x\(item.height)")
                    .panelTextFont(size: 8.5, weight: .medium, design: .monospaced)
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

                if showDelete {
                    deleteButton {
                        store.deleteImage(item)
                    }
                }
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(item.isFavorite ? Color.yellow.opacity(0.22) : Color.white.opacity(0.055), lineWidth: 1)
        )
        .onDrag {
            onExternalDragStarted()
            return imageDragProvider(fileURL: fileURL)
        }
        .help(text(.clipboardDragImage))
    }

    private func favoriteButton(isFavorite: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isFavorite ? Color.yellow.opacity(0.92) : Color.white.opacity(0.36))
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isFavorite ? Color.yellow.opacity(0.13) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(isFavorite ? text(.clipboardUnfavorite) : text(.clipboardFavorite))
    }

    private func deleteButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "trash")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.red.opacity(0.74))
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.red.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
        .help(text(.clipboardDeleteFavorite))
    }

    private func expandedPreview(_ item: ClipboardExpandedItem) -> some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.94))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )

            expandedPreviewBody(item)
                .padding(14)

            Button {
                expandedItem = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(IconButtonStyle(selected: false))
            .padding(8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            expandedItem = nil
        }
    }

    @ViewBuilder
    private func expandedPreviewBody(_ item: ClipboardExpandedItem) -> some View {
        switch item {
        case .text(let textItem):
            ScrollView {
                Text(textItem.text.isEmpty ? text(.clipboardEmptyText) : textItem.text)
                    .panelTextFont(size: 13, weight: .semibold)
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .textSelection(.enabled)
                    .padding(.trailing, 26)
                    .onTapGesture {
                        expandedItem = nil
                    }
            }
            .scrollIndicators(.visible)
        case .image(let imageItem):
            let fileURL = store.fileURL(for: imageItem)
            if let image = NSImage(contentsOf: fileURL) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(24)
                    .onTapGesture {
                        expandedItem = nil
                    }
            } else {
                emptyState(symbol: "photo.badge.exclamationmark", title: text(.clipboardNoImages))
            }
        }
    }

    private func previewText(for item: ClipboardTextHistoryItem) -> String {
        let collapsed = item.text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? text(.clipboardEmptyText) : collapsed
    }

    private func tabTitle(_ tab: ClipboardHistoryTab) -> String {
        switch tab {
        case .text:
            return text(.clipboardText)
        case .images:
            return text(.clipboardImages)
        case .favorites:
            return text(.clipboardFavorites)
        }
    }

    private func tabIcon(_ tab: ClipboardHistoryTab) -> String {
        switch tab {
        case .text:
            return "text.alignleft"
        case .images:
            return "photo"
        case .favorites:
            return "star"
        }
    }

    private func tabCount(_ tab: ClipboardHistoryTab) -> Int {
        switch tab {
        case .text:
            return store.textItems.count
        case .images:
            return store.imageItems.count
        case .favorites:
            return store.favoriteTextItems.count + store.favoriteImageItems.count
        }
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
                .panelTextFont(size: 10.5, weight: .bold, design: .monospaced)
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
