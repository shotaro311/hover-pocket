import Darwin
import CryptoKit
import Foundation

final class PocketAppPinnedDirectory: @unchecked Sendable {
    private struct Identity: Equatable {
        let device: UInt64
        let inode: UInt64
    }

    let url: URL
    private let descriptor: Int32
    private let identity: Identity

    init(url: URL) throws {
        let standardized = url.standardizedFileURL
        let opened: Int32
        do {
            opened = try Self.openAbsoluteDirectory(standardized, createMissing: true)
        } catch let error as PocketAppGenerationError {
            throw error
        } catch {
            throw PocketAppGenerationError.rootUnsafe
        }
        var value = stat()
        guard fstat(opened, &value) == 0, (value.st_mode & S_IFMT) == S_IFDIR else {
            close(opened)
            throw PocketAppGenerationError.rootUnsafe
        }
        self.url = standardized
        self.descriptor = opened
        self.identity = Identity(device: UInt64(value.st_dev), inode: UInt64(value.st_ino))
    }

    deinit {
        close(descriptor)
    }

    func validate() throws {
        var held = stat()
        guard fstat(descriptor, &held) == 0,
              Identity(device: UInt64(held.st_dev), inode: UInt64(held.st_ino)) == identity else {
            throw PocketAppGenerationError.rootUnsafe
        }
        let current = try Self.openAbsoluteDirectory(url, createMissing: false)
        defer { close(current) }
        var observed = stat()
        guard fstat(current, &observed) == 0,
              Identity(device: UInt64(observed.st_dev), inode: UInt64(observed.st_ino)) == identity else {
            throw PocketAppGenerationError.rootUnsafe
        }
    }

    private static func openAbsoluteDirectory(_ url: URL, createMissing: Bool) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/") else { throw PocketAppGenerationError.rootUnsafe }
        var current = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else { throw PocketAppGenerationError.rootUnsafe }
        for component in url.standardizedFileURL.pathComponents.dropFirst() {
            let next: Int32 = component.withCString { pointer in
                openat(current, pointer, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            if next >= 0 {
                close(current)
                current = next
                continue
            }
            guard createMissing, errno == ENOENT else {
                close(current)
                throw PocketAppGenerationError.rootUnsafe
            }
            let created = component.withCString { pointer in
                mkdirat(current, pointer, S_IRWXU)
            }
            guard created == 0 || errno == EEXIST else {
                close(current)
                throw PocketAppGenerationError.rootUnsafe
            }
            let opened: Int32 = component.withCString { pointer in
                openat(current, pointer, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard opened >= 0 else {
                close(current)
                throw PocketAppGenerationError.rootUnsafe
            }
            close(current)
            current = opened
        }
        return current
    }
}

final class CodexPocketAppGenerationAdapter: PocketAppGenerationAdapter, @unchecked Sendable {
    let allowsActivation = false
    private final class BoundedCollector: @unchecked Sendable {
        private let lock = NSLock()
        private let limit: Int
        private var storage = Data()
        private var exceeded = false

        init(limit: Int) {
            self.limit = limit
        }

        func append(_ data: Data) {
            guard !data.isEmpty else { return }
            lock.withLock {
                let remaining = max(0, limit - storage.count)
                if remaining > 0 {
                    storage.append(data.prefix(remaining))
                }
                if data.count > remaining { exceeded = true }
            }
        }

        var didExceedLimit: Bool { lock.withLock { exceeded } }
        var data: Data { lock.withLock { storage } }
    }

    private static let allowedEnvironmentKeys = [
        "HOME", "USER", "LOGNAME", "PATH", "TMPDIR", "LANG", "LC_ALL", "TERM"
    ]

    private let executableURL: URL
    private let executableIdentity: ExecutableIdentity
    private let workspaceRoot: PocketAppPinnedDirectory
    private let timeout: TimeInterval

    private struct ExecutableIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let owner: UInt32
        let mode: UInt16
        let digest: String
    }

    private static let supportedVersion = "codex-cli 0.145.0"
    private static let openAITeamID = "2DC432GLL2"

    init(executableURL: URL, workspaceRoot: URL, timeout: TimeInterval = 60) throws {
        guard executableURL.isFileURL,
              timeout >= 1,
              timeout <= 300 else {
            throw PocketAppGenerationError.generatorUnavailable
        }
        let verifiedURL = executableURL.standardizedFileURL
        let identity = try Self.verifyExecutable(verifiedURL)
        guard Self.supportsConfidentialGeneration else {
            throw PocketAppGenerationError.generatorUnavailable
        }
        self.executableURL = verifiedURL
        self.executableIdentity = identity
        self.workspaceRoot = try PocketAppPinnedDirectory(url: workspaceRoot)
        self.timeout = timeout
    }

    func generate(
        _ request: PocketAppGenerationRequest,
        cancellation: PocketAppGenerationCancellation
    ) throws -> PocketAppGenerationEnvelope {
        try request.validate()
        guard try Self.verifyExecutable(executableURL) == executableIdentity else {
            throw PocketAppGenerationError.generatorUnavailable
        }
        try workspaceRoot.validate()
        if cancellation.isCancelled { throw PocketAppGenerationError.generatorCancelled }

        let workspace = workspaceRoot.url
            .appendingPathComponent("codex-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer {
            try? FileManager.default.removeItem(at: workspace)
        }
        try workspaceRoot.validate()

        let schemaURL = workspace.appendingPathComponent("generation-output.schema.json")
        try Data(PocketAppGenerationContract.outputSchemaJSON.utf8).write(to: schemaURL, options: [.withoutOverwriting])
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: schemaURL.path)

        let process = Process()
        process.executableURL = executableURL
        process.currentDirectoryURL = workspace
        process.arguments = [
            "exec",
            "--sandbox", "read-only",
            "--ephemeral",
            "--ignore-user-config",
            "--skip-git-repo-check",
            "--output-schema", schemaURL.path,
            "-"
        ]
        let inherited = ProcessInfo.processInfo.environment
        process.environment = Dictionary(uniqueKeysWithValues: Self.allowedEnvironmentKeys.compactMap { key in
            inherited[key].map { (key, $0) }
        })

        let standardInput = Pipe()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = standardError

        let outputCollector = BoundedCollector(limit: PocketAppGenerationContract.maximumOutputBytes)
        let errorCollector = BoundedCollector(limit: PocketAppGenerationContract.maximumErrorBytes)
        standardOutput.fileHandleForReading.readabilityHandler = { handle in
            outputCollector.append(handle.availableData)
        }
        standardError.fileHandleForReading.readabilityHandler = { handle in
            errorCollector.append(handle.availableData)
        }
        defer {
            standardOutput.fileHandleForReading.readabilityHandler = nil
            standardError.fileHandleForReading.readabilityHandler = nil
        }

        do {
            try process.run()
            let pid = process.processIdentifier
            if setpgid(pid, pid) != 0, getpgid(pid) != pid {
                Self.stop(process)
                throw PocketAppGenerationError.generatorUnavailable
            }
        } catch {
            throw PocketAppGenerationError.generatorUnavailable
        }
        do {
            let prompt = try PocketAppGenerationContract.prompt(request)
            try standardInput.fileHandleForWriting.write(contentsOf: Data(prompt.utf8))
            try standardInput.fileHandleForWriting.close()
        } catch {
            Self.stop(process)
            throw PocketAppGenerationError.generatorFailed
        }

        let deadline = Date().addingTimeInterval(timeout)
        var terminalError: PocketAppGenerationError?
        while process.isRunning {
            if cancellation.isCancelled {
                terminalError = .generatorCancelled
                Self.stop(process)
                break
            }
            if outputCollector.didExceedLimit || errorCollector.didExceedLimit {
                terminalError = .outputLimitExceeded
                Self.stop(process)
                break
            }
            if Date() > deadline {
                terminalError = .generatorTimedOut
                Self.stop(process)
                break
            }
            Thread.sleep(forTimeInterval: 0.025)
        }
        process.waitUntilExit()
        standardOutput.fileHandleForReading.readabilityHandler = nil
        standardError.fileHandleForReading.readabilityHandler = nil
        outputCollector.append(standardOutput.fileHandleForReading.readDataToEndOfFile())
        errorCollector.append(standardError.fileHandleForReading.readDataToEndOfFile())

        if let terminalError { throw terminalError }
        if outputCollector.didExceedLimit || errorCollector.didExceedLimit {
            throw PocketAppGenerationError.outputLimitExceeded
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw PocketAppGenerationError.generatorFailed
        }
        try workspaceRoot.validate()
        return try PocketAppGenerationContract.decodeEnvelope(outputCollector.data)
    }

    static func stop(_ process: Process) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        if getpgid(pid) == pid {
            _ = kill(-pid, SIGTERM)
        } else {
            _ = kill(pid, SIGTERM)
        }
        let deadline = Date().addingTimeInterval(0.2)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            if getpgid(pid) == pid {
                _ = kill(-pid, SIGKILL)
            } else {
                _ = kill(pid, SIGKILL)
            }
        }
    }

    static func resolveExecutable() -> URL? {
        guard supportsConfidentialGeneration else { return nil }
        let fixed = [
            "/opt/homebrew/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex",
            "/opt/homebrew/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-x64/vendor/x86_64-apple-darwin/bin/codex",
            "/usr/local/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex",
            "/usr/local/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-x64/vendor/x86_64-apple-darwin/bin/codex"
        ]
        for path in fixed {
            let candidate = URL(fileURLWithPath: path)
            if (try? verifyExecutable(candidate)) != nil {
                return candidate
            }
        }
        return nil
    }

    // File-backed ChatGPT credentials are readable by the same Codex process that
    // executes model-requested tools. Until credentials can be brokered outside that
    // process and an OS sandbox outside-root canary passes, production generation is
    // intentionally unavailable. Fixture generation and package preview remain usable.
    static var supportsConfidentialGeneration: Bool { false }

    private static func verifyExecutable(_ url: URL) throws -> ExecutableIdentity {
        var link = stat()
        guard url.path.withCString({ lstat($0, &link) }) == 0,
              (link.st_mode & S_IFMT) == S_IFREG,
              (link.st_mode & (S_IWGRP | S_IWOTH)) == 0,
              UInt32(link.st_uid) == 0 || UInt32(link.st_uid) == UInt32(geteuid()),
              FileManager.default.isExecutableFile(atPath: url.path) else {
            throw PocketAppGenerationError.generatorUnavailable
        }
        let signature = try runTrustedTool(
            "/usr/bin/codesign",
            arguments: ["-dv", "--verbose=4", url.path],
            captureStandardError: true
        )
        guard signature.contains("TeamIdentifier=\(openAITeamID)"),
              signature.contains("Authority=Developer ID Application: OpenAI OpCo, LLC (\(openAITeamID))") else {
            throw PocketAppGenerationError.generatorUnavailable
        }
        _ = try runTrustedTool(
            "/usr/bin/codesign",
            arguments: ["--verify", "--strict", url.path],
            captureStandardError: true
        )
        let version = try runTrustedTool(url.path, arguments: ["--version"], captureStandardError: false)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard version == supportedVersion else {
            throw PocketAppGenerationError.generatorUnavailable
        }
        let bytes = try Data(contentsOf: url, options: [.mappedIfSafe])
        let digest = "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return ExecutableIdentity(
            device: UInt64(link.st_dev),
            inode: UInt64(link.st_ino),
            owner: UInt32(link.st_uid),
            mode: UInt16(link.st_mode & 0o7777),
            digest: digest
        )
    }

    private static func runTrustedTool(
        _ path: String,
        arguments: [String],
        captureStandardError: Bool
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C"]
        let pipe = Pipe()
        process.standardOutput = pipe
        if captureStandardError { process.standardError = pipe }
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw PocketAppGenerationError.generatorUnavailable
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw PocketAppGenerationError.generatorUnavailable
        }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
