import Darwin
import Foundation

enum ApplicationDataVerificationCommand {
    static func run() -> Never {
        let fileManager = FileManager.default
        let environment = ProcessInfo.processInfo.environment
        let requestedIsolation = environment[HoverPocketApplicationData.isolatedE2EFlag] == "1"
        let usesIsolation = HoverPocketApplicationData.usesIsolatedE2ERoot(environment: environment)
        let resolvedRoot = HoverPocketApplicationData.rootDirectory(
            fileManager: fileManager,
            environment: environment
        )
        var failures: [String] = []

#if DEBUG
        let expectedIsolation = requestedIsolation
#else
        let expectedIsolation = false
#endif

        if usesIsolation != expectedIsolation {
            failures.append("isolation-mode")
        }

        if usesIsolation {
            guard let configuredRoot = environment[HoverPocketApplicationData.isolatedRootKey] else {
                failures.append("configured-root")
                finish(failures: failures, requestedIsolation: requestedIsolation)
            }
            let expectedRoot = URL(fileURLWithPath: configuredRoot, isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            if resolvedRoot != expectedRoot {
                failures.append("isolated-root")
            }
        } else {
            let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? fileManager.homeDirectoryForCurrentUser
            let expectedRoot = applicationSupport.appendingPathComponent(
                "HoverPocket",
                isDirectory: true
            )
            if resolvedRoot.standardizedFileURL != expectedRoot.standardizedFileURL {
                failures.append("default-root")
            }
        }

        finish(failures: failures, requestedIsolation: requestedIsolation)
    }

    private static func finish(failures: [String], requestedIsolation: Bool) -> Never {
        print("application_data_verify=\(failures.isEmpty ? "ok" : "failed")")
        print("application_data_isolation_requested=\(requestedIsolation)")
        print("application_data_isolation_effective=\(HoverPocketApplicationData.usesIsolatedE2ERoot())")
#if DEBUG
        print("application_data_release_override_disabled=not-applicable")
#else
        print("application_data_release_override_disabled=true")
#endif
        if !failures.isEmpty {
            print("application_data_failures=\(failures.joined(separator: ","))")
        }
        Darwin.exit(failures.isEmpty ? 0 : 1)
    }
}
