import Foundation

struct AssetPendingCapture: Codable {
    let folder: String?
    let files: [String]
    func write(to directory: URL) throws {
        try JSONEncoder().encode(self).write(to: directory.appendingPathComponent("capture.json"), options: .atomic)
    }
    static func retry(root: URL, store: AssetLibraryStore) async throws -> Int {
        guard FileManager.default.fileExists(atPath: root.path) else { return 0 }
        try AssetLibraryStore.noLinks(root)
        var completed = 0
        for directory in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            try AssetLibraryStore.noLinks(directory)
            let manifest = directory.appendingPathComponent("capture.json")
            guard FileManager.default.fileExists(atPath: manifest.path) else { continue }
            try AssetLibraryStore.noLinks(manifest)
            let capture = try JSONDecoder().decode(Self.self, from: Data(contentsOf: manifest))
            guard !capture.files.isEmpty, capture.files.allSatisfy({ !$0.isEmpty && ![".", ".."].contains($0) && URL(fileURLWithPath: $0).lastPathComponent == $0 }) else { throw LibraryError.message("保存待ちファイルの一覧が不正です。") }
            for name in capture.files {
                let result = try await store.importFile(directory.appendingPathComponent(name), folder: capture.folder)
                guard ["saved", "duplicate"].contains(result.status) else { throw LibraryError.message("保存待ちの素材を登録できません。ゴミ箱内にある場合は先に復元してください。") }
            }
            try FileManager.default.trashItem(at: directory, resultingItemURL: nil); completed += 1
        }
        return completed
    }
}
