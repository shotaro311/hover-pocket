import Darwin
import Foundation

struct PocketAppFileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let size: Int
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
}

struct PocketAppFileSnapshot: Sendable {
    let rootDirectory: URL
    let files: [String: Data]
    let identities: [String: PocketAppFileIdentity]

    static func capture(directory: URL) throws -> PocketAppFileSnapshot {
        let root = directory.standardizedFileURL
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw PocketAppPackageError.invalid("$:package_root") }
        defer { close(rootFD) }

        var rootBefore = stat()
        guard fstat(rootFD, &rootBefore) == 0, (rootBefore.st_mode & S_IFMT) == S_IFDIR else {
            throw PocketAppPackageError.invalid("$:package_root")
        }
        let paths = try inventory(root: root)
        var files: [String: Data] = [:]
        var identities: [String: PocketAppFileIdentity] = [:]
        var total = 0
        for path in paths.sorted() {
            let captured = try readStable(relativePath: path, rootFD: rootFD)
            guard captured.data.count <= PocketAppPackageRuntime.maximumFileBytes else {
                throw PocketAppPackageError.invalid("$:package_file_size")
            }
            total += captured.data.count
            guard files.count < PocketAppPackageRuntime.maximumFiles,
                  total <= PocketAppPackageRuntime.maximumPackageBytes else {
                throw PocketAppPackageError.invalid("$:package_size")
            }
            files[path] = captured.data
            identities[path] = captured.identity
        }

        let afterPaths = try inventory(root: root)
        guard paths == afterPaths else { throw PocketAppPackageError.invalid("$:package_changed") }
        for path in paths {
            let current = try stableIdentity(relativePath: path, rootFD: rootFD)
            guard current == identities[path] else { throw PocketAppPackageError.invalid("$:package_changed") }
        }
        var rootAfter = stat()
        guard fstat(rootFD, &rootAfter) == 0,
              rootBefore.st_dev == rootAfter.st_dev,
              rootBefore.st_ino == rootAfter.st_ino else {
            throw PocketAppPackageError.invalid("$:package_changed")
        }
        return PocketAppFileSnapshot(rootDirectory: root, files: files, identities: identities)
    }

    static func readFileNoFollow(
        rootDirectory: URL,
        relativePath: String,
        maximumBytes: Int
    ) throws -> Data {
        let root = rootDirectory.standardizedFileURL
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw PocketAppPackageError.invalid("$:host_root") }
        defer { close(rootFD) }
        let fd = try openStable(relativePath: relativePath, rootFD: rootFD)
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG,
              before.st_size >= 0, before.st_size <= off_t(maximumBytes) else {
            throw PocketAppPackageError.invalid("$:host_file")
        }
        let first = try readAll(fd: fd, size: Int(before.st_size))
        let second = try readAll(fd: fd, size: Int(before.st_size))
        var after = stat()
        guard fstat(fd, &after) == 0, identity(before) == identity(after), first == second else {
            throw PocketAppPackageError.invalid("$:host_file_changed")
        }
        return first
    }

    func materialize(at directory: URL) throws {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: directory.path) else {
            throw PocketAppPackageError.invalid("$:materialize_exists")
        }
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            var madeDirectories: Set<String> = []
            for path in files.keys.sorted() {
                let components = path.split(separator: "/").map(String.init)
                var relativeDirectory = ""
                for component in components.dropLast() {
                    relativeDirectory = relativeDirectory.isEmpty ? component : "\(relativeDirectory)/\(component)"
                    if madeDirectories.insert(relativeDirectory).inserted {
                        let url = directory.appendingPathComponent(relativeDirectory, isDirectory: true)
                        try fileManager.createDirectory(
                            at: url,
                            withIntermediateDirectories: false,
                            attributes: [.posixPermissions: 0o700]
                        )
                    }
                }
                guard let data = files[path] else { throw PocketAppPackageError.invalid("$:materialize") }
                let target = directory.appendingPathComponent(path, isDirectory: false)
                try data.write(to: target, options: [.withoutOverwriting])
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            }
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    private static func inventory(root: URL) throws -> Set<String> {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else {
            throw PocketAppPackageError.invalid("$:package_inventory")
        }
        var paths: Set<String> = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true else {
                enumerator.skipDescendants()
                throw PocketAppPackageError.invalid("$:package_symlink")
            }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else { throw PocketAppPackageError.invalid("$:package_file") }
            let relative = String(url.standardizedFileURL.path.dropFirst(root.path.count + 1))
            guard safeRelativePath(relative), paths.insert(relative).inserted else {
                throw PocketAppPackageError.invalid("$:package_path")
            }
            guard paths.count <= PocketAppPackageRuntime.maximumFiles else {
                throw PocketAppPackageError.invalid("$:package_size")
            }
        }
        return paths
    }

    private static func readStable(
        relativePath: String,
        rootFD: Int32
    ) throws -> (data: Data, identity: PocketAppFileIdentity) {
        let fd = try openStable(relativePath: relativePath, rootFD: rootFD)
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG,
              before.st_size >= 0, before.st_size <= off_t(PocketAppPackageRuntime.maximumFileBytes) else {
            throw PocketAppPackageError.invalid("$:package_file")
        }
        let size = Int(before.st_size)
        let first = try readAll(fd: fd, size: size)
        let second = try readAll(fd: fd, size: size)
        var after = stat()
        guard first == second, fstat(fd, &after) == 0 else {
            throw PocketAppPackageError.invalid("$:package_changed")
        }
        let beforeIdentity = identity(before)
        let afterIdentity = identity(after)
        guard beforeIdentity == afterIdentity, first.count == beforeIdentity.size else {
            throw PocketAppPackageError.invalid("$:package_changed")
        }
        return (first, beforeIdentity)
    }

    private static func stableIdentity(relativePath: String, rootFD: Int32) throws -> PocketAppFileIdentity {
        let fd = try openStable(relativePath: relativePath, rootFD: rootFD)
        defer { close(fd) }
        var value = stat()
        guard fstat(fd, &value) == 0, (value.st_mode & S_IFMT) == S_IFREG else {
            throw PocketAppPackageError.invalid("$:package_file")
        }
        return identity(value)
    }

    private static func openStable(relativePath: String, rootFD: Int32) throws -> Int32 {
        guard safeRelativePath(relativePath) else { throw PocketAppPackageError.invalid("$:package_path") }
        let components = relativePath.split(separator: "/").map(String.init)
        guard let last = components.last else { throw PocketAppPackageError.invalid("$:package_path") }
        var directoryFD = dup(rootFD)
        guard directoryFD >= 0 else { throw PocketAppPackageError.invalid("$:package_open") }
        for component in components.dropLast() {
            let next = component.withCString {
                openat(directoryFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            close(directoryFD)
            guard next >= 0 else { throw PocketAppPackageError.invalid("$:package_symlink") }
            directoryFD = next
        }
        let fileFD = last.withCString {
            openat(directoryFD, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        close(directoryFD)
        guard fileFD >= 0 else { throw PocketAppPackageError.invalid("$:package_open") }
        return fileFD
    }

    private static func readAll(fd: Int32, size: Int) throws -> Data {
        if size == 0 { return Data() }
        var data = Data(count: size)
        let readCount = data.withUnsafeMutableBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return -1 }
            var offset = 0
            while offset < size {
                let count = pread(fd, base.advanced(by: offset), size - offset, off_t(offset))
                if count <= 0 { return -1 }
                offset += count
            }
            return offset
        }
        guard readCount == size else { throw PocketAppPackageError.invalid("$:package_read") }
        return data
    }

    private static func identity(_ value: stat) -> PocketAppFileIdentity {
        PocketAppFileIdentity(
            device: UInt64(value.st_dev),
            inode: UInt64(value.st_ino),
            size: Int(value.st_size),
            modifiedSeconds: Int64(value.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec)
        )
    }

    private static func safeRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("/"), !value.contains("\\"), !value.contains("\0") else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        return value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { component in
            !component.isEmpty && component != "." && component != ".." && component.unicodeScalars.allSatisfy(allowed.contains)
        }
    }
}
