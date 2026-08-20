#!/usr/bin/env python3
from __future__ import annotations

import itertools
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "contracts" / "voice" / "an3-a-foundation-fixture.json"


def fail(message: str) -> None:
    raise SystemExit(f"FAIL voice-foundation contract: {message}")


def main() -> None:
    fixture = json.loads(FIXTURE.read_text(encoding="utf-8"))
    compact_height = fixture["designTokens"]["compactHeight"]
    provider_kinds = fixture["providerKinds"]
    modes = fixture["modes"]

    matrix_cases = 0
    for os_name, sizes in fixture["baselinePanels"].items():
        expanded_tokens = fixture["designTokens"]["expandedHeight"][os_name]
        for size_name, provider_kind, mode in itertools.product(sizes, provider_kinds, modes):
            baseline = sizes[size_name]
            baseline_provider_rect = (
                0,
                54,
                baseline["width"],
                baseline["height"] - 54,
            )
            extra_height = {
                "disabled": 0,
                "compact": compact_height,
                "expanded": expanded_tokens[size_name],
            }[mode]
            shell = (
                0,
                0,
                baseline["width"],
                baseline["height"] + extra_height,
            )
            provider_rect = (
                0,
                54,
                baseline["width"],
                baseline["height"] - 54,
            )
            if shell[0] != 0 or shell[1] != 0 or shell[2] != baseline["width"]:
                fail(f"{os_name}/{size_name}/{provider_kind}/{mode}: shell anchor changed")
            if provider_rect != baseline_provider_rect:
                fail(f"{os_name}/{size_name}/{provider_kind}/{mode}: provider rect changed")
            if shell[3] - baseline["height"] != extra_height:
                fail(f"{os_name}/{size_name}/{provider_kind}/{mode}: downward height mismatch")
            matrix_cases += 1

    scope = fixture["sessionScope"]
    visible = [
        session["sessionId"]
        for session in scope["sessions"]
        if session["rootSessionId"] == scope["rootSessionId"]
    ]
    if visible != scope["expectedVisibleSessionIds"]:
        fail("root/child/descendant filtering fixture mismatch")

    if fixture["compact"]["visualTitle"]:
        fail("compact must not have a visual title")
    if not fixture["compact"]["explicitToggleOnly"]:
        fail("compact must use an explicit toggle")
    if fixture["expanded"]["fullscreen"]:
        fail("fullscreen must not exist")
    if not fixture["expanded"]["independentInternalScroll"]:
        fail("expanded columns must scroll internally")

    activation = fixture["an3AActivation"]
    forbidden_activation = [
        activation["productionMicrophone"],
        activation["productionWebRtc"],
        activation["brokerToolExecution"],
        activation["mcpExposure"],
        activation["productionRealtimeAdapter"],
    ]
    if not activation["defaultOff"] or any(forbidden_activation):
        fail("AN3-A activation boundary regressed")

    index_html = (ROOT / "windows" / "ui" / "index.html").read_text(encoding="utf-8")
    app_js = (ROOT / "windows" / "ui" / "js" / "app.js").read_text(encoding="utf-8")
    styles = (ROOT / "windows" / "ui" / "styles.css").read_text(encoding="utf-8")
    bridge = (
        ROOT
        / "windows"
        / "src"
        / "HoverPocket.Shell"
        / "Bridge"
        / "PanelBridgeController.cs"
    ).read_text(encoding="utf-8")
    mac_shell = (
        ROOT / "Sources" / "HoverPocket" / "Views" / "HoverPanelShell.swift"
    ).read_text(encoding="utf-8")
    mac_voice = (
        ROOT / "Sources" / "HoverPocket" / "Views" / "VoiceLaneHostView.swift"
    ).read_text(encoding="utf-8")
    mac_runtime = (
        ROOT / "Sources" / "HoverPocket" / "Voice" / "VoiceFoundation.swift"
    ).read_text(encoding="utf-8")
    mac_window = (
        ROOT / "Sources" / "HoverPocket" / "Windowing" / "HoverWindowController.swift"
    ).read_text(encoding="utf-8")
    mac_geometry = (
        ROOT / "Sources" / "HoverPocket" / "Windowing" / "PanelGeometry.swift"
    ).read_text(encoding="utf-8")
    mac_app = (
        ROOT / "Sources" / "HoverPocket" / "App" / "AppDelegate.swift"
    ).read_text(encoding="utf-8")
    windows_app = (
        ROOT / "windows" / "src" / "HoverPocket.Shell" / "App.xaml.cs"
    ).read_text(encoding="utf-8")
    windows_options = (
        ROOT / "windows" / "src" / "HoverPocket.Shell" / "StartupOptions.cs"
    ).read_text(encoding="utf-8")
    windows_client = (
        ROOT
        / "windows"
        / "src"
        / "HoverPocket.Shell"
        / "Voice"
        / "CodexAppServerClient.cs"
    ).read_text(encoding="utf-8")
    windows_coordinator = (
        ROOT
        / "windows"
        / "src"
        / "HoverPocket.Shell"
        / "Voice"
        / "CodexVoiceCoordinator.cs"
    ).read_text(encoding="utf-8")
    windows_verifier = (
        ROOT
        / "windows"
        / "src"
        / "HoverPocket.Shell"
        / "Verification"
        / "VoiceFoundationVerifier.cs"
    ).read_text(encoding="utf-8")
    windows_geometry = (
        ROOT
        / "windows"
        / "src"
        / "HoverPocket.Shell"
        / "Voice"
        / "VoicePanelGeometry.cs"
    ).read_text(encoding="utf-8")
    windows_shell = (
        ROOT
        / "windows"
        / "src"
        / "HoverPocket.Shell"
        / "Windows"
        / "HoverShellController.cs"
    ).read_text(encoding="utf-8")
    windows_settings_html = (
        ROOT / "windows" / "ui" / "settings" / "index.html"
    ).read_text(encoding="utf-8")
    windows_settings_js = (
        ROOT / "windows" / "ui" / "settings" / "settings.js"
    ).read_text(encoding="utf-8")

    provider_pos = index_html.find('data-provider-container')
    voice_pos = index_html.find('data-voice-lane')
    if provider_pos < 0 or voice_pos <= provider_pos:
        fail("Windows Voice Lane is not the Host-owned final row")
    if "hp-ai-lane" in index_html:
        fail("legacy AI command lane DOM is mounted")
    if any(route in app_js or route in bridge for route in (
        '"ailane.submit"',
        '"ailane.approve"',
        '"ailane.reject"',
    )):
        fail("legacy AI command lane route is still mounted")
    if "renderVoiceLane(state)" not in app_js:
        fail("Windows Host Voice renderer missing")
    if ".hp-voice-expanded-grid" not in styles or "overflow: auto" not in styles:
        fail("Windows internal expanded scrolling missing")
    if "fullscreen" in app_js.lower():
        fail("Windows Voice renderer gained a fullscreen route/state")
    if "mute.disabled = Boolean(lane.muted && !lane.transportAttached);" not in app_js:
        fail("Windows unavailable Voice transport can report an unmuted state")
    if "VoiceLaneHostView" not in mac_shell:
        fail("macOS Host Voice row missing")
    if "accessibilityLabel(\"Voice Lane\")" not in mac_voice:
        if "localized(japanese: \"音声レーン\", english: \"Voice Lane\")" not in mac_voice:
            fail("macOS Voice accessibility region missing")
    if "VoiceLaneLocalization" not in mac_voice or "音声接続はAN3-Aではまだ利用できません。" not in mac_voice:
        fail("macOS Voice Japanese/English localization missing")
    if "ScrollView" not in mac_voice:
        fail("macOS Voice internal scroll missing")
    if "accessibilityReduceMotion" not in mac_voice:
        fail("macOS Reduce Motion handling missing")
    if ".disabled(runtime.snapshot.muted && runtime.snapshot.connection != .connected)" not in mac_voice:
        fail("macOS unavailable Voice adapter can report an unmuted state")
    if "prefers-reduced-motion: reduce" not in styles:
        fail("Windows Reduce Motion handling missing")
    if "AVAudio" in mac_runtime or "WebRTC" in mac_runtime:
        fail("AN3-A macOS runtime enabled production audio")
    if "VoiceTranscriptBuffer" not in mac_runtime or "VoiceSessionScope" not in mac_runtime:
        fail("macOS memory/scope contracts missing")
    if "additionalPreviewHeight: voiceLaneHeight(on: screen)" not in mac_window:
        fail("macOS window is not extended downward for Voice Lane")
    show_preview = mac_window[mac_window.find("private func showPreview"):]
    if "VoiceLaneRuntime.shared.attachPanel()" not in show_preview:
        fail("macOS panel show path does not reattach Voice state")
    if "resolvedVoiceLaneLayout(on screen" not in mac_window or "screen.visibleFrame.minY" not in mac_window:
        fail("macOS short-display fallback is not resolved against the target screen")
    if (
        "private func orderOutPreviewWindow(_ previewWindow: NSPanel)" not in mac_window
        or "VoiceLaneRuntime.shared.detachPanel()" not in mac_window
        or mac_window.count("previewWindow.orderOut(nil)") != 1
    ):
        fail("macOS panel hide paths do not converge on Voice detach/mute")
    if "additionalPreviewHeight: CGFloat = 0" not in mac_geometry:
        fail("macOS panel geometry lacks a Voice Lane height input")
    if 'data-voice-enabled' not in windows_settings_html or 'data-voice-layout' not in windows_settings_html:
        fail("Windows Settings Voice controls missing")
    if 'settings.setVoiceEnabled' not in windows_settings_js or 'settings.setVoiceLayout' not in windows_settings_js:
        fail("Windows Settings Voice routes missing")
    if "new AiLaneVerifier().Run()" not in windows_app or "new VoiceFoundationVerifier().Run()" not in windows_app:
        fail("Windows legacy and Voice verifiers are not separate")
    if 'verifyTarget, "voice"' not in windows_options:
        fail("Windows Voice verifier command is not independently addressable")
    if "voiceLane = surface == BridgeSurface.Panel" not in bridge:
        fail("Windows Settings bridge can receive Voice transcript/session state")
    if "voiceLocalizationOk" not in app_js or 't("voiceMicrophoneUnavailable")' not in app_js:
        fail("Windows rendered Voice UI does not verify Japanese and English localized copy")
    if "ReadBoundedLineAsync" not in windows_client or ".ReadLineAsync(" in windows_client:
        fail("Windows app-server response allocation is not bounded before newline parsing")
    if "MaxLineBytes" not in windows_client or "utf8ByteCount" not in windows_client:
        fail("Windows app-server JSONL limit is not enforced in UTF-8 bytes")
    if "DrainStandardErrorAsync" not in windows_client:
        fail("Windows app-server stderr is not drained through a bounded sink")
    handler_position = windows_coordinator.find("candidate.ServerRequestReceived += OnServerRequestReceived;")
    reader_start_position = windows_coordinator.find("candidate.StartReading();", handler_position)
    initialize_position = windows_coordinator.find("candidate.InitializeAsync(", reader_start_position)
    if handler_position < 0 or not handler_position < reader_start_position < initialize_position:
        fail("Windows app-server reader starts before fail-closed handlers are attached")
    if "request-before-reader-start" not in windows_verifier:
        fail("Windows app-server startup request race lacks a deterministic regression")
    if "DisposeDetachedClientAsync" not in windows_coordinator:
        fail("Windows failed/crashed app-server clients are not disposed through one boundary")
    if "RunTrackedRestartAsync" not in windows_coordinator or "CancelRestartAsync" not in windows_coordinator:
        fail("Windows Voice OFF cannot await an in-flight retry startup")
    if "_featureTransitionGate.WaitAsync" not in windows_coordinator \
            or "feature-transition-serialization" not in windows_verifier:
        fail("Windows Voice enable/disable transitions are not serialized")
    if "voice_compatibility_probe_failed" not in windows_coordinator:
        fail("Windows compatibility probe failures do not transition Voice fail-closed")
    request_handler = windows_coordinator[windows_coordinator.find("private void OnServerRequestReceived"):]
    request_handler = request_handler[:request_handler.find("private void OnClientDisconnected")]
    if "ClientGeneration(client)" not in request_handler or "CompareExchange" not in request_handler:
        fail("Windows stale app-server requests can block the active Voice generation")
    if "Task.Run(RunAsync).GetAwaiter().GetResult();" not in windows_verifier:
        fail("Windows Voice verifier can deadlock the WPF synchronization context")
    if (
        "func applicationShouldTerminate" not in mac_app
        or "await VoiceLaneRuntime.shared.shutdown()" not in mac_app
        or "func shutdown() async" not in mac_runtime
    ):
        fail("macOS termination does not await Voice adapter teardown")
    if "private var recoveryTask: Task<Void, Never>?" not in mac_runtime \
            or "await pendingRecovery?.value" not in mac_runtime \
            or "verifyRecoveryTeardownIsSerialized" not in (
                ROOT / "Sources" / "HoverPocket" / "App" / "VoiceFoundationVerificationCommand.swift"
            ).read_text(encoding="utf-8"):
        fail("macOS recovery teardown is not tracked by configuration and shutdown")
    if "private var audioCommandTask: Task<Void, Never>?" not in mac_runtime \
            or "verifyAudioCommandsRemainOrdered" not in (
                ROOT / "Sources" / "HoverPocket" / "App" / "VoiceFoundationVerificationCommand.swift"
            ).read_text(encoding="utf-8"):
        fail("macOS Voice adapter audio commands are not serialized")
    if "let safeErrorCode = VoiceTextSafety.sanitizeErrorCode(" not in mac_runtime:
        fail("macOS adapter error codes bypass the runtime sanitizer")
    if "maxRetainedSessions" not in mac_runtime or "MaxRetainedSessions" not in windows_coordinator:
        fail("Voice session retention is not bounded on both operating systems")
    if "NormalizeTranscriptRole" not in windows_coordinator \
            or '"tool"' not in windows_verifier \
            or "unknown transcript role was published" not in windows_verifier:
        fail("Windows unknown transcript roles can be presented as Host/system content")
    if "expansionBlocked" not in app_js:
        fail("Windows compact fallback does not report why Expanded is unavailable")
    if 'waiting_for_approval: "voiceActivityWaitingForApproval"' not in app_js \
            or 'waiting_for_user: "voiceSessionWaitingForUser"' not in app_js:
        fail("Windows Voice renderer does not localize wire-format activity/session states")
    if "japaneseAvailabilityFallbackOk" not in app_js or "englishAvailabilityFallbackOk" not in app_js:
        fail("Windows Voice renderer does not verify compatibility-specific unavailable copy")
    if "monitor.WorkArea.Bottom" not in windows_geometry:
        fail("Windows Expanded fallback ignores the taskbar work area")
    if "session.progress?.completed" not in app_js or "voiceSessionUpdatedText(session.updatedAt)" not in app_js:
        fail("Windows session cards omit progress or update time")
    if "session.updatedAt.formatted" not in mac_voice:
        fail("macOS session cards omit update time")
    staged_recovery = windows_shell[
        windows_shell.find("private async Task RunStagedRecoveryAsync"):
        windows_shell.find("private async Task RunRecoveryStageAsync")
    ]
    recovery_stage = windows_shell[
        windows_shell.find("private async Task RunRecoveryStageAsync"):
        windows_shell.find("private void OnWindowWin32MessageReceived")
    ]
    if staged_recovery.count(
        "await _panelBridgeController.NotifySystemTransitionAsync(cancellationToken)"
    ) != 1 or "NotifySystemTransitionAsync(" in recovery_stage:
        fail("Windows staged recovery notifies Voice more than once")
    if "transition-cancellation" not in windows_verifier \
            or "cancellationToken.ThrowIfCancellationRequested();" not in windows_coordinator:
        fail("Windows stale staged recovery can schedule a replacement after cancellation")
    mac_verifier = (
        ROOT / "Sources" / "HoverPocket" / "App" / "VoiceFoundationVerificationCommand.swift"
    ).read_text(encoding="utf-8")
    if "await pendingRestart?.value" not in mac_runtime \
            or "verifyRecoveryWaitsForCancelledStartup" not in mac_verifier:
        fail("macOS recovery can overlap a cancelled non-cooperative startup")

    print(
        "PASS voice-foundation contract: "
        f"{matrix_cases} geometry/state cases, root scope, default-off, "
        "legacy lane negative regression, internal scroll, accessibility"
    )


if __name__ == "__main__":
    main()
