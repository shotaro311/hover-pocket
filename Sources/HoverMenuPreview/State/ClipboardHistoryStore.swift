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

    private lazy var storageDirectory: URL = {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base
            .appendingPathComponent("HoverMenuPreview", isDirectory: true)
            .appendingPathComponent("Clipboard", isDirectory: true)
    }()

    private var metadataURL: URL {
        storageDirectory.appendingPathComponent("history.json", isDirectory: false)
    }

    private init() {
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
        var didChange = false

        if let text = pasteboard.string(forType: .string),
           addTextIfUseful(text) {
            didChange = true
        }

        if let image = NSImage(pasteboard: pasteboard),
           addImageIfUseful(image) {
            didChange = true
        }

        if didChange {
            trimHistory()
            save()
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

    private func addImageIfUseful(_ image: NSImage) -> Bool {
        guard let pngData = Self.pngData(from: image) else { return false }
        let hash = Self.hashString(for: pngData)
        imageItems.removeAll { $0.contentHash == hash }

        do {
            try ensureStorageDirectory()
            let id = UUID()
            let fileName = "\(id.uuidString).png"
            let fileURL = storageDirectory.appendingPathComponent(fileName, isDirectory: false)
            try pngData.write(to: fileURL, options: .atomic)

            imageItems.insert(
                ClipboardImageHistoryItem(
                    id: id,
                    fileName: fileName,
                    contentHash: hash,
                    width: Int(image.size.width.rounded()),
                    height: Int(image.size.height.rounded()),
                    createdAt: Date()
                ),
                at: 0
            )
            return true
        } catch {
            lastErrorMessage = "Clipboard image could not be saved."
            return false
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

    private func save() {
        do {
            try ensureStorageDirectory()
            let metadata = ClipboardHistoryMetadata(textItems: textItems, imageItems: imageItems)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(metadata)
            try data.write(to: metadataURL, options: .atomic)
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = "Clipboard history could not be saved."
        }
    }

    private func ensureStorageDirectory() throws {
        try fileManager.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData)
        else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }

    private static func hashString(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
