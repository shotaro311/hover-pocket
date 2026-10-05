import Foundation
import CryptoKit
import Darwin

actor AssetLibraryStore {
    let root: URL
    let format: LibraryFormat
    private let db: LibraryDatabase
    private let fm = FileManager.default
    private let lockFD: Int32
    private var undo: [LibraryAsset] = []
    private(set) var notice: String?

    init(root: URL, contractRoot: URL) throws {
        self.root = root
        format = try LibraryFormat(contractRoot: contractRoot)
        try Self.noLinks(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.noLinks(root)
        for directory in ["originals", "staging", "cache", "outbox", "snapshots"] {
            let url = root.appendingPathComponent(directory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Self.noLinks(url)
        }
        lockFD = Darwin.open(root.appendingPathComponent("writer.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            if lockFD >= 0 { Darwin.close(lockFD) }
            throw LibraryError.message("別のHoverPocketが素材ライブラリを使用しています。")
        }
        do {
            let databaseURL = root.appendingPathComponent("library.sqlite")
            try Self.noLinks(databaseURL)
            db = try LibraryDatabase(databaseURL)
            let version = Int(try db.scalar("PRAGMA user_version") ?? "0") ?? -1
            guard (0...1).contains(version) else { throw LibraryError.message("新しい版のライブラリです。対応するアプリへ更新してください。") }
            guard try db.scalar("PRAGMA quick_check") == "ok" else { throw LibraryError.message("DBの整合性を確認できません。原本とDBを保持しています。") }
            try db.script("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;")
            try db.script(String(contentsOf: contractRoot.appendingPathComponent("001-initial.sql"), encoding: .utf8))
        } catch { Darwin.close(lockFD); throw error }
    }
    deinit { flock(lockFD, LOCK_UN); Darwin.close(lockFD) }

    func start() throws {
        for row in try db.rows("SELECT * FROM imports WHERE sha256 IS NOT NULL") {
            let asset = LibraryAsset(id: row["id"]!, name: row["name"]!, extension: row["extension"]!,
                kind: LibraryFormat.kind(row["extension"]!), sha256: row["sha256"]!, sizeBytes: Int64(row["size"]!)!,
                createdAt: row["created"]!, favorite: false, trashed: false, internetOrigin: row["internet"] == "1", folderIds: [], tagIds: [])
            let original = try path(asset), stage = root.appendingPathComponent("staging/\(asset.id).partial")
            if !fm.fileExists(atPath: original.path), fm.fileExists(atPath: stage.path), try Self.hash(stage) == asset.sha256 {
                try fm.moveItem(at: stage, to: original)
            }
            if fm.fileExists(atPath: original.path), try Self.hash(original) == asset.sha256 {
                try protect(original, asset)
                try commit(asset, folder: row["folder"])
            }
        }
        try db.execute("DELETE FROM assets WHERE id IN (SELECT id FROM purges WHERE recycled=1)")
        let uncertainPurges = try db.scalar("SELECT count(*) FROM purges WHERE recycled=0") ?? "0"
        let pending = try db.scalar("SELECT count(*) FROM imports") ?? "0"
        let orphanCount = try orphans().count
        if pending != "0" || orphanCount > 0 || uncertainPurges != "0" {
            notice = "未完了の取り込み \(pending)件、未登録の原本 \(orphanCount)件、ゴミ箱への移動確認待ち \(uncertainPurges)件を保持しています。移動確認待ちはmacOSのゴミ箱を確認してください。"
        }
        let snapshot = root.appendingPathComponent("snapshots/daily-\(LibraryFormat.now().prefix(10)).sqlite")
        if !fm.fileExists(atPath: snapshot.path) { try db.backup(to: snapshot) }
    }

    static func noLinks(_ url: URL) throws {
        // standardizedFileURL rewrites /private/tmp to the /tmp symlink on macOS.
        // Keep the explicitly resolved path while checking each component with lstat.
        var current = url.absoluteURL
        while current.path != "/" {
            // lstat also detects dangling symlinks; never traverse managed or imported links.
            var info = stat()
            if lstat(current.path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK {
                let systemAliases = ["/tmp": "/private/tmp", "/var": "/private/var", "/etc": "/private/etc"]
                if let expected = systemAliases[current.path], info.st_uid == 0 {
                    let destination = try FileManager.default.destinationOfSymbolicLink(atPath: current.path)
                    if destination == expected || "/" + destination == expected {
                        current.deleteLastPathComponent(); continue
                    }
                }
                throw LibraryError.message("シンボリックリンクは扱えません。通常のファイルを選んでください。")
            }
            current.deleteLastPathComponent()
        }
    }
    static func hash(_ url: URL) throws -> String {
        try noLinks(url)
        let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
        var hash = SHA256()
        while let data = try input.read(upToCount: 131_072), !data.isEmpty {
            try Task.checkCancellation(); hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    func path(_ asset: LibraryAsset, verifyHash: Bool = false) throws -> URL {
        try LibraryFormat.validate(asset)
        let url = root.appendingPathComponent(asset.relativePath)
        try Self.noLinks(url)
        if verifyHash {
            let info = try fm.attributesOfItem(atPath: url.path)
            guard (info[.size] as? NSNumber)?.int64Value == asset.sizeBytes,
                  try Self.hash(url) == asset.sha256 else {
                throw LibraryError.message("原本が欠損しているか変更されています。バックアップを確認してください。")
            }
        }
        return url
    }
    func readPath(_ asset: LibraryAsset) throws -> URL {
        let url = try path(asset)
        let values = try fm.attributesOfItem(atPath: url.path)
        guard (values[.size] as? NSNumber)?.int64Value == asset.sizeBytes,
              let modified = values[.modificationDate] as? Date, let expected = LibraryFormat.utc(asset.createdAt),
              abs(modified.timeIntervalSince(expected)) < 0.002 else { throw LibraryError.message("原本が欠損しているか変更されています。") }
        return url
    }
    private func reserve(_ bytes: Int64) throws {
        let attributes = try fm.attributesOfFileSystem(forPath: root.path)
        guard let free = attributes[.systemFreeSize] as? NSNumber, bytes >= 0, free.int64Value - 512 * 1024 * 1024 > bytes else {
            throw LibraryError.message("空き容量が不足しています。512 MiBの予備領域を残して停止しました。")
        }
    }
    private func protect(_ url: URL, _ asset: LibraryAsset) throws {
        try fm.setAttributes([.posixPermissions: 0o444, .modificationDate: LibraryFormat.utc(asset.createdAt)!], ofItemAtPath: url.path)
    }
    func importFile(_ source: URL, folder: String? = nil, internet: Bool = false) throws -> LibraryImport {
        try Self.noLinks(source)
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isPackageKey])
        guard values.isRegularFile == true, values.isPackage != true else { return LibraryImport(status: "skipped", error: "通常ファイルではありません。") }
        guard !Self.contains(root, source) else { return LibraryImport(status: "skipped", error: "ライブラリ管理領域は取り込みません。") }
        let fd = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw LibraryError.message("ファイルを読み取れません。接続と権限を確認してください。") }
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? input.close() }
        var before = stat(); guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { throw LibraryError.message("通常ファイルを選んでください。") }
        try reserve(before.st_size)
        let id = UUID().uuidString.lowercased(), name = source.lastPathComponent, created = LibraryFormat.now()
        let ext = LibraryFormat.validExtension(source.pathExtension.lowercased()) ? source.pathExtension.lowercased() : ""
        let stage = root.appendingPathComponent("staging/\(id).partial")
        let folder = try validFolder(folder)
        let quarantined = internet || getxattr(source.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) > 0
        try db.execute("INSERT INTO imports(id,name,extension,created,internet,folder) VALUES(?,?,?,?,?,?)",
            [id, name, ext, created, quarantined ? "1" : "0", folder])
        guard fm.createFile(atPath: stage.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw LibraryError.message("一時ファイルを作成できません。") }
        let output = try FileHandle(forWritingTo: stage)
        defer { try? output.close() }
        var digest = SHA256(), copied: Int64 = 0
        while let data = try input.read(upToCount: 131_072), !data.isEmpty {
            try Task.checkCancellation()
            if copied % (64 * 1024 * 1024) == 0 { try reserve(Int64(data.count)) }
            try output.write(contentsOf: data); digest.update(data: data); copied += Int64(data.count)
        }
        try output.synchronize(); try output.close()
        var after = stat()
        guard fstat(fd, &after) == 0, before.st_size == after.st_size, copied == before.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw LibraryError.message("コピー中に元のファイルが変更されました。保存を確定せず、再試行できます。")
        }
        let sha = digest.finalize().map { String(format: "%02x", $0) }.joined()
        if let existing = try db.scalar("SELECT id FROM assets WHERE sha256=?", [sha]), let asset = try get(existing) {
            _ = try path(asset, verifyHash: true)
            try db.transaction {
                if let folder { try db.execute("INSERT OR IGNORE INTO memberships VALUES(?,?)", [existing, folder]) }
                if quarantined { try db.execute("UPDATE assets SET internet=1 WHERE id=?", [existing]) }
                try db.execute("DELETE FROM imports WHERE id=?", [id])
            }
            try? fm.trashItem(at: stage, resultingItemURL: nil)
            return LibraryImport(status: asset.trashed ? "restoreAvailable" : "duplicate", assetId: existing)
        }
        let asset = LibraryAsset(id: id, name: name, extension: ext, kind: LibraryFormat.kind(ext), sha256: sha,
            sizeBytes: copied, createdAt: created, favorite: false, trashed: false, internetOrigin: quarantined, folderIds: [], tagIds: [])
        try db.execute("UPDATE imports SET sha256=?,size=? WHERE id=?", [sha, String(copied), id])
        let original = try path(asset)
        try fm.moveItem(at: stage, to: original); try protect(original, asset)
        try commit(asset, folder: folder)
        return LibraryImport(status: "saved", assetId: id)
    }
    private func validFolder(_ id: String?) throws -> String? {
        guard let id else { return nil }
        guard try db.scalar("SELECT id FROM categories WHERE id=? AND type='folder'", [id]) != nil else { throw LibraryError.message("保存先のフォルダがありません。選び直してください。") }
        return id
    }
    private func insert(_ a: LibraryAsset) throws {
        try LibraryFormat.validate(a)
        try db.execute("INSERT INTO assets VALUES(?,?,?,?,?,?,?,?,?,?,?)", [a.id, a.name, format.normalize(a.name), a.extension,
            a.kind, a.sha256, String(a.sizeBytes), a.createdAt, a.favorite ? "1" : "0", a.trashed ? "1" : "0", a.internetOrigin ? "1" : "0"])
    }
    private func commit(_ a: LibraryAsset, folder: String?) throws {
        try db.transaction {
            if try db.scalar("SELECT id FROM assets WHERE sha256=?", [a.sha256]) == nil {
                try insert(a)
                if let folder, try db.scalar("SELECT id FROM categories WHERE id=?", [folder]) != nil {
                    try db.execute("INSERT OR IGNORE INTO memberships VALUES(?,?)", [a.id, folder])
                }
            }
            try db.execute("DELETE FROM imports WHERE id=?", [a.id])
        }
    }
    private func assets(_ sql: String, _ values: [String?] = []) throws -> [LibraryAsset] {
        try db.rows(sql, values).map { row in
            let memberships = try db.rows("SELECT categories.id,type FROM memberships JOIN categories ON category=categories.id WHERE asset=?", [row["id"]])
            return try LibraryAsset(databaseRow: row,
                folderIds: memberships.filter { $0["type"] == "folder" }.compactMap { $0["id"] }.sorted(),
                tagIds: memberships.filter { $0["type"] == "tag" }.compactMap { $0["id"] }.sorted())
        }
    }
    func get(_ id: String) throws -> LibraryAsset? { try assets("SELECT * FROM assets WHERE id=?", [id]).first }
    private func categories(_ type: String) throws -> [LibraryCategory] {
        try db.rows("SELECT * FROM categories WHERE type=? ORDER BY normalized,id", [type]).map {
            LibraryCategory(id: $0["id"]!, name: $0["name"]!, parentId: $0["parent"])
        }
    }
    private func searches() throws -> [LibrarySearch] {
        try db.rows("SELECT * FROM searches ORDER BY name,id").map {
            let query = try JSONDecoder().decode(LibraryQuery.self, from: Data($0["filter"]!.utf8)); try query.validate()
            return LibrarySearch(id: $0["id"]!, name: $0["name"]!, filter: query)
        }
    }
    private func filter(_ q: LibraryQuery) throws -> (String, [String?]) {
        try q.validate()
        var clauses = ["trashed=?"], args: [String?] = [q.view == "trash" ? "1" : "0"]
        if q.view == "favorites" { clauses.append("favorite=1") }
        if q.view == "uncategorized" { clauses.append("NOT EXISTS(SELECT 1 FROM memberships WHERE asset=assets.id)") }
        if !q.text.isEmpty {
            clauses.append("(instr(normalized,?)>0 OR EXISTS(SELECT 1 FROM memberships JOIN categories ON category=categories.id WHERE asset=assets.id AND instr(categories.normalized,?)>0))")
            args += [format.normalize(q.text), format.normalize(q.text)]
        }
        if let kind = q.kind, !kind.isEmpty { clauses.append("kind=?"); args.append(kind) }
        if let ext = q.extension { clauses.append("extension=?"); args.append(ext) }
        if let date = q.createdAfter { clauses.append("julianday(created)>=julianday(?)"); args.append(date) }
        if let date = q.createdBefore { clauses.append("julianday(created)<julianday(?)"); args.append(date) }
        for ids in [q.folderIds + [q.folderId].compactMap { $0 }, q.tagIds + [q.tagId].compactMap { $0 }] where !ids.isEmpty {
            clauses.append("EXISTS(SELECT 1 FROM memberships WHERE asset=assets.id AND category IN (\(ids.map { _ in "?" }.joined(separator: ","))))")
            args += ids
        }
        return (clauses.joined(separator: " AND "), args)
    }
    private func order(_ q: LibraryQuery) -> String {
        let column = q.sortBy == "name" ? "normalized" : q.sortBy == "size" ? "size" : "julianday(created)"
        return column + (q.descending ? " DESC" : " ASC") + ",id ASC"
    }
    func query(_ q: LibraryQuery) throws -> LibraryPage {
        let (whereSQL, args) = try filter(q)
        return try LibraryPage(items: assets("SELECT * FROM assets WHERE \(whereSQL) ORDER BY \(order(q)) LIMIT ? OFFSET ?", args + [String(q.limit), String(q.offset)]),
            total: Int(db.scalar("SELECT count(*) FROM assets WHERE \(whereSQL)", args) ?? "0") ?? 0,
            folders: categories("folder"), tags: categories("tag"), searches: searches(), extensions: db.rows("SELECT DISTINCT extension FROM assets ORDER BY extension").compactMap { $0["extension"] })
    }
    func matches(_ id: String, query q: LibraryQuery) throws -> Bool {
        let (sql, args) = try filter(q)
        return try db.scalar("SELECT id FROM assets WHERE \(sql) AND id=?", args + [id]) != nil
    }
    func range(_ q: LibraryQuery, anchor: String, target: String) throws -> [String] {
        let (sql, args) = try filter(q)
        let ids = try db.rows("SELECT id FROM assets WHERE \(sql) ORDER BY \(order(q))", args).compactMap { $0["id"] }
        guard let a = ids.firstIndex(of: anchor), let b = ids.firstIndex(of: target) else { return [] }
        return Array(ids[min(a, b)...max(a, b)])
    }
    func category(type: String, name: String, parent: String? = nil) throws -> String {
        guard ["folder", "tag"].contains(type), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              type == "folder" || parent == nil else { throw LibraryError.message("分類の名前を入力してください。") }
        _ = try validFolder(parent)
        let normalized = format.normalize(name)
        if let id = try db.scalar("SELECT id FROM categories WHERE type=? AND normalized=? AND COALESCE(parent,'')=?", [type, normalized, parent ?? ""]) { return id }
        let id = UUID().uuidString.lowercased()
        try db.execute("INSERT INTO categories VALUES(?,?,?,?,?)", [id, type, name, normalized, parent]); return id
    }
    func changeCategory(id: String, operation: String, name: String?, parent: String?) throws {
        guard let category = try db.rows("SELECT * FROM categories WHERE id=?", [id]).first else { throw LibraryError.message("分類がありません。") }
        try db.transaction {
            switch operation {
            case "rename":
                guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LibraryError.message("分類の名前を入力してください。") }
                try db.execute("UPDATE categories SET name=?,normalized=? WHERE id=?", [name, format.normalize(name), id])
            case "delete":
                try db.execute("UPDATE categories SET parent=NULL WHERE parent=?", [id])
                try db.execute("DELETE FROM memberships WHERE category=?", [id]); try db.execute("DELETE FROM categories WHERE id=?", [id])
            case "move":
                guard category["type"] == "folder" else { throw LibraryError.message("タグには親フォルダを設定できません。") }
                var next = try validFolder(parent), seen = Set([id])
                while let p = next {
                    guard seen.insert(p).inserted else { throw LibraryError.message("フォルダを自身の子へ移動できません。") }
                    next = try db.scalar("SELECT parent FROM categories WHERE id=?", [p])
                }
                try db.execute("UPDATE categories SET parent=? WHERE id=?", [parent, id])
            default: throw LibraryError.message("分類の操作が不正です。")
            }
        }
    }
    func update(ids: [String], operation: String, value: String? = nil) throws {
        let before = try Set(ids).compactMap { try get($0) }
        try db.transaction {
            for asset in before {
                switch operation {
                case "trash", "restore": try db.execute("UPDATE assets SET trashed=? WHERE id=?", [operation == "trash" ? "1" : "0", asset.id])
                case "favoriteSet":
                    guard let value, ["true", "false"].contains(value) else { throw LibraryError.message("お気に入りの値が不正です。") }
                    try db.execute("UPDATE assets SET favorite=? WHERE id=?", [value == "true" ? "1" : "0", asset.id])
                case "favorite": try db.execute("UPDATE assets SET favorite=? WHERE id=?", [asset.favorite ? "0" : "1", asset.id])
                case "rename":
                    guard var name = value?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
                          !name.contains("/"), !name.contains(":"), !name.contains("\0") else { throw LibraryError.message("有効な名前を入力してください。") }
                    if !asset.extension.isEmpty && !name.lowercased().hasSuffix("." + asset.extension) { name += "." + asset.extension }
                    try db.execute("UPDATE assets SET name=?,normalized=? WHERE id=?", [name, format.normalize(name), asset.id])
                case "classify":
                    guard let value, try db.scalar("SELECT id FROM categories WHERE id=?", [value]) != nil else { throw LibraryError.message("分類がありません。") }
                    try db.execute("INSERT OR IGNORE INTO memberships VALUES(?,?)", [asset.id, value])
                case "unclassify": try db.execute("DELETE FROM memberships WHERE asset=? AND category=?", [asset.id, value])
                default: throw LibraryError.message("素材の操作が不正です。")
                }
            }
        }
        undo = before
    }
    func undoLast() throws {
        try db.transaction {
            for a in undo {
                try db.execute("UPDATE assets SET name=?,normalized=?,favorite=?,trashed=? WHERE id=?", [a.name, format.normalize(a.name), a.favorite ? "1" : "0", a.trashed ? "1" : "0", a.id])
                try db.execute("DELETE FROM memberships WHERE asset=?", [a.id])
                for id in a.folderIds + a.tagIds where try db.scalar("SELECT id FROM categories WHERE id=?", [id]) != nil {
                    try db.execute("INSERT INTO memberships VALUES(?,?)", [a.id, id])
                }
            }
        }
        undo = []
    }
    func saveSearch(name: String, query: LibraryQuery) throws {
        try query.validate()
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LibraryError.message("検索名を入力してください。") }
        try db.execute("INSERT INTO searches VALUES(?,?,?)", [UUID().uuidString.lowercased(), name, String(decoding: JSONEncoder().encode(query), as: UTF8.self)])
    }
    func copyOut(_ id: String, destination: URL? = nil) throws -> URL {
        guard let a = try get(id) else { throw LibraryError.message("素材がありません。") }
        let original = try path(a, verifyHash: true)
        let output: URL
        if let destination {
            try Self.noLinks(destination)
            guard !Self.contains(root, destination), !fm.fileExists(atPath: destination.path) else { throw LibraryError.message("既存ファイルを上書きしない保存先を選んでください。") }
            output = destination
        } else {
            let directory = root.appendingPathComponent("outbox/" + UUID().uuidString.lowercased())
            try fm.createDirectory(at: directory, withIntermediateDirectories: false)
            let name = a.name.components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters)).joined(separator: "_")
            var stem = a.extension.isEmpty ? name : String(name.dropLast(a.extension.count + 1))
            while stem.utf8.count > 180 { stem.removeLast() }
            output = directory.appendingPathComponent("asset-" + stem + (a.extension.isEmpty ? "" : "." + a.extension))
        }
        try fm.copyItem(at: original, to: output)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
        if a.internetOrigin {
            let flag = "0083;\(String(Int(Date().timeIntervalSince1970), radix: 16));HoverPocket;"
            guard flag.withCString({ setxattr(output.path, "com.apple.quarantine", $0, strlen($0), 0, 0) }) == 0 else {
                throw LibraryError.message("インターネット由来の保護情報を付けられないため、このコピーを外へ渡せません。")
            }
        }
        guard try Self.hash(output) == a.sha256 else { throw LibraryError.message("作業コピーを検証できませんでした。") }
        return output
    }
    func export(to destination: URL) throws -> LibraryManifest {
        try Self.noLinks(destination)
        guard !Self.contains(root, destination), !fm.fileExists(atPath: destination.path) else { throw LibraryError.message("管理領域外の新しいフォルダを選んでください。") }
        let manifest = try LibraryManifest(version: 1, createdAt: LibraryFormat.now(), assets: assets("SELECT * FROM assets ORDER BY id"), folders: categories("folder"), tags: categories("tag"), searches: searches(), excludedPending: Int(db.scalar("SELECT count(*) FROM imports") ?? "0"))
        let stage = destination.appendingPathExtension("partial-" + UUID().uuidString)
        try fm.createDirectory(at: stage.appendingPathComponent("originals"), withIntermediateDirectories: true)
        for a in manifest.assets {
            try Task.checkCancellation()
            let target = stage.appendingPathComponent(a.relativePath)
            try fm.copyItem(at: path(a, verifyHash: true), to: target)
            guard try Self.hash(target) == a.sha256 else { throw LibraryError.message("バックアップ原本の検証に失敗しました。") }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(to: stage.appendingPathComponent("manifest.json"), options: .atomic)
        try fm.moveItem(at: stage, to: destination); return manifest
    }
    func restore(from source: URL) throws {
        guard try db.scalar("SELECT (SELECT count(*) FROM assets)+(SELECT count(*) FROM categories)+(SELECT count(*) FROM searches)+(SELECT count(*) FROM imports)") == "0" else { throw LibraryError.message("復元には空のライブラリが必要です。現在の素材は保持されています。") }
        try Self.noLinks(source); try Self.noLinks(source.appendingPathComponent("originals"))
        try Self.noLinks(source.appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder().decode(LibraryManifest.self, from: Data(contentsOf: source.appendingPathComponent("manifest.json")))
        guard manifest.version == 1, LibraryFormat.utc(manifest.createdAt) != nil,
              Set(manifest.assets.map(\.id)).count == manifest.assets.count,
              Set(manifest.assets.map(\.sha256)).count == manifest.assets.count,
              Set(manifest.searches.map(\.id)).count == manifest.searches.count else { throw LibraryError.message("対応していないバックアップです。") }
        let categories = manifest.folders + manifest.tags
        guard Set(categories.map(\.id)).count == categories.count else { throw LibraryError.message("分類IDが重複しています。") }
        let folders = Set(manifest.folders.map(\.id)), tags = Set(manifest.tags.map(\.id))
        let categoryMap = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
        for c in categories {
            guard LibraryFormat.validID(c.id), !c.name.isEmpty, !tags.contains(c.id) || c.parentId == nil else { throw LibraryError.message("分類が不正です。") }
            var seen = Set([c.id]), next = c.parentId
            while let id = next {
                guard folders.contains(id), seen.insert(id).inserted else { throw LibraryError.message("分類の参照が不正です。") }
                next = categoryMap[id]?.parentId
            }
        }
        var total: Int64 = 0
        for a in manifest.assets {
            try LibraryFormat.validate(a)
            guard Set(a.folderIds).isSubset(of: folders), Set(a.tagIds).isSubset(of: tags) else { throw LibraryError.message("素材の分類参照が不正です。") }
            let file = source.appendingPathComponent(a.relativePath)
            try Self.noLinks(file)
            guard (try fm.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value == a.sizeBytes,
                  try Self.hash(file) == a.sha256 else { throw LibraryError.message("バックアップの原本が欠損・変更されています。") }
            let sum = total.addingReportingOverflow(a.sizeBytes)
            guard !sum.overflow else { throw LibraryError.message("バックアップの容量が不正です。") }; total = sum.partialValue
        }
        try reserve(total)
        for s in manifest.searches {
            guard LibraryFormat.validID(s.id), !s.name.isEmpty else { throw LibraryError.message("保存検索が不正です。") }
            try s.filter.validate()
        }
        try db.transaction {
            for (type, list) in [("folder", manifest.folders), ("tag", manifest.tags)] {
                for c in list { try db.execute("INSERT INTO categories VALUES(?,?,?,?,?)", [c.id, type, c.name, format.normalize(c.name), c.parentId]) }
            }
            for a in manifest.assets {
                let target = try path(a)
                try fm.copyItem(at: source.appendingPathComponent(a.relativePath), to: target)
                try protect(target, a); try insert(a)
                for id in a.folderIds + a.tagIds { try db.execute("INSERT INTO memberships VALUES(?,?)", [a.id, id]) }
            }
            for s in manifest.searches { try db.execute("INSERT INTO searches VALUES(?,?,?)", [s.id, s.name, String(decoding: JSONEncoder().encode(s.filter), as: UTF8.self)]) }
        }
    }
    func orphans() throws -> [URL] {
        let known = Set(try db.rows("SELECT id FROM assets").compactMap { $0["id"] })
        return try fm.contentsOfDirectory(at: root.appendingPathComponent("originals"), includingPropertiesForKeys: [.isRegularFileKey]).filter {
            LibraryFormat.validID($0.deletingPathExtension().lastPathComponent) && !known.contains($0.deletingPathExtension().lastPathComponent)
        }
    }
    func recoverOrphans() throws -> Int {
        var count = 0
        for file in try orphans() {
            try Self.noLinks(file)
            let id = file.deletingPathExtension().lastPathComponent, ext = file.pathExtension
            let attributes = try fm.attributesOfItem(atPath: file.path), sha = try Self.hash(file)
            guard try db.scalar("SELECT id FROM assets WHERE sha256=?", [sha]) == nil else { continue }
            let asset = LibraryAsset(id: id, name: "復旧-" + file.lastPathComponent, extension: ext, kind: LibraryFormat.kind(ext), sha256: sha,
                sizeBytes: (attributes[.size] as! NSNumber).int64Value, createdAt: LibraryFormat.now(), favorite: false, trashed: false, internetOrigin: true, folderIds: [], tagIds: [])
            try protect(file, asset); try insert(asset); count += 1
        }
        return count
    }
    func emptyTrash() throws -> Int {
        var count = 0
        for asset in try assets("SELECT * FROM assets WHERE trashed=1") {
            let original = try path(asset, verifyHash: true)
            try db.execute("INSERT OR REPLACE INTO purges VALUES(?,?,0)", [asset.id, LibraryFormat.now()])
            try fm.trashItem(at: original, resultingItemURL: nil)
            try db.execute("UPDATE purges SET recycled=1 WHERE id=?", [asset.id])
            try db.execute("DELETE FROM assets WHERE id=?", [asset.id]); count += 1
        }
        undo = []; return count
    }
    func snapshots() throws -> [String] {
        try fm.contentsOfDirectory(atPath: root.appendingPathComponent("snapshots").path).filter { $0.hasSuffix(".sqlite") }.sorted().reversed()
    }
    func restoreSnapshot(_ name: String) throws {
        guard try snapshots().contains(name), !name.contains("/"), !name.contains("..") else { throw LibraryError.message("スナップショットがありません。") }
        let source = root.appendingPathComponent("snapshots/" + name)
        try Self.noLinks(source)
        let candidate = try LibraryDatabase(source)
        guard try candidate.scalar("PRAGMA user_version") == "1", try candidate.scalar("PRAGMA quick_check") == "ok",
              try candidate.rows("PRAGMA foreign_key_check").isEmpty else { throw LibraryError.message("スナップショットの整合性を確認できません。") }
        for row in try candidate.rows("SELECT * FROM assets") {
            let asset = try LibraryAsset(databaseRow: row)
            _ = try path(asset, verifyHash: true)
        }
        for row in try candidate.rows("SELECT filter FROM searches") {
            try JSONDecoder().decode(LibraryQuery.self, from: Data((row["filter"] ?? "").utf8)).validate()
        }
        let before = root.appendingPathComponent("snapshots/before-restore-" + UUID().uuidString + ".sqlite")
        try db.backup(to: before)
        do { try db.restore(from: source) }
        catch { try? db.restore(from: before); throw error }
        undo = []
    }

    static func recoverBrokenDatabase(root: URL, snapshot: URL) throws {
        try noLinks(root); try noLinks(snapshot)
        let fm = FileManager.default, database = root.appendingPathComponent("library.sqlite")
        guard snapshot.deletingLastPathComponent().resolvingSymlinksInPath() == root.appendingPathComponent("snapshots").resolvingSymlinksInPath(), snapshot.pathExtension == "sqlite" else { throw LibraryError.message("このライブラリのDBスナップショットを選んでください。") }
        let fd = Darwin.open(root.appendingPathComponent("writer.lock").path, O_RDWR | O_NOFOLLOW)
        guard fd >= 0 else { throw LibraryError.message("ライブラリのロックを確認できません。") }
        defer { flock(fd, LOCK_UN); Darwin.close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw LibraryError.message("別のアプリがライブラリを使用しています。") }
        try noLinks(database)
        if let current = try? LibraryDatabase(database), let version = try? current.scalar("PRAGMA user_version"), (Int(version) ?? 0) > 1 { throw LibraryError.message("新しい版のDBはこのアプリで置き換えられません。") }
        let candidate = try LibraryDatabase(snapshot)
        guard try candidate.scalar("PRAGMA quick_check") == "ok", try candidate.scalar("PRAGMA user_version") == "1", try candidate.rows("PRAGMA foreign_key_check").isEmpty else { throw LibraryError.message("復旧元のDBを検証できません。") }
        for row in try candidate.rows("SELECT * FROM assets") {
            let asset = try LibraryAsset(databaseRow: row)
            try LibraryFormat.validate(asset)
            let file = root.appendingPathComponent(asset.relativePath)
            guard try hash(file) == asset.sha256 else { throw LibraryError.message("復旧元のDBと原本が一致しません。") }
        }
        let staged = root.appendingPathComponent("recovery-" + UUID().uuidString + ".sqlite")
        try candidate.backup(to: staged)
        let preserved = root.appendingPathComponent("before-recovery-" + UUID().uuidString)
        try fm.createDirectory(at: preserved, withIntermediateDirectories: false)
        var moved: [URL] = []
        do {
            for suffix in ["", "-wal", "-shm"] {
                let file = URL(fileURLWithPath: database.path + suffix)
                try noLinks(file)
                if fm.fileExists(atPath: file.path) { try fm.moveItem(at: file, to: preserved.appendingPathComponent(file.lastPathComponent)); moved.append(file) }
            }
            try fm.moveItem(at: staged, to: database)
        } catch {
            for file in moved { try? fm.moveItem(at: preserved.appendingPathComponent(file.lastPathComponent), to: file) }
            throw error
        }
    }

    static func importEstimate(_ urls: [URL]) throws -> (count: Int, bytes: Int64) {
        var count = 0, bytes: Int64 = 0
        func inspect(_ url: URL) throws {
            try Task.checkCancellation()
            guard (try? noLinks(url)) != nil else { return }
            let flags = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isPackageKey, .fileSizeKey])
            if flags.isPackage == true { return }
            if flags.isRegularFile == true { count += 1; bytes += Int64(flags.fileSize ?? 0) }
            else if flags.isDirectory == true, let iterator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsPackageDescendants, .skipsHiddenFiles]) {
                for case let file as URL in iterator {
                    try Task.checkCancellation()
                    let flags = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                    if flags.isSymbolicLink == true { iterator.skipDescendants(); continue }
                    if flags.isRegularFile == true { count += 1; bytes += Int64(flags.fileSize ?? 0) }
                }
            }
        }
        for url in urls { try inspect(url) }; return (count, bytes)
    }
    private static func contains(_ directory: URL, _ file: URL) -> Bool {
        let parent = directory.resolvingSymlinksInPath().path, path = file.resolvingSymlinksInPath().path
        return path == parent || path.hasPrefix(parent + "/")
    }
}
