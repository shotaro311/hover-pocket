import Foundation

@MainActor
enum PocketAppRuntimeActivationVerification {
    static func verify(failures: inout [String]) {
        let appA = "local.generated.activation-a"
        let appB = "local.generated.activation-b"
        let appC = "local.generated.activation-c"
        let digest1 = "sha256:" + String(repeating: "1", count: 64)
        let digest2 = "sha256:" + String(repeating: "2", count: 64)
        let digest3 = "sha256:" + String(repeating: "3", count: 64)
        let permissions = ["sticky.read"]

        var managed: [String: PocketAppManagedPackage] = [:]
        var candidates: [String: PocketAppRuntimeActivationRegistry.Candidate] = [:]

        func candidate(
            appID: String,
            version: String,
            digest: String
        ) -> PocketAppRuntimeActivationRegistry.Candidate {
            PocketAppRuntimeActivationRegistry.Candidate(
                readback: PocketAppRuntimeReadback(
                    appID: appID,
                    version: version,
                    packageDigest: digest,
                    effectivePermissions: permissions
                ),
                runtimeHandle: NSObject(),
                activationLease: PocketAppActivationLease(),
                surfaceIDs: ["main"]
            )
        }

        func receipt(
            action: String,
            appID: String,
            version: String?,
            digest: String?,
            state: PocketAppLifecycleState
        ) -> PocketAppLifecycleReceipt {
            PocketAppLifecycleReceipt(
                action: action,
                packageID: appID,
                version: version,
                packageDigest: digest,
                effectivePermissions: state == .enabled ? permissions : [],
                state: state,
                readbackVerified: true,
                dataDisposition: state == .removed ? .preserve : nil
            )
        }

        func managedPackage(
            appID: String,
            version: String,
            digest: String,
            state: PocketAppLifecycleState
        ) -> PocketAppManagedPackage {
            PocketAppManagedPackage(
                packageID: appID,
                state: state,
                version: version,
                packageDigest: digest,
                installedVersions: ["1.0.0", "1.1.0"]
            )
        }

        let registry = PocketAppRuntimeActivationRegistry(
            managedPackagesSource: { Array(managed.values) },
            candidateSource: { candidates[$0] }
        )
        let cancellationLease = PocketAppActivationLease()
        var cancellationObserved = false
        _ = cancellationLease.registerCancellation { cancellationObserved = true }
        cancellationLease.invalidate()
        require(
            cancellationObserved && !cancellationLease.isActive,
            "activation_inflight_cancellation",
            failures: &failures
        )
        require(
            PocketSurfaceRegistry.generatedProviderID(appID: appA).hasPrefix("generated-pocket-app:")
                && PocketSurfaceRegistry.generatedSurfaceRouteID(appID: appA, surfaceID: "main")
                    .hasPrefix("generated-pocket-app:\(appA)/"),
            "activation_identity_namespace",
            failures: &failures
        )

        candidates[appA] = candidate(appID: appA, version: "1.0.0", digest: digest1)
        candidates[appB] = candidate(appID: appB, version: "1.0.0", digest: digest1)
        managed[appA] = managedPackage(appID: appA, version: "1.0.0", digest: digest1, state: .enabled)
        managed[appB] = managedPackage(appID: appB, version: "1.0.0", digest: digest1, state: .enabled)

        do {
            _ = try registry.synchronize(receipt(
                action: "install", appID: appA, version: "1.0.0", digest: digest1, state: .enabled
            ))
            _ = try registry.synchronize(receipt(
                action: "install", appID: appB, version: "1.0.0", digest: digest1, state: .enabled
            ))
            require(
                registry.executionRegistry.activeAppIDs == [appA, appB]
                    && registry.surfaceRegistry.activeAppIDs == [appA, appB],
                "activation_multiple_apps",
                failures: &failures
            )

            candidates[appA] = candidate(appID: appA, version: "1.1.0", digest: digest2)
            managed[appA] = managedPackage(appID: appA, version: "1.1.0", digest: digest2, state: .enabled)
            _ = try registry.synchronize(receipt(
                action: "update", appID: appA, version: "1.1.0", digest: digest2, state: .enabled
            ))
            require(
                registry.executionRegistry.readback(appID: appA)?.packageDigest == digest2
                    && registry.executionRegistry.readback(appID: appB)?.packageDigest == digest1,
                "activation_update_isolated",
                failures: &failures
            )

            managed[appA] = managedPackage(appID: appA, version: "1.1.0", digest: digest2, state: .disabled)
            candidates.removeValue(forKey: appA)
            _ = try registry.synchronize(receipt(
                action: "disable", appID: appA, version: "1.1.0", digest: digest2, state: .disabled
            ))
            require(
                registry.executionRegistry.readback(appID: appA) == nil
                    && registry.surfaceRegistry.readback(appID: appA) == nil
                    && registry.executionRegistry.readback(appID: appB) != nil,
                "activation_disable",
                failures: &failures
            )

            candidates[appA] = candidate(appID: appA, version: "1.1.0", digest: digest2)
            managed[appA] = managedPackage(appID: appA, version: "1.1.0", digest: digest2, state: .enabled)
            _ = try registry.synchronize(receipt(
                action: "enable", appID: appA, version: "1.1.0", digest: digest2, state: .enabled
            ))
            require(
                registry.executionRegistry.readback(appID: appA)?.version == "1.1.0",
                "activation_enable",
                failures: &failures
            )

            let restarted = PocketAppRuntimeActivationRegistry(
                managedPackagesSource: { Array(managed.values) },
                candidateSource: { candidates[$0] }
            )
            let restartFailures = restarted.restoreEnabledApps()
            require(
                restartFailures.isEmpty
                    && restarted.executionRegistry.activeAppIDs == [appA, appB]
                    && restarted.surfaceRegistry.activeAppIDs == [appA, appB],
                "activation_restart_restore",
                failures: &failures
            )

            candidates[appA] = candidate(appID: appA, version: "1.0.0", digest: digest3)
            managed[appA] = managedPackage(appID: appA, version: "1.0.0", digest: digest3, state: .enabled)
            _ = try registry.synchronize(receipt(
                action: "rollback", appID: appA, version: "1.0.0", digest: digest3, state: .enabled
            ))
            require(
                registry.executionRegistry.readback(appID: appA)?.packageDigest == digest3
                    && registry.executionRegistry.readback(appID: appB)?.packageDigest == digest1,
                "activation_rollback",
                failures: &failures
            )

            managed.removeValue(forKey: appA)
            candidates.removeValue(forKey: appA)
            _ = try registry.synchronize(receipt(
                action: "remove", appID: appA, version: nil, digest: nil, state: .removed
            ))
            require(
                registry.executionRegistry.readback(appID: appA) == nil
                    && registry.surfaceRegistry.readback(appID: appA) == nil
                    && registry.executionRegistry.readback(appID: appB) != nil,
                "activation_remove",
                failures: &failures
            )

            candidates[appC] = candidate(appID: appC, version: "1.0.0", digest: digest1)
            managed[appC] = managedPackage(appID: appC, version: "1.0.0", digest: digest1, state: .enabled)
            do {
                _ = try registry.synchronize(receipt(
                    action: "install", appID: appC, version: "1.0.0", digest: digest2, state: .enabled
                ))
                failures.append("activation_mismatch_accepted")
            } catch PocketAppRuntimeActivationError.readbackMismatch {
            }
            require(
                registry.executionRegistry.readback(appID: appC) == nil
                    && registry.executionRegistry.readback(appID: appB) != nil,
                "activation_mismatch_fail_closed",
                failures: &failures
            )

            var injectFailure = false
            let failing = PocketAppRuntimeActivationRegistry(
                managedPackagesSource: { Array(managed.values) },
                candidateSource: { candidates[$0] },
                failureInjection: { point in
                    point == "before_runtime_registry_commit" && injectFailure
                }
            )
            _ = try failing.synchronize(receipt(
                action: "install", appID: appB, version: "1.0.0", digest: digest1, state: .enabled
            ))
            injectFailure = true
            do {
                _ = try failing.synchronize(receipt(
                    action: "install", appID: appC, version: "1.0.0", digest: digest1, state: .enabled
                ))
                failures.append("activation_failure_injection_accepted")
            } catch PocketAppRuntimeActivationError.unavailable {
            }
            require(
                failing.executionRegistry.readback(appID: appC) == nil
                    && failing.surfaceRegistry.readback(appID: appC) == nil
                    && failing.executionRegistry.readback(appID: appB) != nil,
                "activation_failure_injection_fail_closed",
                failures: &failures
            )
        } catch {
            failures.append("activation_verifier_unexpected_error")
        }
    }

    private static func require(
        _ condition: @autoclosure () -> Bool,
        _ name: String,
        failures: inout [String]
    ) {
        if !condition() {
            failures.append(name)
        }
    }
}
