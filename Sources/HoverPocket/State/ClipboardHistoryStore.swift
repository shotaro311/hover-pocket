import AppKit
import CryptoKit
import Foundation

@MainActor
final class ClipboardHistoryStore: ObservableObject {
    static let shared = ClipboardHistoryStore()

    @Published private(set) var textItems: [ClipboardTextHistoryItem] = []
    @Published private(set) var imageItems: [ClipboardImageHistoryItem] = []
    @Published private(set) var isMonitoring = false
    @Published private(set) var lastErrorMessage: String?

    private let maxTextItems = 30
    private let maxImageItems = 20
    private let pollInterval: TimeInterval = 0.75
    private let fileManager = FileManager.default
    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var saveDebounceTask: Task<Void, Never>?
    private var pendingWriteTask: Task<Void, Never>?

    private lazy var storageDirectory: URL = {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base
            .appendingPathComponent("HoverPocket", isDirectory: true)
            .appendingPathComponent("Clipboard", isDirectory: true)
    }()

    private lazy var legacyStorageDirectories: [URL] = {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return [
            base
                .appendingPathComponent("NotchPocket", isDirectory: true)
                .appendingPathComponent("Clipboard", isDirectory: true),
            base
                .appendingPathComponent("HoverMenuPreview", isDirectory: true)
                .appendingPathComponent("Clipboard", isDirectory: true)
        ]
    }()

    private var metadataURL: URL {
        storageDirectory.appendingPathComponent("history.json", isDirectory: false)
    }

    private init() {
        migrateLegacyStorageIfNeeded()
        load()
    }

    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true
        lastChangeCount = NSPasteboard.general.changeCount
        captureCurrentPasteboardIfUseful()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.captureIfChanged()
            }
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        isMonitoring = false
    }

    func copyText(_ item: ClipboardTextHistoryItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.text, forType: .string)
        promoteTextItem(item)
    }

    func copyImage(_ item: ClipboardImageHistoryItem) {
        let url = item.fileURL(in: storageDirectory)
        guard let image = NSImage(contentsOf: url) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        promoteImageItem(item)
    }

    func clear() {
        textItems = []
        imageItems = []
        try? fileManager.removeItem(at: storageDirectory)
        save()
    }

    func fileURL(for item: ClipboardImageHistoryItem) -> URL {
        item.fileURL(in: storageDirectory)
    }

    private func captureIfChanged() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        captureCurrentPasteboardIfUseful()
    }

    private func captureCurrentPasteboardIfUseful() {
        let pasteboard = NSPasteboard.general

        if let text = pasteboard.string(forType: .string),
           addTextIfUseful(text) {
            trimHistory()
            save()
        }

        if let imageData = pasteboard.data(forType: .png)
            ?? pasteboard.data(forType: .tiff)
            ?? NSImage(pasteboard: pasteboard)?.tiffRepresentation {
            captureImage(from: imageData)
        }
    }

    private func addTextIfUseful(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        textItems.removeAll { $0.text == text }
        textItems.insert(
            ClipboardTextHistoryItem(id: UUID(), text: text, createdAt: Date()),
            at: 0
        )
        return true
    }

    /// Converts and hashes clipboard image data off the main actor; PNG encode,
    /// SHA256 and file writes are too heavy for the 0.75s poll on the main thread.
    private func captureImage(from imageData: Data) {
        let storageDirectory = self.storageDirectory
        Task.detached(priority: .utility) { [weak self] in
            guard let bitmap = NSBitmapImageRep(data: imageData),
                  let pngData = bitmap.representation(using: .png, properties: [:])
            else { return }
            let hash = Self.hashString(for: pngData)
            let alreadyKnown = await MainActor.run { [weak self] in
                self?.imageItems.first?.contentHash == hash
            }
            guard !alreadyKnown else { return }
            let id = UUID()
            let fileName = "\(id.uuidString).png"
            let fileURL = storageDirectory.appendingPathComponent(fileName, isDirectory: false)
            let width = Int(bitmap.size.width.rounded())
            let height = Int(bitmap.size.height.rounded())
            do {
                try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
                try pngData.write(to: fileURL, options: .atomic)
            } catch {
                await MainActor.run { [weak self] in
                    self?.lastErrorMessage = "Clipboard image could not be saved."
                }
                return
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.imageItems.removeAll { $0.contentHash == hash }
                self.imageItems.insert(
                    ClipboardImageHistoryItem(
                        id: id,
                        fileName: fileName,
                        contentHash: hash,
                        width: width,
                        height: height,
                        createdAt: Date()
                    ),
                    at: 0
                )
                self.trimHistory()
                self.save()
            }
        }
    }

    private func promoteTextItem(_ item: ClipboardTextHistoryItem) {
        textItems.removeAll { $0.id == item.id || $0.text == item.text }
        textItems.insert(item, at: 0)
        save()
    }

    private func promoteImageItem(_ item: ClipboardImageHistoryItem) {
        imageItems.removeAll { $0.id == item.id || $0.contentHash == item.contentHash }
        imageItems.insert(item, at: 0)
        save()
    }

    private func trimHistory() {
        if textItems.count > maxTextItems {
            textItems = Array(textItems.prefix(maxTextItems))
        }

        guard imageItems.count > maxImageItems else { return }
        let removed = imageItems.dropFirst(maxImageItems)
        imageItems = Array(imageItems.prefix(maxImageItems))
        for item in removed {
            try? fileManager.removeItem(at: item.fileURL(in: storageDirectory))
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: metadataURL),
              let metadata = try? JSONDecoder().decode(ClipboardHistoryMetadata.self, from: data)
        else {
            return
        }
        textItems = Array(metadata.textItems.prefix(maxTextItems))
        imageItems = Array(metadata.imageItems.prefix(maxImageItems)).filter {
            fileManager.fileExists(atPath: $0.fileURL(in: storageDirectory).path)
        }
    }

    /// Debounces rapid successive saves, then encodes and writes off the main actor.
    /// Writes are chained so an older snapshot can never overwrite a newer one.
    private func save() {
        saveDebounceTask?.cancel()
        saveDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.writeMetadataNow()
        }
    }

    private func writeMetadataNow() {
        let metadata = ClipboardHistoryMetadata(textItems: textItems, imageItems: imageItems)
        let metadataURL = self.metadataURL
        let storageDirectory = self.storageDirectory
        let previousWrite = pendingWriteTask
        pendingWriteTask = Task.detached(priority: .utility) { [weak self] in
            await previousWrite?.value
            do {
                try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(metadata)
                try data.write(to: metadataURL, options: .atomic)
                await MainActor.run { [weak self] in
                    self?.lastErrorMessage = nil
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.lastErrorMessage = "Clipboard history could not be saved."
                }
            }
        }
    }

    private func migrateLegacyStorageIfNeeded() {
        guard !fileManager.fileExists(atPath: metadataURL.path) else { return }
        guard let legacyStorageDirectory = legacyStorageDirectories.first(where: { directory in
            let legacyMetadataURL = directory.appendingPathComponent("history.json", isDirectory: false)
            return fileManager.fileExists(atPath: legacyMetadataURL.path)
        }) else {
            return
        }

        do {
            try fileManager.createDirectory(
                at: storageDirectory.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: storageDirectory.path) {
                let legacyItems = try fileManager.contentsOfDirectory(
                    at: legacyStorageDirectory,
                    includingPropertiesForKeys: nil
                )
                for legacyItem in legacyItems {
                    let destination = storageDirectory.appendingPathComponent(
                        legacyItem.lastPathComponent,
                        isDirectory: false
                    )
                    guard !fileManager.fileExists(atPath: destination.path) else { continue }
                    try fileManager.copyItem(at: legacyItem, to: destination)
                }
            } else {
                try fileManager.copyItem(at: legacyStorageDirectory, to: storageDirectory)
            }
        } catch {
            lastErrorMessage = "Legacy clipboard history could not be migrated."
        }
    }

    private nonisolated static func hashString(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
