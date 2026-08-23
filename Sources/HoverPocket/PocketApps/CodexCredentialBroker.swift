import Darwin
import Foundation
import Security

enum CodexCredentialBrokerError: Error {
    case unavailable
}

enum CodexCredentialBrokerPeerIdentity {
    static func isAuthorizedPeer(socketFD: Int32, expectedProcessID: pid_t) -> Bool {
        guard expectedProcessID > 0 else { return false }
        var peerUserID: uid_t = 0
        var peerGroupID: gid_t = 0
        guard getpeereid(socketFD, &peerUserID, &peerGroupID) == 0,
              peerUserID == geteuid() else {
            return false
        }

        var peerProcessID: pid_t = 0
        var peerProcessIDSize = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(
            socketFD,
            SOL_LOCAL,
            LOCAL_PEERPID,
            &peerProcessID,
            &peerProcessIDSize
        ) == 0,
              peerProcessID > 0,
              peerProcessID == expectedProcessID,
              peerProcessIDSize == MemoryLayout<pid_t>.size else {
            return false
        }

        return hasSameDesignatedRequirement(processID: peerProcessID)
    }

    private static func hasSameDesignatedRequirement(processID: pid_t) -> Bool {
        var currentCode: SecCode?
        var peerCode: SecCode?
        let attributes = [kSecGuestAttributePid: NSNumber(value: processID)] as CFDictionary
        guard SecCodeCopySelf([], &currentCode) == errSecSuccess,
              let currentCode,
              SecCodeCopyGuestWithAttributes(nil, attributes, [], &peerCode) == errSecSuccess,
              let peerCode else {
            return false
        }

        var currentStaticCode: SecStaticCode?
        var requirement: SecRequirement?
        guard SecCodeCopyStaticCode(currentCode, [], &currentStaticCode) == errSecSuccess,
              let currentStaticCode,
              SecCodeCopyDesignatedRequirement(currentStaticCode, [], &requirement) == errSecSuccess,
              let requirement else {
            return false
        }

        return SecCodeCheckValidity(peerCode, [], requirement) == errSecSuccess
    }
}

final class CodexCredentialBrokerLease: @unchecked Sendable {
    private let lock = NSLock()
    private let expectedCapability: String
    private let expiresAt: Date
    private let secretProvider: @Sendable () throws -> String
    private var consumed = false

    let capability: String

    init(
        lifetime: TimeInterval = 30,
        now: Date = Date(),
        secretProvider: @escaping @Sendable () throws -> String
    ) throws {
        guard lifetime > 0, lifetime <= 60 else {
            throw CodexCredentialBrokerError.unavailable
        }
        let capability = try Self.randomCapability()
        self.capability = capability
        self.expectedCapability = capability
        self.expiresAt = now.addingTimeInterval(lifetime)
        self.secretProvider = secretProvider
    }

    init(
        capability: String,
        expiresAt: Date,
        secretProvider: @escaping @Sendable () throws -> String
    ) throws {
        guard Self.isValidCapability(capability) else {
            throw CodexCredentialBrokerError.unavailable
        }
        self.capability = capability
        self.expectedCapability = capability
        self.expiresAt = expiresAt
        self.secretProvider = secretProvider
    }

    func redeem(_ presentedCapability: String, now: Date = Date()) throws -> String {
        let provider: @Sendable () throws -> String
        lock.lock()
        guard !consumed else {
            lock.unlock()
            throw CodexCredentialBrokerError.unavailable
        }
        consumed = true
        guard now <= expiresAt,
              Self.constantTimeEqual(presentedCapability, expectedCapability) else {
            lock.unlock()
            throw CodexCredentialBrokerError.unavailable
        }
        provider = secretProvider
        lock.unlock()

        let secret = try provider()
        guard Self.isValidSecret(secret) else {
            throw CodexCredentialBrokerError.unavailable
        }
        return secret
    }

    func cancel() {
        lock.withLock {
            consumed = true
        }
    }

    var isConsumed: Bool {
        lock.withLock { consumed }
    }

    private static func randomCapability() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw CodexCredentialBrokerError.unavailable
        }
        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    fileprivate static func isValidCapability(_ value: String) -> Bool {
        value.utf8.count >= 32
            && value.utf8.count <= 128
            && value.utf8.allSatisfy {
                ($0 >= 48 && $0 <= 57)
                    || ($0 >= 65 && $0 <= 90)
                    || ($0 >= 97 && $0 <= 122)
                    || $0 == 45
                    || $0 == 95
            }
    }

    fileprivate static func isValidSecret(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 8_192
            && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        let count = max(left.count, right.count)
        var difference = left.count ^ right.count
        for index in 0..<count {
            let leftByte = index < left.count ? left[index] : 0
            let rightByte = index < right.count ? right[index] : 0
            difference |= Int(leftByte ^ rightByte)
        }
        return difference == 0
    }
}

private final class CodexCredentialBrokerCleanupState: @unchecked Sendable {
    private enum Stage {
        case pending
        case cleaning
        case finished
    }

    private let condition = NSCondition()
    private let socketFD: Int32
    private let endpointPath: String
    private let rootPath: String
    private var stage = Stage.pending

    init(socketFD: Int32, endpointPath: String, rootPath: String) {
        self.socketFD = socketFD
        self.endpointPath = endpointPath
        self.rootPath = rootPath
    }

    func perform() {
        condition.lock()
        guard stage == .pending else {
            condition.unlock()
            return
        }
        stage = .cleaning
        condition.unlock()

        close(socketFD)
        _ = unlink(endpointPath)
        _ = rmdir(rootPath)

        condition.lock()
        stage = .finished
        condition.broadcast()
        condition.unlock()
    }

    func waitUntilFinished() {
        condition.lock()
        while stage != .finished {
            condition.wait()
        }
        condition.unlock()
    }
}

final class CodexCredentialBrokerServer: @unchecked Sendable {
    private static let requestPrefix = "HP-CODEX-BROKER/1 "
    private let lifecycleCondition = NSCondition()
    private let queue = DispatchQueue(label: "local.hoverpocket.codex-credential-broker")
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let socketFD: Int32
    private let lease: CodexCredentialBrokerLease
    private let peerAuthorizer: @Sendable (Int32) -> Bool
    private let cleanupState: CodexCredentialBrokerCleanupState
    private var source: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var finishing = false

    let rootDirectory: URL
    let endpoint: URL
    var capability: String { lease.capability }
    var isConsumed: Bool { lease.isConsumed }

    init(
        lifetime: TimeInterval = 30,
        expectedClientProcessID: pid_t,
        peerAuthorizer: (@Sendable (Int32) -> Bool)? = nil,
        secretProvider: @escaping @Sendable () throws -> String
    ) throws {
        guard expectedClientProcessID > 0 else {
            throw CodexCredentialBrokerError.unavailable
        }
        self.peerAuthorizer = peerAuthorizer ?? { socketFD in
            CodexCredentialBrokerPeerIdentity.isAuthorizedPeer(
                socketFD: socketFD,
                expectedProcessID: expectedClientProcessID
            )
        }
        lease = try CodexCredentialBrokerLease(
            lifetime: lifetime,
            secretProvider: secretProvider
        )
        let identifier = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        let requestedRoot = URL(
            fileURLWithPath: "/tmp/hoverpocket-codex-broker-\(identifier)",
            isDirectory: true
        )
        let rootPath = requestedRoot.path
        guard mkdir(rootPath, S_IRWXU) == 0 else {
            throw CodexCredentialBrokerError.unavailable
        }
        rootDirectory = URL(fileURLWithPath: "/private\(rootPath)", isDirectory: true)
        endpoint = rootDirectory.appendingPathComponent("credential.sock")

        var rootStat = stat()
        guard lstat(rootDirectory.path, &rootStat) == 0,
              (rootStat.st_mode & S_IFMT) == S_IFDIR,
              (rootStat.st_mode & (S_IRWXG | S_IRWXO)) == 0,
              UInt32(rootStat.st_uid) == UInt32(geteuid()) else {
            _ = rmdir(rootDirectory.path)
            throw CodexCredentialBrokerError.unavailable
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            _ = rmdir(rootDirectory.path)
            throw CodexCredentialBrokerError.unavailable
        }
        socketFD = fd
        do {
            try Self.bind(fd: fd, path: endpoint.path)
            guard chmod(endpoint.path, S_IRUSR | S_IWUSR) == 0,
                  listen(fd, 1) == 0 else {
                throw CodexCredentialBrokerError.unavailable
            }
        } catch {
            close(fd)
            _ = unlink(endpoint.path)
            _ = rmdir(rootDirectory.path)
            throw error
        }

        cleanupState = CodexCredentialBrokerCleanupState(
            socketFD: fd,
            endpointPath: endpoint.path,
            rootPath: rootDirectory.path
        )
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        self.source = source
        queue.setSpecific(key: queueKey, value: 1)
        source.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        let cleanupState = self.cleanupState
        source.setCancelHandler {
            cleanupState.perform()
        }
        source.resume()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        self.timer = timer
        timer.schedule(deadline: .now() + lifetime)
        timer.setEventHandler { [weak self] in
            self?.cancel()
        }
        timer.resume()
    }

    deinit {
        cancel()
    }

    func cancel() {
        finish()
    }

    private func acceptConnection() {
        let clientFD = accept(socketFD, nil, nil)
        guard clientFD >= 0 else {
            finish()
            return
        }
        Self.applyTimeouts(to: clientFD)
        defer {
            close(clientFD)
            finish()
        }

        guard peerAuthorizer(clientFD) else {
            Self.writeLine("ERR", to: clientFD)
            lease.cancel()
            return
        }

        guard let request = Self.readLine(from: clientFD, maximumBytes: 512),
              request.hasPrefix(Self.requestPrefix) else {
            Self.writeLine("ERR", to: clientFD)
            lease.cancel()
            return
        }
        let presentedCapability = String(request.dropFirst(Self.requestPrefix.count))
        do {
            let secret = try lease.redeem(presentedCapability)
            let encoded = Data(secret.utf8).base64EncodedString()
            Self.writeLine("OK \(encoded)", to: clientFD)
        } catch {
            Self.writeLine("ERR", to: clientFD)
        }
    }

    private func finish() {
        lifecycleCondition.lock()
        if finishing {
            if DispatchQueue.getSpecific(key: queueKey) == 1 {
                lifecycleCondition.unlock()
                return
            }
            lifecycleCondition.unlock()
            cleanupState.waitUntilFinished()
            return
        }
        finishing = true
        let source = self.source
        self.source = nil
        let timer = self.timer
        self.timer = nil
        lifecycleCondition.unlock()

        lease.cancel()
        timer?.cancel()
        source?.cancel()
        if DispatchQueue.getSpecific(key: queueKey) == 1 {
            return
        }
        cleanupState.waitUntilFinished()
    }

    private static func bind(fd: Int32, path: String) throws {
        var existing = stat()
        guard lstat(path, &existing) != 0, errno == ENOENT else {
            throw CodexCredentialBrokerError.unavailable
        }
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let maximum = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < maximum else {
            throw CodexCredentialBrokerError.unavailable
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: maximum) {
                _ = strlcpy($0, path, maximum)
            }
        }
        let status = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard status == 0 else {
            throw CodexCredentialBrokerError.unavailable
        }
    }

    fileprivate static func connect(fd: Int32, path: String) throws {
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let maximum = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < maximum else {
            throw CodexCredentialBrokerError.unavailable
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: maximum) {
                _ = strlcpy($0, path, maximum)
            }
        }
        let status = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard status == 0 else {
            throw CodexCredentialBrokerError.unavailable
        }
    }

    fileprivate static func readLine(from fd: Int32, maximumBytes: Int) -> String? {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(min(maximumBytes, 512))
        while bytes.count < maximumBytes {
            var byte: UInt8 = 0
            let count = Darwin.read(fd, &byte, 1)
            guard count == 1 else { return nil }
            if byte == 10 {
                return String(data: Data(bytes), encoding: .utf8)
            }
            guard byte != 0, byte != 13 else { return nil }
            bytes.append(byte)
        }
        return nil
    }

    fileprivate static func writeLine(_ line: String, to fd: Int32) {
        let data = Data((line + "\n").utf8)
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let count = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
                guard count > 0 else { return }
                offset += count
            }
        }
    }

    fileprivate static func applyTimeouts(to fd: Int32) {
        var noSignal: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }
}

enum CodexCredentialBrokerDeinitProbe {
    static let argument = "--verify-codex-credential-broker-deinit"

    static func run() -> Int32 {
        do {
            var server: CodexCredentialBrokerServer? = try CodexCredentialBrokerServer(
                lifetime: 5,
                expectedClientProcessID: getpid()
            ) {
                "deinit-probe-secret"
            }
            guard let rootPath = server?.rootDirectory.path else { return 1 }
            server = nil
            return FileManager.default.fileExists(atPath: rootPath) ? 1 : 0
        } catch {
            return 1
        }
    }
}

enum CodexCredentialBrokerClient {
    static func fetchSecret(
        endpoint: URL,
        capability: String,
        expectedServerProcessID: pid_t
    ) throws -> String {
        guard endpoint.isFileURL,
              endpoint.path.hasPrefix("/private/tmp/hoverpocket-codex-broker-"),
              CodexCredentialBrokerLease.isValidCapability(capability),
              expectedServerProcessID > 0 else {
            throw CodexCredentialBrokerError.unavailable
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw CodexCredentialBrokerError.unavailable
        }
        defer { close(fd) }
        CodexCredentialBrokerServer.applyTimeouts(to: fd)
        try CodexCredentialBrokerServer.connect(fd: fd, path: endpoint.path)
        guard CodexCredentialBrokerPeerIdentity.isAuthorizedPeer(
            socketFD: fd,
            expectedProcessID: expectedServerProcessID
        ) else {
            throw CodexCredentialBrokerError.unavailable
        }
        CodexCredentialBrokerServer.writeLine("HP-CODEX-BROKER/1 \(capability)", to: fd)
        guard let response = CodexCredentialBrokerServer.readLine(from: fd, maximumBytes: 12_000),
              response.hasPrefix("OK "),
              let data = Data(base64Encoded: String(response.dropFirst(3))),
              let secret = String(data: data, encoding: .utf8),
              !secret.isEmpty,
              secret.utf8.count <= 8_192,
              secret.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw CodexCredentialBrokerError.unavailable
        }
        return secret
    }
}

enum CodexCredentialBrokerHelper {
    static let argument = "--codex-credential-helper"

    private struct Bootstrap: Codable {
        let version: Int
        let endpoint: String
        let capability: String
        let serverProcessID: Int32
    }

    static func makeBootstrapData(
        endpoint: URL,
        capability: String,
        serverProcessID: pid_t
    ) throws -> Data {
        guard endpoint.isFileURL,
              CodexCredentialBrokerLease.isValidCapability(capability),
              serverProcessID > 0 else {
            throw CodexCredentialBrokerError.unavailable
        }
        let bootstrap = Bootstrap(
            version: 1,
            endpoint: endpoint.path,
            capability: capability,
            serverProcessID: serverProcessID
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(bootstrap)
        guard data.count <= 2_047 else {
            throw CodexCredentialBrokerError.unavailable
        }
        data.append(10)
        return data
    }

    static func run(input: FileHandle = .standardInput) -> Int32 {
        guard let line = CodexCredentialBrokerServer.readLine(
            from: input.fileDescriptor,
            maximumBytes: 2_048
        ),
              let data = line.data(using: .utf8),
              let bootstrap = try? JSONDecoder().decode(Bootstrap.self, from: data),
              bootstrap.version == 1,
              bootstrap.serverProcessID > 0 else {
            return 1
        }
        do {
            let secret = try CodexCredentialBrokerClient.fetchSecret(
                endpoint: URL(fileURLWithPath: bootstrap.endpoint),
                capability: bootstrap.capability,
                expectedServerProcessID: bootstrap.serverProcessID
            )
            try FileHandle.standardOutput.write(contentsOf: Data(secret.utf8))
            return 0
        } catch {
            try? FileHandle.standardError.write(contentsOf: Data("credential unavailable\n".utf8))
            return 1
        }
    }
}
