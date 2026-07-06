import Foundation

enum ClipboardVerificationCommand {
    @MainActor
    static func run() -> Never {
        let outputURL = outputFileURL()
        let result = verifyFavorites()
        let outputLines = [
            "clipboard_verify=\(result.ok ? "ok" : "failed")",
            "clipboard_favorite_text_after_clear=\(result.favoriteTextCount)",
            "clipboard_favorite_image_after_clear=\(result.favoriteImageCount)",
            "clipboard_regular_image_removed=\(result.regularImageRemoved)",
            "clipboard_legacy_decode_default_favorite=\(result.legacyDecodeDefaultFavorite)"
        ]

        outputLines.forEach { print($0) }
        if let outputURL {
            let output = outputLines.joined(separator: "\n") + "\n"
            try? output.write(to: outputURL, atomically: true, encoding: .utf8)
        }
        exit(result.ok ? 0 : 1)
    }

    @MainActor
    private static func verifyFavorites() -> ClipboardVerificationResult {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("hoverpocket-clipboard-verify-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let regularImageURL = root.appendingPathComponent("regular.png", isDirectory: false)
        let favoriteImageURL = root.appendingPathComponent("favorite.png", isDirectory: false)

        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data([0x89, 0x50, 0x4E, 0x47]).write(to: regularImageURL)
            try Data([0x89, 0x50, 0x4E, 0x47, 0x01]).write(to: favoriteImageURL)

            let metadata = ClipboardHistoryMetadata(
                textItems: [
                    ClipboardTextHistoryItem(id: UUID(), text: "Regular", createdAt: Date(timeIntervalSinceReferenceDate: 1)),
                    ClipboardTextHistoryItem(id: UUID(), text: "Pinned", createdAt: Date(timeIntervalSinceReferenceDate: 2), isFavorite: true)
                ],
                imageItems: [
                    ClipboardImageHistoryItem(
                        id: UUID(),
                        fileName: "regular.png",
                        contentHash: "regular",
                        width: 10,
                        height: 10,
                        createdAt: Date(timeIntervalSinceReferenceDate: 3)
                    ),
                    ClipboardImageHistoryItem(
                        id: UUID(),
                        fileName: "favorite.png",
                        contentHash: "favorite",
                        width: 20,
                        height: 20,
                        createdAt: Date(timeIntervalSinceReferenceDate: 4),
                        isFavorite: true
                    )
                ]
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(metadata)
            try data.write(to: root.appendingPathComponent("history.json", isDirectory: false), options: .atomic)
        } catch {
            return ClipboardVerificationResult(
                ok: false,
                favoriteTextCount: 0,
                favoriteImageCount: 0,
                regularImageRemoved: false,
                legacyDecodeDefaultFavorite: false
            )
        }

        let store = ClipboardHistoryStore(storageDirectory: root)
        store.clear()

        let favoriteTextCount = store.favoriteTextItems.count
        let favoriteImageCount = store.favoriteImageItems.count
        let regularImageRemoved = !FileManager.default.fileExists(atPath: regularImageURL.path)
        let favoriteImageKept = FileManager.default.fileExists(atPath: favoriteImageURL.path)

        let toggledTextOK: Bool
        if let textItem = store.textItems.first {
            store.toggleTextFavorite(textItem)
            toggledTextOK = store.favoriteTextItems.isEmpty
        } else {
            toggledTextOK = false
        }

        let deleteImageOK: Bool
        if let imageItem = store.imageItems.first {
            store.deleteImage(imageItem)
            deleteImageOK = store.favoriteImageItems.isEmpty && !FileManager.default.fileExists(atPath: favoriteImageURL.path)
        } else {
            deleteImageOK = false
        }

        let legacyDecodeDefaultFavorite = verifyLegacyDecodeDefaultFavorite()
        let ok = favoriteTextCount == 1
            && favoriteImageCount == 1
            && regularImageRemoved
            && favoriteImageKept
            && toggledTextOK
            && deleteImageOK
            && legacyDecodeDefaultFavorite

        return ClipboardVerificationResult(
            ok: ok,
            favoriteTextCount: favoriteTextCount,
            favoriteImageCount: favoriteImageCount,
            regularImageRemoved: regularImageRemoved,
            legacyDecodeDefaultFavorite: legacyDecodeDefaultFavorite
        )
    }

    private static func verifyLegacyDecodeDefaultFavorite() -> Bool {
        let textID = UUID().uuidString
        let imageID = UUID().uuidString
        let textJSON = """
        {"id":"\(textID)","text":"Legacy","createdAt":0}
        """
        let imageJSON = """
        {"id":"\(imageID)","fileName":"legacy.png","contentHash":"legacy","width":1,"height":1,"createdAt":0}
        """
        guard let textData = textJSON.data(using: .utf8),
              let imageData = imageJSON.data(using: .utf8),
              let textItem = try? JSONDecoder().decode(ClipboardTextHistoryItem.self, from: textData),
              let imageItem = try? JSONDecoder().decode(ClipboardImageHistoryItem.self, from: imageData)
        else {
            return false
        }
        return !textItem.isFavorite && !imageItem.isFavorite
    }

    private static func outputFileURL() -> URL? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--verify-output") else {
            return nil
        }
        let pathIndex = arguments.index(after: index)
        guard arguments.indices.contains(pathIndex) else {
            return nil
        }
        return URL(fileURLWithPath: arguments[pathIndex])
    }
}

private struct ClipboardVerificationResult {
    let ok: Bool
    let favoriteTextCount: Int
    let favoriteImageCount: Int
    let regularImageRemoved: Bool
    let legacyDecodeDefaultFavorite: Bool
}
