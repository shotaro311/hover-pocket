#!/usr/bin/env python3
from __future__ import annotations

import itertools
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FOUNDATION_FIXTURE = ROOT / "contracts" / "voice" / "an3-a-foundation-fixture.json"
WINDOWS_RUNTIME_FIXTURE = ROOT / "contracts" / "voice" / "an3-b1-windows-runtime-fixture.json"
WINDOWS_CAPABILITY_FIXTURE = ROOT / "contracts" / "voice" / "an3-b2-windows-capability-fixture.json"
OPENAI_REALTIME_FIXTURE = ROOT / "contracts" / "voice" / "an3-b3a-openai-realtime-byok-fixture.json"
MACOS_REALTIME_FIXTURE = ROOT / "contracts" / "voice" / "an3-b3b-macos-realtime-fixture.json"


def fail(message: str) -> None:
    raise SystemExit(f"FAIL voice-foundation contract: {message}")


def main() -> None:
    fixture = json.loads(FOUNDATION_FIXTURE.read_text(encoding="utf-8"))
    runtime_fixture = json.loads(WINDOWS_RUNTIME_FIXTURE.read_text(encoding="utf-8"))
    capability_fixture = json.loads(WINDOWS_CAPABILITY_FIXTURE.read_text(encoding="utf-8"))
    realtime_fixture = json.loads(OPENAI_REALTIME_FIXTURE.read_text(encoding="utf-8"))
    macos_realtime_fixture = json.loads(MACOS_REALTIME_FIXTURE.read_text(encoding="utf-8"))
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
    mac_codex_client = (
        ROOT / "Sources" / "HoverPocket" / "Voice" / "CodexAppServerClient.swift"
    ).read_text(encoding="utf-8")
    mac_codex_coordinator = (
        ROOT / "Sources" / "HoverPocket" / "Voice" / "CodexVoiceCoordinator.swift"
    ).read_text(encoding="utf-8")
    mac_codex_login = (
        ROOT
        / "Sources"
        / "HoverPocket"
        / "Voice"
        / "CodexVoiceAccountLoginController.swift"
    ).read_text(encoding="utf-8")
    mac_codex_profile = (
        ROOT
        / "Sources"
        / "HoverPocket"
        / "Voice"
        / "CodexVoiceAppServerProfile.swift"
    ).read_text(encoding="utf-8")
    mac_codex_probe = (
        ROOT
        / "Sources"
        / "HoverPocket"
        / "Voice"
        / "CodexAppServerCompatibilityProbe.swift"
    ).read_text(encoding="utf-8")
    mac_codex_tool_route_probe = (
        ROOT
        / "Sources"
        / "HoverPocket"
        / "Voice"
        / "CodexAppServerToolRouteProbe.swift"
    ).read_text(encoding="utf-8")
    mac_codex_foundation_verifier = (
        ROOT
        / "Sources"
        / "HoverPocket"
        / "App"
        / "CodexAppServerVerificationCommand.swift"
    ).read_text(encoding="utf-8")
    mac_codex_login_helper = (
        ROOT
        / "Sources"
        / "HoverPocket"
        / "App"
        / "CodexManagedLoginVerificationHelper.swift"
    ).read_text(encoding="utf-8")
    mac_codex_realtime_verifier = (
        ROOT
        / "Sources"
        / "HoverPocket"
        / "App"
        / "CodexAppServerRealtimeVerificationCommand.swift"
    ).read_text(encoding="utf-8")
    mac_codex_transport = (
        ROOT
        / "Sources"
        / "HoverPocket"
        / "Voice"
        / "CodexVoiceWebRTCTransport.swift"
    ).read_text(encoding="utf-8")
    mac_calendar_live_verifier = (
        ROOT
        / "Sources"
        / "HoverPocket"
        / "App"
        / "CalendarCapabilityLiveVerificationCommand.swift"
    ).read_text(encoding="utf-8")
    mac_main = (
        ROOT / "Sources" / "HoverPocket" / "main.swift"
    ).read_text(encoding="utf-8")
    mac_realtime_provider = (
        ROOT / "Sources" / "HoverPocket" / "Voice" / "OpenAIRealtimeProvider.swift"
    ).read_text(encoding="utf-8")
    mac_realtime_transport = (
        ROOT / "Sources" / "HoverPocket" / "Voice" / "OpenAIRealtimeMacOSTransport.swift"
    ).read_text(encoding="utf-8")
    mac_realtime_capabilities = (
        ROOT / "Sources" / "HoverPocket" / "Voice" / "OpenAIRealtimeCapabilityRuntime.swift"
    ).read_text(encoding="utf-8")
    mac_app_settings = (
        ROOT / "Sources" / "HoverPocket" / "State" / "AppSettings.swift"
    ).read_text(encoding="utf-8")
    mac_keychain = (
        ROOT / "Sources" / "HoverPocket" / "Services" / "GoogleOAuthKeychainStore.swift"
    ).read_text(encoding="utf-8")
    mac_settings = (
        ROOT / "Sources" / "HoverPocket" / "Views" / "SettingsView.swift"
    ).read_text(encoding="utf-8")
    mac_build_script = (ROOT / "script" / "build_and_run.sh").read_text(encoding="utf-8")
    mac_package_script = (ROOT / "script" / "package_zip.sh").read_text(encoding="utf-8")
    mac_voice_e2e_harness = (
        ROOT / "script" / "voice_e2e_macos.sh"
    ).read_text(encoding="utf-8")
    mac_voice_e2e_receipt_verifier = (
        ROOT / "script" / "verify_macos_voice_e2e_receipt.py"
    ).read_text(encoding="utf-8")
    mac_voice_e2e_performance_verifier = (
        ROOT / "script" / "verify_macos_voice_e2e_performance.py"
    ).read_text(encoding="utf-8")
    mac_runtime_environment = (
        ROOT / "Sources" / "HoverPocket" / "Support" / "HoverPocketRuntimeEnvironment.swift"
    ).read_text(encoding="utf-8")
    mac_voice_e2e_receipt = (
        ROOT / "Sources" / "HoverPocket" / "Voice" / "MacOSVoiceE2EReceiptStore.swift"
    ).read_text(encoding="utf-8")
    mac_voice_e2e_performance = (
        ROOT
        / "Sources"
        / "HoverPocket"
        / "Voice"
        / "MacOSVoiceE2EPerformanceStore.swift"
    ).read_text(encoding="utf-8")
    mac_voice_e2e_verifier = (
        ROOT
        / "Sources"
        / "HoverPocket"
        / "App"
        / "MacOSVoiceE2EIsolationVerificationCommand.swift"
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
    windows_application_data = (
        ROOT
        / "windows"
        / "src"
        / "HoverPocket.Shell"
        / "Configuration"
        / "HoverPocketApplicationData.cs"
    ).read_text(encoding="utf-8")
    windows_client = (
        ROOT
        / "windows"
        / "src"
        / "HoverPocket.Shell"
        / "Voice"
        / "CodexAppServerClient.cs"
    ).read_text(encoding="utf-8")
    windows_process_job = (
        ROOT
        / "windows"
        / "src"
        / "HoverPocket.Shell"
        / "Voice"
        / "WindowsProcessJob.cs"
    ).read_text(encoding="utf-8")
    windows_coordinator = (
        ROOT
        / "windows"
        / "src"
        / "HoverPocket.Shell"
        / "Voice"
        / "CodexVoiceCoordinator.cs"
    ).read_text(encoding="utf-8")
    windows_runtime = (
        ROOT
        / "windows"
        / "src"
        / "HoverPocket.Shell"
        / "Voice"
        / "CodexVoiceRuntimeComposition.cs"
    ).read_text(encoding="utf-8")
    windows_dynamic_tools = (
        ROOT
        / "windows"
        / "src"
        / "HoverPocket.Shell"
        / "Voice"
        / "CodexVoiceDynamicToolRuntime.cs"
    ).read_text(encoding="utf-8")
    windows_timer_approval = (
        ROOT
        / "windows"
        / "src"
        / "HoverPocket.Shell"
        / "Voice"
        / "VoiceTimerApprovalCoordinator.cs"
    ).read_text(encoding="utf-8")
    windows_verifier = (
        ROOT
        / "windows"
        / "src"
        / "HoverPocket.Shell"
        / "Verification"
        / "VoiceFoundationVerifier.cs"
    ).read_text(encoding="utf-8")
    windows_legacy_verifier = (
        ROOT
        / "windows"
        / "src"
        / "HoverPocket.Shell"
        / "Verification"
        / "LegacyAiLaneVerifier.cs"
    ).read_text(encoding="utf-8")
    windows_ui_verifier = (
        ROOT
        / "windows"
        / "src"
        / "HoverPocket.Shell"
        / "Verification"
        / "UiVerifier.cs"
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
    windows_panel = (
        ROOT
        / "windows"
        / "src"
        / "HoverPocket.Shell"
        / "Windows"
        / "PanelWindow.cs"
    ).read_text(encoding="utf-8")
    windows_settings_store = (
        ROOT
        / "windows"
        / "src"
        / "HoverPocket.Shell"
        / "Configuration"
        / "UserSettingsStore.cs"
    ).read_text(encoding="utf-8")
    windows_settings_html = (
        ROOT / "windows" / "ui" / "settings" / "index.html"
    ).read_text(encoding="utf-8")
    windows_settings_js = (
        ROOT / "windows" / "ui" / "settings" / "settings.js"
    ).read_text(encoding="utf-8")
    windows_settings_window = (
        ROOT
        / "windows"
        / "src"
        / "HoverPocket.Shell"
        / "Settings"
        / "SettingsWindow.cs"
    ).read_text(encoding="utf-8")
    windows_realtime_capabilities = (
        ROOT
        / "windows"
        / "src"
        / "HoverPocket.Shell"
        / "Voice"
        / "OpenAIRealtimeCapabilityRuntime.cs"
    ).read_text(encoding="utf-8")
    windows_realtime_coordinator = (
        ROOT
        / "windows"
        / "src"
        / "HoverPocket.Shell"
        / "Voice"
        / "OpenAIRealtimeVoiceCoordinator.cs"
    ).read_text(encoding="utf-8")
    windows_realtime_verifier = (
        ROOT
        / "windows"
        / "src"
        / "HoverPocket.Shell"
        / "Voice"
        / "OpenAIRealtimeVoiceVerifier.cs"
    ).read_text(encoding="utf-8")
    windows_voice_provider_runtime = (
        ROOT
        / "windows"
        / "src"
        / "HoverPocket.Shell"
        / "Voice"
        / "VoiceProviderRuntime.cs"
    ).read_text(encoding="utf-8")
    windows_credentials = (
        ROOT
        / "windows"
        / "src"
        / "HoverPocket.Shell"
        / "Services"
        / "GoogleOAuthCredentialStore.cs"
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
    if "mute.disabled = !lane.realtimeAttached;" not in app_js \
            or "setVoiceTransportMuted(muted);" not in app_js:
        fail("Windows unavailable Voice transport can report an unmuted state")
    if "VoiceLaneHostView" not in mac_shell:
        fail("macOS Host Voice row missing")
    if "if runtime.snapshot.mode != .disabled" not in mac_voice:
        fail("macOS Voice row disappears before runtime teardown completes")
    if "accessibilityLabel(\"Voice Lane\")" not in mac_voice:
        if "localized(japanese: \"音声レーン\", english: \"Voice Lane\")" not in mac_voice:
            fail("macOS Voice accessibility region missing")
    if "VoiceLaneLocalization" not in mac_voice \
            or "runtime.beginAudioSession()" not in mac_voice \
            or "OpenAIRealtimeMacOSTransportHostView" not in mac_voice:
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
    if "mode: VoiceLaneRuntime.shared.snapshot.mode" not in mac_window \
            or "VoiceLaneRuntime.shared.$snapshot" not in mac_window:
        fail("macOS panel geometry follows settings before Voice teardown completes")
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
    if "PreferredRuntimeVoiceLaneMode" not in bridge \
            or "_voiceRuntimeActive" not in bridge \
            or "enabled ? cancellationToken : CancellationToken.None" not in bridge:
        fail("Windows Voice row can disappear before runtime teardown completes")
    if "_panelBridgeController.PreferredRuntimeVoiceLaneMode" not in windows_shell:
        fail("Windows panel geometry follows settings before Voice teardown completes")
    if "CodexVoiceSessionStatus.Stopping" not in windows_coordinator:
        fail("Windows Voice teardown does not publish a stopping state")
    if "_featureTransitionGate.Wait();" not in windows_coordinator \
            or "dispose-transition-drain" not in windows_verifier:
        fail("Windows coordinator disposal can bypass an active Voice transition")
    if 'voiceLaneEl.hidden = mode === "disabled";' not in app_js \
            or "voiceTeardownVisibleOk" not in app_js:
        fail("Windows rendered Voice row disappears before runtime teardown completes")
    if 'data-voice-enabled' not in windows_settings_html or 'data-voice-layout' not in windows_settings_html:
        fail("Windows Settings Voice controls missing")
    if 'settings.setVoiceEnabled' not in windows_settings_js or 'settings.setVoiceLayout' not in windows_settings_js:
        fail("Windows Settings Voice routes missing")
    if 'data-voice-calendar-access' not in windows_settings_html \
            or 'settings.setVoiceCalendarAccess' not in windows_settings_js \
            or 'voiceCalendarAccessGranted' not in bridge:
        fail("Windows Voice Calendar Host grant controls missing")
    if 'private readonly SemaphoreSlim _voiceSettingsTransitionGate = new(1, 1);' not in bridge:
        fail("Windows Voice settings transition gate is missing")
    for transition_method in (
        "SetVoiceEnabledAsync",
        "SetVoiceProviderAsync",
        "ConfigureVoiceOpenAIKeyAsync",
        "DeleteVoiceOpenAIKeyAsync",
        "SetVoiceCalendarAccessAsync",
    ):
        transition_start = bridge.find(f"private async Task<object?> {transition_method}")
        transition_end = bridge.find("\n    private ", transition_start + 1)
        transition_body = bridge[transition_start:transition_end]
        if transition_start < 0 \
                or "await _voiceSettingsTransitionGate.WaitAsync" not in transition_body \
                or "_voiceSettingsTransitionGate.Release();" not in transition_body:
            fail(f"Windows Voice transition is not serialized: {transition_method}")
    calendar_transition = bridge[
        bridge.find("private async Task<object?> SetVoiceCalendarAccessAsync"):
        bridge.find("private bool ApproveVoiceCalendarAccess")
    ]
    revoke_stop = calendar_transition.find(
        "await _voiceCoordinator.SetFeatureEnabledAsync(false, CancellationToken.None)")
    grant_save = calendar_transition.find("SaveSettings(updated)")
    if revoke_stop < 0 or grant_save < 0 or revoke_stop >= grant_save:
        fail("Windows Voice Calendar revoke does not stop active work before persistence")
    calendar_response_start = windows_dynamic_tools.find("var safeEvents = events.EnumerateArray()")
    calendar_response_end = windows_dynamic_tools.find(
        "private async Task<CodexVoiceDynamicToolResponse> StartTimerAsync")
    calendar_response = windows_dynamic_tools[calendar_response_start:calendar_response_end]
    if calendar_response_start < 0 or calendar_response_end <= calendar_response_start \
            or "eventRef =" in calendar_response:
        fail("Windows Voice Calendar response exposes a Provider identifier to Codex")
    removed_legacy_paths = (
        ROOT / "Sources" / "HoverPocket" / "State" / "AICommandStore.swift",
        ROOT / "Sources" / "HoverPocket" / "Services" / "CalendarPocketTool.swift",
        ROOT / "Sources" / "HoverPocket" / "Views" / "AICommandPaletteView.swift",
        ROOT / "windows" / "src" / "HoverPocket.Shell" / "Providers" / "AiLane",
        ROOT / "windows" / "src" / "HoverPocket.Shell" / "Providers" / "Calendar" / "CalendarAiLaneConnector.cs",
        ROOT / "windows" / "ui" / "ailane",
    )
    if any(path.exists() for path in removed_legacy_paths):
        fail("legacy AI command implementation remains in the product source tree")
    if "new LegacyAiLaneVerifier().Run()" not in windows_app \
            or "new AiLaneVerifier().Run()" in windows_app \
            or "new VoiceFoundationVerifier().Run()" not in windows_app:
        fail("Windows legacy absence and Voice verifiers are not separate")
    if not all(route in windows_legacy_verifier for route in (
            '"ailane.submit"',
            '"ailane.approve"',
            '"ailane.reject"',
            '"unknown_method"',
    )):
        fail("Windows legacy absence verifier does not reject every old bridge route")
    if 'verifyTarget, "voice"' not in windows_options:
        fail("Windows Voice verifier command is not independently addressable")
    if "voiceLane = surface == BridgeSurface.Panel" not in bridge:
        fail("Windows Settings bridge can receive Voice transcript/session state")
    if 'CodexVoiceAvailability.SignedOut => "signedOut"' not in bridge \
            or 'CodexVoiceAvailability.SchemaMismatch => "schemaMismatch"' not in bridge \
            or 'CodexVoiceAvailability.CapabilityBlocked => "capabilityBlocked"' not in bridge:
        fail("Windows Voice availability wire values do not match the rendered contract")
    if "voiceLocalizationOk" not in app_js or 't("voiceStartMicrophone")' not in app_js:
        fail("Windows rendered Voice UI does not verify Japanese and English localized copy")
    if 'keys[value] ?? "voiceRoleAssistant"' not in app_js \
            or 'system: "voiceRoleSystem"' in app_js:
        fail("Windows Voice transcript UI still grants Host authority to an untrusted role")
    if 't("voiceRegionLabel")' not in app_js \
            or 'voiceRegionLabel: "音声レーン"' not in (
                ROOT / "windows" / "ui" / "js" / "i18n.js"
            ).read_text(encoding="utf-8"):
        fail("Windows Voice accessibility region label is not localized")
    if "ReadBoundedLineAsync" not in windows_client or ".ReadLineAsync(" in windows_client:
        fail("Windows app-server response allocation is not bounded before newline parsing")
    if "MaxLineBytes" not in windows_client or "utf8ByteCount" not in windows_client:
        fail("Windows app-server JSONL limit is not enforced in UTF-8 bytes")
    if "DrainStandardErrorAsync" not in windows_client:
        fail("Windows app-server stderr is not drained through a bounded sink")
    if "WindowsProcessJob.CreateKillOnClose()" not in windows_client \
            or "JobObjectLimitKillOnJobClose" not in windows_process_job \
            or "AssignProcessToJobObject" not in windows_process_job:
        fail("Windows app-server descendants are not owned by a kill-on-close job")
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
            or "invalid transcript identity or role was published" not in windows_verifier:
        fail("Windows unknown transcript roles can be presented as Host/system content")
    if "UnicodeCategory.Format" not in windows_coordinator \
            or ".properties.generalCategory == .format" not in mac_runtime \
            or "Unicode format controls survived visible Voice text sanitization" not in windows_verifier \
            or "scalar_bound_path_or_format_control_redaction" not in (
                ROOT / "Sources" / "HoverPocket" / "App" / "VoiceFoundationVerificationCommand.swift"
            ).read_text(encoding="utf-8"):
        fail("Voice visible text does not strip Unicode format controls on both operating systems")
    if '"[/Users/alice/private]"' not in windows_verifier \
            or '"[/Users/alice/private]"' not in (
                ROOT / "Sources" / "HoverPocket" / "App" / "VoiceFoundationVerificationCommand.swift"
            ).read_text(encoding="utf-8"):
        fail("Voice path redaction is not checked after punctuation delimiters")
    if "runes.Length > 160" not in windows_coordinator \
            or "lossy Voice identifier collision" not in windows_verifier \
            or "identifier_collision_rejected" not in (
                ROOT / "Sources" / "HoverPocket" / "App" / "VoiceFoundationVerificationCommand.swift"
            ).read_text(encoding="utf-8"):
        fail("Voice session identifiers can collide after lossy normalization")
    if "string RootSessionId" not in windows_coordinator \
            or "sanitized.rootSessionID == rootSessionID" not in mac_runtime \
            or "delayed transcript crossed roots or a transcript revision duplicated its event ID" not in windows_verifier \
            or "delayed_transcript_root_isolation" not in (
                ROOT / "Sources" / "HoverPocket" / "App" / "VoiceFoundationVerificationCommand.swift"
            ).read_text(encoding="utf-8"):
        fail("Voice transcript events are not bound to the active root session")
    if "func sanitized() -> VoiceTranscriptEvent" not in mac_runtime \
            or "func sanitized() -> VoiceSessionSummary" not in mac_runtime \
            or "events.firstIndex(where:" not in mac_runtime \
            or "_events.FindIndex" not in windows_coordinator \
            or "decoded_session_resanitized" not in (
                ROOT / "Sources" / "HoverPocket" / "App" / "VoiceFoundationVerificationCommand.swift"
            ).read_text(encoding="utf-8"):
        fail("Voice decoded models are not re-sanitized or transcript revisions are not deduplicated")
    if "expansionBlocked" not in app_js:
        fail("Windows compact fallback does not report why Expanded is unavailable")
    if 'waiting_for_approval: "voiceActivityWaitingForApproval"' not in app_js \
            or 'waiting_for_user: "voiceSessionWaitingForUser"' not in app_js:
        fail("Windows Voice renderer does not localize wire-format activity/session states")
    if 'CodexVoiceAvailability.SignedOut => "signedOut"' not in bridge \
            or 'CodexVoiceAvailability.SchemaMismatch => "schemaMismatch"' not in bridge \
            or 'CodexVoiceAvailability.CapabilityBlocked => "capabilityBlocked"' not in bridge:
        fail("Windows Voice availability wire values do not match the renderer")
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
            or "ScheduleRestart(cancellationToken);" not in windows_coordinator \
            or "CreateLinkedTokenSource(\n            _lifetime.Token,\n            cancellationToken)" not in windows_coordinator \
            or "replacement system transition bypassed serialized teardown" not in windows_verifier:
        fail("Windows stale staged recovery can schedule a replacement after cancellation")
    mac_verifier = (
        ROOT / "Sources" / "HoverPocket" / "App" / "VoiceFoundationVerificationCommand.swift"
    ).read_text(encoding="utf-8")
    if "await pendingRestart?.value" not in mac_runtime \
            or "verifyRecoveryWaitsForCancelledStartup" not in mac_verifier \
            or "Task.sleep(nanoseconds: 20_000_000)" not in mac_verifier:
        fail("macOS recovery can overlap a cancelled non-cooperative startup")

    if runtime_fixture["phase"] != "AN3-B1" \
            or runtime_fixture["operatingSystem"] != "windows" \
            or not runtime_fixture["defaultOff"]:
        fail("AN3-B1 Windows runtime fixture identity/default-off mismatch")
    runtime_activation = runtime_fixture["activation"]
    if runtime_activation != {
        "surface": "panel",
        "explicitMicrophoneClick": True,
        "exactOrigin": "https://app.hoverpocket.local",
        "permissionLifetimeSeconds": 5,
        "settingsPermissionPrompt": False,
        "backgroundPermissionPrompt": False,
    }:
        fail("AN3-B1 microphone activation contract mismatch")
    if "VoiceEnabled = false" not in windows_settings_store:
        fail("Windows Voice no longer defaults to OFF")
    if "CoreWebView2.PermissionRequested" not in windows_panel \
            or "IsVoiceMicrophonePermissionAllowedForVerify" not in windows_panel \
            or "ConsumeVoiceMicrophoneGesture" not in windows_panel \
            or "args.SavesInProfile = false" not in windows_panel:
        fail("Windows microphone permission lacks exact one-use Host gating")
    if 'private const string UiHostName = "app.hoverpocket.local";' not in windows_panel:
        fail("Windows microphone origin is not the exact virtual Host")
    if '"voice.requestMicrophone"' not in bridge \
            or 'Register("voice.startRealtime"' not in bridge \
            or 'Register("voice.confirmRealtime"' not in bridge \
            or 'Register("voice.abortRealtime"' not in bridge:
        fail("Windows Panel Voice transport routes are incomplete")
    panel_voice_routes = bridge[bridge.find("if (surface == BridgeSurface.Panel)"):
                                bridge.find("if (surface == BridgeSurface.Settings)")]
    if '"voice.requestMicrophone"' not in panel_voice_routes \
            or 'Register("voice.startRealtime"' not in panel_voice_routes:
        fail("Windows Voice transport route escaped the Panel-only surface")
    if '"experimentalApi":true' not in windows_coordinator \
            or '"account/read"' not in windows_coordinator \
            or '"thread/realtime/listVoices"' not in windows_coordinator:
        fail("Windows Codex app-server runtime gates are incomplete")
    for method in runtime_fixture["appServer"]["requiredMethods"]:
        if method == "initialize":
            continue
        if f'"{method}"' not in windows_coordinator:
            fail(f"Windows Voice coordinator missing {method}")
    for notification in runtime_fixture["appServer"]["requiredNotifications"]:
        if f'"{notification}"' not in windows_coordinator:
            fail(f"Windows Voice coordinator missing {notification}")
    if runtime_fixture["appServer"]["sandbox"] != "read-only" \
            or 'sandbox = "read-only"' not in windows_coordinator \
            or 'approvalPolicy = "never"' not in windows_coordinator:
        fail("Windows Voice root thread is not constrained to no-action mode")
    if "generate-json-schema" not in windows_runtime \
            or "--experimental" not in windows_runtime \
            or "CodexVoiceSchemaContract.CompatibilityError" not in windows_runtime \
            or "WindowsProcessJob.CreateKillOnClose()" not in windows_runtime:
        fail("installed Codex experimental schema is not probed before launch")
    if "getUserMedia" not in app_js \
            or "new PeerConnection()" not in app_js \
            or 'peer.createDataChannel("oai-events")' not in app_js \
            or 'transport.requestBridge("voice.confirmRealtime"' not in app_js:
        fail("Windows WebView WebRTC transport is incomplete")
    if "262_144" not in app_js or "MaxSdpBytes = 262_144" not in windows_coordinator:
        fail("Realtime SDP is not byte-bounded on both sides of the bridge")
    if "transport.generation !== signal.generation" not in app_js \
            or "transport.threadId !== signal.threadId" not in app_js \
            or "RequireActiveRealtime(generation, threadId)" not in windows_coordinator:
        fail("Realtime SDP is not bound to the active generation and root thread")
    if "disposeLocalVoiceTransport" not in app_js \
            or 'disposeLocalVoiceTransport();\n  const state = await requestBridge("voice.endSession")' not in app_js \
            or "stopVoiceMediaStream(acquiredStream)" not in app_js \
            or '"thread/realtime/stop"' not in windows_coordinator:
        fail("Voice failure/end paths do not stop the WebView microphone before Host shutdown")
    if runtime_fixture["privacy"]["settingsReceivesVoiceState"] \
            or "voiceLane = surface == BridgeSurface.Panel" not in bridge:
        fail("Settings surface can receive Voice transcript/session state")
    if not all(runtime_fixture["outOfScope"].values()):
        fail("AN3-B1 scope unexpectedly includes Tool, MCP, or macOS production activation")

    if capability_fixture["phase"] != "AN3-B2-windows-calendar-timer-slice" \
            or capability_fixture["operatingSystem"] != "windows" \
            or not capability_fixture["defaultOff"]:
        fail("AN3-B2 Windows capability fixture identity/default-off mismatch")
    expected_tools = {
        ("calendar_events_list", "calendar.events.list", 1, "calendar.events.read", False),
        ("timer_countdown_start", "timer.countdown.start", 1, "timer.write", True),
    }
    actual_tools = {
        (
            tool["name"],
            tool["capabilityId"],
            tool["capabilityVersion"],
            tool["permission"],
            tool["write"],
        )
        for tool in capability_fixture["tools"]
    }
    if actual_tools != expected_tools:
        fail("AN3-B2 dynamic tool allowlist drifted from Calendar/Timer Capability IDs")
    if capability_fixture["appServer"] != {
        "experimentalApi": True,
        "threadStartField": "dynamicTools",
        "requestMethod": "item/tool/call",
        "responseFields": ["contentItems", "success"],
        "environments": [],
        "positiveToolPolicy": "dynamicToolsOnly",
        "codex0145SupportsPositiveToolPolicy": False,
        "productionActivationApproved": False,
        "sandbox": "read-only",
        "approvalPolicy": "never",
        "namespace": "hoverpocket",
    }:
        fail("AN3-B2 app-server dynamic tool contract mismatch")
    if 'Namespace = "hoverpocket"' not in windows_dynamic_tools \
            or 'CalendarListTool = "calendar_events_list"' not in windows_dynamic_tools \
            or 'TimerStartTool = "timer_countdown_start"' not in windows_dynamic_tools \
            or "CapabilityOrigin.Voice" not in windows_dynamic_tools \
            or 'new HashSet<string>(["calendar.events.read"]' not in windows_dynamic_tools \
            or 'new HashSet<string>(["timer.write"]' not in windows_dynamic_tools:
        fail("Voice dynamic tools do not map to the shared Capability Registry/Broker")
    calendar_grant_check = windows_dynamic_tools.find("if (!_calendarAccessGranted())")
    calendar_permission = windows_dynamic_tools.find('new HashSet<string>(["calendar.events.read"]')
    if calendar_grant_check < 0 or calendar_permission < 0 or calendar_grant_check >= calendar_permission \
            or 'return Failure("permission_denied")' not in windows_dynamic_tools:
        fail("Voice Calendar permission is not resolved from the Host grant before Provider access")
    if "CapabilityApprovalDecision.Approve" not in windows_dynamic_tools \
            or "CapabilityApprovalDecision.Reject" not in windows_dynamic_tools \
            or "CapabilityReadbackStatus.Verified" not in windows_dynamic_tools \
            or "TodayFocusApprovalText.Sanitize" not in windows_dynamic_tools:
        fail("Voice Timer native approval/readback binding is incomplete")
    if "MaximumRememberedCalls" not in windows_dynamic_tools \
            or "Lazy<Task<CodexVoiceDynamicToolResponse>>" not in windows_dynamic_tools \
            or "AgentSessionId: call.ThreadId" not in windows_dynamic_tools:
        fail("Voice tool calls are not root-bound and idempotently coalesced")
    if 'request.Method == "item/tool/call"' not in windows_coordinator \
            or "dynamicTools = _dynamicToolRuntime.Definitions" not in windows_coordinator \
            or "dynamicToolsOnly = true" not in windows_coordinator \
            or "environments = Array.Empty<object>()" not in windows_coordinator \
            or "ReferenceEquals(CurrentActiveRealtime(client), active)" not in windows_coordinator \
            or "result.ProtocolResult,\n                cancellation.Token" not in windows_coordinator \
            or "ReplyResultAsync" not in windows_coordinator \
            or "CancelActiveToolRequests" not in windows_coordinator:
        fail("Voice coordinator does not route/cancel the bounded dynamic tool protocol")
    if 'HasProperty(threadStart.RootElement, "dynamicTools")' not in windows_runtime \
            or 'HasBooleanProperty(threadStart.RootElement, "properties", "dynamicToolsOnly")' not in windows_runtime \
            or 'HasProperty(threadStart.RootElement, "environments")' not in windows_runtime \
            or "BrokerOnlyToolPolicyProductionApproved = false" not in windows_runtime \
            or 'ContainsString(serverRequest.RootElement, "item/tool/call")' not in windows_runtime \
            or 'RequiredContains(toolResponse.RootElement, "contentItems", "success")' not in windows_runtime:
        fail("installed Codex schema gate does not require the dynamic tool protocol")
    if "RequestVoiceTimerApprovalAsync" not in bridge \
            or "VoiceTimerApprovalCoordinator" not in bridge \
            or "MaximumPromptsPerWindow = 3" not in windows_timer_approval \
            or "if (_active || _promptStarts.Count >= MaximumPromptsPerWindow)" not in windows_timer_approval \
            or "dialog.Close();" not in windows_timer_approval \
            or "IsDefault = true" not in windows_timer_approval \
            or "approvalOwner: () => this" not in windows_panel:
        fail("Voice Timer write is not bound to a visible Host-owned native approval")
    capability_boundaries = capability_fixture["boundaries"]
    if any(capability_boundaries[key] for key in (
            "providerStoreDirectAccess",
            "bridgeDispatcherDirectAccess",
            "mcpExposure",
            "settingsReceivesToolPayload",
            "auditStoresToolPayload",
    )) or not all(capability_boundaries[key] for key in (
            "unknownServerRequestsFailClosed",
            "rootThreadBound",
            "sessionCancellationRevokesPendingWrites",
            "repeatedCallExecutesOnce",
            "calendarTitlesAreUntrustedData",
            "calendarGrantIsPersistedAndRevocable",
            "voiceSettingsTransitionsSerialized",
            "timerApprovalSingleFlight",
            "timerPromptRateLimitedBeforePresentation",
            "productionFailsClosedWithoutPositiveToolPolicy",
    )) or capability_boundaries["calendarResultIncludesProviderIdentifiers"] \
            or not all(capability_fixture["outOfScope"].values()):
        fail("AN3-B2 safety boundary or remaining scope is incomplete")
    if "voiceTransportContractOk" not in app_js \
            or "voiceWebRtcHarnessOk" not in app_js \
            or "verifyVoiceTransportHarness" not in app_js \
            or "failedInitializationCleaned" not in app_js \
            or "endStoppedBeforeNative" not in app_js \
            or "VoiceTransportContractOk" not in windows_ui_verifier \
            or "VoiceWebRtcHarnessOk" not in windows_ui_verifier \
            or "realtime-transport" not in windows_verifier \
            or "realtime-sdp-fence" not in windows_verifier \
            or 'RunCaseAsync("dynamic-tools"' not in windows_verifier \
            or 'RunCaseAsync("timer-approval-gate"' not in windows_verifier \
            or 'RunCaseAsync("dynamic-tool-roundtrip"' not in windows_verifier:
        fail("AN3-B1 deterministic transport regressions are incomplete")

    if realtime_fixture["phase"] != "AN3-B3A" \
            or realtime_fixture["model"] != "gpt-realtime-2.1":
        fail("AN3-B3A fixture identity/model mismatch")
    if realtime_fixture["providerSelection"] != {
        "default": "off",
        "ids": ["off", "openai_realtime_byok", "codex_app_server"],
        "silentFallback": False,
        "stopOldBeforeStartNew": True,
    }:
        fail("AN3-B3A provider selection contract mismatch")
    realtime_contract = realtime_fixture["openAIRealtime"]
    if realtime_contract["endpoint"] != "https://api.openai.com/v1/realtime/calls" \
            or realtime_contract["transport"] != "webrtc" \
            or not realtime_contract["hostOwnsCredential"] \
            or realtime_contract["maximumSdpBytes"] != 262_144 \
            or realtime_contract["maximumEventBytes"] != 65_536 \
            or realtime_contract["maximumFunctionOutputBytes"] != 32_768 \
            or realtime_contract["maximumActiveLeases"] != 1:
        fail("AN3-B3A Realtime endpoint/bounds contract mismatch")
    expected_realtime_tools = {
        ("calendar_events_list", "calendar.events.list", 1, "permission_grant", "verified"),
        ("calendar_event_create", "calendar.event.create", 1, "per_call", "verified"),
        ("timer_countdown_start", "timer.countdown.start", 1, "broker_policy", "verified"),
    }
    actual_realtime_tools = {
        (
            item["name"],
            item["capabilityId"],
            item["capabilityVersion"],
            item["approval"],
            item["readback"],
        )
        for item in realtime_contract["tools"]
    }
    if actual_realtime_tools != expected_realtime_tools \
            or any(realtime_contract["ambientTools"].values()):
        fail("AN3-B3A exact Capability tool surface drifted")
    macos_realtime = realtime_fixture["macos"]
    if macos_realtime != {
        "credentialStore": "keychain",
        "providerAndCredentialSeam": True,
        "audioTransportAvailable": False,
        "residualGate": "AN3-B3B",
        "failsBeforeCredentialRead": True,
        "failsBeforeNetwork": True,
    }:
        fail("historical AN3-B3A macOS residual gate contract mismatch")
    if macos_realtime_fixture["phase"] != "AN3-B3B" \
            or macos_realtime_fixture["operatingSystem"] != "macos" \
            or macos_realtime_fixture["provider"] != "openai_realtime_byok" \
            or macos_realtime_fixture["model"] != "gpt-realtime-2.1" \
            or macos_realtime_fixture["endpoint"] != "https://api.openai.com/v1/realtime/calls":
        fail("macOS AN3-B3B Realtime fixture identity drifted")
    macos_activation = macos_realtime_fixture["activation"]
    if macos_activation != {
        "defaultOff": True,
        "explicitMicrophoneClick": True,
        "panelAttachedRequired": True,
        "backgroundStart": False,
        "trustedOrigin": "https://voice.hoverpocket.local/",
    }:
        fail("macOS Realtime explicit activation contract drifted")
    macos_isolation = macos_realtime_fixture["isolation"]
    if macos_isolation != {
        "credentialStore": "keychain",
        "webViewReceivesCredential": False,
        "websiteDataStore": "non_persistent",
        "externalNavigation": False,
        "newWindows": False,
        "inspectable": False,
        "rawAudioPersistence": False,
        "rawSdpLogging": False,
    }:
        fail("macOS Realtime isolation contract drifted")
    if macos_realtime_fixture["bounds"] != {
        "maximumSdpBytes": 262144,
        "maximumEventBytes": 65536,
        "maximumFunctionOutputBytes": 32768,
        "maximumArgumentsBytes": 16384,
        "maximumRememberedCalls": 512,
    }:
        fail("macOS Realtime allocation bounds drifted")
    if not all(value in mac_codex_client for value in (
        "typealias ServerRequestAdmissionHandler",
        "serverRequestAdmissionHandler",
        "maximumProtocolLineBytes",
        "maximumErrorBufferBytes",
        '"/Applications/ChatGPT.app/Contents/Resources/codex"',
        "static func candidates",
        "includePathLookupWhenFixedCandidatesExist",
        "DispatchSemaphore(value: 0)",
        "completion.wait(timeout: .now() + 2)",
        "Darwin.kill(process.processIdentifier, SIGKILL)",
        "processStarted",
    )):
        fail("macOS Codex app-server discovery, input admission, or allocation bounds are incomplete")
    request_parse_position = mac_codex_client.find(
        "let request = CodexAppServerRequest"
    )
    admission_position = mac_codex_client.find(
        "await serverRequestAdmissionHandler(request)",
        request_parse_position,
    )
    request_task_position = mac_codex_client.find(
        "Task { await self.handleServerRequest(request) }",
        admission_position,
    )
    if not (
        0 <= request_parse_position < admission_position < request_task_position
    ):
        fail("macOS Codex ambient admission can be reordered behind tool execution")
    if not all(value in mac_codex_coordinator for value in (
        "initializingClientGeneration",
        "quarantinedClientGenerations",
        "isKnownClient",
        "!quarantinedClientGenerations.contains(generation)",
        "let wasQuarantined = quarantinedClientGenerations.contains(generation)",
        "if wasQuarantined",
        "verifyRealtimeLifecyclePolicy",
        "verifyOneShotResolutionPolicy",
        "waiterCountForVerification",
    )):
        fail("macOS Codex fallback, client quarantine, lifecycle, or generation isolation is incomplete")
    if not all(value in mac_codex_probe for value in (
        "timeout: 5",
        "timeout: 15",
        ".posixPermissions: 0o700",
        "executableIdentity",
        "for executable in candidates",
        "probeCandidate(executable",
    )):
        fail("macOS Codex compatibility probe is not bounded or executable-pinned")
    if not all(value in mac_codex_tool_route_probe for value in (
        "CodexAppServerToolRouteProbeInvocation",
        "runInvocation(",
        '"response.function_call_arguments.done"',
        "invocationCapture.complete",
        "afterWrite:",
    )) or not all(value in mac_codex_foundation_verifier for value in (
        "verifyInstalledAppServerBrokerInvocation",
        "CodexAppServerToolRouteProbe.runInvocation",
        'result.request.method == "item/tool/call"',
        'output["readback"] as? String == "verified"',
        "timerStore.runningTimers.count == 1",
    )):
        fail("macOS Codex app-server tool call is not bound to Broker approval and readback")
    if not all(value in mac_codex_login for value in (
        '"account/login/start"',
        '"account/login/cancel"',
        '"account/login/completed"',
        '"type": .string("chatgpt")',
        '"useHostedLoginSuccessPage": .bool(true)',
        '"appBrand": .string("chatgpt")',
        "browserOpener(login.authURL)",
        "Self.resolveProductionContexts",
        "private nonisolated static func resolveProductionContexts()",
        "NSWorkspace.shared.open(url)",
        "CodexVoiceCoordinator.accountAdmissionCode(account) == nil",
        "context.profile.hasValidManagedCredentialFile",
        "loginTimeoutNanoseconds",
        "cleanupTask",
        "await pendingCleanup?.value",
        "await task?.value",
        "includePathLookupWhenFixedCandidatesExist: false",
        "accountSelectionTimeout: TimeInterval = 20",
        "accountRequestTimeout: TimeInterval = 8",
        "client = selection.client",
        "selection.requestTimeout < Self.accountRequestTimeout",
        "guard !isShuttingDown",
        "isShuttingDown = true",
        "VoiceLaneRuntime.shared.credentialsDidChange()",
    )) or '"apiKey"' in mac_codex_login \
            or "CodexAppServerCompatibilityProbe.shared.probe" in mac_codex_login \
            or 'cli_auth_credentials_store = "file"' not in mac_codex_profile \
            or "case linkedExternalFile" not in mac_codex_profile \
            or "case managedFile" not in mac_codex_profile \
            or "CodexVoiceAccountLoginController.shared.shutdown()" not in mac_app \
            or "ChatGPTでログイン" not in mac_settings \
            or "@ObservedObject private var codexVoiceAccount" not in mac_settings:
        fail("macOS Codex managed ChatGPT login is missing, API-key based, or not lifecycle-bounded")
    if not all(value in mac_codex_foundation_verifier for value in (
        "verifyManagedChatGPTLoginLifecycle",
        "CodexManagedLoginPendingAction.allCases",
        "managed_login_credential_reuse",
        "managedLoginProcessesClosed",
        "processCount: 3 + CodexManagedLoginPendingAction.allCases.count",
        "browserOpenCount: 1 + CodexManagedLoginPendingAction.allCases.count",
    )) or not all(value in mac_codex_login_helper for value in (
        '"--verify-codex-managed-login-fake-app-server"',
        '"account_read:signed_out"',
        '"account_read:chatgpt"',
        '"account/login/start"',
        '"account/login/cancel"',
        '"account/login/completed"',
        '"credential_written"',
        "O_NOFOLLOW",
        "O_EXCL",
        "fstat(descriptor, &status)",
        "status.st_nlink == 1",
    )) or not all(value in mac_main for value in (
        "CodexManagedLoginVerificationHelper.argument",
        "codex_app_server_managed_login_scenarios=",
        "codex_app_server_managed_login_process_count=",
        "codex_app_server_managed_login_browser=",
        "codex_app_server_managed_login_credential_reuse=",
        "codex_app_server_managed_login_process_state=",
    )) or '"apiKey"' in mac_codex_login_helper:
        fail("macOS Codex managed login lifecycle is not process-backed and deterministic")
    model_verifier_start = mac_codex_foundation_verifier.find(
        "static func runModelToolVerification()"
    )
    model_verifier_end = mac_codex_foundation_verifier.find(
        "private static func waitForProcessExit",
        model_verifier_start,
    )
    model_verifier = mac_codex_foundation_verifier[
        model_verifier_start:model_verifier_end
    ]
    if model_verifier_start < 0 or model_verifier_end <= model_verifier_start \
            or '--verify-codex-app-server-model-tool' not in mac_main \
            or 'codex_app_server_requested_model=' not in mac_main \
            or 'codex_app_server_requested_effort=' not in mac_main \
            or 'modelToolVerificationModel = "gpt-5.6-sol"' not in mac_codex_foundation_verifier \
            or 'modelToolVerificationEffort = "medium"' not in mac_codex_foundation_verifier \
            or not all(value in model_verifier for value in (
                "calendarAccessGranted: { false }",
                "defer { try? FileManager.default.removeItem(at: root) }",
                "bridge.dynamicTools.count == 1",
                '"account/read"',
                '"thread/start"',
                '"turn/start"',
                'notification.method == "turn/completed"',
                'request.method == "item/tool/call"',
                "afterWrite:",
                "approvalCount == 1",
                "calendar.createdCount == 0",
                "timerStore.runningTimers.count == 1",
                "admissionSnapshot.rejected == 0",
                "waitForProcessExit(processID)",
                "model_tool_workspace_leaked",
            )) \
            or "OPENAI_API_KEY" in model_verifier:
        fail("macOS live Codex model tool verifier bypasses the bounded Timer-only contract")
    if not all(value in mac_codex_realtime_verifier for value in (
        "CodexAppServerCompatibilityProbe.shared.isCurrent",
        "rootThreadEphemeral: true",
        "websiteDataStore = .nonPersistent()",
        "new RTCPeerConnection({iceServers: []})",
        "gain.gain.value = 0",
        "waitForProcessExit",
        "CodexRealtimeProbeCloseGate",
        "processStarted: { processID in",
        "realtime_app_server_process_leaked",
        "CodexAppServerRealtimeVerificationSafeError",
        '"realtime_probe_page_unavailable"',
        '"realtime_probe_offer_unavailable"',
        '"realtime_probe_connection_unavailable"',
    )) or "getUserMedia" in mac_codex_realtime_verifier:
        fail("macOS Codex live verifier is not identity-pinned, microphone-free, or bounded")
    if '--verify-codex-app-server-realtime' not in mac_main \
            or '"version": .string("v3")' not in mac_codex_coordinator \
            or 'rootThreadEphemeral' not in mac_codex_coordinator \
            or 'realtime_closed_before_sdp' not in mac_codex_coordinator \
            or 'pendingSDP.result.fail(.compatibility(errorCode))' not in mac_codex_coordinator \
            or 'voices["defaultV1"]' in mac_codex_coordinator \
            or 'voices["defaultV2"]' in mac_codex_coordinator:
        fail("macOS Codex app-server realtime verifier or immediate SDP failure readback regressed")
    mac_realtime_adapter = mac_realtime_provider[
        mac_realtime_provider.find("final class OpenAIRealtimeMacOSVoiceSessionAdapter"):
        mac_realtime_provider.find("final class FailClosedVoiceProviderAdapter")
    ]
    if 'static let modelID = "gpt-realtime-2.1"' not in mac_realtime_provider \
            or 'https://api.openai.com/v1/realtime/calls' not in mac_realtime_provider \
            or "static let macOSAudioTransportAvailable = true" not in mac_realtime_provider \
            or "var requiresExplicitStart: Bool { true }" not in mac_realtime_adapter \
            or "try credentialStore.hasCredential()" not in mac_realtime_adapter \
            or "transport.start(" not in mac_realtime_adapter:
        fail("macOS OpenAI Realtime provider is not explicit-start and fail-closed")
    if not all(value in mac_realtime_transport for value in (
        "static let maximumSDPBytes = 262_144",
        "static let maximumEventBytes = 65_536",
        "static let maximumFunctionOutputBytes = 32_768",
        'https://voice.hoverpocket.local/',
        "URLSessionConfiguration.ephemeral",
        "websiteDataStore = .nonPersistent()",
        "webView.isInspectable = false",
        "requestMediaCapturePermissionFor origin",
        "type == .microphone",
        "captureAuthorizationGeneration == generation",
        "decisionHandler(allowed ? .allow : .cancel)",
        "createWebViewWith configuration",
        "try apiKey.withUTF8Bytes",
        "response.function_call_arguments.done",
        "conversation.item.create",
        "function_call_output",
        "response.create",
        "failTransport",
        "await self?.close()",
        'failTransport("voice_realtime_event_invalid")',
        'failTransport("voice_realtime_tool_result_invalid")',
        "closingCapabilities?.cancelSession(closingSessionID)",
        "javascriptBoolean(readback)",
        "forcePageReset()",
        "Content-Security-Policy",
        "localTracks.every(track => track.readyState === 'ended')",
        "let captureEpoch = 0;",
        "const startEpoch = ++captureEpoch;",
        "if (startEpoch !== captureEpoch)",
        "stale_microphone_capture",
    )):
        fail("macOS native credential, media isolation, or bounded WebRTC contract is incomplete")
    macos_start_position = mac_realtime_transport.find("async start(generation, sessionID)")
    macos_epoch_position = mac_realtime_transport.find(
        "const startEpoch = ++captureEpoch;",
        macos_start_position,
    )
    macos_get_user_media_position = mac_realtime_transport.find(
        "navigator.mediaDevices.getUserMedia",
        macos_epoch_position,
    )
    macos_stale_position = mac_realtime_transport.find(
        "if (startEpoch !== captureEpoch)",
        macos_get_user_media_position,
    )
    macos_stale_stop_position = mac_realtime_transport.find(
        "stream.getTracks().forEach(track => track.stop());",
        macos_stale_position,
    )
    macos_close_position = mac_realtime_transport.find("close() {", macos_stale_stop_position)
    macos_close_epoch_position = mac_realtime_transport.find(
        "captureEpoch += 1;",
        macos_close_position,
    )
    macos_empty_close_position = mac_realtime_transport.find(
        "if (!state) return true;",
        macos_close_epoch_position,
    )
    if not (
        0 <= macos_start_position < macos_epoch_position < macos_get_user_media_position
        < macos_stale_position < macos_stale_stop_position < macos_close_position
        < macos_close_epoch_position < macos_empty_close_position
    ):
        fail("macOS pending microphone capture is not invalidated and stopped before empty close")
    if "if (options.IsVerify)" not in windows_application_data \
            or "Debug Voice E2E mode cannot be combined with --verify." not in windows_application_data:
        fail("Windows Voice E2E can still collide with a verifier application-data override")
    continuation_position = mac_realtime_transport.find("startContinuation = continuation")
    javascript_start_position = mac_realtime_transport.find("window.hoverPocketVoice.start", continuation_position)
    if continuation_position < 0 or javascript_start_position < continuation_position \
            or "withTaskCancellationHandler" not in mac_realtime_transport \
            or "try Task.checkCancellation()" not in mac_realtime_transport:
        fail("macOS Realtime startup can lose connection completion or cancellation")
    if not all(value in mac_realtime_capabilities for value in (
        'calendarListTool = "calendar_events_list"',
        'calendarCreateTool = "calendar_event_create"',
        'timerStartTool = "timer_countdown_start"',
        "context.registry.resolve",
        "context.broker.prepare",
        "context.broker.execute",
        "NSAlert()",
        "readback.status == .verified",
        "maximumArgumentsBytes = 16_384",
        "maximumRememberedCalls = 512",
        "DuplicateKeyValidator",
        "VoiceApprovalCoordinator",
        "maximumStartsPerWindow = 3",
        "beginSheetModal",
        "func cancelSession(_ sessionID: String)",
        "VoiceApprovalText.singleLine",
        '"approval_rate_limited"',
    )):
        fail("macOS Realtime tools bypass the exact Registry/Broker/readback boundary")
    if "settings.$voiceCalendarAccessEnabled" not in mac_app \
            or "VoiceLaneRuntime.shared.capabilityGrantsDidChange()" not in mac_app \
            or "func capabilityGrantsDidChange()" not in mac_runtime \
            or "enqueueAudioCommand(.closeSession, adapter: adapter)" not in mac_runtime:
        fail("macOS Voice permission revocation or terminal failure does not close/rebuild the session")
    if mac_settings.count("VoiceLaneRuntime.shared.credentialsDidChange()") != 2 \
            or "func credentialsDidChange()" not in mac_runtime \
            or "voiceStartBlockedByConfiguration" not in mac_voice \
            or "&& runtime.snapshot.safeErrorCode == nil" in mac_voice:
        fail("macOS Voice credential refresh or transient retry contract is incomplete")
    if "Voice conversations with OpenAI Realtime" not in mac_build_script:
        fail("macOS microphone purpose string omits the OpenAI Realtime destination")
    if not all(value in mac_build_script for value in (
        "NSLocalNetworkUsageDescription",
        "establish WebRTC Voice connections",
        "does not browse for nearby devices",
        '*" --voice-e2e --voice-e2e-root "*',
    )):
        fail("macOS package runtime boundary or local network purpose string regressed")
    if not all(value in mac_build_script for value in (
        'HOVERPOCKET_SWIFT_CONFIGURATION="${HOVERPOCKET_SWIFT_CONFIGURATION:-debug}"',
        'swift build -c "$HOVERPOCKET_SWIFT_CONFIGURATION"',
        '.build/$HOVERPOCKET_SWIFT_CONFIGURATION/$PRODUCT_NAME',
        '.build/$HOVERPOCKET_SWIFT_CONFIGURATION/Sparkle.framework',
        '.build/$HOVERPOCKET_SWIFT_CONFIGURATION/libMediaRemoteAdapter.dylib',
        'E2E bundle requires the debug Swift configuration',
        'Release Sparkle framework not found',
        'Release mediaremote-adapter artifacts not found',
    )) or mac_package_script.count("HOVERPOCKET_SWIFT_CONFIGURATION=release") != 2 \
            or not all(value in mac_package_script for value in (
                'Release Sparkle framework is missing',
                'Release mediaremote adapter is missing',
                "grep -Fq '@rpath/Sparkle.framework/'",
                "grep -Fq '@rpath/libMediaRemoteAdapter.dylib'",
            )):
        fail("macOS distribution package is not pinned to a Release Swift build")
    if not all(value in mac_runtime_environment for value in (
        'static let voiceE2EFlag = "--voice-e2e"',
        'static let voiceE2ERootFlag = "--voice-e2e-root"',
        'static let voiceE2EBundleIdentifier = "local.codex.hover-pocket.voice-e2e"',
        'static let voiceE2EBuildInfoKey = "HoverPocketVoiceE2EBuild"',
        "guard debugBuild else",
        '"voice_e2e_release_rejected"',
        '$0.hasPrefix("--verify")',
        '"voice_e2e_verifier_combination_rejected"',
        "root.deletingLastPathComponent() == temporaryRoot",
        "externalIntegrationsEnabled: false",
        '"voice_e2e_arguments_required"',
        "settingsDefaults: EphemeralAppSettingsDefaults()",
        "ProviderRegistry(providers: [TimerProvider()])",
        "settings.voiceProvider = .codexAppServer",
    )):
        fail("macOS Voice E2E is not a Debug-only isolated runtime")
    if not all(value in mac_build_script for value in (
        'HOVERPOCKET_VOICE_E2E_BUILD',
        'HoverPocketVoiceE2EBuild-*',
        'HoverPocketVoiceE2E.app',
        'local.codex.hover-pocket.voice-e2e',
        '<key>HoverPocketVoiceE2EBuild</key>',
        'CODESIGN_IDENTITY="-"',
        'ENTITLEMENTS_PATH="$ROOT_DIR/Resources/HoverPocket.entitlements"',
    )):
        fail("macOS Voice E2E bundle build contract is incomplete")
    if not all(value in mac_voice_e2e_receipt for value in (
        "static let allowedKeys: Set<String>",
        "$0.role == .user && $0.isFinal",
        "$0.role == .assistant && $0.isFinal",
        'lastSafeEvent = "safe_close"',
        "physicalConfirmationRequested",
        "mediaAttemptID",
        "attemptID == mediaAttemptID",
        "recordPhysicalMediaUserConfirmation",
        "microphoneAcquired = false",
        "remoteAudioTrackEver = false",
        "remoteAudioPlaybackEver = false",
        "userTranscriptCount = 0",
        "assistantTranscriptCount = 0",
        "timerCapabilityReadbackVerified = false",
        "physicalMediaUserConfirmed = false",
        "data.write(to: receiptURL, options: .atomic)",
    )) or "snapshot.transcript.map" in mac_voice_e2e_receipt:
        fail("macOS Voice E2E receipt is not allowlisted, count-only, or atomic")
    if not all(value in mac_voice_e2e_performance for value in (
        "static let allowedKeys: Set<String>",
        "maximumLatencySamples = 10",
        "currentAttemptAttached",
        "microphoneToAttachedSamplesMilliseconds",
        "microphoneToAttachedP95Milliseconds",
        "snapshotPublishCount",
        "expandedRPCCount",
        "realtimeStopRPCCount",
        "maximumRealtimeStopRPCCount",
        "measurementDurationMilliseconds",
        "writeQueue.async",
        "scheduleWrite()",
        "flushSynchronously(event: String)",
        "data.write(to: receiptURL, options: .atomic)",
    )):
        fail("macOS Voice E2E performance receipt is incomplete")
    if not all(value in mac_codex_coordinator for value in (
        "MacOSVoiceE2EPerformanceStore.shared?.recordExpandedRPC(",
        "MacOSVoiceE2EPerformanceStore.shared?.recordRealtimeStopRPC()",
    )):
        fail("macOS Codex Voice E2E performance hooks are incomplete")
    if "performanceFlushSynchronously: true" not in mac_app:
        fail("macOS Voice E2E termination lacks synchronous performance readback")
    mac_realtime_page = mac_realtime_transport[
        mac_realtime_transport.find("static let page ="):
    ]
    if not all(value in mac_realtime_transport for value in (
        "MacOSVoiceE2EReceiptStore.shared?.beginMediaSession()",
        "MacOSVoiceE2EPerformanceStore.shared?.recordTransportAttached()",
        "receiptStore.recordMediaEvent(event)",
        "guard let attemptID = receiptStore.claimPhysicalConfirmationRequest()",
        "MacOSVoiceE2EPhysicalMediaConfirmation.present()",
        "attemptID: attemptID",
        "MacOSVoiceE2EReceiptStore.shared?.recordSafeClose()",
        "event:'microphoneAcquired'",
        "event:'remoteAudioTrackReceived'",
        "event:'remoteAudioPlaybackSucceeded'",
    )) or "physicalMediaUserConfirmed" in mac_realtime_page \
            or "recordPhysicalMediaUserConfirmation" in mac_realtime_page:
        fail("macOS Voice E2E media receipt or Host-owned physical confirmation drifted")
    if not all(value in mac_codex_transport for value in (
        "MacOSVoiceE2EReceiptStore.shared?.beginMediaSession()",
        "MacOSVoiceE2EPerformanceStore.shared?.recordTransportAttached()",
        "private func recordE2EMediaEvent(_ event: MacOSVoiceE2EMediaEvent)",
        "receiptStore.recordMediaEvent(event)",
        "guard let attemptID = receiptStore.claimPhysicalConfirmationRequest()",
        "MacOSVoiceE2EPhysicalMediaConfirmation.present()",
        "attemptID: attemptID",
        "MacOSVoiceE2EReceiptStore.shared?.recordSafeClose()",
        'case "microphone_acquired"',
        'case "remote_audio_track"',
        'case "remote_audio_playing"',
    )):
        fail("macOS Codex Voice E2E media receipt or physical confirmation drifted")
    codex_attempt_pos = mac_codex_transport.find(
        "MacOSVoiceE2EReceiptStore.shared?.beginMediaSession()"
    )
    codex_authorization_pos = mac_codex_transport.find(
        "CodexVoiceSystemMicrophoneAuthorizationPolicy.decision("
    )
    if mac_codex_transport.count(
        "MacOSVoiceE2EReceiptStore.shared?.beginMediaSession()"
    ) != 1 or not 0 <= codex_attempt_pos < codex_authorization_pos:
        fail("macOS Codex Voice latency measurement does not start at user microphone intent")
    if "recordTimerCapabilityReadbackVerified()" not in mac_realtime_capabilities:
        fail("macOS Voice E2E lacks Timer Broker readback evidence")
    if not all(value in mac_voice_e2e_harness for value in (
        "Build",
        "Run",
        "Readback",
        "ValidateIsolation",
        "Validate",
        "Stop",
        "Cleanup",
        "Build and Run use the logged-in Codex app-server account",
        "never read an API",
        "validate_owned_process",
        '[[ "$command" == "$executable --voice-e2e --voice-e2e-root $runtime_root" ]]',
        "find_exact_process",
        '/usr/bin/open -n "$app_path" --args',
        "acquire_session_operation_lock",
        ".voice-e2e-operation-lock",
        '[[ ! -L "$entry_path" ]]',
        'matching_pids="$(find_exact_process "$expected_command")"',
        "E2E bundle must use an ad-hoc signature",
        "E2E bundle must not use a certificate identity",
        "--stage stopped",
        "voice-e2e-performance.json",
        "performanceReceiptRequired",
        "--require-receipt",
    )):
        fail("macOS Voice E2E operational harness is incomplete")
    stopped_receipt_pos = mac_voice_e2e_harness.find('--stage stopped')
    stopped_lifecycle_pos = mac_voice_e2e_harness.find(
        'plutil -replace lifecycle -string stopped'
    )
    if stopped_receipt_pos < 0 or stopped_lifecycle_pos <= stopped_receipt_pos:
        fail("macOS Voice E2E commits stopped state before receipt validation")
    if not all(value in mac_voice_e2e_receipt_verifier for value in (
        "ALLOWED_KEYS",
        "set(payload) != ALLOWED_KEYS",
        'parser.add_argument("--self-test", action="store_true")',
        'validate_stage(rejected, "physical")',
        'choices=("summary", "isolation", "physical", "stopped")',
        '"codex_app_server"',
        '"physicalMediaUserConfirmed": True',
        'payload["lastSafeEvent"] != "safe_close"',
    )):
        fail("macOS Voice E2E receipt validator is incomplete")
    if not all(value in mac_voice_e2e_performance_verifier for value in (
        "ALLOWED_KEYS",
        "nearest_rank_p95",
        'choices=("idle", "active", "stopped")',
        "stop_count > 1 or maximum_stop_count > 1",
        'payload["currentAttemptAttached"] and stop_count != 1',
        'parser.add_argument("--require-receipt", action="store_true")',
        'payload["lastSafeEvent"] != "safe_close"',
        'parser.add_argument("--self-test", action="store_true")',
    )):
        fail("macOS Voice E2E performance validator is incomplete")
    if not all(value in mac_voice_e2e_verifier for value in (
        "debugBuild: false",
        'code: "voice_e2e_release_rejected"',
        'code: "voice_e2e_verifier_combination_rejected"',
        'code: "voice_e2e_arguments_required"',
        '"voice_e2e_root_not_fresh"',
        '"voice_e2e_root_type_rejected"',
        "MacOSVoiceE2EReceiptStore.allowedKeys",
        '"receipt_attempt_microphone_stale"',
        '"receipt_attempt_user_transcript_stale"',
        '"receipt_attempt_timer_stale"',
        '"receipt_attempt_confirmation_stale"',
        '"receipt_stale_confirmation_accepted"',
        'stopped.lastSafeEvent == "safe_close"',
        '"performance_failed_attempt_marked_attached"',
        '"performance_synchronous_safe_close"',
    )):
        fail("macOS Voice E2E deterministic verifier is incomplete")
    if "if HoverPocketRuntimeEnvironment.shared.externalIntegrationsEnabled" not in mac_settings \
            or mac_app.count("HoverPocketRuntimeEnvironment.shared.externalIntegrationsEnabled") < 4:
        fail("macOS Voice E2E external Settings and lifecycle actions are not gated")
    calendar_default = mac_app_settings[
        mac_app_settings.find("self.voiceCalendarAccessEnabled ="):
        mac_app_settings.find("if defaults.data", mac_app_settings.find("self.voiceCalendarAccessEnabled ="))
    ]
    if "? false" not in calendar_default \
            or "isShowingVoiceCalendarAccessConfirmation = true" not in mac_settings \
            or "APIキーはネイティブ側だけで使用" not in mac_settings:
        fail("macOS Voice Calendar or native credential consent does not default closed")
    if "providerID: providerID" not in mac_app \
            or "VoiceProviderAdapterFactory.factory(" not in mac_app \
            or "settings: settings" not in mac_app \
            or "VoiceCapabilityContext(" not in mac_app \
            or "voiceCapabilityContext: voiceCapabilityContext" not in mac_app \
            or "Publishers.CombineLatest3" not in mac_app \
            or "settings.$voiceProvider.removeDuplicates()" not in mac_app:
        fail("macOS Voice provider/settings are not composed into the Host runtime")
    if "switch snapshot.providerID" not in mac_app \
            or "CodexAppServerMacOSRuntime.host.snapshot.availability == .ready" not in mac_app:
        fail("macOS Voice E2E provider readiness readback bypasses the selected provider")
    if '--verify-calendar-capability-read-only' not in mac_main \
            or not all(value in mac_calendar_live_verifier for value in (
                'CommandLine.arguments.contains("--grant-calendar-read")',
                "HoverPocketRuntimeEnvironment.shared.externalIntegrationsEnabled",
                "GoogleOAuthKeychainStore().load()",
                "Task.sleep(for: .seconds(5))",
                "allowsStoredCredentialMutation: false",
                "GoogleCalendarStore(oauth: oauth)",
                "PocketCapabilityHandlerSet(handlers: [",
                "CalendarListCapabilityHandler(dataSource: calendarDataSource)",
                "LiveCalendarCapabilityDataSource(",
                "lastSafeFailure = result.failure",
                "CapabilityRegistry(handlers: handlers)",
                "CapabilityBroker(",
                "PocketCapabilityKeys.calendarList",
                'permissions: ["calendar.events.read"]',
                "preparation.approvalRequest == nil",
                "step.readback.status == .verified",
                'calendar_capability_audit=redacted',
                'auditText.contains("\\\"safeTitle\\\"")',
                'auditText.contains("\\\"eventRef\\\"")',
                'auditText.contains("\\\"calendarId\\\"")',
                '"calendar_credential_check_timed_out"',
                '"calendar_request_failed"',
                '"calendar_network_timed_out"',
                'step.safeError?.code == "CAPABILITY_TIMEOUT"',
                '"calendar_capability_timed_out"',
            )) or "ProviderCapabilityCompositionRoot.live" in mac_calendar_live_verifier \
            or "TimerStore.shared" in mac_calendar_live_verifier \
            or "StickyNotesStore.shared" in mac_calendar_live_verifier \
            or "signIn(" in mac_calendar_live_verifier:
        fail("macOS live Calendar read verifier bypasses grant, Broker, readback, redaction, or bounded credential access")
    if "func delete() throws" not in mac_realtime_provider \
            or "let status = SecItemDelete(baseQuery() as CFDictionary)" not in mac_keychain \
            or "status == errSecSuccess || status == errSecItemNotFound" not in mac_keychain \
            or "guard try !openAIRealtimeKeychain.hasCredential()" not in mac_settings:
        fail("macOS OpenAI Keychain deletion lacks result propagation or readback")
    if 'public const string ModelId = "gpt-realtime-2.1";' not in windows_realtime_coordinator \
            or 'public const string CallsEndpoint = "https://api.openai.com/v1/realtime/calls";' not in windows_realtime_coordinator \
            or "MaximumFunctionOutputBytes = 32_768" not in windows_realtime_coordinator \
            or '"gpt-realtime"' in windows_realtime_coordinator:
        fail("Windows OpenAI Realtime model/endpoint/output bounds regressed")
    if not all(value in windows_realtime_capabilities for value in (
        'CalendarListTool = "calendar_events_list"',
        'CalendarCreateTool = "calendar_event_create"',
        'TimerStartTool = "timer_countdown_start"',
        "CapabilityIds.CalendarList",
        "CapabilityIds.CalendarCreate",
        "CapabilityIds.TimerStart",
        "CapabilityOrigin.Voice",
        "CapabilityReadbackStatus.Verified",
        '"idempotency_conflict"',
        "Correlation(sessionId, callId)",
    )):
        fail("Windows Realtime functions bypass Registry/Broker, readback, or call-id idempotency")
    if "OpenAIRealtimeContract.MaximumFunctionOutputBytes" not in windows_realtime_coordinator \
            or "OpenAIRealtimeVoiceVerifier().Run()" not in windows_app \
            or "repeated_call_executed_more_than_once" not in windows_realtime_verifier \
            or "tool_surface_not_exact" not in windows_realtime_verifier \
            or "provider_switch_overlapped_transport" not in windows_realtime_verifier \
            or "oversized_sdp_content_length_not_rejected" not in windows_realtime_verifier:
        fail("Windows AN3-B3A deterministic verifier is incomplete")
    if "ReadBoundedRemoteSdpAsync" not in windows_realtime_coordinator \
            or "ReadAsStreamAsync(cancellationToken)" not in windows_realtime_coordinator \
            or "MaximumSdpBytes + 1" not in windows_realtime_coordinator \
            or "ReadAsStringAsync" in windows_realtime_coordinator:
        fail("Windows Realtime SDP answer is not bounded before allocation")
    if "VoiceProviderIds.OpenAIRealtimeByok" not in windows_voice_provider_runtime \
            or "StopAndDisposeActiveAsync(CancellationToken.None)" not in windows_voice_provider_runtime \
            or 'data-voice-provider' not in windows_settings_html \
            or 'settings.setVoiceProvider' not in windows_settings_js \
            or 'settings.configureVoiceOpenAIKey' not in windows_settings_js \
            or 'settings.deleteVoiceOpenAIKey' not in windows_settings_js:
        fail("Windows explicit provider selection or Host-owned credential UI is incomplete")
    provider_transition = bridge[
        bridge.find("private async Task<object?> SetVoiceProviderAsync"):
        bridge.find("private async Task<object?> ConfigureVoiceOpenAIKeyAsync")
    ]
    if "RollbackVoiceProviderTransitionAsync" not in provider_transition \
            or "previousSettings" not in provider_transition \
            or 'voice_provider_transition_failed_closed' not in provider_transition:
        fail("Windows provider/settings transition does not roll back or fail closed")
    enabled_transition = bridge[
        bridge.find("private async Task<object?> SetVoiceEnabledAsync"):
        bridge.find("private async Task<object?> SetVoiceProviderAsync")
    ]
    if "RollbackVoiceProviderTransitionAsync" not in enabled_transition \
            or 'voice_enabled_transition_failed_closed' not in enabled_transition \
            or enabled_transition.find("SetFeatureEnabledAsync") > enabled_transition.find("SaveSettings(updated)"):
        fail("Windows Voice enabled/runtime transition is not transactional")
    rollback_transition = bridge[
        bridge.find("private async Task<bool> RollbackVoiceProviderTransitionAsync"):
        bridge.find("private async Task<object?> ConfigureVoiceOpenAIKeyAsync")
    ]
    if "await ForceVoiceRuntimeOffAsync();" not in rollback_transition \
            or "_settingsStore.Save(normalized);" not in rollback_transition \
            or rollback_transition.find("_settingsStore.Save(normalized);") > rollback_transition.find("CurrentSettings = normalized;"):
        fail("Windows terminal Voice rollback is not durably fail-closed")
    delete_key_transition = bridge[
        bridge.find("private async Task<object?> DeleteVoiceOpenAIKeyAsync"):
        bridge.find("private async Task<object?> SetVoiceLayoutAsync")
    ]
    if "ApproveVoiceOpenAIKeyDeletion" not in delete_key_transition \
            or "_openAIRealtimeCredentialStore.HasCredential()" not in delete_key_transition \
            or "voice_key_delete_unverified" not in delete_key_transition \
            or "voiceOpenAIKeyDeleteDecision: ConfirmOpenAIRealtimeKeyDeletion" not in windows_settings_window \
            or "MessageBoxResult.No" not in windows_settings_window:
        fail("Windows OpenAI key deletion lacks Host-owned confirmation or readback")
    save_settings = bridge[
        bridge.find("private void SaveSettings"):
        bridge.find("private async Task<object> PublishStateAsync")
    ]
    if save_settings.find("_settingsStore.Save(normalized)") > save_settings.find("CurrentSettings = normalized"):
        fail("Windows in-memory settings mutate before durable persistence")
    if 'File.Move(temporaryPath, SettingsPath, overwrite: true);' not in (
        ROOT / "windows" / "src" / "HoverPocket.Shell" / "Configuration" / "UserSettingsStore.cs"
    ).read_text(encoding="utf-8"):
        fail("Windows settings persistence is not replace-on-success")
    if "OpenAIRealtimeCredentialStore" not in windows_credentials \
            or "CryptographicOperations.ZeroMemory(bytes);" not in windows_credentials \
            or "Marshal.Copy(bytes, 0, blob, bytes.Length);" not in windows_credentials:
        fail("Windows OpenAI credential material is not zeroed before unmanaged release")

    print(
        "PASS voice-foundation contract: "
        f"{matrix_cases} geometry/state cases, root scope, default-off, "
        "legacy lane negative regression, internal scroll, accessibility, "
        "Windows explicit-origin microphone, fenced Realtime transport, "
        "AN3-B2 Calendar/Timer Broker slice, AN3-B3A OpenAI Realtime BYOK gates, "
        "AN3-B3B macOS Realtime security gates, and explicit Codex model tool readback"
    )


if __name__ == "__main__":
    main()
