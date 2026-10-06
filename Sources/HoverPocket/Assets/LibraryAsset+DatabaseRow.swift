import Foundation

extension LibraryAsset {
    init(databaseRow row: [String: String], folderIds: [String] = [], tagIds: [String] = []) throws {
        guard let id = row["id"], let name = row["name"], let ext = row["extension"],
              let kind = row["kind"], let sha256 = row["sha256"],
              let size = row["size"].flatMap(Int64.init), let createdAt = row["created"] else {
            throw LibraryError.message("素材のDB情報を読み取れません。原本は変更していません。")
        }
        self.init(id: id, name: name, extension: ext, kind: kind, sha256: sha256,
                  sizeBytes: size, createdAt: createdAt, favorite: row["favorite"] == "1",
                  trashed: row["trashed"] == "1", internetOrigin: row["internet"] == "1",
                  folderIds: folderIds, tagIds: tagIds)
    }
}
