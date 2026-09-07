import Foundation

/// Removes only tool-owned storage. Native providers and user-exported files are outside these roots.
@MainActor
struct PocketToolRemoval {
    let definitionRoot: URL
    let userDataRoot: URL
    let generationRoot: URL
    var moveToTrash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }

    func removeDataAndHistory(packageID: String) throws {
        guard packageID != "local.example.today-focus", packageID.count <= 160,
              packageID.range(of: "^[a-z][a-z0-9]*(?:\\.[a-z0-9][a-z0-9-]*){2,}$", options: .regularExpression) != nil else {
            throw PocketAppGenerationError.invalidRequest
        }
        let roots = try [definitionRoot, userDataRoot, generationRoot].map { try PocketAppPinnedDirectory(url: $0) }
        var targets = [userDataRoot.appendingPathComponent(packageID),
                       definitionRoot.appendingPathComponent("Health/" + packageID + ".json"),
                       definitionRoot.appendingPathComponent("BackupRestore/PriorData/" + packageID)]
        for directory in try children(definitionRoot.appendingPathComponent("DataMigrations")) {
            if try owner(directory, file: "journal.json", key: "packageID") == packageID { targets.append(directory) }
        }
        for directory in try children(generationRoot) where directory.lastPathComponent.hasPrefix("draft-") {
            if try owner(directory, file: "manifest.json", key: "id") == packageID { targets.append(directory) }
        }
        for directory in try children(definitionRoot.appendingPathComponent("MigrationDrafts")) {
            if try owner(directory.appendingPathComponent("package"), file: "manifest.json", key: "id") == packageID { targets.append(directory) }
        }
        targets.append(generationRoot.appendingPathComponent("History/" + packageID))
        // Keep the removed-app marker until all content is gone so a failed cleanup can be retried.
        targets.append(definitionRoot.appendingPathComponent("Apps/" + packageID))
        for target in targets { try validateTreeIfPresent(target) }
        for target in targets {
            for root in roots { try root.validate() }
            guard try exists(target) else { continue }
            try validateTreeIfPresent(target)
            try moveToTrash(target)
            guard try !exists(target) else { throw PocketAppGenerationError.rootUnsafe }
        }
        for target in targets where try exists(target) { throw PocketAppGenerationError.rootUnsafe }
    }

    private func exists(_ url: URL) throws -> Bool {
        do { _ = try FileManager.default.attributesOfItem(atPath: url.path); return true }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return false }
    }

    private func children(_ url: URL) throws -> [URL] {
        guard try exists(url) else { return [] }
        let root = try PocketAppPinnedDirectory(url: url)
        return try FileManager.default.contentsOfDirectory(at: root.url, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") }
    }

    private func owner(_ directory: URL, file: String, key: String) throws -> String? {
        guard try exists(directory) else { return nil }
        _ = try PocketAppPinnedDirectory(url: directory)
        guard try exists(directory.appendingPathComponent(file)) else { return nil }
        let data = try PocketAppFileSnapshot.readFileNoFollow(rootDirectory: directory, relativePath: file, maximumBytes: 1_024 * 1_024)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any])?[key] as? String
    }

    private func validateTreeIfPresent(_ url: URL) throws {
        guard try exists(url) else { return }
        // Validate every ancestor as well as descendants; a symlink must never redirect a deletion.
        _ = try PocketAppPinnedDirectory(url: url.deletingLastPathComponent())
        func validate(_ item: URL) throws -> Bool {
            let attributes = try FileManager.default.attributesOfItem(atPath: item.path)
            guard let type = attributes[.type] as? FileAttributeType,
                  type == .typeDirectory || type == .typeRegular,
                  type != .typeRegular || (attributes[.referenceCount] as? NSNumber)?.intValue == 1 else {
                throw PocketAppGenerationError.rootUnsafe
            }
            return type == .typeDirectory
        }
        if try validate(url) {
            guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else {
                throw PocketAppGenerationError.rootUnsafe
            }
            for case let item as URL in enumerator { _ = try validate(item) }
        }
    }
}
