import Foundation

extension AssetLibraryStore {
    func syncMeta(_ key: String) throws -> String? { try db.scalar("SELECT value FROM sync_meta WHERE key=?", [key]) }
    private func setSyncMeta(_ key: String, _ value: String) throws {
        try db.execute("INSERT OR REPLACE INTO sync_meta VALUES(?,?)", [key, value])
    }
    static func syncJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
    private func syncValue(_ key: String) throws -> LibrarySyncValue? {
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        if parts[0] == "asset" {
            return try assets("SELECT * FROM assets WHERE sha256=?", [parts[1]]).first.map {
                LibrarySyncValue(entityType: "asset", entityId: $0.sha256, deleted: false, asset: $0, category: nil)
            }
        }
        guard let c = try categories(parts[0]).first(where: { $0.id == parts[1] }) else { return nil }
        return LibrarySyncValue(entityType: parts[0], entityId: c.id, deleted: false, asset: nil, category: c)
    }
    private func syncSnapshot(_ value: LibrarySyncValue) throws -> String {
        if let actual = try syncValue(value.key) { return try Self.syncJSON(actual) }
        var absent = value; absent.deleted = true
        return try Self.syncJSON(absent)
    }
    func configureSync(folder: URL, create: Bool) throws {
        guard try syncMeta("recoveryBlocked") != "1" else { throw LibraryError.message("DB復旧前の同期履歴との照合が必要です。素材を保持したまま同期を停止しています。") }
        try Self.noLinks(folder)
        let folder = folder.resolvingSymlinksInPath()
        guard !Self.contains(root, folder), !Self.contains(folder, root), folder.path != "/" else {
            throw LibraryError.message("素材の保存先とは別の同期専用フォルダを選んでください。")
        }
        let marker = folder.appendingPathComponent("hoverpocket-sync.json")
        if !fm.fileExists(atPath: marker.path) {
            guard create else { throw LibraryError.message("同期情報がまだ届いていません。Syncthingで接続したフォルダを選んでください。") }
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let existing = try fm.contentsOfDirectory(atPath: folder.path).filter { ![".stfolder", ".stignore", ".DS_Store"].contains($0) }
            guard existing.isEmpty else { throw LibraryError.message("新しい同期には空の専用フォルダを選んでください。") }
            try Self.writeSyncFile(Data(Self.syncJSON(LibrarySyncMarker(version: 1, groupId: UUID().uuidString.lowercased())).utf8), to: marker)
        }
        let group = try readSyncMarker(folder)
        if let bound = try syncMeta("group"), bound != group {
            throw LibraryError.message("別の同期グループです。現在の同期履歴を保持しています。元のフォルダを選んでください。")
        }
        // Keep this latch outside SQLite so pre-sync snapshots cannot erase recovery protection.
        try Self.writeSyncFile(Data([1]), to: root.appendingPathComponent("sync-configured"))
        try db.transaction {
            if try syncMeta("device") == nil { try setSyncMeta("device", UUID().uuidString.lowercased()) }
            try setSyncMeta("group", group); try setSyncMeta("folder", folder.path); try setSyncMeta("enabled", "1")
        }
    }
    func pauseSync() throws { try setSyncMeta("enabled", "0") }
    func resumeSync() throws {
        guard let folder = try syncMeta("folder") else { throw LibraryError.message("同期フォルダを選択してください。") }
        try configureSync(folder: URL(fileURLWithPath: folder), create: false)
    }
    private func readSyncMarker(_ folder: URL) throws -> String {
        let file = folder.appendingPathComponent("hoverpocket-sync.json"); try Self.noLinks(file)
        guard (try fm.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? Int.max < 4096 else { throw LibraryError.message("同期情報の形式が不正です。") }
        let marker = try JSONDecoder().decode(LibrarySyncMarker.self, from: Data(contentsOf: file))
        guard marker.version == 1, LibraryFormat.validID(marker.groupId) else { throw LibraryError.message("対応していない同期フォルダです。") }
        return marker.groupId
    }
    private func syncEvent(_ revision: String) throws -> LibrarySyncEvent? {
        guard let body = try db.scalar("SELECT body FROM sync_events WHERE revision=?", [revision]) else { return nil }
        return try JSONDecoder().decode(LibrarySyncEvent.self, from: Data(body.utf8))
    }
    private func ancestor(_ older: String, of newer: String) throws -> Bool {
        var pending = [newer], seen = Set<String>()
        while let next = pending.popLast() {
            if next == older { return true }
            guard seen.insert(next).inserted else { continue }
            guard seen.count <= 100_000 else { throw LibraryError.message("同期履歴が大きすぎるため確認を停止しました。") }
            if let event = try syncEvent(next) { pending += event.parents }
        }
        return false
    }
    private func queueSync(_ value: LibrarySyncValue, parents: [String], group: String, device: String) throws {
        let event = LibrarySyncEvent(group: group, device: device, parents: parents, value: value)
        try event.validate(group: group)
        try db.execute("INSERT INTO sync_events VALUES(?,?,?,'applied',0)", [event.revision, value.key, Self.syncJSON(event)])
        try db.execute("INSERT OR REPLACE INTO sync_heads VALUES(?,?,?)", [value.key, event.revision, syncSnapshot(value)])
    }
    private func captureSyncChanges(group: String, device: String) throws {
        var values = try assets("SELECT * FROM assets ORDER BY id").map {
            LibrarySyncValue(entityType: "asset", entityId: $0.sha256, deleted: false, asset: $0, category: nil)
        }
        for type in ["folder", "tag"] {
            values += try categories(type).map { .init(entityType: type, entityId: $0.id, deleted: false, asset: nil, category: $0) }
        }
        let present = Set(values.map(\.key))
        for head in try db.rows("SELECT * FROM sync_heads") where !present.contains(head["entity_key"]!) {
            var absent = try JSONDecoder().decode(LibrarySyncValue.self, from: Data(head["snapshot"]!.utf8))
            absent.deleted = true; values.append(absent)
        }
        try db.transaction {
            for value in values {
                try Task.checkCancellation()
                let snapshot = try Self.syncJSON(value)
                let head = try db.rows("SELECT * FROM sync_heads WHERE entity_key=?", [value.key]).first
                if head?["snapshot"] == snapshot { continue }
                try queueSync(value, parents: head?["revision"].map { [$0] } ?? [], group: group, device: device)
            }
        }
    }
    static func writeSyncFile(_ data: Data, to target: URL) throws {
        try noLinks(target)
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) {
            guard try Data(contentsOf: target) == data else { throw LibraryError.message("同期ファイルの衝突を検出しました。上書きせず保持しています。") }
            return
        }
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try noLinks(target.deletingLastPathComponent())
        let stage = target.deletingLastPathComponent().appendingPathComponent(".partial-" + UUID().uuidString)
        guard fm.createFile(atPath: stage.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw LibraryError.message("同期記録を保存できません。") }
        let file = try FileHandle(forWritingTo: stage); try file.synchronize(); try file.close()
        try fm.moveItem(at: stage, to: target)
    }
    private func verifySyncBlob(_ blob: URL, hash: String) throws {
        try Self.noLinks(blob)
        let info = try fm.attributesOfItem(atPath: blob.path)
        guard let size = (info[.size] as? NSNumber)?.int64Value, let modified = info[.modificationDate] as? Date else { throw LibraryError.message("同期原本を確認できません。") }
        if let previous = syncBlobChecks[hash], previous.size == size, previous.modified == modified, Date().timeIntervalSince(previous.checked) < 300 { return }
        guard try Self.hash(blob) == hash else { throw LibraryError.message("転送先の原本が破損しています。上書きせず停止しました。") }
        syncBlobChecks[hash] = (size, modified, Date())
    }
    private func exportSyncEvents(_ folder: URL) throws {
        for row in try db.rows("SELECT * FROM sync_events WHERE exported=0 AND disposition='applied' ORDER BY rowid") {
            try Task.checkCancellation()
            let event = try JSONDecoder().decode(LibrarySyncEvent.self, from: Data(row["body"]!.utf8))
            if let asset = event.asset {
                let blob = folder.appendingPathComponent("blobs/" + asset.sha256)
                try Self.noLinks(blob)
                if !fm.fileExists(atPath: blob.path) {
                    guard let local = try assets("SELECT * FROM assets WHERE sha256=?", [asset.sha256]).first else {
                        throw LibraryError.message("送信前の原本が見つかりません。同期が終わるまでゴミ箱を空にしないでください。")
                    }
                    let source = try path(local, verifyHash: true)
                    try fm.createDirectory(at: blob.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Self.noLinks(blob.deletingLastPathComponent())
                    let stage = blob.deletingLastPathComponent().appendingPathComponent(".partial-" + UUID().uuidString)
                    try fm.copyItem(at: source, to: stage)
                    guard try Self.hash(stage) == asset.sha256 else { throw LibraryError.message("送信する原本の内容を確認できません。") }
                    try fm.moveItem(at: stage, to: blob)
                }
                try verifySyncBlob(blob, hash: asset.sha256)
            }
            let file = folder.appendingPathComponent("events/\(event.deviceId)/\(event.revision).json")
            try Self.writeSyncFile(Data(row["body"]!.utf8), to: file)
            try db.execute("UPDATE sync_events SET exported=1 WHERE revision=?", [event.revision])
        }
    }
    private func receiveSyncEvents(_ folder: URL, group: String) throws {
        let events = folder.appendingPathComponent("events"); try Self.noLinks(events)
        guard fm.fileExists(atPath: events.path) else { return }
        for device in try fm.contentsOfDirectory(at: events, includingPropertiesForKeys: nil) where LibraryFormat.validID(device.lastPathComponent) {
            try Self.noLinks(device)
            for file in try fm.contentsOfDirectory(at: device, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
                try Task.checkCancellation()
                let revision = file.deletingPathExtension().lastPathComponent
                guard LibraryFormat.validID(revision) else { continue }
                if try db.scalar("SELECT revision FROM sync_events WHERE revision=?", [revision]) != nil { continue }
                try Self.noLinks(file)
                guard let size = try fm.attributesOfItem(atPath: file.path)[.size] as? NSNumber, size.intValue <= 4 * 1024 * 1024 else { throw LibraryError.message("同期記録が大きすぎます。") }
                let data = try Data(contentsOf: file)
                let event = try LibrarySyncEvent.decode(data, group: group)
                guard event.deviceId == device.lastPathComponent, event.revision == revision else { throw LibraryError.message("同期記録の識別情報が一致しません。") }
                try db.execute("INSERT INTO sync_events VALUES(?,?,?,'pending',1)", [revision, event.value.key, Self.syncJSON(event)])
            }
        }
    }
    private func syncCategoryWasDeleted(_ id: String, type: String) throws -> Bool {
        guard let revision = try db.scalar("SELECT revision FROM sync_heads WHERE entity_key=?", [type + ":" + id]) else { return false }
        return try syncEvent(revision)?.deleted == true
    }
    private func applySyncValue(_ value: LibrarySyncValue, folder: URL) throws {
        if let incoming = value.asset {
            func survivingCategories(_ ids: [String], type: String) throws -> [String] {
                try ids.filter { id in
                    if try db.scalar("SELECT id FROM categories WHERE id=? AND type=?", [id, type]) != nil { return true }
                    if try syncCategoryWasDeleted(id, type: type) { return false }
                    throw LibrarySyncWait.dependency
                }
            }
            let folders = try survivingCategories(incoming.folderIds, type: "folder")
            let tags = try survivingCategories(incoming.tagIds, type: "tag")
            let existing = try assets("SELECT * FROM assets WHERE sha256=?", [incoming.sha256]).first
            let a = LibraryAsset(id: existing?.id ?? incoming.id, name: incoming.name,
                extension: existing?.extension ?? incoming.extension, kind: existing?.kind ?? incoming.kind,
                sha256: incoming.sha256, sizeBytes: existing?.sizeBytes ?? incoming.sizeBytes,
                createdAt: existing?.createdAt ?? incoming.createdAt, favorite: incoming.favorite,
                trashed: value.deleted || incoming.trashed, internetOrigin: incoming.internetOrigin || (existing?.internetOrigin ?? false),
                folderIds: folders, tagIds: tags)
            guard existing == nil || existing?.sizeBytes == incoming.sizeBytes else { throw LibraryError.message("同じ素材の容量が一致しません。") }
            if existing == nil {
                guard try get(a.id) == nil else { throw LibraryError.message("素材IDが既存の別の原本と重複しています。") }
                let blob = folder.appendingPathComponent("blobs/" + a.sha256); try Self.noLinks(blob)
                guard fm.fileExists(atPath: blob.path) else { throw LibrarySyncWait.dependency }
                guard (try fm.attributesOfItem(atPath: blob.path)[.size] as? NSNumber)?.int64Value == a.sizeBytes,
                      try Self.hash(blob) == a.sha256 else { throw LibraryError.message("受信した原本の内容が一致しません。再転送を確認してください。") }
                try reserve(a.sizeBytes)
                let target = try path(a)
                if fm.fileExists(atPath: target.path) {
                    guard try Self.hash(target) == a.sha256 else { throw LibraryError.message("未登録の原本と受信素材が競合しています。") }
                } else {
                    let stage = root.appendingPathComponent("staging/sync-" + UUID().uuidString)
                    try fm.copyItem(at: blob, to: stage)
                    guard try Self.hash(stage) == a.sha256 else { throw LibraryError.message("取り込み中に同期原本が変更されました。") }
                    try fm.moveItem(at: stage, to: target)
                }
                try protect(target, a); try insert(a)
            } else {
                _ = try readPath(a)
                try db.execute("UPDATE assets SET name=?,normalized=?,favorite=?,trashed=?,internet=? WHERE id=?", [a.name, format.normalize(a.name), a.favorite ? "1" : "0", a.trashed ? "1" : "0", a.internetOrigin ? "1" : "0", a.id])
            }
            try db.execute("DELETE FROM memberships WHERE asset=?", [a.id])
            for id in a.folderIds + a.tagIds { try db.execute("INSERT INTO memberships VALUES(?,?)", [a.id, id]) }
        } else if let c = value.category {
            if value.deleted {
                try db.execute("UPDATE categories SET parent=NULL WHERE parent=?", [c.id])
                try db.execute("DELETE FROM memberships WHERE category=?", [c.id]); try db.execute("DELETE FROM categories WHERE id=?", [c.id]); return
            }
            var parent = c.parentId
            if let id = parent, try db.scalar("SELECT id FROM categories WHERE id=? AND type='folder'", [id]) == nil {
                guard try syncCategoryWasDeleted(id, type: "folder") else { throw LibrarySyncWait.dependency }
                parent = nil
            }
            var seen = Set([c.id]), next = parent
            while let id = next {
                guard seen.insert(id).inserted else { throw LibraryError.message("フォルダが循環するため適用できません。") }
                next = try db.scalar("SELECT parent FROM categories WHERE id=?", [id])
            }
            if let id = try db.scalar("SELECT id FROM categories WHERE type=? AND normalized=? AND COALESCE(parent,'')=?", [value.entityType, format.normalize(c.name), parent ?? ""]), id != c.id {
                throw LibraryError.message("同名の分類があります。名前を変更して再試行してください。")
            }
            if let type = try db.scalar("SELECT type FROM categories WHERE id=?", [c.id]), type != value.entityType { throw LibraryError.message("分類の種類が一致しません。") }
            try db.execute("INSERT INTO categories VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name,normalized=excluded.normalized,parent=excluded.parent", [c.id, value.entityType, c.name, format.normalize(c.name), parent])
        }
    }
    private func refreshSyncSnapshots() throws {
        // Local edits were captured before receiving; category deletion also changes memberships/children.
        for head in try db.rows("SELECT entity_key,snapshot FROM sync_heads") {
            let previous = try JSONDecoder().decode(LibrarySyncValue.self, from: Data(head["snapshot"]!.utf8))
            try db.execute("UPDATE sync_heads SET snapshot=? WHERE entity_key=?", [syncSnapshot(previous), head["entity_key"]])
        }
    }
    private func applySyncPending(_ folder: URL) throws -> Int {
        var applied = 0, madeProgress = true
        while madeProgress {
            madeProgress = false
            for row in try db.rows("SELECT * FROM sync_events WHERE disposition='pending' ORDER BY rowid") {
                try Task.checkCancellation()
                let event = try JSONDecoder().decode(LibrarySyncEvent.self, from: Data(row["body"]!.utf8))
                var ready = true
                for parent in event.parents {
                    guard let p = try syncEvent(parent) else { ready = false; break }
                    guard p.value.key == event.value.key else { throw LibraryError.message("同期履歴の親が別の素材を指しています。") }
                    if try db.scalar("SELECT disposition FROM sync_events WHERE revision=?", [parent]) == "pending" { ready = false }
                }
                if !ready { continue }
                let head = try db.scalar("SELECT revision FROM sync_heads WHERE entity_key=?", [event.value.key])
                if let head, try ancestor(event.revision, of: head) {
                    try db.execute("UPDATE sync_events SET disposition='applied' WHERE revision=?", [event.revision]); madeProgress = true; continue
                }
                if let head, try !ancestor(head, of: event.revision) {
                    try db.execute("UPDATE sync_events SET disposition='conflict' WHERE revision=?", [event.revision]); madeProgress = true; continue
                }
                do {
                    try db.transaction {
                        try applySyncValue(event.value, folder: folder)
                        try db.execute("INSERT OR REPLACE INTO sync_heads VALUES(?,?,?)", [event.value.key, event.revision, syncSnapshot(event.value)])
                        try db.execute("UPDATE sync_events SET disposition='applied' WHERE revision=?", [event.revision])
                        if event.category != nil { try refreshSyncSnapshots() }
                    }
                    madeProgress = true; applied += 1
                } catch LibrarySyncWait.dependency { continue }
                catch is CancellationError { throw CancellationError() }
                catch {
                    try setSyncMeta("error:" + event.revision, error.localizedDescription)
                    try db.execute("UPDATE sync_events SET disposition='conflict' WHERE revision=?", [event.revision])
                    madeProgress = true
                }
            }
        }
        for row in try db.rows("SELECT revision,entity_key FROM sync_events WHERE disposition='conflict'") {
            if let head = try db.scalar("SELECT revision FROM sync_heads WHERE entity_key=?", [row["entity_key"]]), try ancestor(row["revision"]!, of: head) {
                try db.execute("UPDATE sync_events SET disposition='applied' WHERE revision=?", [row["revision"]])
            }
        }
        let conflicts = try db.rows("SELECT revision,entity_key FROM sync_events WHERE disposition='conflict'")
        for older in conflicts {
            for newer in conflicts where older["entity_key"] == newer["entity_key"] && older["revision"] != newer["revision"] {
                if try ancestor(older["revision"]!, of: newer["revision"]!) {
                    try db.execute("UPDATE sync_events SET disposition='applied' WHERE revision=?", [older["revision"]]); break
                }
            }
        }
        return applied
    }
    func syncEventCount() throws -> Int { Int(try db.scalar("SELECT count(*) FROM sync_events") ?? "0") ?? 0 }
    private func syncDetail(_ value: LibrarySyncValue?) throws -> String {
        guard let value else { return "この端末にはありません" }
        if let a = value.asset {
            let folderNames = try a.folderIds.compactMap { try db.scalar("SELECT name FROM categories WHERE id=?", [$0]) }.joined(separator: "、")
            let tagNames = try a.tagIds.compactMap { try db.scalar("SELECT name FROM categories WHERE id=?", [$0]) }.joined(separator: "、")
            return (value.deleted || a.trashed ? "ゴミ箱" : "ライブラリ") + (a.favorite ? "・お気に入り" : "") + "\nフォルダ: " + (folderNames.isEmpty ? "なし／未到着" : folderNames) + "\nタグ: " + (tagNames.isEmpty ? "なし／未到着" : tagNames)
        }
        if value.deleted { return "削除済みの分類" }
        let parent = try value.category?.parentId.flatMap { try db.scalar("SELECT name FROM categories WHERE id=?", [$0]) }
        return "親フォルダ: " + (parent ?? "なし")
    }
    func syncStatus() throws -> LibrarySyncStatus {
        var status = LibrarySyncStatus(enabled: try syncMeta("enabled") == "1", folder: try syncMeta("folder") ?? "")
        status.pending = Int(try db.scalar("SELECT count(*) FROM sync_events WHERE disposition='pending' OR exported=0") ?? "0") ?? 0
        for row in try db.rows("SELECT * FROM sync_events WHERE disposition='conflict'") {
            let event = try JSONDecoder().decode(LibrarySyncEvent.self, from: Data(row["body"]!.utf8))
            let local = try syncValue(event.value.key)
            status.conflicts.append(.init(id: event.revision, key: event.value.key, name: local?.name ?? event.value.name, remoteName: event.value.name,
                localDetail: try syncDetail(local), remoteDetail: try syncDetail(event.value),
                reason: try syncMeta("error:" + event.revision) ?? "両端末で異なる変更がありました。残す内容を選択してください。"))
        }
        return status
    }
    func syncOnce() throws -> LibrarySyncStatus {
        guard try syncMeta("enabled") == "1", let path = try syncMeta("folder"), let group = try syncMeta("group"), let device = try syncMeta("device") else { return try syncStatus() }
        let folder = URL(fileURLWithPath: path)
        guard try readSyncMarker(folder) == group else { throw LibraryError.message("同期フォルダが別のグループに変わったため停止しました。") }
        try captureSyncChanges(group: group, device: device)
        try exportSyncEvents(folder)
        try receiveSyncEvents(folder, group: group)
        let applied = try applySyncPending(folder)
        var status = try syncStatus(); status.applied = applied; return status
    }
    func resolveSync(revision: String, useRemote: Bool) throws {
        guard try syncMeta("enabled") == "1", let path = try syncMeta("folder"), let group = try syncMeta("group"), let device = try syncMeta("device"),
              let event = try syncEvent(revision) else { throw LibraryError.message("同期を再開してから競合を選択してください。") }
        guard try readSyncMarker(URL(fileURLWithPath: path)) == group else { throw LibraryError.message("同期フォルダを確認してください。") }
        try captureSyncChanges(group: group, device: device)
        let conflicts = try db.rows("SELECT revision FROM sync_events WHERE entity_key=? AND disposition='conflict'", [event.value.key]).compactMap { $0["revision"] }
        guard conflicts.contains(revision) else { throw LibraryError.message("競合の状態が変わりました。更新して選び直してください。") }
        let head = try db.scalar("SELECT revision FROM sync_heads WHERE entity_key=?", [event.value.key])
        var value = event.value
        if !useRemote {
            if let local = try syncValue(event.value.key) { value = local }
            else { value.deleted = true }
        }
        try db.transaction {
            if useRemote { try applySyncValue(value, folder: URL(fileURLWithPath: path)); if value.category != nil { try refreshSyncSnapshots() } }
            try queueSync(value, parents: Array(Set(conflicts + [head].compactMap { $0 })), group: group, device: device)
            for id in conflicts { try db.execute("UPDATE sync_events SET disposition='applied' WHERE revision=?", [id]) }
        }
    }
}
