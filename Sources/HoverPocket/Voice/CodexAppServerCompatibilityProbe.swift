import CryptoKit
import Darwin
import Foundation

struct CodexAppServerCompatibilityResult: Equatable, Sendable {
    let gate: VoiceAdapterGate
    let executableURL: URL?
    let version: String?
    let schemaDigest: String?
    let executableIdentity: String?
}

enum CodexAppServerSchemaContract {
    static let requiredMarkers = [
        "thread/realtime/start",
        "thread/realtime/listVoices",
        "thread/realtime/transcript/delta",
        "thread/realtime/sdp",
        "item/tool/call",
        "dynamicTools",
        "contentItems"
    ]

    static func gate(schemaText: String, threadStartSchema: Data) -> VoiceAdapterGate {
        guard requiredMarkers.allSatisfy(schemaText.contains) else {
            return .blocked("codex_realtime_schema_missing")
        }
        guard let object = try? JSONSerialization.jsonObject(with: threadStartSchema) as? [String: Any],
              let properties = object["properties"] as? [String: Any],
              let field = properties["dynamicToolsOnly"] as? [String: Any],
              field["type"] as? String == "boolean" else {
            return .blocked("codex_broker_only_tool_policy_missing")
        }
        return .ready
    }
}

actor CodexAppServerCompatibilityProbe {
    static let shared = CodexAppServerCompatibilityProbe()

    private struct ExecutableIdentity: Hashable {
        let path: String
        let size: UInt64
        let modificationTime: TimeInterval
        let fileIdentifier: UInt64
    }

    private var cache: [ExecutableIdentity: CodexAppServerCompatibilityResult] = [:]
    private var schemaProbeExecutions = 0

    func probe(explicitURL: URL? = nil) -> CodexAppServerCompatibilityResult {
        let executable: URL
        do {
            executable = try CodexExecutableResolver.resolve(explicitURL)
        } catch {
            return CodexAppServerCompatibilityResult(
                gate: .blocked("codex_not_found"),
                executableURL: nil,
                version: nil,
                schemaDigest: nil,
                executableIdentity: nil
            )
        }

        guard let executableIdentity = Self.identityToken(executable),
              let identity = Self.identity(executable) else {
            return CodexAppServerCompatibilityResult(
                gate: .blocked("codex_identity_unavailable"),
                executableURL: executable,
                version: nil,
                schemaDigest: nil,
                executableIdentity: nil
            )
        }
        if let cached = cache[identity] {
            return cached
        }
        guard let version = Self.readVersion(executable) else {
            return CodexAppServerCompatibilityResult(
                gate: .blocked("codex_version_probe_failed"),
                executableURL: executable,
                version: nil,
                schemaDigest: nil,
                executableIdentity: executableIdentity
            )
        }

        schemaProbeExecutions += 1
        let result = Self.generateAndValidateSchema(
            executable,
            version: version,
            executableIdentity: executableIdentity
        )
        cache[identity] = result
        if cache.count > 4 {
            cache = [identity: result]
        }
        return result
    }

    func resetCacheForVerification() {
        cache.removeAll()
        schemaProbeExecutions = 0
    }

    func schemaProbeExecutionCountForVerification() -> Int {
        schemaProbeExecutions
    }

    func isCurrent(_ result: CodexAppServerCompatibilityResult) -> Bool {
        guard let executableURL = result.executableURL,
              let expected = result.executableIdentity else { return false }
        return Self.identityToken(executableURL) == expected
    }

    nonisolated static func identityToken(_ executable: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: executable.path),
              let fileSize = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        let fileIdentifier = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let source = [
            executable.path,
            String(fileSize.uint64Value),
            String(modified.timeIntervalSince1970),
            String(fileIdentifier)
        ].joined(separator: "\n")
        return SHA256.hash(data: Data(source.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func identity(_ executable: URL) -> ExecutableIdentity? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: executable.path),
              let fileSize = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        let fileIdentifier = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        return ExecutableIdentity(
            path: executable.path,
            size: fileSize.uint64Value,
            modificationTime: modified.timeIntervalSince1970,
            fileIdentifier: fileIdentifier
        )
    }

    private static func readVersion(_ executable: URL) -> String? {
        let output = Pipe()
        guard runProcess(
            executable: executable,
            arguments: ["--version"],
            standardOutput: output,
            timeout: 5
        ) == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard data.count <= 4_096,
              let value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return String(value.prefix(160))
    }

    private static func generateAndValidateSchema(
        _ executable: URL,
        version: String,
        executableIdentity: String
    ) -> CodexAppServerCompatibilityResult {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "HoverPocketCodexSchema-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return blocked("codex_schema_directory_failed", executable, version, executableIdentity)
        }

        guard runProcess(
            executable: executable,
            arguments: [
                "app-server",
                "generate-json-schema",
                "--experimental",
                "--out",
                root.path
            ],
            standardOutput: FileHandle.nullDevice,
            timeout: 15
        ) == 0 else {
            return blocked("codex_schema_probe_failed", executable, version, executableIdentity)
        }

        let requiredFiles = [
            "ClientRequest.json",
            "ServerNotification.json",
            "ServerRequest.json",
            "DynamicToolCallParams.json",
            "DynamicToolCallResponse.json",
            "v2/ThreadStartParams.json"
        ]
        var combined = Data()
        var threadStartSchema = Data()
        for relativePath in requiredFiles {
            let url = root.appendingPathComponent(relativePath)
            guard let data = try? Data(contentsOf: url), data.count <= 12 * 1_024 * 1_024 else {
                return blocked("codex_schema_incomplete", executable, version, executableIdentity)
            }
            combined.append(data)
            if relativePath == "v2/ThreadStartParams.json" {
                threadStartSchema = data
            }
        }
        let schemaText = String(decoding: combined, as: UTF8.self)
        let digest = SHA256.hash(data: combined)
            .map { String(format: "%02x", $0) }
            .joined()
        let gate = CodexAppServerSchemaContract.gate(
            schemaText: schemaText,
            threadStartSchema: threadStartSchema
        )
        guard gate.isReady else {
            return CodexAppServerCompatibilityResult(
                gate: gate,
                executableURL: executable,
                version: version,
                schemaDigest: digest,
                executableIdentity: executableIdentity
            )
        }
        return CodexAppServerCompatibilityResult(
            gate: .ready,
            executableURL: executable,
            version: version,
            schemaDigest: digest,
            executableIdentity: executableIdentity
        )
    }

    private static func blocked(
        _ code: String,
        _ executable: URL,
        _ version: String,
        _ executableIdentity: String
    ) -> CodexAppServerCompatibilityResult {
        CodexAppServerCompatibilityResult(
            gate: .blocked(code),
            executableURL: executable,
            version: version,
            schemaDigest: nil,
            executableIdentity: executableIdentity
        )
    }

    private static func runProcess(
        executable: URL,
        arguments: [String],
        standardOutput: Any,
        timeout: TimeInterval
    ) -> Int32? {
        let process = Process()
        let terminated = DispatchSemaphore(value: 0)
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = standardOutput
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in terminated.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        guard terminated.wait(timeout: .now() + timeout) == .success else {
            if process.isRunning {
                process.terminate()
            }
            if terminated.wait(timeout: .now() + 0.5) == .timedOut,
               process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                _ = terminated.wait(timeout: .now() + 0.5)
            }
            return nil
        }
        return process.terminationStatus
    }
}
