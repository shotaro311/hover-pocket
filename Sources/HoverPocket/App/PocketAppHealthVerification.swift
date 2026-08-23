import Foundation

@MainActor
enum PocketAppHealthVerification {
    static func verify(failures: inout [String]) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hover-pocket-health-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            let store = try PocketAppHealthStore(rootDirectory: root)
            let appID = "local.generated.health"
            let enabled = package(appID: appID, state: .enabled)
            let disabled = package(appID: appID, state: .disabled)
            let start = Date(timeIntervalSince1970: 1_787_536_800)

            try store.recordActivationSuccess(packageID: appID, now: start)
            var snapshot = store.snapshots(packages: [enabled], issues: [], now: start).first
            require(snapshot?.status == .healthy, "health_initial_healthy", failures: &failures)

            let unusedAt = start.addingTimeInterval(PocketAppHealthStore.unusedInterval + 1)
            snapshot = store.snapshots(packages: [enabled], issues: [], now: unusedAt).first
            require(
                snapshot?.status == .unused && snapshot?.disableSuggested == true,
                "health_unused_suggestion",
                failures: &failures
            )

            try store.recordUse(packageID: appID, now: unusedAt)
            snapshot = store.snapshots(packages: [enabled], issues: [], now: unusedAt).first
            require(
                snapshot?.status == .healthy && snapshot?.disableSuggested == false,
                "health_use_recovers",
                failures: &failures
            )

            for offset in 1...3 {
                try store.recordActivationFailure(
                    packageID: appID,
                    now: unusedAt.addingTimeInterval(TimeInterval(offset))
                )
            }
            snapshot = store.snapshots(
                packages: [enabled],
                issues: [],
                now: unusedAt.addingTimeInterval(3)
            ).first
            require(
                snapshot?.status == .attention
                    && snapshot?.reasonCode == "ACTIVATION_FAILURES"
                    && snapshot?.consecutiveActivationFailures == 3,
                "health_activation_failures",
                failures: &failures
            )

            let recoveredAt = unusedAt.addingTimeInterval(4)
            try store.recordActivationSuccess(packageID: appID, now: recoveredAt)
            snapshot = store.snapshots(packages: [enabled], issues: [], now: recoveredAt).first
            require(
                snapshot?.status == .healthy && snapshot?.consecutiveActivationFailures == 0,
                "health_activation_recovery",
                failures: &failures
            )
            snapshot = store.snapshots(packages: [disabled], issues: [], now: recoveredAt).first
            require(
                snapshot?.status == .disabled && snapshot?.disableSuggested == false,
                "health_disabled_no_suggestion",
                failures: &failures
            )

            try store.recordUse(packageID: appID, now: recoveredAt)
            let beforeSoak = try Data(contentsOf: root.appendingPathComponent("\(appID).json"))
            for index in 0..<512 {
                try store.recordUse(
                    packageID: appID,
                    now: recoveredAt.addingTimeInterval(TimeInterval(index) / 4)
                )
            }
            let afterSoak = try Data(contentsOf: root.appendingPathComponent("\(appID).json"))
            require(beforeSoak == afterSoak, "health_usage_debounce", failures: &failures)
            let remaining = try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            let onlyRecordIsRegular = try remaining.first?
                .resourceValues(forKeys: [.isRegularFileKey])
                .isRegularFile == true
            require(
                remaining.count == 1
                    && remaining.first?.lastPathComponent == "\(appID).json"
                    && onlyRecordIsRegular,
                "health_soak_atomic_cleanup",
                failures: &failures
            )

            let corruptID = "local.generated.corrupt"
            try Data("not-json".utf8).write(to: root.appendingPathComponent("\(corruptID).json"))
            snapshot = store.snapshots(
                packages: [package(appID: corruptID, state: .enabled)],
                issues: [],
                now: recoveredAt
            ).first
            require(
                snapshot?.status == .attention
                    && snapshot?.reasonCode == "HEALTH_METADATA_CORRUPT"
                    && snapshot?.disableSuggested == false,
                "health_corrupt_fail_safe",
                failures: &failures
            )

            let linkedID = "local.generated.linked"
            let linkedURL = root.appendingPathComponent("\(linkedID).json")
            try FileManager.default.createSymbolicLink(
                atPath: linkedURL.path,
                withDestinationPath: root.appendingPathComponent("\(corruptID).json").path
            )
            snapshot = store.snapshots(
                packages: [package(appID: linkedID, state: .enabled)],
                issues: [],
                now: recoveredAt
            ).first
            require(
                snapshot?.status == .attention && snapshot?.disableSuggested == false,
                "health_symlink_fail_safe",
                failures: &failures
            )
        } catch {
            failures.append("health_verification:\(error)")
        }
    }

    private static func package(
        appID: String,
        state: PocketAppLifecycleState
    ) -> PocketAppManagedPackage {
        PocketAppManagedPackage(
            packageID: appID,
            state: state,
            version: "1.0.0",
            packageDigest: "sha256:" + String(repeating: "a", count: 64),
            installedVersions: ["1.0.0"]
        )
    }

    private static func require(
        _ condition: Bool,
        _ label: String,
        failures: inout [String]
    ) {
        if !condition { failures.append(label) }
    }
}
