import Foundation

/// Only registrations in the signed Host and its bundled package directories establish standard ownership.
enum PocketAppOwnership {
    static let standardPackageIDs: Set<String> = {
        guard let root = Bundle.hoverPocketResources.resourceURL?.appendingPathComponent("PocketApps"),
              let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        return Set(entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }.map(\.lastPathComponent))
    }()

    static func isStandard(_ id: String) -> Bool {
        standardPackageIDs.contains(id) || ProviderRegistry.builtIn.manifests.contains { $0.id.rawValue == id }
            || id == PocketDraftProvider.pluginID.rawValue
    }
}
