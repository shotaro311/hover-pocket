import Darwin
import Foundation

enum CodexManagedLoginVerificationHelper {
    static let argument = "--verify-codex-managed-login-fake-app-server"
    static let modeEnvironmentKey = "HOVERPOCKET_MANAGED_LOGIN_FAKE_MODE"
    static let receiptEnvironmentKey = "HOVERPOCKET_MANAGED_LOGIN_FAKE_RECEIPT"

    private static let successMode = "success"
    private static let pendingMode = "pending"
    private static let loginID = "managed-login-verification"

    static func run() -> Int32 {
        let environment = ProcessInfo.processInfo.environment
        guard let mode = environment[modeEnvironmentKey],
              mode == successMode || mode == pendingMode,
              let receiptPath = environment[receiptEnvironmentKey],
              !receiptPath.isEmpty,
              let codexHomePath = environment["CODEX_HOME"],
              !codexHomePath.isEmpty else {
            return 2
        }
        let receiptURL = URL(fileURLWithPath: receiptPath)
        let authURL = URL(fileURLWithPath: codexHomePath, isDirectory: true)
            .appendingPathComponent("auth.json")
        guard validateFixture(
            codexHomeURL: authURL.deletingLastPathComponent(),
            receiptURL: receiptURL
        ), let receipt = ReceiptWriter(url: receiptURL) else {
            return 2
        }
        var loggedIn = FileManager.default.fileExists(atPath: authURL.path)
        guard receipt.append("process_started:\(getpid())") else { return 5 }

        let decoder = JSONDecoder()
        while let line = readLine() {
            guard let data = line.data(using: .utf8),
                  let message = try? decoder.decode(CodexJSONValue.self, from: data),
                  let object = message.objectValue,
                  let method = object["method"]?.stringValue else {
                guard receipt.append("malformed_input") else { return 5 }
                continue
            }
            guard let requestID = object["id"] else {
                continue
            }

            switch method {
            case "initialize":
                guard receipt.append("initialize") else { return 5 }
                guard writeResponse(id: requestID, result: .object([:])) else { return 3 }
            case "account/read":
                guard receipt.append(
                    loggedIn ? "account_read:chatgpt" : "account_read:signed_out"
                ) else { return 5 }
                let account: CodexJSONValue = loggedIn
                    ? .object(["type": .string("chatgpt")])
                    : .null
                guard writeResponse(
                    id: requestID,
                    result: .object([
                        "requiresOpenaiAuth": .bool(true),
                        "account": account
                    ])
                ) else { return 3 }
            case "account/login/start":
                guard let params = object["params"]?.objectValue,
                      params == CodexVoiceAccountLoginController.loginStartParameters else {
                    guard receipt.append("login_start:invalid") else { return 5 }
                    guard writeError(id: requestID, code: -32602) else { return 3 }
                    continue
                }
                guard receipt.append("login_start") else { return 5 }
                guard writeResponse(
                    id: requestID,
                    result: .object([
                        "type": .string("chatgpt"),
                        "loginId": .string(loginID),
                        "authUrl": .string("https://auth.openai.com/hoverpocket-verification")
                    ])
                ) else { return 3 }
                if mode == successMode {
                    do {
                        try Data("{\"auth_mode\":\"chatgpt\"}".utf8)
                            .write(to: authURL, options: .atomic)
                        guard chmod(authURL.path, 0o600) == 0 else { return 4 }
                    } catch {
                        return 4
                    }
                    loggedIn = true
                    guard receipt.append("credential_written") else { return 5 }
                    guard write(.object([
                        "method": .string("account/login/completed"),
                        "params": .object([
                            "loginId": .string(loginID),
                            "success": .bool(true)
                        ])
                    ])) else { return 3 }
                    guard receipt.append("login_completed") else { return 5 }
                }
            case "account/login/cancel":
                guard object["params"]?.objectValue
                    == CodexVoiceAccountLoginController.loginCancelParameters(
                        loginID: loginID
                    ) else {
                    guard receipt.append("login_cancel:invalid") else { return 5 }
                    guard writeError(id: requestID, code: -32602) else { return 3 }
                    continue
                }
                guard receipt.append("login_cancel") else { return 5 }
                guard writeResponse(id: requestID, result: .object([:])) else { return 3 }
            default:
                guard receipt.append("unexpected_request:\(method)") else { return 5 }
                guard writeError(id: requestID, code: -32601) else { return 3 }
            }
        }
        guard receipt.append("process_exit") else { return 5 }
        return 0
    }

    private static func writeResponse(
        id: CodexJSONValue,
        result: CodexJSONValue
    ) -> Bool {
        write(.object(["id": id, "result": result]))
    }

    private static func writeError(id: CodexJSONValue, code: Int64) -> Bool {
        write(.object([
            "id": id,
            "error": .object([
                "code": .integer(code),
                "message": .string("Managed login verification request rejected")
            ])
        ]))
    }

    private static func write(_ value: CodexJSONValue) -> Bool {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var data = try encoder.encode(value)
            data.append(0x0A)
            try FileHandle.standardOutput.write(contentsOf: data)
            return true
        } catch {
            return false
        }
    }

    private static func validateFixture(codexHomeURL: URL, receiptURL: URL) -> Bool {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory.standardizedFileURL
            .resolvingSymlinksInPath()
        let codexHome = codexHomeURL.standardizedFileURL.resolvingSymlinksInPath()
        let receipt = receiptURL.standardizedFileURL
        let fixture = codexHome.deletingLastPathComponent()
        let lifecycleRoot = fixture.deletingLastPathComponent()
        guard codexHome.lastPathComponent == "codex-home",
              receipt.deletingLastPathComponent() == fixture,
              receipt.lastPathComponent == "receipt.log",
              lifecycleRoot.deletingLastPathComponent() == temporaryRoot,
              lifecycleRoot.lastPathComponent.hasPrefix(
                "hoverpocket-managed-login-lifecycle-"
              ),
              isOwnedPrivateDirectory(lifecycleRoot),
              isOwnedPrivateDirectory(fixture),
              isOwnedPrivateDirectory(codexHome) else {
            return false
        }
        let authURL = codexHome.appendingPathComponent("auth.json")
        guard fileManager.fileExists(atPath: authURL.path) else { return true }
        var status = stat()
        guard lstat(authURL.path, &status) == 0 else { return false }
        return (status.st_mode & S_IFMT) == S_IFREG
            && status.st_uid == getuid()
            && (status.st_mode & 0o077) == 0
    }

    private static func isOwnedPrivateDirectory(_ url: URL) -> Bool {
        var status = stat()
        guard lstat(url.path, &status) == 0 else { return false }
        return (status.st_mode & S_IFMT) == S_IFDIR
            && status.st_uid == getuid()
            && (status.st_mode & 0o077) == 0
    }

    private final class ReceiptWriter {
        private let descriptor: Int32

        init?(url: URL) {
            let path = url.path
            let baseFlags = O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW
            var created = false
            var descriptor = Darwin.open(path, baseFlags)
            if descriptor == -1, errno == ENOENT {
                descriptor = Darwin.open(
                    path,
                    baseFlags | O_CREAT | O_EXCL,
                    mode_t(0o600)
                )
                created = descriptor >= 0
            }
            guard descriptor >= 0 else { return nil }

            if created, fchmod(descriptor, mode_t(0o600)) != 0 {
                Darwin.close(descriptor)
                return nil
            }
            var status = stat()
            guard fstat(descriptor, &status) == 0,
                  (status.st_mode & S_IFMT) == S_IFREG,
                  status.st_uid == getuid(),
                  (status.st_mode & 0o777) == 0o600,
                  status.st_nlink == 1 else {
                Darwin.close(descriptor)
                return nil
            }
            self.descriptor = descriptor
        }

        deinit {
            Darwin.close(descriptor)
        }

        func append(_ event: String) -> Bool {
            let data = Data("\(event)\n".utf8)
            let wroteAllBytes = data.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return false }
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(
                        descriptor,
                        baseAddress.advanced(by: offset),
                        bytes.count - offset
                    )
                    if written > 0 {
                        offset += written
                    } else if written == -1, errno == EINTR {
                        continue
                    } else {
                        return false
                    }
                }
                return true
            }
            return wroteAllBytes && fsync(descriptor) == 0
        }
    }
}
