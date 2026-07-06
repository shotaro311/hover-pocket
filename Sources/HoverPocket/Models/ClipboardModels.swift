import Foundation

struct ClipboardTextHistoryItem: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let text: String
    let createdAt: Date
    let isFavorite: Bool

    init(id: UUID, text: String, createdAt: Date, isFavorite: Bool = false) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.isFavorite = isFavorite
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case text
        case createdAt
        case isFavorite
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
    }

    var previewText: String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? "Empty text" : collapsed
    }

    func withFavorite(_ value: Bool) -> ClipboardTextHistoryItem {
        ClipboardTextHistoryItem(id: id, text: text, createdAt: createdAt, isFavorite: value)
    }
}

struct ClipboardImageHistoryItem: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let fileName: String
    let contentHash: String
    let width: Int
    let height: Int
    let createdAt: Date
    let isFavorite: Bool

    init(
        id: UUID,
        fileName: String,
        contentHash: String,
        width: Int,
        height: Int,
        createdAt: Date,
        isFavorite: Bool = false
    ) {
        self.id = id
        self.fileName = fileName
        self.contentHash = contentHash
        self.width = width
        self.height = height
        self.createdAt = createdAt
        self.isFavorite = isFavorite
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case fileName
        case contentHash
        case width
        case height
        case createdAt
        case isFavorite
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        fileName = try container.decode(String.self, forKey: .fileName)
        contentHash = try container.decode(String.self, forKey: .contentHash)
        width = try container.decode(Int.self, forKey: .width)
        height = try container.decode(Int.self, forKey: .height)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
    }

    func fileURL(in directory: URL) -> URL {
        directory.appendingPathComponent(fileName, isDirectory: false)
    }

    func withFavorite(_ value: Bool) -> ClipboardImageHistoryItem {
        ClipboardImageHistoryItem(
            id: id,
            fileName: fileName,
            contentHash: contentHash,
            width: width,
            height: height,
            createdAt: createdAt,
            isFavorite: value
        )
    }
}

struct ClipboardHistoryMetadata: Codable, Equatable, Sendable {
    var textItems: [ClipboardTextHistoryItem]
    var imageItems: [ClipboardImageHistoryItem]
}
