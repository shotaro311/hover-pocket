import Foundation

enum VoiceFoundationVerificationError: Error {
    case failed(String)
}

@MainActor
enum VoiceFoundationVerificationCommand {
    static func run() async throws {
        try verifyGeometryAndScope()
        try verifyTranscriptBoundsAndRedaction()
        try verifyLocalization()
        try await verifyDefaultOffAndFakeAdapter()
        try await verifyAppLifetimeDetachAndRestart()
        try await verifyStaleAdapterFailureDoesNotReplaceReadyAdapter()
        try await verifyRecoveryWaitsForCancelledStartup()
        try await verifyDisableWaitsForAdapterTeardown()
        try await verifyRecoveryTeardownIsSerialized()
        try await verifyAudioCommandsRemainOrdered()
        try await verifyShutdownWaitsForAdapterTeardown()
    }

    private static func verifyGeometryAndScope() throws {
        let sizes = ["small", "medium", "large", "extraLarge"]
        let expectedExpanded: [String: Double] = [
            "small": 190,
            "medium": 220,
            "large": 250,
            "extraLarge": 280
        ]
        for size in sizes {
            guard VoiceLaneGeometry.height(enabled: false, preference: .compact, panelSizeRawValue: size) == 0,
                  VoiceLaneGeometry.height(enabled: true, preference: .compact, panelSizeRawValue: size) == 64,
                  VoiceLaneGeometry.height(enabled: true, preference: .expanded, panelSizeRawValue: size) == expectedExpanded[size]
            else {
                throw VoiceFoundationVerificationError.failed("geometry_\(size)")
            }
        }
        guard VoiceLaneGeometry.resolvedPreference(
            requested: .expanded,
            availableExtraHeight: 219,
            panelSizeRawValue: "medium"
        ) == .compact,
        VoiceLaneGeometry.resolvedPreference(
            requested: .expanded,
            availableExtraHeight: 220,
            panelSizeRawValue: "medium"
        ) == .expanded
        else {
            throw VoiceFoundationVerificationError.failed("short_display_fallback")
        }

        let baseline = PanelGeometry.previewSize(panelSize: .medium)
        let compact = PanelGeometry.previewSize(
            panelSize: .medium,
            additionalHeight: CGFloat(VoiceLaneGeometry.compactHeight)
        )
        let expanded = PanelGeometry.previewSize(
            panelSize: .medium,
            additionalHeight: CGFloat(VoiceLaneGeometry.expandedHeight(panelSizeRawValue: "medium"))
        )
        guard compact.width == baseline.width,
              expanded.width == baseline.width,
              compact.height == baseline.height + 64,
              expanded.height == baseline.height + 220
        else {
            throw VoiceFoundationVerificationError.failed("window_downward_expansion")
        }

        let now = Date(timeIntervalSince1970: 0)
        let sessions = [
            VoiceSessionSummary(
                sessionID: "root-a",
                rootSessionID: "root-a",
                title: "Root",
                status: .running,
                updatedAt: now
            ),
            VoiceSessionSummary(
                sessionID: "child-a",
                rootSessionID: "root-a",
                parentSessionID: "root-a",
                title: "Child",
                status: .running,
                updatedAt: now.addingTimeInterval(1)
            ),
            VoiceSessionSummary(
                sessionID: "grandchild-a",
                rootSessionID: "root-a",
                parentSessionID: "child-a",
                title: "Descendant",
                status: .running,
                updatedAt: now.addingTimeInterval(2)
            ),
            VoiceSessionSummary(
                sessionID: "root-b",
                rootSessionID: "root-b",
                title: "Other root",
                status: .running,
                updatedAt: now.addingTimeInterval(3)
            )
        ]
        let visible = VoiceSessionScope.visibleSessions(
            rootSessionID: "root-a",
            sessions: sessions
        )
        guard visible.count == 3,
              visible.allSatisfy({ $0.rootSessionID == "root-a" })
        else {
            throw VoiceFoundationVerificationError.failed("root_scope")
        }
    }

    private static func verifyTranscriptBoundsAndRedaction() throws {
        var buffer = VoiceTranscriptBuffer()
        let now = Date(timeIntervalSince1970: 0)
        for index in 0..<90 {
            buffer.append(VoiceTranscriptEvent(
                id: "event-\(index)",
                role: .user,
                text: index == 89
                    ? "/Users/test/private.txt"
                    : String(repeating: "あ", count: 160),
                isFinal: true,
                timestamp: now.addingTimeInterval(Double(index))
            ))
        }
        let scalarCount = buffer.events.reduce(0) { count, event in
            count + event.text.unicodeScalars.count
        }
        guard buffer.events.count <= 64,
              scalarCount <= 8_192,
              buffer.events.allSatisfy({ !$0.text.contains("/Users/") })
        else {
            throw VoiceFoundationVerificationError.failed("transcript_bounds_redaction")
        }

        let combining = VoiceTranscriptEvent(
            id: "combining",
            role: .assistant,
            text: "a" + String(repeating: "\u{0301}", count: 10_000),
            isFinal: true,
            timestamp: now
        )
        let pathSamples = ["/tmp/private.txt", "/Volumes/work/secret.mov", #"C:\work\secret.txt"#]
        guard combining.text.unicodeScalars.count <= 1_024,
              pathSamples.allSatisfy({ VoiceTextSafety.sanitizeVisibleText($0, limit: 200) == "[redacted]" })
        else {
            throw VoiceFoundationVerificationError.failed("scalar_bound_or_absolute_path_redaction")
        }
    }

    private static func verifyLocalization() throws {
        let japanese = VoiceLaneLocalization.text(
            japanese: "音声接続はまだ利用できません",
            english: "Voice transport is not available yet",
            language: .japanese
        )
        let english = VoiceLaneLocalization.text(
            japanese: "音声接続はまだ利用できません",
            english: "Voice transport is not available yet",
            language: .english
        )
        guard japanese == "音声接続はまだ利用できません",
              english == "Voice transport is not available yet",
              VoiceLaneLocalization.connection(.connected, language: .japanese) == "接続済み",
              VoiceLaneLocalization.connection(.connected, language: .english) == "Connected",
              VoiceLaneLocalization.sessionStatus(.waitingForUser, language: .japanese) == "ユーザー操作待ち",
              VoiceLaneLocalization.transcriptRole(.user, language: .english) == "You"
        else {
            throw VoiceFoundationVerificationError.failed("voice_localization")
        }
    }

    private static func verifyDefaultOffAndFakeAdapter() async throws {
        let runtime = VoiceLaneRuntime(restartDelaysNanoseconds: [0])
        var factoryCalled = false
        await runtime.configure(
            featureEnabled: false,
            preferredLayout: .compact,
            adapterFactory: {
                factoryCalled = true
                return FakeVoiceSessionAdapter()
            }
        ).value
        guard !factoryCalled, runtime.snapshot == .disabled else {
            throw VoiceFoundationVerificationError.failed("default_off_side_effect")
        }

        await runtime.configure(
            featureEnabled: true,
            preferredLayout: .compact,
            adapterFactory: nil
        ).value
        guard runtime.snapshot.mode == .compact,
              runtime.snapshot.connection == .disconnected,
              runtime.snapshot.safeErrorCode == "voice_adapter_unavailable"
        else {
            throw VoiceFoundationVerificationError.failed("production_adapter_fail_closed")
        }
        runtime.setMuted(false)
        guard runtime.snapshot.muted else {
            throw VoiceFoundationVerificationError.failed("unavailable_adapter_reported_unmuted")
        }
        runtime.recoverAfterSystemTransition()
        guard runtime.snapshot.connection == .disconnected,
              runtime.snapshot.activity == .failed,
              runtime.snapshot.safeErrorCode == "voice_adapter_unavailable"
        else {
            throw VoiceFoundationVerificationError.failed("unavailable_adapter_recovery_state")
        }
        runtime.setResolvedLayout(requested: .expanded, resolved: .compact)
        guard runtime.snapshot.mode == .compact,
              runtime.snapshot.layoutBlockedReason != nil
        else {
            throw VoiceFoundationVerificationError.failed("expanded_unavailable_reason")
        }

        let unsafeGateRuntime = VoiceLaneRuntime(restartDelaysNanoseconds: [])
        let unsafeGateAdapter = FakeVoiceSessionAdapter(gate: VoiceAdapterGate(
            installedSchemaCompatible: false,
            accountReady: false,
            capabilityReady: false,
            safeErrorCode: "token=secret /tmp/private.txt"
        ))
        unsafeGateRuntime.configure(
            featureEnabled: true,
            preferredLayout: .compact,
            adapterFactory: { unsafeGateAdapter }
        )
        try await waitUntil {
            unsafeGateAdapter.stopCount == 1
                && unsafeGateRuntime.snapshot.safeErrorCode != nil
        }
        guard unsafeGateRuntime.snapshot.safeErrorCode == "_redacted_" else {
            throw VoiceFoundationVerificationError.failed("adapter_error_code_not_sanitized")
        }
        await unsafeGateRuntime.shutdown()
    }

    private static func verifyAppLifetimeDetachAndRestart() async throws {
        let adapter = FakeVoiceSessionAdapter(startFailuresRemaining: 1)
        let runtime = VoiceLaneRuntime(restartDelaysNanoseconds: [0, 0])
        await runtime.configure(
            featureEnabled: true,
            preferredLayout: .compact,
            adapterFactory: { adapter }
        ).value
        try await waitUntil {
            runtime.snapshot.connection == .connected
        }
        runtime.setMuted(false)
        guard !runtime.snapshot.muted else {
            throw VoiceFoundationVerificationError.failed("connected_adapter_could_not_unmute")
        }
        runtime.endAudioSession()
        try await waitUntil { adapter.closeAudioSessionCount == 1 }
        guard runtime.snapshot.connection == .connected,
              runtime.snapshot.muted,
              adapter.muted
        else {
            throw VoiceFoundationVerificationError.failed("ending_audio_disconnected_transport")
        }
        runtime.setMuted(false)
        try await waitUntil { !adapter.muted }
        guard runtime.snapshot.connection == .connected, !runtime.snapshot.muted else {
            throw VoiceFoundationVerificationError.failed("ended_audio_transport_not_reusable")
        }
        runtime.setMuted(true)

        runtime.setRootSessionID("root-a")
        runtime.appendTranscript(VoiceTranscriptEvent(
            id: "event",
            role: .assistant,
            text: "memory-only",
            isFinal: true,
            timestamp: Date(timeIntervalSince1970: 0)
        ))
        runtime.upsertSession(VoiceSessionSummary(
            sessionID: "root-a",
            rootSessionID: "root-a",
            title: "Root",
            status: .running,
            updatedAt: Date(timeIntervalSince1970: 0)
        ))
        runtime.attachPanel()
        runtime.detachPanel()
        let detached = runtime.snapshot
        runtime.attachPanel()
        let reattached = runtime.snapshot

        guard detached.muted,
              !detached.uiAttached,
              detached.rootSessionID == "root-a",
              detached.transcript.count == 1,
              detached.sessions.count == 1,
              reattached.rootSessionID == "root-a",
              reattached.transcript.count == 1,
              adapter.startCount == 2
        else {
            throw VoiceFoundationVerificationError.failed("lifetime_restart")
        }

        for index in 0..<90 {
            runtime.upsertSession(VoiceSessionSummary(
                sessionID: "child-\(index)",
                rootSessionID: "root-a",
                parentSessionID: "root-a",
                title: "Child \(index)",
                status: .running,
                updatedAt: Date(timeIntervalSince1970: Double(index + 1))
            ))
        }
        guard runtime.snapshot.sessions.count <= VoiceLaneRuntime.maxRetainedSessions else {
            throw VoiceFoundationVerificationError.failed("session_retention_bound")
        }

        runtime.setRootSessionID("root-b")
        guard runtime.snapshot.transcript.isEmpty,
              runtime.snapshot.sessions.isEmpty,
              runtime.snapshot.rootSessionID == "root-b"
        else {
            throw VoiceFoundationVerificationError.failed("root_transition_isolation")
        }

        let stopCountBeforeCrash = adapter.stopCount
        runtime.markAdapterCrashed()
        try await waitUntil {
            runtime.snapshot.connection == .connected
                && adapter.stopCount == stopCountBeforeCrash + 1
        }

        runtime.handleUnexpectedServerRequest(method: "unknown/request")
        guard runtime.snapshot.activity == .failed,
              runtime.snapshot.safeErrorCode == "unexpected_server_request"
        else {
            throw VoiceFoundationVerificationError.failed("unexpected_request_fail_closed")
        }
        await runtime.shutdown()
    }

    private static func verifyStaleAdapterFailureDoesNotReplaceReadyAdapter() async throws {
        let stale = GatedVoiceSessionAdapter()
        let healthy = FakeVoiceSessionAdapter()
        let runtime = VoiceLaneRuntime(restartDelaysNanoseconds: [0])
        var factoryCount = 0
        let factory: VoiceLaneRuntime.AdapterFactory = {
            factoryCount += 1
            return factoryCount == 1 ? stale : healthy
        }
        runtime.configure(
            featureEnabled: true,
            preferredLayout: .compact,
            adapterFactory: factory
        )
        try await waitUntil { stale.startCount == 1 }
        let disableTask = runtime.configure(
            featureEnabled: false,
            preferredLayout: .compact,
            adapterFactory: nil
        )
        let replacementTask = runtime.configure(
            featureEnabled: true,
            preferredLayout: .compact,
            adapterFactory: factory
        )
        stale.failStart()
        await disableTask.value
        await replacementTask.value
        try await waitUntil {
            runtime.snapshot.connection == .connected && healthy.startCount == 1
        }
        try await waitUntil { stale.stopCount == 1 }
        guard runtime.snapshot.connection == .connected,
              runtime.snapshot.safeErrorCode == nil,
              healthy.startCount == 1
        else {
            throw VoiceFoundationVerificationError.failed("stale_adapter_failure_replaced_ready_adapter")
        }
        await runtime.shutdown()
    }

    private static func verifyDisableWaitsForAdapterTeardown() async throws {
        let oldAdapter = GatedStopVoiceSessionAdapter()
        let replacementAdapter = FakeVoiceSessionAdapter()
        let runtime = VoiceLaneRuntime(restartDelaysNanoseconds: [0])
        await runtime.configure(
            featureEnabled: true,
            preferredLayout: .compact,
            adapterFactory: { oldAdapter }
        ).value
        try await waitUntil { runtime.snapshot.connection == .connected }

        let disableTask = runtime.configure(
            featureEnabled: false,
            preferredLayout: .compact,
            adapterFactory: nil
        )
        try await waitUntil { oldAdapter.stopCount == 1 }
        guard runtime.snapshot != .disabled else {
            throw VoiceFoundationVerificationError.failed("voice_off_published_before_adapter_teardown")
        }

        let replacementTask = runtime.configure(
            featureEnabled: true,
            preferredLayout: .compact,
            adapterFactory: { replacementAdapter }
        )
        await Task.yield()
        guard replacementAdapter.startCount == 0 else {
            throw VoiceFoundationVerificationError.failed("replacement_started_before_adapter_teardown")
        }

        oldAdapter.finishStop()
        await disableTask.value
        await replacementTask.value
        try await waitUntil { runtime.snapshot.connection == .connected }
        guard replacementAdapter.startCount == 1 else {
            throw VoiceFoundationVerificationError.failed("replacement_not_started_after_adapter_teardown")
        }
        await runtime.shutdown()
    }

    private static func verifyRecoveryWaitsForCancelledStartup() async throws {
        let stale = GatedVoiceSessionAdapter()
        let healthy = FakeVoiceSessionAdapter()
        let runtime = VoiceLaneRuntime(restartDelaysNanoseconds: [0])
        var factoryCount = 0
        let factory: VoiceLaneRuntime.AdapterFactory = {
            factoryCount += 1
            return factoryCount == 1 ? stale : healthy
        }
        runtime.configure(
            featureEnabled: true,
            preferredLayout: .compact,
            adapterFactory: factory
        )
        try await waitUntil { stale.startCount == 1 }

        runtime.recoverAfterSystemTransition()
        await Task.yield()
        guard factoryCount == 1, healthy.startCount == 0 else {
            throw VoiceFoundationVerificationError.failed("recovery_overlapped_cancelled_startup")
        }

        stale.failStart()
        try await waitUntil {
            runtime.snapshot.connection == .connected
                && healthy.startCount == 1
                && stale.stopCount == 1
        }
        guard factoryCount == 2 else {
            throw VoiceFoundationVerificationError.failed("recovery_started_multiple_replacements")
        }
        await runtime.shutdown()
    }

    private static func verifyShutdownWaitsForAdapterTeardown() async throws {
        let adapter = GatedStopVoiceSessionAdapter()
        let runtime = VoiceLaneRuntime(restartDelaysNanoseconds: [0])
        runtime.configure(
            featureEnabled: true,
            preferredLayout: .compact,
            adapterFactory: { adapter }
        )
        try await waitUntil { runtime.snapshot.connection == .connected }

        var shutdownCompleted = false
        let shutdownTask = Task { @MainActor in
            await runtime.shutdown()
            shutdownCompleted = true
        }
        try await waitUntil { adapter.stopCount == 1 }
        guard !shutdownCompleted else {
            throw VoiceFoundationVerificationError.failed("shutdown_returned_before_adapter_teardown")
        }

        adapter.finishStop()
        await shutdownTask.value
        guard shutdownCompleted, runtime.snapshot == .disabled else {
            throw VoiceFoundationVerificationError.failed("shutdown_did_not_complete_after_adapter_teardown")
        }
    }

    private static func verifyRecoveryTeardownIsSerialized() async throws {
        let oldAdapter = GatedStopVoiceSessionAdapter()
        let replacementAdapter = FakeVoiceSessionAdapter()
        let runtime = VoiceLaneRuntime(restartDelaysNanoseconds: [0])
        await runtime.configure(
            featureEnabled: true,
            preferredLayout: .compact,
            adapterFactory: { oldAdapter }
        ).value
        try await waitUntil { runtime.snapshot.connection == .connected }

        runtime.recoverAfterSystemTransition()
        try await waitUntil { oldAdapter.stopCount == 1 }
        let disableTask = runtime.configure(
            featureEnabled: false,
            preferredLayout: .compact,
            adapterFactory: nil
        )
        let replacementTask = runtime.configure(
            featureEnabled: true,
            preferredLayout: .compact,
            adapterFactory: { replacementAdapter }
        )
        await Task.yield()
        guard replacementAdapter.startCount == 0 else {
            throw VoiceFoundationVerificationError.failed("recovery_replacement_started_before_teardown")
        }

        oldAdapter.finishStop()
        await disableTask.value
        await replacementTask.value
        try await waitUntil { runtime.snapshot.connection == .connected }
        guard replacementAdapter.startCount == 1 else {
            throw VoiceFoundationVerificationError.failed("recovery_replacement_not_started_after_teardown")
        }
        await runtime.shutdown()
    }

    private static func verifyAudioCommandsRemainOrdered() async throws {
        let adapter = GatedCloseVoiceSessionAdapter()
        let runtime = VoiceLaneRuntime(restartDelaysNanoseconds: [0])
        await runtime.configure(
            featureEnabled: true,
            preferredLayout: .compact,
            adapterFactory: { adapter }
        ).value
        try await waitUntil { runtime.snapshot.connection == .connected }

        runtime.endAudioSession()
        try await waitUntil { adapter.closeCount == 1 }
        runtime.setMuted(false)
        await Task.yield()
        guard adapter.muteValues.isEmpty else {
            throw VoiceFoundationVerificationError.failed("unmute_overtook_audio_session_close")
        }

        adapter.finishClose()
        try await waitUntil { adapter.muteValues == [false] }
        guard !runtime.snapshot.muted else {
            throw VoiceFoundationVerificationError.failed("ordered_unmute_snapshot_mismatch")
        }
        await runtime.shutdown()
    }

    private static func waitUntil(
        _ predicate: @MainActor () -> Bool
    ) async throws {
        for _ in 0..<200 {
            if predicate() {
                return
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw VoiceFoundationVerificationError.failed("timeout")
    }
}

@MainActor
private final class GatedVoiceSessionAdapter: VoiceSessionAdapter {
    private var startContinuation: CheckedContinuation<Void, Error>?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func probeCompatibility() async -> VoiceAdapterGate { .ready }

    func start() async throws {
        startCount += 1
        try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
        }
    }

    func failStart() {
        startContinuation?.resume(throwing: FakeVoiceSessionAdapterError.startFailed)
        startContinuation = nil
    }

    func setMuted(_ muted: Bool) async { _ = muted }
    func closeAudioSession() async { }
    func stop() async { stopCount += 1 }
}

@MainActor
private final class GatedStopVoiceSessionAdapter: VoiceSessionAdapter {
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private(set) var stopCount = 0

    func probeCompatibility() async -> VoiceAdapterGate { .ready }
    func start() async throws { }
    func setMuted(_ muted: Bool) async { _ = muted }
    func closeAudioSession() async { }

    func stop() async {
        stopCount += 1
        await withCheckedContinuation { continuation in
            stopContinuation = continuation
        }
    }

    func finishStop() {
        stopContinuation?.resume()
        stopContinuation = nil
    }
}

@MainActor
private final class GatedCloseVoiceSessionAdapter: VoiceSessionAdapter {
    private var closeContinuation: CheckedContinuation<Void, Never>?
    private(set) var closeCount = 0
    private(set) var muteValues: [Bool] = []

    func probeCompatibility() async -> VoiceAdapterGate { .ready }
    func start() async throws { }
    func setMuted(_ muted: Bool) async { muteValues.append(muted) }

    func closeAudioSession() async {
        closeCount += 1
        await withCheckedContinuation { continuation in
            closeContinuation = continuation
        }
    }

    func finishClose() {
        closeContinuation?.resume()
        closeContinuation = nil
    }

    func stop() async { }
}
