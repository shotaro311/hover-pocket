import AppKit
import SwiftUI

@MainActor
enum VoiceActivityVerification {
    private static var previewWindow: NSWindow?
    private static var panelController: HoverWindowController?

    static func run(showPreview: Bool) async throws {
        let runtime = VoiceLaneRuntime.shared
        let adapter = ActivityVoiceAdapter()
        var count = 0
        func check(_ condition: Bool, _ name: String) throws {
            guard condition else { throw VoiceFoundationVerificationError.failed(name) }
            count += 1
        }
        try check(NSImage(systemSymbolName: "person.wave.2.fill", accessibilityDescription: nil) != nil, "conversation_symbol_available")
        try check(!VoiceActivityPresentation(snapshot: .disabled).showsConversation, "voice_off_hidden")
        await runtime.configure(featureEnabled: true, preferredLayout: .compact,
            providerID: .codexAppServer, adapterFactory: { adapter }).value
        try check(!VoiceActivityPresentation(snapshot: runtime.snapshot).showsConversation, "enabled_without_session_hidden")
        runtime.attachPanel()
        runtime.beginAudioSession()
        for _ in 0..<100 where runtime.snapshot.connection != .connected {
            try await Task.sleep(for: .milliseconds(10))
        }
        runtime.setRootSessionID("activity-verification-session")
        let listening = VoiceActivityPresentation(snapshot: runtime.snapshot)
        try check(listening.showsConversation && listening.animates, "connected_listening_animated")
        try check(listening.barHeight(index: 2, time: 0) != listening.barHeight(index: 2, time: 0.4), "waveform_changes_over_time")
        runtime.reportTransportActivity(.speaking)
        let speaking = VoiceActivityPresentation(snapshot: runtime.snapshot)
        try check(speaking.animates && speaking.activity == .speaking, "speaking_animated")
        try check((0..<9).allSatisfy { (3...17).contains(speaking.barHeight(index: $0, time: 1.2)) }, "waveform_bounds")
        runtime.setMuted(true)
        let muted = VoiceActivityPresentation(snapshot: runtime.snapshot)
        try check(muted.showsConversation && muted.muted && !muted.animates, "mute_keeps_indicator_stops_animation")
        try check(muted.barHeight(index: 0, time: 0) == muted.barHeight(index: 0, time: 20), "muted_waveform_static")
        runtime.setMuted(false)
        runtime.setContinueWhenPanelHidden(true)
        runtime.detachPanel()
        try check(VoiceActivityPresentation(snapshot: runtime.snapshot).animates, "hidden_panel_conversation_visible")
        runtime.attachPanel()
        guard let screen = NSScreen.main else { throw VoiceFoundationVerificationError.failed("screen_missing") }
        for center in [screen.frame.midX, screen.frame.midX + 100] {
            let notch = ScreenNotchProfile.actual(minX: center - 90, width: 180, centerX: center)
            let active = PanelGeometry.accessMetrics(on: screen, notchProfile: notch,
                showsNotchSideHandleArea: false, showsVoiceConversation: true)
            try check(active.width == 288 && active.minX == center - 144, "notch_symmetric_wings")
            let plain = PanelGeometry.accessMetrics(on: screen, notchProfile: .none(centerX: center),
                showsNotchSideHandleArea: false, showsVoiceConversation: true)
            try check(plain.width == 108 && plain.height > 0 && plain.height < 33 && plain.minX == center - 54, "no_notch_compact_bar")
        }
        for inset: CGFloat in [22, 24, 28, 32, 38] {
            for scale: CGFloat in [1, 2] {
                let height = PanelGeometry.voiceAccessHeight(topInset: inset, backingScaleFactor: scale)
                try check(height <= inset - 1 / scale && height < PanelLayout.pillHeight,
                    "voice_indicator_within_top_area_\(Int(inset))_\(Int(scale))")
            }
        }
        let inactive = PanelGeometry.accessMetrics(on: screen, notchProfile: .none(centerX: screen.frame.midX),
            showsNotchSideHandleArea: false)
        try check(inactive.width == PanelLayout.miniBarTriggerWidth && inactive.height == PanelLayout.miniBarTriggerHeight, "voice_off_geometry_unchanged")
        let defaults = EphemeralAppSettingsDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.aiNativeEnabled = true
        settings.preferredProviderRawValue = "today-focus"
        settings.lastSelectedProviderRawValue = "today-focus"
        let store = ProviderStore(registry: .builtIn, settings: settings)
        try check(!store.availableManifests.contains { $0.id.rawValue == "today-focus" }, "today_focus_absent_from_settings")
        try check(!store.visibleManifests.contains { $0.id.rawValue == "today-focus" }, "today_focus_absent_from_panel")
        try check(store.selectedProvider != nil && store.selectedPluginID?.rawValue != "today-focus", "removed_provider_selection_falls_back")
        print("voice_activity_verification=passed checks=\(count)")
        if showPreview {
            NSApp.setActivationPolicy(.regular)
            let panel = HoverWindowController(settingsDefaults: EphemeralAppSettingsDefaults(),
                providerRegistry: ProviderRegistry(providers: [CalculatorProvider()]))
            panel.appSettings.voiceEnabled = true
            panel.appSettings.appLanguage = .japanese
            panel.appSettings.showNotchSideHandleArea = true
            panel.showPill()
            panelController = panel
            settings.appLanguage = .japanese
            settings.voiceEnabled = true
            let window = NSWindow(contentRect: NSRect(x: 280, y: 220, width: 560, height: 340),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "HoverPocket 音声表示の検証（音声は接続しません）"
            window.contentView = NSHostingView(rootView: Preview(runtime: runtime, settings: settings))
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            previewWindow = window
            try await Task.sleep(for: .seconds(180))
            window.orderOut(nil)
        }
        try check(!runtime.endAudioSession(expectedRootSessionID: "unrelated-session"), "end_rejects_other_session")
        let bridge = CodexAppServerCapabilityBridge(runtime: EmptyCapabilityRuntime(),
            endVoiceSession: { runtime.endAudioSession(expectedRootSessionID: $0) })
        try check(bridge.dynamicTools.contains { $0.objectValue?["name"]?.stringValue == "voice_session_end" }, "end_tool_advertised")
        let request = CodexAppServerRequest(id: .string("end-voice"), method: "item/tool/call", params: .object([
            "threadId": .string("activity-verification-session"), "turnId": .string("user-end-turn"),
            "callId": .string("end-call"), "tool": .string("voice_session_end"), "arguments": .object([:])
        ]))
        let invalid = CodexAppServerRequest(id: .string("bad-end"), method: "item/tool/call", params: .object([
            "threadId": .string("activity-verification-session"), "turnId": .string("user-end-turn"),
            "callId": .string("bad-end-call"), "tool": .string("voice_session_end"),
            "arguments": .object(["unrecognized": .bool(true)])
        ]))
        if runtime.snapshot.connection == .connected {
            _ = await bridge.handle(request: invalid, context: CodexVoiceToolRequestContext(
                rootThreadID: "activity-verification-session", clientGeneration: 1))
            try check(runtime.snapshot.connection == .connected, "end_rejects_invalid_arguments")
            _ = await bridge.handle(request: request, context: CodexVoiceToolRequestContext(
                rootThreadID: "other-root", clientGeneration: 1))
            try check(runtime.snapshot.connection == .connected, "end_rejects_wrong_request_thread")
        }
        _ = await bridge.handle(request: request, context: CodexVoiceToolRequestContext(
            rootThreadID: "activity-verification-session", clientGeneration: 1))
        for _ in 0..<100 where runtime.snapshot.connection != .disconnected {
            try await Task.sleep(for: .milliseconds(10))
        }
        try check(!VoiceActivityPresentation(snapshot: runtime.snapshot).showsConversation, "ended_session_indicator_hidden")
        try check(runtime.snapshot.muted, "voice_end_muted")
        for _ in 0..<100 where adapter.closeCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
        try check(adapter.closeCount > 0, "voice_end_closes_transport")
        let closedCount = adapter.closeCount
        _ = await bridge.handle(request: request, context: CodexVoiceToolRequestContext(
            rootThreadID: "activity-verification-session", clientGeneration: 1))
        try check(adapter.closeCount == closedCount, "end_replay_does_not_close_again")
        runtime.attachPanel()
        runtime.beginAudioSession()
        for _ in 0..<100 where runtime.snapshot.connection != .connected {
            try await Task.sleep(for: .milliseconds(10))
        }
        runtime.setRootSessionID("new-voice-session")
        _ = await bridge.handle(request: request, context: CodexVoiceToolRequestContext(
            rootThreadID: "activity-verification-session", clientGeneration: 1))
        try check(runtime.snapshot.connection == .connected, "old_end_request_cannot_stop_new_session")
        runtime.endAudioSession()
        await runtime.shutdown()
        print("voice_activity_lifecycle=passed checks=\(count)")
    }

    private struct Preview: View {
        @ObservedObject var runtime: VoiceLaneRuntime
        @ObservedObject var settings: AppSettings
        var body: some View {
            VStack(spacing: 22) {
                Text("ノッチあり / ノッチなし").foregroundStyle(.secondary)
                if VoiceActivityPresentation(snapshot: runtime.snapshot).showsConversation {
                    VoiceAccessIndicator(presentation: VoiceActivityPresentation(snapshot: runtime.snapshot),
                        language: .japanese, notchWidth: 180, height: 31.5)
                        .frame(width: 288)
                    VoiceAccessIndicator(presentation: VoiceActivityPresentation(snapshot: runtime.snapshot), language: .japanese, height: 23)
                        .frame(width: 108)
                }
                VoiceLaneHostView(runtime: runtime, settings: settings)
                    .background(Color(white: 0.08))
                HStack {
                    Button("聞き取り中") { runtime.setMuted(false); runtime.reportTransportActivity(.listening) }
                    Button("応答中") { runtime.setMuted(false); runtime.reportTransportActivity(.speaking) }
                    Button("ミュート") { runtime.setMuted(true) }
                    Button("会話終了") { runtime.endAudioSession() }
                }
            }
            .padding(24)
            .frame(width: 560, height: 340)
            .background(Color(white: 0.16))
            .preferredColorScheme(.dark)
        }
    }
}

@MainActor
private final class ActivityVoiceAdapter: VoiceSessionAdapter {
    var requiresExplicitStart: Bool { true }
    private(set) var closeCount = 0
    func probeCompatibility() async -> VoiceAdapterGate { .ready }
    func start() async throws {}
    func setMuted(_ muted: Bool) async {}
    func closeAudioSession() async { closeCount += 1 }
    func stop() async {}
}

@MainActor
private final class EmptyCapabilityRuntime: OpenAIRealtimeCapabilityExecuting {
    func sessionTools() throws -> [[String: Any]] { [] }
    func execute(sessionID: String, callID: String, toolName: String, argumentsJSON: String) async -> String { "{}" }
    func cancelSession(_ sessionID: String) {}
}
