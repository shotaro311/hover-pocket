import Combine
import Foundation

enum VoiceFoundationVerificationError: Error {
    case failed(String)
}

private struct UnsafeDecodedTranscriptFixture: Codable {
    let id: String
    let rootSessionID: String
    let role: String
    let text: String
    let isFinal: Bool
    let timestamp: Date
}

private struct UnsafeDecodedSessionProgressFixture: Codable {
    let completed: Int
    let total: Int
}

private struct UnsafeDecodedSessionFixture: Codable {
    let sessionID: String
    let rootSessionID: String
    let parentSessionID: String?
    let title: String
    let status: String
    let safeSummary: String?
    let progress: UnsafeDecodedSessionProgressFixture?
    let updatedAt: Date
}

@MainActor
enum VoiceFoundationVerificationCommand {
    static func run() async throws {
        try verifySettingsBindingUsesPublishedValues()
        try verifyGeometryAndScope()
        try verifyTranscriptBoundsAndRedaction()
        try await verifyDecodedModelsAreResanitized()
        try verifyLocalization()
        try await verifyDefaultOffAndFakeAdapter()
        try await verifyRealtimeProviderAndMacOSTransport()
        try await verifyExplicitAudioStart()
        try await verifyCapabilityGrantRefresh()
        try await verifyRealtimeCapabilityBrokerRuntime()
        try await verifyAppLifetimeDetachAndRestart()
        try await verifyStaleAdapterFailureDoesNotReplaceReadyAdapter()
        try await verifyRecoveryWaitsForCancelledStartup()
        try await verifyDisableWaitsForAdapterTeardown()
        try await verifyRecoveryTeardownIsSerialized()
        try await verifyAudioCommandsRemainOrdered()
        try await verifyShutdownWaitsForAdapterTeardown()
    }

    private static func verifySettingsBindingUsesPublishedValues() throws {
        let defaults = EphemeralAppSettingsDefaults()
        let settings = AppSettings(defaults: defaults)
        var received: [VoiceRuntimeSettingsConfiguration] = []
        let cancellable = voiceRuntimeSettingsPublisher(settings: settings)
            .dropFirst()
            .sink { received.append($0) }
        defer { cancellable.cancel() }

        settings.voiceProvider = .codexAppServer
        settings.voiceEnabled = true
        settings.voiceLaneLayoutPreference = .expanded

        guard received == [
            VoiceRuntimeSettingsConfiguration(
                featureEnabled: false,
                preferredLayout: .compact,
                providerID: .codexAppServer
            ),
            VoiceRuntimeSettingsConfiguration(
                featureEnabled: true,
                preferredLayout: .compact,
                providerID: .codexAppServer
            ),
            VoiceRuntimeSettingsConfiguration(
                featureEnabled: true,
                preferredLayout: .expanded,
                providerID: .codexAppServer
            )
        ] else {
            throw VoiceFoundationVerificationError.failed("settings_binding_stale_value")
        }
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

        let collisionCandidates = [
            VoiceSessionSummary(
                sessionID: "foreign/child",
                rootSessionID: "root/a",
                title: "Foreign",
                status: .running,
                updatedAt: now
            ),
            VoiceSessionSummary(
                sessionID: "local-child",
                rootSessionID: "roota",
                title: "Local",
                status: .running,
                updatedAt: now
            )
        ]
        let isolated = VoiceSessionScope.visibleSessions(
            rootSessionID: "roota",
            sessions: collisionCandidates
        )
        guard VoiceTextSafety.sanitizeIdentifier("root/a").isEmpty,
              VoiceTextSafety.sanitizeIdentifier("roota") == "roota",
              VoiceTextSafety.sanitizeIdentifier(String(repeating: "a", count: 161)).isEmpty,
              isolated.count == 1,
              isolated.first?.sessionID == "local-child"
        else {
            throw VoiceFoundationVerificationError.failed("identifier_collision_rejected")
        }
    }

    private static func verifyTranscriptBoundsAndRedaction() throws {
        var buffer = VoiceTranscriptBuffer()
        let now = Date(timeIntervalSince1970: 0)
        for index in 0..<90 {
            buffer.append(VoiceTranscriptEvent(
                id: "event-\(index)",
                rootSessionID: "root-a",
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
        let validEventCount = buffer.events.count
        buffer.append(VoiceTranscriptEvent(
            id: "invalid/event",
            rootSessionID: "root-a",
            role: .user,
            text: "must not render with a colliding identity",
            isFinal: true,
            timestamp: now.addingTimeInterval(100)
        ))
        guard buffer.events.count <= 64,
              buffer.events.count == validEventCount,
              scalarCount <= 8_192,
              buffer.events.contains(where: { $0.text == "/Users/test/private.txt" })
        else {
            throw VoiceFoundationVerificationError.failed("transcript_bounds_redaction")
        }

        let combining = VoiceTranscriptEvent(
            id: "combining",
            rootSessionID: "root-a",
            role: .assistant,
            text: "a" + String(repeating: "\u{0301}", count: 10_000),
            isFinal: true,
            timestamp: now
        )
        let redactionSamples = [
            "/tmp/private.txt",
            "/Volumes/work/secret.mov",
            #"C:\work\secret.txt"#,
            "[/Users/alice/private]",
            #"[C:\Users\alice\private]"#,
            "Sources/HoverPocket/App.swift",
            #"Sources\HoverPocket\App.swift"#,
            "Bearer sk-proj-secret",
            "sk-proj-abcdefghijklmnopqrstuvwxyz",
            #"{"access_token":"abcdefghijklmnopqrstuvwxyz"}"#,
            #"{"client_secret" : "abcdefghijklmnopqrstuvwxyz"}"#
        ]
        let bidiSamples = [
            "trusted\u{202E}detadpu",
            "trusted\u{2066}spoof\u{2069}"
        ]
        let nonPathSamples = [
            "https://example.com/Sources/HoverPocket/App.swift",
            "and/or",
            "input/output",
            #"input\output"#
        ]
        guard combining.text.unicodeScalars.count <= 1_024,
              redactionSamples.allSatisfy({ VoiceTextSafety.sanitizeVisibleText($0, limit: 200) == "[redacted]" }),
              nonPathSamples.allSatisfy({ VoiceTextSafety.sanitizeVisibleText($0, limit: 200) == $0 }),
              bidiSamples.allSatisfy({ sample in
                  let sanitized = VoiceTextSafety.sanitizeVisibleText(sample, limit: 200)
                  return !sanitized.unicodeScalars.contains(where: {
                      $0.properties.generalCategory == .format
                  })
              })
        else {
            throw VoiceFoundationVerificationError.failed("scalar_bound_path_or_format_control_redaction")
        }
        guard VoiceApprovalText.singleLine("予定\n  偽の承認\t対象", limit: 80) == "予定 偽の承認 対象" else {
            throw VoiceFoundationVerificationError.failed("voice_approval_text_not_canonical")
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

    private static func verifyDecodedModelsAreResanitized() async throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let now = Date(timeIntervalSince1970: 0)
        var buffer = VoiceTranscriptBuffer()
        let decodedEvent = try decoder.decode(
            VoiceTranscriptEvent.self,
            from: encoder.encode(UnsafeDecodedTranscriptFixture(
                id: "decoded-event",
                rootSessionID: "root-a",
                role: "assistant",
                text: "[/Users/alice/private]",
                isFinal: false,
                timestamp: now
            ))
        )
        buffer.append(decodedEvent)
        guard buffer.events.count == 1,
              buffer.events[0].text == "[/Users/alice/private]"
        else {
            throw VoiceFoundationVerificationError.failed("decoded_transcript_resanitized")
        }
        buffer.append(VoiceTranscriptEvent(
            id: "decoded-event",
            rootSessionID: "root-a",
            role: .assistant,
            text: "final revision",
            isFinal: true,
            timestamp: now.addingTimeInterval(1)
        ))
        buffer.append(VoiceTranscriptEvent(
            id: "decoded-event",
            rootSessionID: "root-a",
            role: .assistant,
            text: "late interim",
            isFinal: false,
            timestamp: now.addingTimeInterval(2)
        ))
        let invalidDecodedEvent = try decoder.decode(
            VoiceTranscriptEvent.self,
            from: encoder.encode(UnsafeDecodedTranscriptFixture(
                id: "invalid/event",
                rootSessionID: "root-a",
                role: "assistant",
                text: "must not render",
                isFinal: true,
                timestamp: now
            ))
        )
        buffer.append(invalidDecodedEvent)
        guard buffer.events.count == 1,
              buffer.events[0].id == "decoded-event",
              buffer.events[0].text == "final revision",
              buffer.events[0].isFinal
        else {
            throw VoiceFoundationVerificationError.failed("transcript_revision_identity")
        }

        let decodedSession = try decoder.decode(
            VoiceSessionSummary.self,
            from: encoder.encode(UnsafeDecodedSessionFixture(
                sessionID: "decoded-session",
                rootSessionID: "root-a",
                parentSessionID: "invalid/parent",
                title: "[/Users/alice/private]",
                status: "running",
                safeSummary: "token=secret",
                progress: UnsafeDecodedSessionProgressFixture(completed: -1, total: 0),
                updatedAt: now
            ))
        )
        let runtime = VoiceLaneRuntime()
        await runtime.configure(
            featureEnabled: true,
            preferredLayout: .compact,
            providerID: .codexAppServer,
            adapterFactory: nil
        ).value
        runtime.setRootSessionID("root-a")
        runtime.upsertSession(decodedSession)
        let session = runtime.snapshot.sessions.first
        guard runtime.snapshot.sessions.count == 1,
              session?.sessionID == "decoded-session",
              session?.parentSessionID == nil,
              session?.title == "[redacted]",
              session?.safeSummary == "[redacted]",
              session?.progress == nil
        else {
            throw VoiceFoundationVerificationError.failed("decoded_session_resanitized")
        }
        await runtime.shutdown()
    }

    private static func verifyDefaultOffAndFakeAdapter() async throws {
        let runtime = VoiceLaneRuntime(restartDelaysNanoseconds: [0])
        var factoryCalled = false
        await runtime.configure(
            featureEnabled: false,
            preferredLayout: .compact,
            providerID: .codexAppServer,
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
            providerID: .codexAppServer,
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
            providerID: .codexAppServer,
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

    private static func verifyRealtimeProviderAndMacOSTransport() async throws {
        let suiteName = "hover-pocket-voice-provider-verify-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw VoiceFoundationVerificationError.failed("provider_defaults_unavailable")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        guard settings.voiceProvider == .off,
              !settings.voiceEnabled,
              !settings.voiceCalendarAccessEnabled,
              OpenAIRealtimeFoundation.modelID == "gpt-realtime-2.1",
              OpenAIRealtimeFoundation.callsEndpoint.path == "/v1/realtime/calls",
              OpenAIRealtimeFoundation.macOSAudioTransportAvailable,
              OpenAIRealtimeContract.maximumSDPBytes == 262_144,
              OpenAIRealtimeContract.maximumEventBytes == 65_536,
              OpenAIRealtimeContract.maximumFunctionOutputBytes == 32_768 else {
            throw VoiceFoundationVerificationError.failed("realtime_provider_defaults")
        }
        try OpenAIRealtimeCallsClient.validateSDP("v=0\r\ns=-\r\n")
        do {
            try OpenAIRealtimeCallsClient.validateSDP("not-sdp")
            throw VoiceFoundationVerificationError.failed("realtime_invalid_sdp_accepted")
        } catch OpenAIRealtimeMacOSTransportError.invalidSDP {
        }

        let key = try OpenAIRealtimeAPIKey(String(repeating: "x", count: 32))
        guard key.description == "[redacted]", key.debugDescription == "[redacted]" else {
            throw VoiceFoundationVerificationError.failed("realtime_key_redaction")
        }

        let credentialStore = CountingOpenAIRealtimeCredentialStore()
        let adapter = OpenAIRealtimeMacOSVoiceSessionAdapter(credentialStore: credentialStore)
        let gate = await adapter.probeCompatibility()
        guard !gate.isReady,
              gate.safeErrorCode == "openai_realtime_macos_transport_unavailable",
              credentialStore.hasCredentialCount == 0,
              credentialStore.loadCount == 0 else {
            throw VoiceFoundationVerificationError.failed("macos_transport_missing_context_touched_credential")
        }

        let offRuntime = VoiceLaneRuntime(restartDelaysNanoseconds: [0])
        var offFactoryCalled = false
        await offRuntime.configure(
            featureEnabled: true,
            preferredLayout: .compact,
            providerID: .off,
            adapterFactory: {
                offFactoryCalled = true
                return FakeVoiceSessionAdapter()
            }
        ).value
        guard !offFactoryCalled, offRuntime.snapshot == .disabled else {
            throw VoiceFoundationVerificationError.failed("provider_off_side_effect")
        }

        let oldAdapter = GatedStopVoiceSessionAdapter()
        let replacement = FakeVoiceSessionAdapter()
        let switchRuntime = VoiceLaneRuntime(restartDelaysNanoseconds: [0])
        await switchRuntime.configure(
            featureEnabled: true,
            preferredLayout: .compact,
            providerID: .codexAppServer,
            adapterFactory: { oldAdapter }
        ).value
        try await waitUntil { switchRuntime.snapshot.connection == .connected }
        let switchTask = switchRuntime.configure(
            featureEnabled: true,
            preferredLayout: .compact,
            providerID: .openAIRealtimeBYOK,
            adapterFactory: { replacement }
        )
        try await waitUntil { oldAdapter.stopCount == 1 }
        guard replacement.startCount == 0 else {
            throw VoiceFoundationVerificationError.failed("provider_switch_started_before_teardown")
        }
        oldAdapter.finishStop()
        await switchTask.value
        try await waitUntil { switchRuntime.snapshot.connection == .connected }
        guard replacement.startCount == 1,
              switchRuntime.snapshot.providerID == .openAIRealtimeBYOK else {
            throw VoiceFoundationVerificationError.failed("provider_switch_readback")
        }
        await switchRuntime.shutdown()
    }

    private static func verifyExplicitAudioStart() async throws {
        let adapter = ExplicitStartVoiceSessionAdapter()
        let runtime = VoiceLaneRuntime(restartDelaysNanoseconds: [0])
        await runtime.configure(
            featureEnabled: true,
            preferredLayout: .compact,
            providerID: .openAIRealtimeBYOK,
            adapterFactory: { adapter }
        ).value
        try await waitUntil { runtime.snapshot.activity == .idle }
        guard adapter.startCount == 0,
              runtime.snapshot.connection == .disconnected,
              runtime.snapshot.muted else {
            throw VoiceFoundationVerificationError.failed("explicit_start_ran_during_enable")
        }
        runtime.beginAudioSession()
        try await Task.sleep(nanoseconds: 5_000_000)
        guard adapter.startCount == 0 else {
            throw VoiceFoundationVerificationError.failed("detached_explicit_start_allowed")
        }
        runtime.attachPanel()
        runtime.beginAudioSession()
        try await waitUntil { runtime.snapshot.connection == .connected }
        guard adapter.startCount == 1,
              runtime.snapshot.activity == .listening,
              !runtime.snapshot.muted else {
            throw VoiceFoundationVerificationError.failed("explicit_start_readback")
        }
        runtime.endAudioSession()
        try await waitUntil { adapter.closeAudioSessionCount == 1 }
        guard runtime.snapshot.connection == .disconnected,
              runtime.snapshot.activity == .idle,
              runtime.snapshot.muted else {
            throw VoiceFoundationVerificationError.failed("explicit_end_readback")
        }
        runtime.beginAudioSession()
        try await waitUntil { adapter.startCount == 2 && runtime.snapshot.connection == .connected }
        runtime.reportTransportFailure("voice_realtime_event_invalid")
        try await waitUntil { adapter.closeAudioSessionCount == 2 }
        guard runtime.snapshot.connection == .disconnected,
              runtime.snapshot.muted,
              runtime.snapshot.safeErrorCode == "voice_realtime_event_invalid" else {
            throw VoiceFoundationVerificationError.failed("transport_failure_did_not_close_media")
        }
        runtime.beginAudioSession()
        try await waitUntil { adapter.startCount == 3 && runtime.snapshot.connection == .connected }
        guard runtime.snapshot.safeErrorCode == nil else {
            throw VoiceFoundationVerificationError.failed("explicit_start_retry_did_not_clear_failure")
        }
        await runtime.shutdown()
    }

    private static func verifyCapabilityGrantRefresh() async throws {
        let first = FakeVoiceSessionAdapter()
        var factoryCount = 0
        let runtime = VoiceLaneRuntime(restartDelaysNanoseconds: [0])
        await runtime.configure(
            featureEnabled: true,
            preferredLayout: .compact,
            providerID: .codexAppServer,
            adapterFactory: {
                factoryCount += 1
                return first
            }
        ).value
        try await waitUntil { first.startCount == 1 && runtime.snapshot.connection == .connected }
        runtime.capabilityGrantsDidChange()
        try await waitUntil {
            first.capabilityGrantRefreshCount == 1
                && runtime.snapshot.connection == .connected
        }
        guard factoryCount == 1,
              first.stopCount == 0,
              first.startCount == 1 else {
            throw VoiceFoundationVerificationError.failed("capability_grant_restarted_adapter")
        }
        await runtime.shutdown()
    }

    private static func verifyRealtimeCapabilityBrokerRuntime() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hoverpocket-voice-capability-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let calendar = VoiceFakeCalendarDataSource(now: now)
        let timerStore = TimerStore(
            storageDirectory: root.appendingPathComponent("timer", isDirectory: true),
            observesWake: false,
            persistenceEnabled: true
        )
        let handlers = try PocketCapabilityHandlerSet(handlers: [
            CalendarListCapabilityHandler(dataSource: calendar),
            CalendarGetCapabilityHandler(dataSource: calendar),
            CalendarCreateCapabilityHandler(dataSource: calendar),
            TimerCapabilityHandler(operation: .start, store: timerStore),
            TimerCapabilityHandler(operation: .get, store: timerStore),
            TimerCapabilityHandler(operation: .stop, store: timerStore)
        ])
        let registry = try CapabilityRegistry(handlers: handlers)
        let brokerRoot = root.appendingPathComponent("broker", isDirectory: true)
        let broker = CapabilityBroker(
            registry: registry,
            ledger: try CapabilityBrokerLedger(rootDirectory: brokerRoot),
            auditLog: try CapabilityBrokerAuditLog(rootDirectory: brokerRoot)
        )
        let context = VoiceCapabilityContext(registry: registry, broker: broker)
        var approvalCount = 0
        let runtime = try OpenAIRealtimeMacOSCapabilityRuntime(
            context: context,
            calendarAccessGranted: { true },
            timeZoneID: { "Asia/Tokyo" },
            now: { now },
            approvalHandler: { _ in
                approvalCount += 1
                return true
            }
        )
        guard try runtime.sessionTools().count == 3 else {
            throw VoiceFoundationVerificationError.failed("voice_tool_surface")
        }

        let listed = await runtime.execute(
            sessionID: "voice-session",
            callID: "calendar-list-call",
            toolName: OpenAIRealtimeMacOSCapabilityRuntime.calendarListTool,
            argumentsJSON: "{}"
        )
        let listedObject = try voiceJSON(listed)
        guard listedObject["status"] as? String == "succeeded",
              listedObject["readback"] as? String == "verified",
              (listedObject["events"] as? [[String: Any]])?.count == 1 else {
            throw VoiceFoundationVerificationError.failed("voice_calendar_list_readback")
        }

        let created = await runtime.execute(
            sessionID: "voice-session",
            callID: "calendar-create-call",
            toolName: OpenAIRealtimeMacOSCapabilityRuntime.calendarCreateTool,
            argumentsJSON: "{\"title\":\"確認予定\",\"start\":\"2027-01-15T09:00:00+09:00\",\"end\":\"2027-01-15T10:00:00+09:00\",\"isAllDay\":false}"
        )
        let createdObject = try voiceJSON(created)
        guard createdObject["status"] as? String == "succeeded",
              createdObject["readback"] as? String == "verified",
              calendar.createdCount == 1 else {
            throw VoiceFoundationVerificationError.failed("voice_calendar_create_readback")
        }

        let timer = await runtime.execute(
            sessionID: "voice-session",
            callID: "timer-start-call",
            toolName: OpenAIRealtimeMacOSCapabilityRuntime.timerStartTool,
            argumentsJSON: "{\"durationSeconds\":600,\"title\":\"集中\"}"
        )
        let timerObject = try voiceJSON(timer)
        guard timerObject["status"] as? String == "succeeded",
              timerObject["readback"] as? String == "verified",
              timerObject["state"] as? String == "running",
              approvalCount == 2 else {
            throw VoiceFoundationVerificationError.failed("voice_timer_start_readback")
        }
        let replay = await runtime.execute(
            sessionID: "voice-session",
            callID: "timer-start-call",
            toolName: OpenAIRealtimeMacOSCapabilityRuntime.timerStartTool,
            argumentsJSON: "{\"durationSeconds\":600,\"title\":\"集中\"}"
        )
        guard replay == timer, approvalCount == 2 else {
            throw VoiceFoundationVerificationError.failed("voice_tool_idempotency")
        }
        let duplicate = await runtime.execute(
            sessionID: "voice-session",
            callID: "duplicate-json-call",
            toolName: OpenAIRealtimeMacOSCapabilityRuntime.timerStartTool,
            argumentsJSON: "{\"durationSeconds\":60,\"durationSeconds\":120}"
        )
        guard try voiceJSON(duplicate)["code"] as? String == "invalid_arguments" else {
            throw VoiceFoundationVerificationError.failed("voice_duplicate_json_accepted")
        }

        let deniedRuntime = try OpenAIRealtimeMacOSCapabilityRuntime(
            context: context,
            calendarAccessGranted: { false },
            timeZoneID: { "Asia/Tokyo" },
            now: { now },
            approvalHandler: { _ in false }
        )
        guard try deniedRuntime.sessionTools().count == 1 else {
            throw VoiceFoundationVerificationError.failed("voice_calendar_permission_surface")
        }
        let deniedCalendar = await deniedRuntime.execute(
            sessionID: "voice-session-2",
            callID: "calendar-denied-call",
            toolName: OpenAIRealtimeMacOSCapabilityRuntime.calendarListTool,
            argumentsJSON: "{}"
        )
        guard try voiceJSON(deniedCalendar)["code"] as? String == "permission_denied" else {
            throw VoiceFoundationVerificationError.failed("voice_calendar_permission_denied")
        }
        let deniedTimer = await deniedRuntime.execute(
            sessionID: "voice-session-2",
            callID: "timer-denied-call",
            toolName: OpenAIRealtimeMacOSCapabilityRuntime.timerStartTool,
            argumentsJSON: "{\"durationSeconds\":60}"
        )
        guard try voiceJSON(deniedTimer)["code"] as? String == "user_rejected" else {
            throw VoiceFoundationVerificationError.failed("voice_timer_rejection")
        }

        var rejectionCount = 0
        let rateRuntime = try OpenAIRealtimeMacOSCapabilityRuntime(
            context: context,
            calendarAccessGranted: { false },
            timeZoneID: { "Asia/Tokyo" },
            now: { now },
            approvalHandler: { _ in
                rejectionCount += 1
                return false
            }
        )
        var rateCodes: [String] = []
        for index in 0..<4 {
            let result = await rateRuntime.execute(
                sessionID: "rate-session",
                callID: "rate-call-\(index)",
                toolName: OpenAIRealtimeMacOSCapabilityRuntime.timerStartTool,
                argumentsJSON: "{\"durationSeconds\":60,\"title\":\"拒否\"}"
            )
            rateCodes.append(try voiceJSON(result)["code"] as? String ?? "")
        }
        guard rateCodes == ["user_rejected", "user_rejected", "user_rejected", "approval_rate_limited"],
              rejectionCount == 3 else {
            throw VoiceFoundationVerificationError.failed("voice_approval_rate_limit")
        }

        var calendarGranted = true
        var approvalStarted = false
        let cancellationRuntime = try OpenAIRealtimeMacOSCapabilityRuntime(
            context: context,
            calendarAccessGranted: { calendarGranted },
            timeZoneID: { "Asia/Tokyo" },
            now: { now },
            approvalHandler: { _ in
                approvalStarted = true
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    return true
                } catch {
                    return false
                }
            }
        )
        let createdBeforeCancellation = calendar.createdCount
        let pending = Task { @MainActor in
            await cancellationRuntime.execute(
                sessionID: "cancel-session",
                callID: "cancel-calendar-call",
                toolName: OpenAIRealtimeMacOSCapabilityRuntime.calendarCreateTool,
                argumentsJSON: "{\"title\":\"取り消す予定\",\"start\":\"2027-01-15T11:00:00+09:00\",\"end\":\"2027-01-15T12:00:00+09:00\",\"isAllDay\":false}"
            )
        }
        try await waitUntil { approvalStarted }
        calendarGranted = false
        cancellationRuntime.cancelSession("cancel-session")
        let cancelled = await pending.value
        guard try voiceJSON(cancelled)["code"] as? String == "session_cancelled",
              calendar.createdCount == createdBeforeCancellation,
              try cancellationRuntime.sessionTools().count == 1 else {
            throw VoiceFoundationVerificationError.failed("voice_session_cancellation_or_grant_rebuild")
        }
    }

    private static func voiceJSON(_ value: String) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any] else {
            throw VoiceFoundationVerificationError.failed("voice_json_output")
        }
        return object
    }

    private static func verifyAppLifetimeDetachAndRestart() async throws {
        let adapter = FakeVoiceSessionAdapter(startFailuresRemaining: 1)
        let runtime = VoiceLaneRuntime(restartDelaysNanoseconds: [0, 0])
        await runtime.configure(
            featureEnabled: true,
            preferredLayout: .compact,
            providerID: .codexAppServer,
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
            rootSessionID: "root-a",
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
        runtime.appendTranscript(VoiceTranscriptEvent(
            id: "delayed-root-a",
            rootSessionID: "root-a",
            role: .assistant,
            text: "must not cross roots",
            isFinal: true,
            timestamp: Date(timeIntervalSince1970: 1)
        ))
        runtime.appendTranscript(VoiceTranscriptEvent(
            id: "current-root-b",
            rootSessionID: "root-b",
            role: .assistant,
            text: "current root",
            isFinal: true,
            timestamp: Date(timeIntervalSince1970: 2)
        ))
        guard runtime.snapshot.transcript.count == 1,
              runtime.snapshot.transcript.first?.id == "current-root-b"
        else {
            throw VoiceFoundationVerificationError.failed("delayed_transcript_root_isolation")
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
            providerID: .codexAppServer,
            adapterFactory: factory
        )
        try await waitUntil { stale.startCount == 1 }
        let disableTask = runtime.configure(
            featureEnabled: false,
            preferredLayout: .compact,
            providerID: .codexAppServer,
            adapterFactory: nil
        )
        let replacementTask = runtime.configure(
            featureEnabled: true,
            preferredLayout: .compact,
            providerID: .codexAppServer,
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
            providerID: .codexAppServer,
            adapterFactory: { oldAdapter }
        ).value
        try await waitUntil { runtime.snapshot.connection == .connected }

        let disableTask = runtime.configure(
            featureEnabled: false,
            preferredLayout: .compact,
            providerID: .codexAppServer,
            adapterFactory: nil
        )
        try await waitUntil { oldAdapter.stopCount == 1 }
        guard runtime.snapshot != .disabled,
              runtime.snapshot.mode == .compact,
              runtime.snapshot.connection == .recovering
        else {
            throw VoiceFoundationVerificationError.failed("voice_off_published_before_adapter_teardown")
        }

        let replacementTask = runtime.configure(
            featureEnabled: true,
            preferredLayout: .compact,
            providerID: .codexAppServer,
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
            providerID: .codexAppServer,
            adapterFactory: factory
        )
        try await waitUntil { stale.startCount == 1 }

        runtime.recoverAfterSystemTransition()
        try await Task.sleep(nanoseconds: 20_000_000)
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
            providerID: .codexAppServer,
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
            providerID: .codexAppServer,
            adapterFactory: { oldAdapter }
        ).value
        try await waitUntil { runtime.snapshot.connection == .connected }

        runtime.recoverAfterSystemTransition()
        try await waitUntil { oldAdapter.stopCount == 1 }
        let disableTask = runtime.configure(
            featureEnabled: false,
            preferredLayout: .compact,
            providerID: .codexAppServer,
            adapterFactory: nil
        )
        let replacementTask = runtime.configure(
            featureEnabled: true,
            preferredLayout: .compact,
            providerID: .codexAppServer,
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
            providerID: .codexAppServer,
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

private final class CountingOpenAIRealtimeCredentialStore: OpenAIRealtimeCredentialStoring, @unchecked Sendable {
    private(set) var hasCredentialCount = 0
    private(set) var loadCount = 0

    func hasCredential() throws -> Bool {
        hasCredentialCount += 1
        return false
    }

    func load() throws -> OpenAIRealtimeAPIKey? {
        loadCount += 1
        return nil
    }

    func save(_ apiKey: OpenAIRealtimeAPIKey) throws { _ = apiKey }
    func delete() throws { }
}

@MainActor
private final class ExplicitStartVoiceSessionAdapter: VoiceSessionAdapter {
    var requiresExplicitStart: Bool { true }
    private(set) var startCount = 0
    private(set) var closeAudioSessionCount = 0
    private(set) var stopCount = 0
    private(set) var muted = true

    func probeCompatibility() async -> VoiceAdapterGate { .ready }

    func start() async throws {
        startCount += 1
        muted = false
    }

    func setMuted(_ muted: Bool) async {
        self.muted = muted
    }

    func closeAudioSession() async {
        closeAudioSessionCount += 1
        muted = true
    }

    func stop() async {
        stopCount += 1
        muted = true
    }
}

@MainActor
private final class VoiceFakeCalendarDataSource: CalendarCapabilityDataSource {
    private var events: [String: CalendarCapabilityEvent]
    private(set) var createdCount = 0

    init(now: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let startOfDay = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .hour, value: 10, to: startOfDay)!
        let end = calendar.date(byAdding: .hour, value: 1, to: start)!
        let event = CalendarCapabilityEvent(
            eventRef: "event-existing",
            eventID: "google-existing",
            safeTitle: "既存予定",
            start: start,
            end: end
        )
        events = [event.eventRef: event]
    }

    func listEvents(from start: Date, to end: Date) async throws -> [CalendarCapabilityEvent] {
        events.values.filter { $0.start < end && $0.end > start }
    }

    func getEvent(eventRef: String) async throws -> CalendarCapabilityEvent? {
        events[eventRef]
    }

    func createEvent(
        _ request: CalendarCapabilityCreateRequest,
        idempotencyKey: String
    ) async throws -> CalendarCapabilityEvent {
        createdCount += 1
        let event = CalendarCapabilityEvent(
            eventRef: "event-created-\(createdCount)",
            eventID: "google-created-\(createdCount)",
            safeTitle: request.title,
            start: request.start,
            end: request.end,
            isAllDay: request.isAllDay,
            allDayStart: request.allDayStart,
            allDayEnd: request.allDayEnd
        )
        events[event.eventRef] = event
        _ = idempotencyKey
        return event
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
