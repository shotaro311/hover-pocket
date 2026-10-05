import AppKit

struct AssetDragCopy: Sendable {
    let asset: LibraryAsset
    let original: URL
    let outbox: URL
    func materialize() throws -> URL {
        try AssetLibraryStore.noLinks(outbox)
        let directory = outbox.appendingPathComponent(UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let name = asset.name.components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters)).joined(separator: "_")
        var stem = asset.extension.isEmpty ? name : String(name.dropLast(asset.extension.count + 1))
        while stem.utf8.count > 180 { stem.removeLast() }
        let output = directory.appendingPathComponent("asset-" + stem + (asset.extension.isEmpty ? "" : "." + asset.extension))
        try AssetLibraryStore.writeCopy(asset: asset, original: original, output: output)
        return output
    }
}

final class AssetDragPasteboardProvider: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
    let copy: AssetDragCopy
    private var url: URL?
    private let lock = NSLock()
    private let failure: @Sendable (String) -> Void
    init(_ copy: AssetDragCopy, failure: @escaping @Sendable (String) -> Void) { self.copy = copy; self.failure = failure }
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard type == .fileURL else { return }
        do {
            let value = try lock.withLock {
                if url == nil { url = try copy.materialize() }
                return url!
            }
            item.setString(value.absoluteString, forType: .fileURL)
        } catch { failure(error.localizedDescription) }
    }
}
