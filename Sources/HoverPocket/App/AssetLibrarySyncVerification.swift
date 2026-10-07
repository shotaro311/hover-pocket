import Foundation

enum AssetLibrarySyncVerification {
    static func run() async throws {
        let args = CommandLine.arguments
        func option(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        guard let source = option("--asset-source-root"), let destination = option("--sync-evidence") else { throw LibraryError.message("検証用のsource/evidence引数が必要です。") }
        let evidence = URL(fileURLWithPath: destination).resolvingSymlinksInPath()
        guard evidence.lastPathComponent.hasPrefix("HoverPocketSyncVerify-") else { throw LibraryError.message("検証用フォルダ名が必要です。") }
        let fm = FileManager.default
        try fm.createDirectory(at: evidence, withIntermediateDirectories: true)
        let contract = URL(fileURLWithPath: source).appendingPathComponent("shared/asset-library")
        if let action = option("--sync-action") {
            let store = try AssetLibraryStore(root: evidence.appendingPathComponent("library"), contractRoot: contract); try await store.start()
            if action == "create" || action == "join" {
                guard let path = option("--sync-transport") else { throw LibraryError.message("検証転送先が必要です。") }
                try await store.configureSync(folder: URL(fileURLWithPath: path), create: action == "create")
            }
            if action == "seed" {
                let folder = try await store.category(type: "folder", name: "Mac同期テスト")
                let file = evidence.appendingPathComponent("Mac-日本語.txt"); try Data("HoverPocket sync verification original\n".utf8).write(to: file)
                _ = try await store.importFile(file, folder: folder)
            }
            if ["rename", "trash", "restore", "favorite"].contains(action) {
                var query = LibraryQuery(); query.view = action == "restore" ? "trash" : "recent"
                let items = try await store.query(query).items
                guard let asset = items.first else { throw LibraryError.message("検証素材がありません。") }
                try await store.update(ids: [asset.id], operation: action, value: action == "rename" ? "Macから更新.txt" : nil)
            }
            let status = try await store.syncOnce()
            var query = LibraryQuery(); query.view = "trash"
            let active = try await store.query(LibraryQuery()), trash = try await store.query(query)
            for asset in active.items + trash.items { _ = try await store.path(asset, verifyHash: true) }
            print(try AssetLibraryStore.syncJSON(["active": active.total, "trash": trash.total, "pending": status.pending, "conflicts": status.conflicts.count]))
            try Data(AssetLibraryStore.syncJSON(LibraryManifest(version: 1, createdAt: LibraryFormat.now(), assets: active.items + trash.items, folders: active.folders, tags: active.tags, searches: [], excludedPending: 0)).utf8).write(to: evidence.appendingPathComponent("readback.json"), options: .atomic)
            return
        }
        var checks = 0
        func check(_ value: Bool, _ name: String) throws {
            guard value else { throw LibraryError.message("FAIL " + name) }; checks += 1; print("PASS " + name)
        }
        let fixtures = try JSONSerialization.jsonObject(with: Data(contentsOf: contract.appendingPathComponent("sync-v1/fixtures.json"))) as! [String: Any]
        for item in fixtures["cases"] as! [[String: Any]] {
            let data = try JSONSerialization.data(withJSONObject: item["event"]!)
            let accepted = (try? LibrarySyncEvent.decode(data, group: fixtures["groupId"] as! String)) != nil
            try check(accepted == (item["valid"] as! Bool), "wire fixture " + (item["name"] as! String))
        }
        let a = try AssetLibraryStore(root: evidence.appendingPathComponent("a"), contractRoot: contract)
        let b = try AssetLibraryStore(root: evidence.appendingPathComponent("b"), contractRoot: contract)
        try await a.start(); try await b.start()
        let transport = evidence.appendingPathComponent("transport")
        try await a.configureSync(folder: transport, create: true); try await b.configureSync(folder: transport, create: false)
        let folder = try await a.category(type: "folder", name: "日本語フォルダ")
        let child = try await a.category(type: "folder", name: "子", parent: folder)
        let tag = try await a.category(type: "tag", name: "タグ")
        let file = evidence.appendingPathComponent("素材.txt"); try Data("round trip original\n".utf8).write(to: file)
        let imported = try await a.importFile(file, folder: child)
        let id = imported.assetId!
        try await a.update(ids: [id], operation: "classify", value: tag)
        _ = try await a.syncOnce(); _ = try await b.syncOnce()
        var remote = try await b.get(id)
        try check(remote?.folderIds == [child] && remote?.tagIds == [tag], "original, parent/child folder and tag arrive")
        let origin = try await a.get(id)!
        let remotePath = try await b.path(remote!, verifyHash: true)
        try check(try AssetLibraryStore.hash(remotePath) == origin.sha256, "received original SHA matches")
        try await b.update(ids: [id], operation: "rename", value: "Windowsからの名称")
        try await b.update(ids: [id], operation: "favorite")
        _ = try await b.syncOnce(); _ = try await a.syncOnce()
        var local = try await a.get(id)!
        try check(local.name == "Windowsからの名称.txt" && local.favorite, "name and favorite round trip")
        try await a.update(ids: [id], operation: "trash"); _ = try await a.syncOnce(); _ = try await b.syncOnce()
        try check(try await b.get(id)!.trashed, "trash propagates")
        _ = try await b.organize(ids: [id], destination: "folder", folderId: folder, sourceFolderId: nil)
        _ = try await b.syncOnce(); _ = try await a.syncOnce()
        local = try await a.get(id)!
        try check(!local.trashed && local.folderIds.contains(folder), "restoration into folder propagates")
        try await a.update(ids: [id], operation: "rename", value: "Macの編集")
        try await b.update(ids: [id], operation: "rename", value: "Windowsの編集")
        _ = try await a.syncOnce(); var bs = try await b.syncOnce(); var ass = try await a.syncOnce()
        try check(bs.conflicts.count == 1 && ass.conflicts.count == 1, "unsent simultaneous changes remain on both devices")
        try check(try await b.get(id)!.name == "Windowsの編集.txt", "conflict never overwrites local edit")
        try await b.update(ids: [id], operation: "rename", value: "Windowsの最新編集")
        _ = try await b.syncOnce(); ass = try await a.syncOnce()
        try check(ass.conflicts.count == 1 && ass.conflicts.first?.remoteName == "Windowsの最新編集.txt", "remote edit chain offers only its latest conflict")
        try await b.resolveSync(revision: bs.conflicts[0].id, useRemote: true)
        _ = try await b.syncOnce(); ass = try await a.syncOnce(); bs = try await b.syncOnce()
        remote = try await b.get(id)
        try check(ass.conflicts.isEmpty && bs.conflicts.isEmpty && remote?.name == "Macの編集.txt", "remote choice merges both histories")
        try await a.update(ids: [id], operation: "rename", value: "A2")
        try await b.update(ids: [id], operation: "rename", value: "B2")
        _ = try await b.syncOnce(); ass = try await a.syncOnce(); _ = try await b.syncOnce()
        try await a.resolveSync(revision: ass.conflicts[0].id, useRemote: false)
        _ = try await a.syncOnce(); bs = try await b.syncOnce()
        remote = try await b.get(id)
        try check(bs.conflicts.isEmpty && remote?.name == "A2.txt", "local choice merges both histories")
        let before = try await a.syncEventCount()
        for _ in 0..<3 { _ = try await a.syncOnce(); _ = try await b.syncOnce() }
        try check(try await a.syncEventCount() == before, "repeated receipt creates no echo events")
        try await a.pauseSync(); try await a.update(ids: [id], operation: "rename", value: "切断中")
        _ = try await a.syncOnce(); _ = try await b.syncOnce()
        try check(try await b.get(id)!.name == "A2.txt", "paused device retains changes locally")
        try await a.resumeSync(); _ = try await a.syncOnce(); _ = try await b.syncOnce()
        try check(try await b.get(id)!.name == "切断中.txt", "reconnect sends retained changes")
        try await a.update(ids: [id], operation: "trash"); _ = try await a.syncOnce(); _ = try await b.syncOnce()
        _ = try await a.emptyTrash(); _ = try await a.syncOnce(); _ = try await b.syncOnce()
        try check(try await b.get(id)!.trashed, "empty trash never deletes remote original")
        try await b.update(ids: [id], operation: "restore"); _ = try await b.syncOnce(); _ = try await a.syncOnce()
        try check(try await a.get(id)?.trashed == false, "remote restore recovers locally purged original from retained transport")
        try await a.changeCategory(id: child, operation: "delete", name: nil, parent: nil)
        _ = try await a.syncOnce(); _ = try await b.syncOnce()
        let categoryEventCount = try await b.syncEventCount()
        _ = try await b.syncOnce(); _ = try await a.syncOnce()
        try check(try await b.syncEventCount() == categoryEventCount, "received category deletion does not echo membership edits")
        let sameFile = evidence.appendingPathComponent("同じ内容.txt"); try Data("round trip original\n".utf8).write(to: sameFile)
        let duplicated = try await b.importFile(sameFile)
        try check(duplicated.assetId == id && duplicated.status == "duplicate", "same content keeps local asset ID")
        let delayedTransport = evidence.appendingPathComponent("delayed")
        try fm.createDirectory(at: delayedTransport, withIntermediateDirectories: true)
        try fm.copyItem(at: transport.appendingPathComponent("hoverpocket-sync.json"), to: delayedTransport.appendingPathComponent("hoverpocket-sync.json"))
        let delayed = try AssetLibraryStore(root: evidence.appendingPathComponent("delayed-library"), contractRoot: contract); try await delayed.start()
        try await delayed.configureSync(folder: delayedTransport, create: false)
        let eventFiles = (fm.enumerator(at: transport.appendingPathComponent("events"), includingPropertiesForKeys: nil)!.allObjects as! [URL]).filter { $0.pathExtension == "json" }
        let descendant = try eventFiles.first { file in
            let event = try JSONDecoder().decode(LibrarySyncEvent.self, from: Data(contentsOf: file))
            return event.entityType == "asset" && !event.parents.isEmpty
        }!
        let delayedFile = delayedTransport.appendingPathComponent("events/" + descendant.deletingLastPathComponent().lastPathComponent + "/" + descendant.lastPathComponent)
        try fm.createDirectory(at: delayedFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: descendant, to: delayedFile)
        let delayedStatus = try await delayed.syncOnce()
        let delayedTotal = try await delayed.query(LibraryQuery()).total
        try check(delayedStatus.pending == 1 && delayedTotal == 0, "out of order child waits for missing parent")
        for file in eventFiles {
            let target = delayedTransport.appendingPathComponent("events/" + file.deletingLastPathComponent().lastPathComponent + "/" + file.lastPathComponent)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: target.path) { try fm.copyItem(at: file, to: target) }
        }
        _ = try await delayed.syncOnce()
        try check(try await delayed.query(LibraryQuery()).total == 0, "metadata arriving before blob stays pending")
        try fm.copyItem(at: transport.appendingPathComponent("blobs"), to: delayedTransport.appendingPathComponent("blobs"))
        let resumed = try await delayed.syncOnce()
        try check(resumed.pending == 0 && resumed.conflicts.isEmpty, "reordered history converges after blob arrives")
        try check(try await delayed.get(id)?.name == "切断中.txt", "full delayed replay retains final value")
        let marker = transport.appendingPathComponent("hoverpocket-sync.json"), saved = try Data(contentsOf: marker)
        try Data(AssetLibraryStore.syncJSON(LibrarySyncMarker(version: 1, groupId: UUID().uuidString.lowercased())).utf8).write(to: marker)
        do { _ = try await a.syncOnce(); throw LibraryError.message("wrong group accepted") }
        catch { try check(error.localizedDescription != "wrong group accepted", "changed group stops sync") }
        try saved.write(to: marker)
        let c = try AssetLibraryStore(root: evidence.appendingPathComponent("c"), contractRoot: contract); try await c.start()
        try await c.configureSync(folder: transport, create: false)
        let blob = transport.appendingPathComponent("blobs/" + origin.sha256)
        let blobData = try Data(contentsOf: blob); try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: blob.path)
        try Data("corrupt".utf8).write(to: blob)
        let cs = try await c.syncOnce()
        try check(try await c.query(LibraryQuery()).total == 0 && !cs.conflicts.isEmpty, "corrupt blob never becomes a library original")
        try blobData.write(to: blob)
        do { try await a.restoreSnapshot(try await a.snapshots()[0]); throw LibraryError.message("sync rollback accepted") }
        catch { try check(error.localizedDescription != "sync rollback accepted", "snapshot rollback requires sync pause") }
        let link = evidence.appendingPathComponent("linked-transport")
        try fm.createSymbolicLink(at: link, withDestinationURL: transport)
        do { try await b.configureSync(folder: link, create: false); throw LibraryError.message("symlink accepted") }
        catch { try check(error.localizedDescription != "symlink accepted", "symlink transport rejected") }
        remote = try await b.get(id)
        try check(remote != nil, "existing data retained through rejection cases")
        let snapshotName = "sync-restore-test.sqlite"
        try LibraryDatabase(evidence.appendingPathComponent("a/library.sqlite")).backup(to: evidence.appendingPathComponent("a/snapshots/" + snapshotName))
        let eventCountBeforeRestore = try await a.syncEventCount()
        try await a.pauseSync(); try await a.update(ids: [id], operation: "rename", value: "復元前の変更")
        try await a.restoreSnapshot(snapshotName)
        let restoredStatus = try await a.syncStatus()
        let eventCountAfterRestore = try await a.syncEventCount()
        try check(!restoredStatus.enabled && eventCountAfterRestore == eventCountBeforeRestore, "snapshot restore keeps latest sync history and stays paused")
        try await a.resumeSync(); _ = try await a.syncOnce()
        try check(try await a.get(id)?.name == "切断中.txt", "snapshot rollback restores data without rewinding sync ancestry")
        for configured in [false, true] {
            let recoveryRoot = evidence.appendingPathComponent(configured ? "recovery-configured" : "recovery-unused")
            let snapshots = recoveryRoot.appendingPathComponent("snapshots")
            try fm.createDirectory(at: snapshots, withIntermediateDirectories: true)
            let snapshot = snapshots.appendingPathComponent("before-sync.sqlite")
            try LibraryDatabase(snapshot).script(String(contentsOf: contract.appendingPathComponent("001-initial.sql"), encoding: .utf8))
            try Data("broken database fixture".utf8).write(to: recoveryRoot.appendingPathComponent("library.sqlite"))
            try Data().write(to: recoveryRoot.appendingPathComponent("writer.lock"))
            if configured { try Data([1]).write(to: recoveryRoot.appendingPathComponent("sync-configured")) }
            try AssetLibraryStore.recoverBrokenDatabase(root: recoveryRoot, snapshot: snapshot)
            let recovered = try AssetLibraryStore(root: recoveryRoot, contractRoot: contract); try await recovered.start()
            try check(try await recovered.syncMeta("recoveryBlocked") == (configured ? "1" : nil), configured ? "pre-sync snapshot cannot erase recovery latch" : "unused sync remains available after ordinary DB recovery")
            if configured {
                do { try await recovered.configureSync(folder: transport, create: false); throw LibraryError.message("unknown sync history accepted") }
                catch { try check(error.localizedDescription != "unknown sync history accepted", "damaged sync history cannot resume automatically") }
            } else {
                try await recovered.configureSync(folder: transport, create: false)
                try check(try await recovered.syncStatus().enabled, "recovered library without sync history can join")
            }
        }
        print("library_sync_verification=ok checks=\(checks)")
    }
}
