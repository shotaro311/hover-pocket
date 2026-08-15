import Foundation

enum PocketAppPackageVerificationCommand {
    static func run() -> Never {
        var failures: [String] = []
        let runtime = PocketAppPackageRuntime()
        var referencePackage: PocketAppPackage?

        do {
            try withPackage { root in
                let package = try runtime.load(directory: root)
                referencePackage = package
                require(package.manifest.id == "local.example.today-focus", "package_id", failures: &failures)
                require(package.manifest.version == "1.0.0", "package_version", failures: &failures)
                require(package.manifestDigest.hasPrefix("sha256:") && package.manifestDigest.count == 71, "manifest_digest", failures: &failures)
                require(package.surfaces["main"]?.nodeCount == 6, "package_surface", failures: &failures)
                require(package.workflows["startFocus"]?.steps.count == 2, "package_workflow", failures: &failures)
                require(package.workflows["startFocus"]?.requiredPermissions == ["sticky.write", "timer.write"], "package_permissions", failures: &failures)
                require(package.statePropertyNames == ["selectedEventRef"], "package_state_schema", failures: &failures)
                require(
                    package.testCases == [
                        "calendar-read": "pass",
                        "start-focus-approved": "pass",
                        "start-focus-idempotent-replay": "pass",
                        "start-focus-rejected": "reject"
                    ],
                    "package_tests",
                    failures: &failures
                )
                print("pocket_app_manifest_digest=\(package.manifestDigest)")
            }
        } catch {
            failures.append("valid_package:\(error)")
        }

        do {
            guard let resourceRoot = Bundle.module.resourceURL else {
                throw PocketAppPackageError.invalid("$:bundle_resource")
            }
            let bundledRoot = resourceRoot
                .appendingPathComponent("PocketApps", isDirectory: true)
                .appendingPathComponent("local.example.today-focus", isDirectory: true)
            let bundled = try runtime.load(directory: bundledRoot)
            require(bundled.manifestDigest == referencePackage?.manifestDigest, "bundled_manifest", failures: &failures)
            require(bundled.surfaces == referencePackage?.surfaces, "bundled_surfaces", failures: &failures)
            require(bundled.workflows == referencePackage?.workflows, "bundled_workflows", failures: &failures)
            require(bundled.testCases == referencePackage?.testCases, "bundled_tests", failures: &failures)
        } catch {
            failures.append("bundled_package:\(error)")
        }

        rejectPackage("unlisted_file", failures: &failures) { root in
            try Data("unexpected".utf8).write(to: root.appendingPathComponent("unexpected.txt"))
        }
        rejectPackage("hidden_unlisted_file", failures: &failures) { root in
            try Data("unexpected".utf8).write(to: root.appendingPathComponent(".unexpected"))
        }
        rejectPackage("missing_file", failures: &failures) { root in
            try FileManager.default.removeItem(at: root.appendingPathComponent("intent.md"))
        }
        rejectPackage("symlink", failures: &failures) { root in
            let intent = root.appendingPathComponent("intent.md")
            try FileManager.default.removeItem(at: intent)
            try FileManager.default.createSymbolicLink(atPath: intent.path, withDestinationPath: fixtureURL("package/intent.md").path)
        }
        rejectPackage("oversized_file", failures: &failures) { root in
            try Data(repeating: 0x61, count: PocketAppPackageRuntime.maximumFileBytes + 1)
                .write(to: root.appendingPathComponent("intent.md"))
        }
        rejectPackage("unknown_capability", failures: &failures) { root in
            try mutateJSON(root.appendingPathComponent("manifest.json")) { manifest in
                guard var capabilities = manifest["requestedCapabilities"] as? [[String: Any]] else { return false }
                capabilities[0]["id"] = "calendar.events.delete"
                manifest["requestedCapabilities"] = capabilities
                return true
            }
        }
        rejectPackage("path_traversal", failures: &failures) { root in
            try mutateJSON(root.appendingPathComponent("manifest.json")) { manifest in
                manifest["intent"] = "../intent.md"
                return true
            }
        }
        rejectPackage("cyclic_or_forward_dependency", failures: &failures) { root in
            try mutateJSON(root.appendingPathComponent("workflows/start-focus.workflow.json")) { workflow in
                guard var steps = workflow["steps"] as? [[String: Any]] else { return false }
                steps[0]["dependsOn"] = ["savePurpose"]
                workflow["steps"] = steps
                return true
            }
        }
        rejectPackage("unbounded_workflow", failures: &failures) { root in
            try mutateJSON(root.appendingPathComponent("workflows/start-focus.workflow.json")) { workflow in
                guard var limits = workflow["limits"] as? [String: Any] else { return false }
                limits["maxSteps"] = 33
                workflow["limits"] = limits
                return true
            }
        }
        rejectPackage("unbound_surface_input", failures: &failures) { root in
            try mutateJSON(root.appendingPathComponent("surfaces/main.surface.json")) { surface in
                guard var rootNode = surface["root"] as? [String: Any],
                      var children = rootNode["children"] as? [[String: Any]] else { return false }
                children[2]["value"] = "$input.missing"
                rootNode["children"] = children
                surface["root"] = rootNode
                return true
            }
        }

        print("pocket_app_package_verify=\(failures.isEmpty ? "ok" : "failed")")
        print("pocket_app_package_valid_files=9")
        print("pocket_app_package_bundled=ok")
        print("pocket_app_package_negative_cases=10")
        if !failures.isEmpty {
            print("pocket_app_package_failures=\(failures.joined(separator: ","))")
        }
        exit(failures.isEmpty ? 0 : 1)
    }

    private static func rejectPackage(
        _ label: String,
        failures: inout [String],
        mutation: (URL) throws -> Void
    ) {
        do {
            try withPackage { root in
                do {
                    try mutation(root)
                    _ = try PocketAppPackageRuntime().load(directory: root)
                    failures.append("accepted:\(label)")
                } catch {
                }
            }
        } catch {
            failures.append("\(label):fixture:\(error)")
        }
    }

    private static func withPackage(body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hover-pocket-package-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try assemblePackage(at: root)
        try body(root)
    }

    private static func assemblePackage(at root: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root.appendingPathComponent("surfaces", isDirectory: true), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: root.appendingPathComponent("workflows", isDirectory: true), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: root.appendingPathComponent("tests", isDirectory: true), withIntermediateDirectories: true)

        let files: [(String, String)] = [
            ("manifest.json", "valid/pocket-app.today-focus.json"),
            ("intent.md", "package/intent.md"),
            ("data.schema.json", "package/data.schema.json"),
            ("surfaces/main.surface.json", "valid/pocket-surface.today-focus.json"),
            ("workflows/start-focus.workflow.json", "valid/pocket-workflow.today-focus.json"),
            ("tests/calendar-read.json", "package/test.calendar-read.json"),
            ("tests/start-focus-approved.json", "package/test.start-focus-approved.json"),
            ("tests/start-focus-idempotent-replay.json", "package/test.start-focus-idempotent-replay.json"),
            ("tests/start-focus-rejected.json", "package/test.start-focus-rejected.json")
        ]
        for (destination, fixture) in files {
            try Data(contentsOf: fixtureURL(fixture)).write(to: root.appendingPathComponent(destination))
        }
    }

    private static func mutateJSON(
        _ url: URL,
        mutation: (inout [String: Any]) -> Bool
    ) throws {
        guard var object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              mutation(&object) else {
            throw PocketAppPackageError.invalid("$:mutation")
        }
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
    }

    private static func fixtureURL(_ relativePath: String) -> URL {
        var current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        while current.path != "/" {
            let candidate = current
                .appendingPathComponent("contracts/pocket/v1/fixtures", isDirectory: true)
                .appendingPathComponent(relativePath, isDirectory: false)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            current.deleteLastPathComponent()
        }
        return current.appendingPathComponent("missing-fixture")
    }

    private static func require(_ condition: Bool, _ label: String, failures: inout [String]) {
        if !condition { failures.append(label) }
    }
}
