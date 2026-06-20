import Foundation

struct ClipboardTextHistoryItem: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let text: String
    let createdAt: Date

    var previewText: String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? "Empty text" : collapsed
    }
}

struct ClipboardImageHistoryItem: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let fileName: String
    let contentHash: String
    let width: Int
    let height: Int
    let createdAt: Date

    func fileURL(in directory: URL) -> URL {
        directory.appendingPathComponent(fileName, isDirectory: false)
    }
}

struct ClipboardHistoryMetadata: Codable, Equatable, Sendable {
    var textItems: [ClipboardTextHistoryItem]
    var imageItems: [ClipboardImageHistoryItem]
}
