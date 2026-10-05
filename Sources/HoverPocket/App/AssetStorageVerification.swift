import Foundation

enum AssetStorageVerification {
    static func run(at evidence: URL, contract: URL) async throws -> [String] {
        var checks: [String] = []
        func check(_ value: Bool, _ name: String) throws {
            guard value else { throw LibraryError.message("FAIL " + name) }; checks.append(name); print("PASS " + name)
        }
        let root = evidence.appendingPathComponent("safety-library")
        let store = try AssetLibraryStore(root: root, contractRoot: contract); try await store.start()
        do { _ = try AssetLibraryStore(root: root, contractRoot: contract); throw LibraryError.message("second writer accepted") }
        catch { try check(error.localizedDescription != "second writer accepted", "second writer refused") }
        let input = evidence.appendingPathComponent("safety-source.txt")
        try Data("safety fixture".utf8).write(to: input)
        let result = try await store.importFile(input), id = result.assetId!
        _ = try await store.importFile(input, internet: true)
        let asset = try await store.get(id)!
        let copy = try await store.copyOut(id)
        try check(asset.internetOrigin && getxattr(copy.path, "com.apple.quarantine", nil, 0, 0, 0) > 0, "duplicate strengthens provenance and working copy quarantine")
        try check(try await store.importFile(root.appendingPathComponent(asset.relativePath)).status == "skipped", "managed original cannot import into itself")
        let existing = evidence.appendingPathComponent("existing-destination.txt")
        try Data("keep this file".utf8).write(to: existing)
        do { _ = try await store.copyOut(id, destination: existing); throw LibraryError.message("overwrite accepted") }
        catch { try check(error.localizedDescription != "overwrite accepted" && (try String(contentsOf: existing, encoding: .utf8)) == "keep this file", "existing save destination preserved") }
        let long = String(repeating: "日本語", count: 80)
        try await store.update(ids: [id], operation: "rename", value: long)
        let longCopy = try await store.copyOut(id)
        try check(longCopy.lastPathComponent.utf8.count <= 255 && longCopy.pathExtension == "txt", "long Unicode external filename preserves extension")
        let badBackup = evidence.appendingPathComponent("bad-backup")
        let manifest = try await store.export(to: badBackup)
        let corrupt = badBackup.appendingPathComponent(manifest.assets[0].relativePath)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: corrupt.path)
        try Data("corrupted".utf8).write(to: corrupt)
        let recipient = try AssetLibraryStore(root: evidence.appendingPathComponent("bad-restore"), contractRoot: contract); try await recipient.start()
        do { try await recipient.restore(from: badBackup); throw LibraryError.message("corruption accepted") }
        catch { try check(error.localizedDescription != "corruption accepted", "corrupt backup refused before import") }
        try check(try await recipient.query(LibraryQuery()).total == 0, "failed restore leaves database empty")
        let snapshots = try await store.snapshots()
        try await store.restoreSnapshot(snapshots.first!)
        try check(try await store.query(LibraryQuery()).total == 0 && FileManager.default.fileExists(atPath: root.appendingPathComponent(asset.relativePath).path), "snapshot restore preserves orphan original")
        try check(try await store.recoverOrphans() == 1, "orphan recovery after database restore")
        let pendingRoot = evidence.appendingPathComponent("pending"), pending = pendingRoot.appendingPathComponent("capture")
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        try AssetPendingCapture(folder: nil, files: ["capture.txt"]).write(to: pending)
        do { _ = try await AssetPendingCapture.retry(root: pendingRoot, store: recipient); throw LibraryError.message("missing pending accepted") }
        catch { try check(error.localizedDescription != "missing pending accepted" && FileManager.default.fileExists(atPath: pending.path), "failed pending retry preserves capture") }
        try Data("completed capture".utf8).write(to: pending.appendingPathComponent("capture.txt"))
        try check(try await AssetPendingCapture.retry(root: pendingRoot, store: recipient) == 1, "pending retry imports completed capture")
        let preferences = try JSONDecoder().decode(AssetCapturePreferences.self, from: Data("{}".utf8))
        try check(preferences.screenshotToastSeconds == 5 && preferences.systemAudio && preferences.microphone, "old capture settings keep default values")
        let broken = evidence.appendingPathComponent("broken-library")
        try FileManager.default.createDirectory(at: broken.appendingPathComponent("snapshots"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: broken.appendingPathComponent("originals"), withIntermediateDirectories: true)
        let snapshot = broken.appendingPathComponent("snapshots/recovery.sqlite")
        try FileManager.default.copyItem(at: root.appendingPathComponent("snapshots/" + snapshots.first!), to: snapshot)
        let damaged = Data("broken database fixture".utf8)
        try damaged.write(to: broken.appendingPathComponent("library.sqlite"))
        try Data().write(to: broken.appendingPathComponent("writer.lock"))
        try FileManager.default.copyItem(at: root.appendingPathComponent(asset.relativePath), to: broken.appendingPathComponent(asset.relativePath))
        try AssetLibraryStore.recoverBrokenDatabase(root: broken, snapshot: snapshot)
        let repaired = try AssetLibraryStore(root: broken, contractRoot: contract); try await repaired.start()
        try check(try await repaired.recoverOrphans() == 1, "broken database recovery preserves original")
        let preserved = try FileManager.default.contentsOfDirectory(at: broken, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("before-recovery-") }!
        try check(try Data(contentsOf: preserved.appendingPathComponent("library.sqlite")) == damaged, "broken database retained byte for byte")
        let purgeDB = try LibraryDatabase(root.appendingPathComponent("library.sqlite"))
        try purgeDB.execute("INSERT INTO purges VALUES(?,?,0)", [id, LibraryFormat.now()])
        try await store.start()
        let purgeNotice = await store.notice
        try check(try await store.get(id) != nil && purgeNotice?.contains("移動確認待ち 1件") == true,
                  "uncertain trash movement preserves record and explains recovery")
        try FileManager.default.trashItem(at: root.appendingPathComponent(asset.relativePath), resultingItemURL: nil)
        try purgeDB.execute("UPDATE purges SET recycled=1 WHERE id=?", [id])
        try await store.start()
        try check(try await store.get(id) == nil && purgeDB.scalar("SELECT count(*) FROM purges") == "0",
                  "completed trash journal recovers after interrupted database cleanup")
        let rowRoot = evidence.appendingPathComponent("row-codec-library")
        let rowStore = try AssetLibraryStore(root: rowRoot, contractRoot: contract)
        let rowImport = try await rowStore.importFile(input)
        let rowAsset = try await rowStore.get(rowImport.assetId!)!
        let rowDB = try LibraryDatabase(rowRoot.appendingPathComponent("library.sqlite"))
        try rowDB.execute("UPDATE assets SET size='invalid' WHERE id=?", [rowAsset.id])
        do {
            _ = try await rowStore.query(LibraryQuery())
            throw LibraryError.message("invalid database row accepted")
        } catch {
            try check(error.localizedDescription.contains("DB情報") &&
                      (try AssetLibraryStore.hash(rowRoot.appendingPathComponent(rowAsset.relativePath))) == rowAsset.sha256,
                      "malformed database row reports an error and preserves original")
        }
        return checks
    }
}
