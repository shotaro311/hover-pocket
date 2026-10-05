import Foundation

struct LibraryAsset: Codable, Identifiable, Sendable, Equatable {
    let id: String
    var name: String
    let `extension`: String
    let kind: String
    let sha256: String
    let sizeBytes: Int64
    let createdAt: String
    var favorite: Bool
    var trashed: Bool
    var internetOrigin: Bool
    var folderIds: [String]
    var tagIds: [String]

    var relativePath: String { "originals/" + id + (`extension`.isEmpty ? "" : "." + `extension`) }
}

struct LibraryCategory: Codable, Sendable {
    let id: String
    let name: String
    let parentId: String?

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name)
        try c.encode(parentId, forKey: .parentId)
    }
}
struct LibrarySearch: Codable, Sendable {
    let id: String
    let name: String
    let filter: LibraryQuery
}
struct LibraryPage: Codable, Sendable {
    let items: [LibraryAsset]
    let total: Int
    let folders: [LibraryCategory]
    let tags: [LibraryCategory]
    let searches: [LibrarySearch]
    let extensions: [String]
}
struct LibraryManifest: Codable, Sendable {
    let version: Int
    let createdAt: String
    let assets: [LibraryAsset]
    let folders: [LibraryCategory]
    let tags: [LibraryCategory]
    let searches: [LibrarySearch]
    var excludedPending: Int?
}
struct LibraryImport: Codable, Sendable {
    let status: String
    var assetId: String? = nil
    var error: String? = nil
}
struct LibraryQuery: Codable, Sendable {
    var version = 1
    var text = ""
    var view = "recent"
    var kind: String?
    var folderId: String?
    var tagId: String?
    var folderIds: [String] = []
    var tagIds: [String] = []
    var createdAfter: String?
    var createdBefore: String?
    var `extension`: String?
    var sortBy = "created"
    var descending = true
    var offset = 0
    var limit = 100

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        view = try c.decodeIfPresent(String.self, forKey: .view) ?? "recent"
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        folderId = try c.decodeIfPresent(String.self, forKey: .folderId)
        tagId = try c.decodeIfPresent(String.self, forKey: .tagId)
        folderIds = try c.decodeIfPresent([String].self, forKey: .folderIds) ?? []
        tagIds = try c.decodeIfPresent([String].self, forKey: .tagIds) ?? []
        createdAfter = try c.decodeIfPresent(String.self, forKey: .createdAfter)
        createdBefore = try c.decodeIfPresent(String.self, forKey: .createdBefore)
        `extension` = try c.decodeIfPresent(String.self, forKey: .extension)
        sortBy = try c.decodeIfPresent(String.self, forKey: .sortBy) ?? "created"
        descending = try c.decodeIfPresent(Bool.self, forKey: .descending) ?? true
        offset = try c.decodeIfPresent(Int.self, forKey: .offset) ?? 0
        limit = try c.decodeIfPresent(Int.self, forKey: .limit) ?? 100
    }
    func validate() throws {
        guard [1, 2].contains(version), offset >= 0, (1...200).contains(limit),
              ["recent", "favorites", "uncategorized", "trash"].contains(view),
              kind == nil || ["", "image", "video", "pdf", "other"].contains(kind!),
              ["created", "name", "size"].contains(sortBy),
              `extension` == nil || LibraryFormat.validExtension(`extension`!),
              version == 2 || (`extension` == nil && sortBy == "created" && descending),
              createdAfter == nil || LibraryFormat.utc(createdAfter!) != nil,
              createdBefore == nil || LibraryFormat.utc(createdBefore!) != nil,
              (folderIds + tagIds + [folderId, tagId].compactMap { $0 }).allSatisfy(LibraryFormat.validID)
        else { throw LibraryError.message("対応していない検索条件です。") }
    }
}

enum LibraryError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

struct LibraryFormat: Sendable {
    let caseFold: [String: String]
    init(contractRoot: URL) throws {
        caseFold = try JSONDecoder().decode([String: String].self,
            from: Data(contentsOf: contractRoot.appendingPathComponent("case-fold.json")))
    }
    func normalize(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping.unicodeScalars
            .map { caseFold[String($0)] ?? String($0) }.joined()
    }
    static func validID(_ value: String) -> Bool {
        value.count == 36 && UUID(uuidString: value) != nil && value == value.lowercased()
    }
    static func validExtension(_ value: String) -> Bool {
        value.count <= 32 && value.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) }
    }
    static func kind(_ ext: String) -> String {
        if ["jpg", "jpeg", "png", "gif", "bmp", "webp", "tif", "tiff"].contains(ext) { return "image" }
        if ["mp4", "mov", "m4v", "webm", "avi", "mkv"].contains(ext) { return "video" }
        return ext == "pdf" ? "pdf" : "other"
    }
    static func utc(_ value: String) -> Date? {
        guard value.hasSuffix("Z") || value.hasSuffix("+00:00") else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    static func now() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
    static func validate(_ asset: LibraryAsset) throws {
        guard validID(asset.id), !asset.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              validExtension(asset.extension), asset.kind == kind(asset.extension), asset.sizeBytes >= 0,
              asset.sha256.count == 64, asset.sha256.utf8.allSatisfy({ (97...102).contains($0) || (48...57).contains($0) }),
              utc(asset.createdAt) != nil, Set(asset.folderIds).count == asset.folderIds.count,
              Set(asset.tagIds).count == asset.tagIds.count,
              (asset.folderIds + asset.tagIds).allSatisfy(validID)
        else { throw LibraryError.message("素材の形式が不正です。原本は変更していません。") }
    }
}
