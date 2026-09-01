import Foundation

enum MacOSVoiceE2EIsolationVerificationCommand {
    @MainActor
    static func run() -> Never {
        var failures: [String] = []
        let fileManager = FileManager.default
        let temporaryDirectory = URL(
            fileURLWithPath: NSTemporaryDirectory(),
            isDirectory: true
        ).standardizedFileURL.resolvingSymlinksInPath()
        let root = temporaryDirectory.appendingPathComponent(
            HoverPocketRuntimeEnvironment.voiceE2ERootPrefix + UUID().uuidString,
            isDirectory: true
        )

        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
            defer { try? fileManager.removeItem(at: root) }

            let metadata = HoverPocketBundleMetadata(
                bundleIdentifier: HoverPocketRuntimeEnvironment.voiceE2EBundleIdentifier,
                isVoiceE2EBuild: true,
                keychainServiceSuffix: "voice-e2e-verifier"
            )
            let arguments = [
                "HoverPocket",
                HoverPocketRuntimeEnvironment.voiceE2EFlag,
                HoverPocketRuntimeEnvironment.voiceE2ERootFlag,
                root.path
            ]
            let environment = try HoverPocketRuntimeEnvironment.resolveForBuild(
                arguments: arguments,
                bundleMetadata: metadata,
                debugBuild: true,
                temporaryDirectory: temporaryDirectory
            )
            check(environment.isIsolatedVoiceE2E, "debug_mode_not_isolated", &failures)
            check(!environment.externalIntegrationsEnabled, "external_integrations_enabled", &failures)
            check(environment.rootDirectory == root, "isolated_root_mismatch", &failures)
            check(
                environment.settingsDefaults is EphemeralAppSettingsDefaults,
                "settings_defaults_not_ephemeral",
                &failures
            )
            for component in [
                "CapabilityBroker",
                "CodexVoiceAppServer",
                "PocketApps",
                "StickyNotes",
                "Timer",
                "Clipboard"
            ] {
                check(
                    isDescendant(environment.storageDirectory(component), of: root),
                    "storage_path_escaped_\(component)",
                    &failures
                )
            }
            check(
                isDescendant(environment.voiceE2EReceiptURL, of: root),
                "receipt_path_escaped",
                &failures
            )
            check(
                isDescendant(environment.voiceE2EPerformanceReceiptURL, of: root),
                "performance_receipt_path_escaped",
                &failures
            )

            if let executableURL = Bundle.main.executableURL {
                let profile = try CodexVoiceAppServerProfile.prepare(
                    executableURL: executableURL,
                    runtimeEnvironment: environment
                )
                let authURL = profile.codexHomeURL.appendingPathComponent("auth.json")
                check(profile.authStorage == .managedFile, "managed_login_disabled", &failures)
                check(
                    isDescendant(profile.codexHomeURL, of: root),
                    "managed_login_profile_escaped",
                    &failures
                )
                check(
                    profile.processEnvironment["CODEX_HOME"] == profile.codexHomeURL.path,
                    "managed_login_codex_home_mismatch",
                    &failures
                )
                check(
                    profile.processEnvironment["HOME"] == root.path,
                    "managed_login_home_not_isolated",
                    &failures
                )
                check(
                    !fileManager.fileExists(atPath: authURL.path),
                    "managed_login_inherited_credential",
                    &failures
                )
                check(
                    (try? fileManager.destinationOfSymbolicLink(atPath: authURL.path)) == nil,
                    "managed_login_external_link",
                    &failures
                )
            } else {
                failures.append("managed_login_executable_missing")
            }

            let settings = AppSettings(defaults: environment.settingsDefaults)
            environment.applyVoiceE2EDefaults(to: settings)
            check(settings.voiceProvider == .codexAppServer, "voice_provider_default", &failures)
            check(!settings.voiceEnabled, "voice_started_without_opt_in", &failures)
            check(!settings.voiceCalendarAccessEnabled, "calendar_grant_default", &failures)
            check(!settings.aiNativeEnabled, "ai_native_default", &failures)
            check(settings.preferredProviderRawValue == TimerProvider.pluginID.rawValue, "timer_default", &failures)
            check(
                environment.providerRegistry.manifests.map(\.id) == [TimerProvider.pluginID],
                "provider_registry_not_timer_only",
                &failures
            )
            check(
                settings.hiddenProviderRawValues.contains(ClipboardProvider.pluginID.rawValue),
                "clipboard_not_hidden",
                &failures
            )

            let credentialStore = OpenAIRealtimeCredentialStoreFactory.make(
                isolatedVoiceE2E: true
            )
            check(
                credentialStore is OpenAIRealtimeEphemeralCredentialStore,
                "credential_store_not_ephemeral",
                &failures
            )
            check(try !credentialStore.hasCredential(), "credential_not_empty", &failures)
            let verifierKey = try OpenAIRealtimeAPIKey("sk-e2e-verifier-0123456789abcdef")
            try credentialStore.save(verifierKey)
            check(try credentialStore.hasCredential(), "credential_save_failed", &failures)
            check(try credentialStore.load() != nil, "credential_load_failed", &failures)
            try credentialStore.delete()
            check(try !credentialStore.hasCredential(), "credential_delete_failed", &failures)

            expectRejected(
                arguments: arguments,
                metadata: metadata,
                debugBuild: false,
                temporaryDirectory: temporaryDirectory,
                code: "voice_e2e_release_rejected",
                failures: &failures
            )
            expectRejected(
                arguments: ["HoverPocket"],
                metadata: metadata,
                debugBuild: false,
                temporaryDirectory: temporaryDirectory,
                code: "voice_e2e_release_rejected",
                failures: &failures
            )
            expectRejected(
                arguments: ["HoverPocket"],
                metadata: metadata,
                debugBuild: true,
                temporaryDirectory: temporaryDirectory,
                code: "voice_e2e_arguments_required",
                failures: &failures
            )
            expectRejected(
                arguments: arguments + ["--verify-timer"],
                metadata: metadata,
                debugBuild: true,
                temporaryDirectory: temporaryDirectory,
                code: "voice_e2e_verifier_combination_rejected",
                failures: &failures
            )
            expectRejected(
                arguments: [
                    "HoverPocket",
                    HoverPocketRuntimeEnvironment.voiceE2ERootFlag,
                    root.path
                ],
                metadata: metadata,
                debugBuild: true,
                temporaryDirectory: temporaryDirectory,
                code: "voice_e2e_root_without_mode_rejected",
                failures: &failures
            )
            expectRejected(
                arguments: ["HoverPocket", HoverPocketRuntimeEnvironment.voiceE2EFlag],
                metadata: metadata,
                debugBuild: true,
                temporaryDirectory: temporaryDirectory,
                code: "voice_e2e_root_required",
                failures: &failures
            )
            expectRejected(
                arguments: arguments,
                metadata: HoverPocketBundleMetadata(
                    bundleIdentifier: HoverPocketRuntimeEnvironment.voiceE2EBundleIdentifier,
                    isVoiceE2EBuild: false,
                    keychainServiceSuffix: "voice-e2e-verifier"
                ),
                debugBuild: true,
                temporaryDirectory: temporaryDirectory,
                code: "voice_e2e_bundle_marker_required",
                failures: &failures
            )
            expectRejected(
                arguments: arguments,
                metadata: HoverPocketBundleMetadata(
                    bundleIdentifier: "local.codex.hover-pocket",
                    isVoiceE2EBuild: true,
                    keychainServiceSuffix: "voice-e2e-verifier"
                ),
                debugBuild: true,
                temporaryDirectory: temporaryDirectory,
                code: "voice_e2e_bundle_identifier_rejected",
                failures: &failures
            )
            expectRejected(
                arguments: arguments,
                metadata: HoverPocketBundleMetadata(
                    bundleIdentifier: HoverPocketRuntimeEnvironment.voiceE2EBundleIdentifier,
                    isVoiceE2EBuild: true,
                    keychainServiceSuffix: "release"
                ),
                debugBuild: true,
                temporaryDirectory: temporaryDirectory,
                code: "voice_e2e_keychain_suffix_rejected",
                failures: &failures
            )

            verifyRejectedRoots(
                metadata: metadata,
                temporaryDirectory: temporaryDirectory,
                fileManager: fileManager,
                failures: &failures
            )
            verifyReceipt(root: root, failures: &failures)
            verifyPerformanceReceipt(root: root, failures: &failures)

            let production = try HoverPocketRuntimeEnvironment.resolveForBuild(
                arguments: ["HoverPocket"],
                bundleMetadata: HoverPocketBundleMetadata(
                    bundleIdentifier: "local.codex.hover-pocket",
                    isVoiceE2EBuild: false,
                    keychainServiceSuffix: "release"
                ),
                debugBuild: false,
                temporaryDirectory: temporaryDirectory
            )
            check(!production.isIsolatedVoiceE2E, "production_marked_isolated", &failures)
            check(production.externalIntegrationsEnabled, "production_integrations_disabled", &failures)
            check(production.rootDirectory.lastPathComponent == "HoverPocket", "production_root_changed", &failures)
        } catch {
            failures.append("unexpected_\(error)")
        }

        if failures.isEmpty {
            print("PASS voice-e2e-isolation verify: Debug-only marked bundle, fresh direct temp root, verifier and Release rejection, isolated storage/defaults, external integration denial, isolated Codex managed login, Codex default, optional BYOK process-memory credential")
            exit(0)
        }
        print("FAIL voice-e2e-isolation verify:")
        failures.forEach { print("- \($0)") }
        exit(1)
    }

    private static func verifyRejectedRoots(
        metadata: HoverPocketBundleMetadata,
        temporaryDirectory: URL,
        fileManager: FileManager,
        failures: inout [String]
    ) {
        let nestedParent = temporaryDirectory.appendingPathComponent(
            HoverPocketRuntimeEnvironment.voiceE2ERootPrefix + UUID().uuidString,
            isDirectory: true
        )
        let nested = nestedParent.appendingPathComponent(
            HoverPocketRuntimeEnvironment.voiceE2ERootPrefix + "Nested",
            isDirectory: true
        )
        let occupied = temporaryDirectory.appendingPathComponent(
            HoverPocketRuntimeEnvironment.voiceE2ERootPrefix + UUID().uuidString,
            isDirectory: true
        )
        let symlinkTarget = temporaryDirectory.appendingPathComponent(
            HoverPocketRuntimeEnvironment.voiceE2ERootPrefix + UUID().uuidString,
            isDirectory: true
        )
        let symlink = temporaryDirectory.appendingPathComponent(
            HoverPocketRuntimeEnvironment.voiceE2ERootPrefix + UUID().uuidString,
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: occupied, withIntermediateDirectories: false)
            try Data("occupied".utf8).write(to: occupied.appendingPathComponent("marker"))
            try fileManager.createDirectory(at: symlinkTarget, withIntermediateDirectories: false)
            try fileManager.createSymbolicLink(at: symlink, withDestinationURL: symlinkTarget)
            defer {
                try? fileManager.removeItem(at: nestedParent)
                try? fileManager.removeItem(at: occupied)
                try? fileManager.removeItem(at: symlink)
                try? fileManager.removeItem(at: symlinkTarget)
            }

            for (root, code) in [
                (nested, "voice_e2e_root_outside_temp_rejected"),
                (occupied, "voice_e2e_root_not_fresh"),
                (symlink, "voice_e2e_root_type_rejected")
            ] {
                expectRejected(
                    arguments: [
                        "HoverPocket",
                        HoverPocketRuntimeEnvironment.voiceE2EFlag,
                        HoverPocketRuntimeEnvironment.voiceE2ERootFlag,
                        root.path
                    ],
                    metadata: metadata,
                    debugBuild: true,
                    temporaryDirectory: temporaryDirectory,
                    code: code,
                    failures: &failures
                )
            }
        } catch {
            failures.append("root_fixture_\(error)")
        }
    }

    @MainActor
    private static func verifyReceipt(root: URL, failures: inout [String]) {
        do {
            let receiptURL = root.appendingPathComponent(
                "voice-e2e-receipt.json",
                isDirectory: false
            )
            let store = try MacOSVoiceE2EReceiptStore(receiptURL: receiptURL)
            let transcript = [
                VoiceTranscriptEvent(
                    id: "user-event",
                    rootSessionID: "root-session",
                    role: .user,
                    text: "sk-proj-secret-material-must-not-appear",
                    isFinal: true,
                    timestamp: Date(timeIntervalSinceReferenceDate: 1)
                ),
                VoiceTranscriptEvent(
                    id: "assistant-event",
                    rootSessionID: "root-session",
                    role: .assistant,
                    text: "/Users/example/private.txt",
                    isFinal: true,
                    timestamp: Date(timeIntervalSinceReferenceDate: 2)
                )
            ]
            func voiceSnapshot(providerID: VoiceProviderID) -> VoiceLaneSnapshot {
                VoiceLaneSnapshot(
                    providerID: providerID,
                    mode: .compact,
                    connection: .connected,
                    activity: .listening,
                    muted: false,
                    transcript: transcript,
                    transcriptPreview: nil,
                    rootSessionID: "root-session",
                    sessions: [],
                    visibleSessionCount: 0,
                    safeErrorCode: nil,
                    layoutBlockedReason: nil,
                    uiAttached: true,
                    restartAttempt: 0
                )
            }
            store.recordVoiceSnapshot(
                voiceSnapshot(providerID: .openAIRealtimeBYOK),
                credentialCurrent: true
            )
            store.beginMediaSession()
            store.recordMediaEvent(.microphoneAcquired)
            store.recordMediaEvent(.remoteAudioTrackReceived)
            store.recordMediaEvent(.remoteAudioPlaybackSucceeded)
            check(
                store.claimPhysicalConfirmationRequest() == nil,
                "physical_confirmation_wrong_provider_claimed",
                &failures
            )
            store.recordVoiceSnapshot(
                voiceSnapshot(providerID: .codexAppServer),
                credentialCurrent: true
            )
            check(
                store.claimPhysicalConfirmationRequest() == nil,
                "physical_confirmation_cross_provider_attempt_claimed",
                &failures
            )
            store.beginMediaSession()
            store.recordVoiceSnapshot(
                voiceSnapshot(providerID: .codexAppServer),
                credentialCurrent: true
            )
            store.recordMediaEvent(.microphoneAcquired)
            store.recordMediaEvent(.remoteAudioTrackReceived)
            store.recordMediaEvent(.remoteAudioPlaybackSucceeded)
            store.recordTimerCapabilityReadbackVerified()
            let confirmationAttemptID = store.claimPhysicalConfirmationRequest()
            check(confirmationAttemptID != nil, "physical_confirmation_not_claimed", &failures)
            check(store.claimPhysicalConfirmationRequest() == nil, "physical_confirmation_claim_repeated", &failures)
            if let confirmationAttemptID {
                check(
                    store.recordPhysicalMediaUserConfirmation(
                        true,
                        attemptID: confirmationAttemptID
                    ),
                    "physical_confirmation_not_recorded",
                    &failures
                )
            }

            let active = try store.readback()
            check(active.schemaVersion == 1, "receipt_schema", &failures)
            check(active.microphoneCurrent, "receipt_microphone_current", &failures)
            check(active.remoteAudioTrackEver, "receipt_remote_track", &failures)
            check(active.remoteAudioPlaybackEver, "receipt_remote_playback", &failures)
            check(active.userTranscriptCount == 1, "receipt_user_count", &failures)
            check(active.assistantTranscriptCount == 1, "receipt_assistant_count", &failures)
            check(active.timerCapabilityReadbackVerified, "receipt_timer_readback", &failures)
            check(active.physicalMediaUserConfirmed, "receipt_physical_confirmation", &failures)
            check(active.credentialCurrent, "receipt_credential_current", &failures)

            let data = try Data(contentsOf: receiptURL)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let receiptKeys = Set(object?.keys.map { $0 } ?? [])
            check(receiptKeys == MacOSVoiceE2EReceiptStore.allowedKeys, "receipt_allowlist", &failures)
            let text = String(decoding: data, as: UTF8.self)
            check(!text.contains("secret-material"), "receipt_contains_transcript", &failures)
            check(!text.contains("/Users/"), "receipt_contains_path", &failures)
            check(data.count <= 16_384, "receipt_size", &failures)

            store.recordVoiceSnapshot(
                voiceSnapshot(providerID: .openAIRealtimeBYOK),
                credentialCurrent: true
            )
            let switchedAway = try store.readback()
            check(!switchedAway.microphoneAcquired, "receipt_provider_switch_microphone_stale", &failures)
            check(!switchedAway.remoteAudioTrackEver, "receipt_provider_switch_track_stale", &failures)
            check(!switchedAway.remoteAudioPlaybackEver, "receipt_provider_switch_playback_stale", &failures)
            check(switchedAway.userTranscriptCount == 0, "receipt_provider_switch_user_stale", &failures)
            check(switchedAway.assistantTranscriptCount == 0, "receipt_provider_switch_assistant_stale", &failures)
            check(!switchedAway.timerCapabilityReadbackVerified, "receipt_provider_switch_timer_stale", &failures)
            check(!switchedAway.physicalMediaUserConfirmed, "receipt_provider_switch_confirmation_stale", &failures)

            store.recordVoiceSnapshot(
                voiceSnapshot(providerID: .codexAppServer),
                credentialCurrent: true
            )
            store.recordTimerCapabilityReadbackVerified()
            check(
                store.claimPhysicalConfirmationRequest() == nil,
                "receipt_provider_roundtrip_reused_attempt",
                &failures
            )
            if let confirmationAttemptID {
                check(
                    !store.recordPhysicalMediaUserConfirmation(
                        true,
                        attemptID: confirmationAttemptID
                    ),
                    "receipt_provider_roundtrip_accepted_stale_confirmation",
                    &failures
                )
            }
            let switchedBack = try store.readback()
            check(switchedBack.userTranscriptCount == 0, "receipt_provider_roundtrip_user_stale", &failures)
            check(switchedBack.assistantTranscriptCount == 0, "receipt_provider_roundtrip_assistant_stale", &failures)
            check(!switchedBack.timerCapabilityReadbackVerified, "receipt_provider_roundtrip_timer_stale", &failures)

            store.beginMediaSession()
            store.recordVoiceSnapshot(
                voiceSnapshot(providerID: .codexAppServer),
                credentialCurrent: true
            )
            store.recordMediaEvent(.microphoneAcquired)
            store.recordMediaEvent(.remoteAudioTrackReceived)
            store.recordMediaEvent(.remoteAudioPlaybackSucceeded)
            store.recordTimerCapabilityReadbackVerified()
            let recoveredConfirmationAttemptID = store.claimPhysicalConfirmationRequest()
            check(
                recoveredConfirmationAttemptID != nil,
                "receipt_provider_roundtrip_fresh_attempt_not_claimed",
                &failures
            )
            if let recoveredConfirmationAttemptID {
                check(
                    store.recordPhysicalMediaUserConfirmation(
                        true,
                        attemptID: recoveredConfirmationAttemptID
                    ),
                    "receipt_provider_roundtrip_fresh_confirmation_failed",
                    &failures
                )
            }
            let recovered = try store.readback()
            check(recovered.userTranscriptCount == 1, "receipt_provider_roundtrip_user_missing", &failures)
            check(recovered.assistantTranscriptCount == 1, "receipt_provider_roundtrip_assistant_missing", &failures)
            check(recovered.timerCapabilityReadbackVerified, "receipt_provider_roundtrip_timer_missing", &failures)
            check(recovered.physicalMediaUserConfirmed, "receipt_provider_roundtrip_confirmation_missing", &failures)

            store.beginMediaSession()
            if let recoveredConfirmationAttemptID {
                check(
                    !store.recordPhysicalMediaUserConfirmation(
                        true,
                        attemptID: recoveredConfirmationAttemptID
                    ),
                    "receipt_stale_confirmation_accepted",
                    &failures
                )
            }
            let freshAttempt = try store.readback()
            check(!freshAttempt.microphoneAcquired, "receipt_attempt_microphone_stale", &failures)
            check(!freshAttempt.microphoneCurrent, "receipt_attempt_microphone_current", &failures)
            check(!freshAttempt.remoteAudioTrackEver, "receipt_attempt_remote_track_stale", &failures)
            check(!freshAttempt.remoteAudioTrackCurrent, "receipt_attempt_remote_track_current", &failures)
            check(!freshAttempt.remoteAudioPlaybackEver, "receipt_attempt_playback_stale", &failures)
            check(!freshAttempt.remoteAudioPlaybackCurrent, "receipt_attempt_playback_current", &failures)
            check(freshAttempt.userTranscriptCount == 0, "receipt_attempt_user_transcript_stale", &failures)
            check(freshAttempt.assistantTranscriptCount == 0, "receipt_attempt_assistant_transcript_stale", &failures)
            check(!freshAttempt.timerCapabilityReadbackVerified, "receipt_attempt_timer_stale", &failures)
            check(!freshAttempt.physicalMediaUserConfirmed, "receipt_attempt_confirmation_stale", &failures)
            check(freshAttempt.credentialCurrent, "receipt_attempt_credential_lost", &failures)

            store.recordCredentialCurrent(false)
            store.recordSafeClose()
            let stopped = try store.readback()
            check(!stopped.microphoneCurrent, "receipt_microphone_not_stopped", &failures)
            check(!stopped.remoteAudioTrackCurrent, "receipt_remote_track_not_stopped", &failures)
            check(!stopped.remoteAudioPlaybackCurrent, "receipt_playback_not_stopped", &failures)
            check(!stopped.credentialCurrent, "receipt_credential_not_cleared", &failures)
            check(stopped.lastSafeEvent == "safe_close", "receipt_safe_close", &failures)
        } catch {
            failures.append("receipt_\(error)")
        }
    }

    @MainActor
    private static func verifyPerformanceReceipt(root: URL, failures: inout [String]) {
        do {
            let receiptURL = root.appendingPathComponent(
                "voice-e2e-performance.json",
                isDirectory: false
            )
            var now: UInt64 = 1_000_000_000
            let store = try MacOSVoiceE2EPerformanceStore(
                receiptURL: receiptURL,
                nowNanoseconds: { now }
            )
            let initializedData = try Data(contentsOf: receiptURL)
            let initializedObject = try JSONSerialization.jsonObject(
                with: initializedData
            ) as? [String: Any]
            check(
                Set(initializedObject?.keys.map { $0 } ?? [])
                    == MacOSVoiceE2EPerformanceStore.allowedKeys,
                "performance_initialized_allowlist",
                &failures
            )
            check(
                initializedObject?["microphoneToAttachedP95Milliseconds"] is NSNull,
                "performance_initialized_p95_not_null",
                &failures
            )
            check(
                initializedObject?["currentAttemptAttached"] as? Bool == false,
                "performance_initialized_attempt_attached",
                &failures
            )
            store.beginMediaAttempt()
            store.recordSnapshotPublish()
            store.recordSnapshotPublish()
            now += 640_000_000
            store.recordTransportAttached()
            store.recordExpandedRPC(count: 3)
            store.recordRealtimeStopRPC()
            now += 360_000_000
            store.flush(event: "deterministic_readback")

            let first = try store.readback()
            check(first.schemaVersion == 1, "performance_schema", &failures)
            check(first.mediaAttemptCount == 1, "performance_attempt_count", &failures)
            check(first.currentAttemptAttached, "performance_attempt_attached", &failures)
            check(
                first.microphoneToAttachedSamplesMilliseconds == [640],
                "performance_attach_sample",
                &failures
            )
            check(
                first.microphoneToAttachedP95Milliseconds == 640,
                "performance_attach_p95",
                &failures
            )
            check(first.snapshotPublishCount == 2, "performance_snapshot_count", &failures)
            check(first.expandedRPCCount == 3, "performance_expanded_rpc", &failures)
            check(first.realtimeStopRPCCount == 1, "performance_stop_rpc", &failures)
            check(
                first.maximumRealtimeStopRPCCount == 1,
                "performance_stop_rpc_maximum",
                &failures
            )
            check(
                first.measurementDurationMilliseconds == 1_000,
                "performance_measurement_duration",
                &failures
            )

            store.beginMediaAttempt()
            now += 900_000_000
            store.recordTransportAttached()
            let second = try store.readback()
            check(
                second.microphoneToAttachedSamplesMilliseconds == [640, 900],
                "performance_samples_retained",
                &failures
            )
            check(
                second.microphoneToAttachedP95Milliseconds == 900,
                "performance_p95_updated",
                &failures
            )
            check(second.currentAttemptAttached, "performance_second_attempt_attached", &failures)
            check(second.snapshotPublishCount == 0, "performance_attempt_snapshot_stale", &failures)
            check(second.expandedRPCCount == 0, "performance_attempt_rpc_stale", &failures)
            check(second.realtimeStopRPCCount == 0, "performance_attempt_stop_stale", &failures)
            check(
                second.maximumRealtimeStopRPCCount == 1,
                "performance_stop_maximum_lost",
                &failures
            )

            store.recordTransportClosed(localStopRequested: false)
            let remotelyStopped = try store.readback()
            check(
                !remotelyStopped.currentAttemptAttached,
                "performance_remote_close_still_attached",
                &failures
            )
            check(
                remotelyStopped.realtimeStopRPCCount == 0,
                "performance_remote_close_added_stop_rpc",
                &failures
            )
            check(
                remotelyStopped.maximumRealtimeStopRPCCount == 1,
                "performance_remote_close_lost_stop_maximum",
                &failures
            )
            check(
                remotelyStopped.lastSafeEvent == "transport_closed",
                "performance_remote_close_event",
                &failures
            )

            store.beginMediaAttempt()
            now += 700_000_000
            store.recordTransportAttached()
            store.recordTransportClosed(localStopRequested: true)
            let localStopPending = try store.readback()
            check(
                localStopPending.currentAttemptAttached,
                "performance_local_stop_lost_attached_gate",
                &failures
            )
            check(
                localStopPending.realtimeStopRPCCount == 0,
                "performance_local_stop_pending_rpc",
                &failures
            )
            store.recordRealtimeStopRPC()
            store.recordTransportClosed(localStopRequested: true)
            let locallyStopped = try store.readback()
            check(
                locallyStopped.currentAttemptAttached,
                "performance_local_stop_response_lost_gate",
                &failures
            )
            check(
                locallyStopped.realtimeStopRPCCount == 1,
                "performance_local_stop_response_rpc",
                &failures
            )
            check(
                locallyStopped.maximumRealtimeStopRPCCount == 1,
                "performance_local_stop_response_duplicate",
                &failures
            )

            store.beginMediaAttempt()
            let failedCurrentAttempt = try store.readback()
            check(
                !failedCurrentAttempt.currentAttemptAttached,
                "performance_failed_attempt_marked_attached",
                &failures
            )
            check(
                failedCurrentAttempt.microphoneToAttachedSamplesMilliseconds == [640, 900, 700],
                "performance_failed_attempt_lost_history",
                &failures
            )
            check(
                failedCurrentAttempt.realtimeStopRPCCount == 0,
                "performance_failed_attempt_stop_stale",
                &failures
            )
            try store.flushSynchronously(event: "safe_close")
            let synchronouslyStopped = try store.readback()
            check(
                synchronouslyStopped.lastSafeEvent == "safe_close",
                "performance_synchronous_safe_close",
                &failures
            )

            let data = try Data(contentsOf: receiptURL)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let keys = Set(object?.keys.map { $0 } ?? [])
            check(
                keys == MacOSVoiceE2EPerformanceStore.allowedKeys,
                "performance_receipt_allowlist",
                &failures
            )
            check(data.count <= 4_096, "performance_receipt_size", &failures)
        } catch {
            failures.append("performance_receipt_\(error)")
        }
    }

    private static func expectRejected(
        arguments: [String],
        metadata: HoverPocketBundleMetadata,
        debugBuild: Bool,
        temporaryDirectory: URL,
        code: String,
        failures: inout [String]
    ) {
        do {
            _ = try HoverPocketRuntimeEnvironment.resolveForBuild(
                arguments: arguments,
                bundleMetadata: metadata,
                debugBuild: debugBuild,
                temporaryDirectory: temporaryDirectory
            )
            failures.append("accepted_\(code)")
        } catch {
            check(String(describing: error) == code, "wrong_rejection_\(code)", &failures)
        }
    }

    private static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let resolvedCandidate = candidate.standardizedFileURL.resolvingSymlinksInPath().path
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath().path
        return resolvedCandidate.hasPrefix(resolvedRoot + "/")
    }

    private static func check(
        _ condition: @autoclosure () throws -> Bool,
        _ failure: String,
        _ failures: inout [String]
    ) {
        do {
            if try !condition() {
                failures.append(failure)
            }
        } catch {
            failures.append("\(failure)_\(error)")
        }
    }
}
