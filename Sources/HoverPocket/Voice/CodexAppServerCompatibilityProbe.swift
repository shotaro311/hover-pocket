import CryptoKit
import Darwin
import Foundation

struct CodexAppServerCompatibilityResult: Equatable, Sendable {
    let gate: VoiceAdapterGate
    let executableURL: URL?
    let version: String?
    let schemaDigest: String?
    let executableIdentity: String?
    let appServerProfile: CodexVoiceAppServerProfile?
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
              [
                  "dynamicTools",
                  "environments",
                  "runtimeWorkspaceRoots",
                  "selectedCapabilityRoots"
              ].allSatisfy({ properties[$0] is [String: Any] }) else {
            return .blocked("codex_thread_tool_contract_missing")
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

    private struct CacheKey: Hashable {
        let executable: ExecutableIdentity
        let version: String
        let profileIdentity: String
        let toolDigest: String
    }

    private var cache: [CacheKey: CodexAppServerCompatibilityResult] = [:]
    private var schemaProbeExecutions = 0

    func probe(
        explicitURL: URL? = nil,
        dynamicTools: [CodexJSONValue] = CodexAppServerCompatibilityProbe.verificationTools
    ) async -> CodexAppServerCompatibilityResult {
        let candidates: [URL]
        do {
            candidates = try CodexExecutableResolver.candidates(explicitURL)
        } catch {
            return CodexAppServerCompatibilityResult(
                gate: .blocked("codex_not_found"),
                executableURL: nil,
                version: nil,
                schemaDigest: nil,
                executableIdentity: nil,
                appServerProfile: nil
            )
        }
        var firstBlocked: CodexAppServerCompatibilityResult?
        for executable in candidates {
            let result = await probeCandidate(executable, dynamicTools: dynamicTools)
            if result.gate.isReady {
                return result
            }
            if firstBlocked == nil {
                firstBlocked = result
            }
        }
        return firstBlocked ?? CodexAppServerCompatibilityResult(
            gate: .blocked("codex_not_found"),
            executableURL: nil,
            version: nil,
            schemaDigest: nil,
            executableIdentity: nil,
            appServerProfile: nil
        )
    }

    private func probeCandidate(
        _ executable: URL,
        dynamicTools: [CodexJSONValue]
    ) async -> CodexAppServerCompatibilityResult {
        guard let executableIdentity = Self.identityToken(executable),
              let identity = Self.identity(executable) else {
            return CodexAppServerCompatibilityResult(
                gate: .blocked("codex_identity_unavailable"),
                executableURL: executable,
                version: nil,
                schemaDigest: nil,
                executableIdentity: nil,
                appServerProfile: nil
            )
        }
        guard let version = Self.readVersion(executable) else {
            return CodexAppServerCompatibilityResult(
                gate: .blocked("codex_version_probe_failed"),
                executableURL: executable,
                version: nil,
                schemaDigest: nil,
                executableIdentity: executableIdentity,
                appServerProfile: nil
            )
        }

        let profile: CodexVoiceAppServerProfile
        do {
            profile = try CodexVoiceAppServerProfile.prepare(executableURL: executable)
        } catch {
            return CodexAppServerCompatibilityResult(
                gate: .blocked("codex_voice_profile_invalid"),
                executableURL: executable,
                version: version,
                schemaDigest: nil,
                executableIdentity: executableIdentity,
                appServerProfile: nil
            )
        }
        guard let toolDigest = Self.toolDigest(dynamicTools) else {
            return CodexAppServerCompatibilityResult(
                gate: .blocked("codex_dynamic_tools_invalid"),
                executableURL: executable,
                version: version,
                schemaDigest: nil,
                executableIdentity: executableIdentity,
                appServerProfile: profile
            )
        }
        let cacheKey = CacheKey(
            executable: identity,
            version: version,
            profileIdentity: profile.identity,
            toolDigest: toolDigest
        )
        if let cached = cache[cacheKey] {
            return cached
        }

        schemaProbeExecutions += 1
        var result = Self.generateAndValidateSchema(
            executable,
            version: version,
            executableIdentity: executableIdentity,
            profile: profile
        )
        if result.gate.isReady {
            do {
                try await CodexAppServerToolRouteProbe.run(
                    executableURL: executable,
                    profile: profile,
                    dynamicTools: dynamicTools
                )
            } catch CodexAppServerToolRouteProbeError.toolRouteMismatch {
                result = Self.blocked(
                    "codex_broker_only_tool_route_mismatch",
                    executable,
                    version,
                    executableIdentity,
                    schemaDigest: result.schemaDigest,
                    profile: profile
                )
            } catch let error as CodexAppServerToolRouteProbeError {
                result = Self.blocked(
                    Self.toolRouteProbeFailureCode(error),
                    executable,
                    version,
                    executableIdentity,
                    schemaDigest: result.schemaDigest,
                    profile: profile
                )
            } catch let error as CodexAppServerClientError {
                result = Self.blocked(
                    Self.clientFailureCode(error),
                    executable,
                    version,
                    executableIdentity,
                    schemaDigest: result.schemaDigest,
                    profile: profile
                )
            } catch is CodexAppServerRPCError {
                result = Self.blocked(
                    "codex_tool_route_probe_rpc_failed",
                    executable,
                    version,
                    executableIdentity,
                    schemaDigest: result.schemaDigest,
                    profile: profile
                )
            } catch {
                result = Self.blocked(
                    "codex_tool_route_probe_failed",
                    executable,
                    version,
                    executableIdentity,
                    schemaDigest: result.schemaDigest,
                    profile: profile
                )
            }
        }
        if Self.shouldCache(result) {
            cache[cacheKey] = result
            if cache.count > 4 {
                cache = [cacheKey: result]
            }
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
              let expectedIdentity = result.executableIdentity,
              let expectedVersion = result.version else { return false }
        return Self.identityToken(executableURL) == expectedIdentity
            && Self.readVersion(executableURL) == expectedVersion
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
        executableIdentity: String,
        profile: CodexVoiceAppServerProfile
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
            return blocked(
                "codex_schema_directory_failed",
                executable,
                version,
                executableIdentity,
                profile: profile
            )
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
            return blocked(
                "codex_schema_probe_failed",
                executable,
                version,
                executableIdentity,
                profile: profile
            )
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
                return blocked(
                    "codex_schema_incomplete",
                    executable,
                    version,
                    executableIdentity,
                    profile: profile
                )
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
                executableIdentity: executableIdentity,
                appServerProfile: profile
            )
        }
        return CodexAppServerCompatibilityResult(
            gate: .ready,
            executableURL: executable,
            version: version,
            schemaDigest: digest,
            executableIdentity: executableIdentity,
            appServerProfile: profile
        )
    }

    private static func blocked(
        _ code: String,
        _ executable: URL,
        _ version: String,
        _ executableIdentity: String,
        schemaDigest: String? = nil,
        profile: CodexVoiceAppServerProfile? = nil
    ) -> CodexAppServerCompatibilityResult {
        CodexAppServerCompatibilityResult(
            gate: .blocked(code),
            executableURL: executable,
            version: version,
            schemaDigest: schemaDigest,
            executableIdentity: executableIdentity,
            appServerProfile: profile
        )
    }

    private static func toolDigest(_ tools: [CodexJSONValue]) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(tools) else { return nil }
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func shouldCache(_ result: CodexAppServerCompatibilityResult) -> Bool {
        if result.gate.isReady {
            return true
        }
        guard let code = result.gate.safeErrorCode else { return false }
        return [
            "codex_realtime_schema_missing",
            "codex_thread_tool_contract_missing",
            "codex_broker_only_tool_route_mismatch"
        ].contains(code)
    }

    private static let verificationTools: [CodexJSONValue] = [
        .object([
            "type": .string("function"),
            "name": .string("hoverpocket_compatibility_read"),
            "description": .string("Verify the delegated HoverPocket tool route."),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([:]),
                "additionalProperties": .bool(false)
            ]),
            "deferLoading": .bool(false)
        ])
    ]

    private static func toolRouteProbeFailureCode(
        _ error: CodexAppServerToolRouteProbeError
    ) -> String {
        switch error {
        case .requestTimedOut:
            return "codex_tool_route_probe_timed_out"
        case .requestInvalid:
            return "codex_tool_route_probe_response_invalid"
        case .socketFailed, .bindFailed, .listenFailed, .missingPort:
            return "codex_tool_route_probe_loopback_failed"
        case .toolRouteMismatch:
            return "codex_broker_only_tool_route_mismatch"
        }
    }

    private static func clientFailureCode(_ error: CodexAppServerClientError) -> String {
        switch error {
        case .executableNotFound, .executableNotRunnable:
            return "codex_tool_route_probe_executable_invalid"
        case .launchFailed:
            return "codex_tool_route_probe_launch_failed"
        case .invalidMessage:
            return "codex_tool_route_probe_response_invalid"
        case .requestTimedOut:
            return "codex_tool_route_probe_timed_out"
        case .transportEnded:
            return "codex_tool_route_probe_transport_ended"
        case .closed:
            return "codex_tool_route_probe_closed"
        }
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
