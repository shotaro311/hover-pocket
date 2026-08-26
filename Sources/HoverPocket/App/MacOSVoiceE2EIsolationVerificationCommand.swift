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

            let settings = AppSettings(defaults: environment.settingsDefaults)
            environment.applyVoiceE2EDefaults(to: settings)
            check(settings.voiceProvider == .openAIRealtimeBYOK, "voice_provider_default", &failures)
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
            print("PASS voice-e2e-isolation verify: Debug-only marked bundle, fresh direct temp root, verifier and Release rejection, isolated storage/defaults, external integration denial, process-memory credential")
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
            store.beginMediaSession()
            store.recordVoiceSnapshot(
                VoiceLaneSnapshot(
                    providerID: .openAIRealtimeBYOK,
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
                ),
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

            store.beginMediaSession()
            if let confirmationAttemptID {
                check(
                    !store.recordPhysicalMediaUserConfirmation(
                        true,
                        attemptID: confirmationAttemptID
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
