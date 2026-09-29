import Darwin
import Foundation

@MainActor
enum PocketToolDataLock {
    private static var held: Set<String> = []

    static func withLock<T>(rootDirectory: URL, packageID: String, _ body: () throws -> T) throws -> T {
        guard packageID.count <= 160,
              packageID.range(of: "^[a-z][a-z0-9]*(?:\\.[a-z0-9][a-z0-9-]*){2,}$", options: .regularExpression) != nil else {
            throw PocketCollectionError.invalidSchema
        }
        let root = try PocketAppPinnedDirectory(url: rootDirectory)
        let identity = root.url.path + "/" + packageID
        // Host activation reads the just-migrated data synchronously on the same actor.
        if held.contains(identity) { return try body() }
        return try root.withValidatedDescriptor { descriptor in
            let lock = openat(descriptor, "." + packageID + ".lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
            guard lock >= 0 else { throw PocketCollectionError.persistenceFailed }
            defer { close(lock) }
            var metadata = stat()
            guard fstat(lock, &metadata) == 0, metadata.st_nlink == 1, (metadata.st_mode & S_IFMT) == S_IFREG,
                  flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw PocketCollectionError.revisionConflict }
            held.insert(identity)
            defer { held.remove(identity); _ = flock(lock, LOCK_UN) }
            return try body()
        }
    }
}
