import CryptoKit
import Darwin
import Foundation

enum CodexVoiceAppServerProfileError: Error, Equatable, Sendable {
    case directoryInvalid
    case configurationWriteFailed
    case authSourceInvalid
    case authLinkInvalid
}

enum CodexVoiceAuthStorage: String, Equatable, Sendable {
    case disabled
    case linkedExternalFile
    case managedFile

    var allowsManagedLogin: Bool { self == .managedFile }
}

enum CodexVoiceAuthStoragePolicy: Equatable, Sendable {
    case disabled
    case managedOnly
    case externalOrManaged
}

struct CodexVoiceAppServerProfile: Equatable, Sendable {
    let codexHomeURL: URL
    let processEnvironment: [String: String]
    let identity: String
    let authStorage: CodexVoiceAuthStorage

    static func prepare(
        executableURL: URL,
        runtimeEnvironment: HoverPocketRuntimeEnvironment = .shared
    ) throws -> CodexVoiceAppServerProfile {
        let fileManager = FileManager.default
        let codexHome = runtimeEnvironment
            .storageDirectory("CodexVoiceAppServer")
            .appendingPathComponent("CodexHome", isDirectory: true)
            .standardizedFileURL
        try prepareOwnedDirectory(codexHome, fileManager: fileManager)

        let configuration = Data(configurationText.utf8)
        let configurationURL = codexHome.appendingPathComponent("config.toml")
        do {
            if (try? Data(contentsOf: configurationURL)) != configuration {
                try configuration.write(to: configurationURL, options: .atomic)
            }
            guard chmod(configurationURL.path, 0o600) == 0 else {
                throw CodexVoiceAppServerProfileError.configurationWriteFailed
            }
        } catch let error as CodexVoiceAppServerProfileError {
            throw error
        } catch {
            throw CodexVoiceAppServerProfileError.configurationWriteFailed
        }

        let authStoragePolicy: CodexVoiceAuthStoragePolicy
        if runtimeEnvironment.isIsolatedVoiceE2E {
            authStoragePolicy = .managedOnly
        } else if runtimeEnvironment.externalIntegrationsEnabled {
            authStoragePolicy = .externalOrManaged
        } else {
            authStoragePolicy = .disabled
        }
        let authStorage = try prepareAuthStorage(
            in: codexHome,
            sourceHome: sourceCodexHome(fileManager: fileManager),
            policy: authStoragePolicy,
            fileManager: fileManager
        )

        let inheritedPath = ProcessInfo.processInfo.environment["PATH"]
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        let home = runtimeEnvironment.externalIntegrationsEnabled
            ? fileManager.homeDirectoryForCurrentUser.standardizedFileURL.path
            : runtimeEnvironment.rootDirectory.standardizedFileURL.path
        let environment = [
            "CODEX_HOME": codexHome.path,
            "HOME": home,
            "PATH": inheritedPath,
            "TMPDIR": fileManager.temporaryDirectory.standardizedFileURL.path,
            "LANG": "C.UTF-8"
        ]
        var identityData = configuration
        identityData.append(Data(codexHome.path.utf8))
        identityData.append(Data(executableURL.standardizedFileURL.path.utf8))
        identityData.append(Data(inheritedPath.utf8))
        identityData.append(Data(authStorage.rawValue.utf8))
        let identity = SHA256.hash(data: identityData)
            .map { String(format: "%02x", $0) }
            .joined()
        return CodexVoiceAppServerProfile(
            codexHomeURL: codexHome,
            processEnvironment: environment,
            identity: identity,
            authStorage: authStorage
        )
    }

    var hasValidManagedCredentialFile: Bool {
        guard authStorage == .managedFile else { return false }
        let file = codexHomeURL.appendingPathComponent("auth.json")
        return Self.isRegularFile(file)
            && !Self.isSymbolicLink(file)
            && Self.isOwnedByCurrentUser(file)
            && Self.hasPrivatePermissions(file)
    }

    static let configurationText = """
    cli_auth_credentials_store = "file"
    approval_policy = "never"
    sandbox_mode = "read-only"
    web_search = "disabled"
    include_permissions_instructions = false
    include_apps_instructions = false
    include_collaboration_mode_instructions = false
    include_environment_context = false

    [skills]
    include_instructions = false

    [orchestrator.skills]
    enabled = false

    [orchestrator.mcp]
    enabled = false

    [tools.experimental_request_user_input]
    enabled = false

    [tools.update_plan]
    enabled = false

    [features]
    shell_tool = false
    view_image = false
    hooks = false
    request_permissions_tool = false
    standalone_web_search = false
    multi_agent = false
    multi_agent_v2 = false
    apps = false
    enable_mcp_apps = false
    tool_suggest = false
    recommended_plugins = false
    plugins = false
    executor_capability_discovery = false
    in_app_browser = false
    browser_use = false
    browser_use_full_cdp_access = false
    browser_use_external = false
    computer_use = false
    remote_plugin = false
    plugin_sharing = false
    image_generation = false
    skill_mcp_dependency_install = false
    skill_search = false
    goals = false
    current_time_reminder = false
    """

    private static func prepareOwnedDirectory(
        _ directory: URL,
        fileManager: FileManager
    ) throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue,
                  !isSymbolicLink(directory),
                  isOwnedByCurrentUser(directory) else {
                throw CodexVoiceAppServerProfileError.directoryInvalid
            }
        } else {
            do {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw CodexVoiceAppServerProfileError.directoryInvalid
            }
        }
        guard chmod(directory.path, 0o700) == 0 else {
            throw CodexVoiceAppServerProfileError.directoryInvalid
        }
    }

    static func prepareAuthStorage(
        in codexHome: URL,
        sourceHome: URL,
        policy: CodexVoiceAuthStoragePolicy,
        fileManager: FileManager
    ) throws -> CodexVoiceAuthStorage {
        let link = codexHome.appendingPathComponent("auth.json")
        guard policy != .disabled else {
            if isSymbolicLink(link) {
                try? fileManager.removeItem(at: link)
            }
            guard !fileManager.fileExists(atPath: link.path) else {
                throw CodexVoiceAppServerProfileError.authLinkInvalid
            }
            return .disabled
        }

        if fileManager.fileExists(atPath: link.path), !isSymbolicLink(link) {
            guard isRegularFile(link),
                  isOwnedByCurrentUser(link),
                  hasPrivatePermissions(link) else {
                throw CodexVoiceAppServerProfileError.authLinkInvalid
            }
            return .managedFile
        }

        if policy == .managedOnly {
            if isSymbolicLink(link) {
                try? fileManager.removeItem(at: link)
            }
            guard !isSymbolicLink(link),
                  !fileManager.fileExists(atPath: link.path) else {
                throw CodexVoiceAppServerProfileError.authLinkInvalid
            }
            return .managedFile
        }

        let source = sourceHome
            .appendingPathComponent("auth.json")
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard fileManager.fileExists(atPath: source.path) else {
            if isSymbolicLink(link) {
                try? fileManager.removeItem(at: link)
            }
            return .managedFile
        }
        guard isRegularFile(source),
              !isSymbolicLink(source),
              isOwnedByCurrentUser(source),
              hasPrivatePermissions(source) else {
            throw CodexVoiceAppServerProfileError.authSourceInvalid
        }

        if isSymbolicLink(link) {
            guard link.resolvingSymlinksInPath() == source else {
                throw CodexVoiceAppServerProfileError.authLinkInvalid
            }
            return .linkedExternalFile
        }
        guard !fileManager.fileExists(atPath: link.path) else {
            throw CodexVoiceAppServerProfileError.authLinkInvalid
        }
        do {
            try fileManager.createSymbolicLink(at: link, withDestinationURL: source)
        } catch {
            throw CodexVoiceAppServerProfileError.authLinkInvalid
        }
        guard isSymbolicLink(link), link.resolvingSymlinksInPath() == source else {
            throw CodexVoiceAppServerProfileError.authLinkInvalid
        }
        return .linkedExternalFile
    }

    private static func sourceCodexHome(fileManager: FileManager) -> URL {
        if let configured = ProcessInfo.processInfo.environment["CODEX_HOME"],
           !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
    }

    private static func fileStatus(_ url: URL) -> stat? {
        var value = stat()
        return lstat(url.path, &value) == 0 ? value : nil
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        guard let value = fileStatus(url) else { return false }
        return (value.st_mode & S_IFMT) == S_IFLNK
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        guard let value = fileStatus(url) else { return false }
        return (value.st_mode & S_IFMT) == S_IFREG
    }

    private static func isOwnedByCurrentUser(_ url: URL) -> Bool {
        fileStatus(url)?.st_uid == getuid()
    }

    private static func hasPrivatePermissions(_ url: URL) -> Bool {
        guard let value = fileStatus(url) else { return false }
        return value.st_mode & 0o077 == 0
    }
}

enum CodexVoiceThreadContract {
    static func startParameters(
        workspaceDirectory: URL,
        dynamicTools: [CodexJSONValue],
        ephemeral: Bool
    ) -> [String: CodexJSONValue] {
        var parameters: [String: CodexJSONValue] = [
            "cwd": .string(workspaceDirectory.standardizedFileURL.path),
            "sandbox": .string("read-only"),
            "approvalPolicy": .string("never"),
            "ephemeral": .bool(ephemeral),
            "environments": .array([]),
            "runtimeWorkspaceRoots": .array([]),
            "selectedCapabilityRoots": .array([]),
            "dynamicTools": .array(dynamicTools)
        ]
        if !ephemeral {
            parameters["approvalsReviewer"] = .string("user")
            parameters["threadSource"] = .string("hoverpocket_voice")
            parameters["sessionStartSource"] = .string("startup")
            parameters["baseInstructions"] = .string(
                "You are the HoverPocket Voice Lane. Only invoke explicitly provided "
                    + "HoverPocket capabilities. Keep spoken replies concise."
            )
        }
        return parameters
    }

    static func toolNames(_ tools: [CodexJSONValue]) -> Set<String>? {
        var names = Set<String>()
        for tool in tools {
            guard let object = tool.objectValue,
                  object["type"]?.stringValue == "function",
                  let name = object["name"]?.stringValue,
                  VoiceTextSafety.sanitizeIdentifier(name) == name,
                  names.insert(name).inserted else {
                return nil
            }
        }
        return names
    }
}
