import Foundation

enum HoverPocketApplicationData {
    static let isolatedE2EFlag = "HOVERPOCKET_ISOLATED_E2E"
    static let isolatedRootKey = "HOVERPOCKET_TEST_DATA_ROOT"

    static func rootDirectory(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
#if DEBUG
        if environment[isolatedE2EFlag] == "1" {
            guard let rawRoot = environment[isolatedRootKey], !rawRoot.isEmpty else {
                preconditionFailure("Isolated E2E mode requires HOVERPOCKET_TEST_DATA_ROOT.")
            }

            let root = URL(fileURLWithPath: rawRoot, isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            let temporaryRoot = fileManager.temporaryDirectory
                .standardizedFileURL
                .resolvingSymlinksInPath()
            let allowedPrefix = temporaryRoot.path.hasSuffix("/")
                ? temporaryRoot.path
                : temporaryRoot.path + "/"
            guard root.path.hasPrefix(allowedPrefix) else {
                preconditionFailure("Isolated E2E data must stay inside the system temporary directory.")
            }
            return root
        }
#endif

        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
        return applicationSupport.appendingPathComponent("HoverPocket", isDirectory: true)
    }

    static func directory(
        _ component: String,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        rootDirectory(fileManager: fileManager, environment: environment)
            .appendingPathComponent(component, isDirectory: true)
    }

    static func usesIsolatedE2ERoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
#if DEBUG
        environment[isolatedE2EFlag] == "1"
#else
        false
#endif
    }
}
