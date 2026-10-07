import Foundation

struct LibrarySyncValue: Codable, Equatable, Sendable {
    var entityType: String
    var entityId: String
    var deleted: Bool
    var asset: LibraryAsset?
    var category: LibraryCategory?
    var key: String { entityType + ":" + entityId }
    var name: String { asset?.name ?? category?.name ?? entityId }
    enum CodingKeys: String, CodingKey { case entityType, entityId, deleted, asset, category }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(entityType, forKey: .entityType); try c.encode(entityId, forKey: .entityId)
        try c.encode(deleted, forKey: .deleted); try c.encode(asset, forKey: .asset); try c.encode(category, forKey: .category)
    }
}
struct LibrarySyncEvent: Codable, Sendable {
    let version: Int
    let groupId: String
    let revision: String
    let deviceId: String
    let entityType: String
    let entityId: String
    let parents: [String]
    let deleted: Bool
    let asset: LibraryAsset?
    let category: LibraryCategory?
    var value: LibrarySyncValue { .init(entityType: entityType, entityId: entityId, deleted: deleted, asset: asset, category: category) }
    init(group: String, device: String, parents: [String], value: LibrarySyncValue) {
        version = 1; groupId = group; revision = UUID().uuidString.lowercased(); deviceId = device
        entityType = value.entityType; entityId = value.entityId; deleted = value.deleted
        asset = value.asset; category = value.category; self.parents = parents.sorted()
    }
    enum CodingKeys: String, CodingKey { case version, groupId, revision, deviceId, entityType, entityId, parents, deleted, asset, category }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version); try c.encode(groupId, forKey: .groupId)
        try c.encode(revision, forKey: .revision); try c.encode(deviceId, forKey: .deviceId)
        try c.encode(entityType, forKey: .entityType); try c.encode(entityId, forKey: .entityId)
        try c.encode(parents, forKey: .parents); try c.encode(deleted, forKey: .deleted)
        try c.encode(asset, forKey: .asset); try c.encode(category, forKey: .category)
    }
    static func decode(_ data: Data, group: String) throws -> LibrarySyncEvent {
        guard data.count <= 4 * 1024 * 1024,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["version", "groupId", "revision", "deviceId", "entityType", "entityId", "parents", "deleted", "asset", "category"]) else { throw LibraryError.message("同期記録の項目が不正です。") }
        let event = try JSONDecoder().decode(Self.self, from: data)
        try event.validate(group: group); return event
    }
    func validate(group: String) throws {
        guard version == 1, groupId == group, LibraryFormat.validID(groupId),
              LibraryFormat.validID(revision), LibraryFormat.validID(deviceId), parents.count <= 256,
              Set(parents).count == parents.count, !parents.contains(revision), parents.allSatisfy(LibraryFormat.validID)
        else { throw LibraryError.message("対応していない同期記録です。") }
        if entityType == "asset" {
            guard let asset, category == nil, entityId == asset.sha256,
                  asset.name.count <= 4096, !asset.name.contains("\0"),
                  !asset.name.contains("/"), !asset.name.contains(":"),
                  asset.folderIds.count + asset.tagIds.count <= 10000,
                  (asset.folderIds + asset.tagIds).allSatisfy(LibraryFormat.validID)
            else { throw LibraryError.message("同期素材が不正です。") }
            try LibraryFormat.validate(asset)
        } else {
            guard ["folder", "tag"].contains(entityType), asset == nil, let category,
                  entityId == category.id, LibraryFormat.validID(entityId),
                  !category.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  category.name.count <= 4096, !category.name.contains("\0"),
                  category.parentId == nil || (entityType == "folder" && LibraryFormat.validID(category.parentId!) && category.parentId != entityId)
            else { throw LibraryError.message("同期分類が不正です。") }
        }
    }
}
struct LibrarySyncMarker: Codable { let version: Int; let groupId: String }
struct LibrarySyncConflict: Identifiable, Sendable {
    let id: String
    let key: String
    let name: String
    let remoteName: String
    let localDetail: String
    let remoteDetail: String
    let reason: String
}
struct LibrarySyncStatus: Sendable {
    var enabled = false
    var folder = ""
    var pending = 0
    var conflicts: [LibrarySyncConflict] = []
    var applied = 0
}
enum LibrarySyncWait: Error { case dependency }

