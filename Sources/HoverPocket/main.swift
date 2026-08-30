import AppKit
import Darwin
import Foundation

_ = signal(SIGPIPE, SIG_IGN)
_ = HoverPocketRuntimeEnvironment.shared

if CommandLine.arguments.contains(CodexCredentialBrokerDeinitProbe.argument) {
    exit(CodexCredentialBrokerDeinitProbe.run())
}

if CommandLine.arguments.contains(CodexCredentialBrokerHelper.argument) {
    exit(CodexCredentialBrokerHelper.run())
}

if CommandLine.arguments.contains(CodexCredentialBrokerHelper.generationArgument) {
    exit(CodexCredentialBrokerHelper.runForGeneration())
}

if CommandLine.arguments.contains(CodexCredentialBrokerGenerationProbe.argument) {
    exit(CodexCredentialBrokerGenerationProbe.run())
}

if CommandLine.arguments.contains("--verify-google-calendar") {
    GoogleCalendarVerificationCommand.run()
}
if CommandLine.arguments.contains("--verify-calendar-capability-read-only") {
    CalendarCapabilityLiveVerificationCommand.run()
}
if CommandLine.arguments.contains("--verify-camera") {
    CameraVerificationCommand.run()
}
if CommandLine.arguments.contains("--verify-media") {
    MediaVerificationCommand.run()
}
if CommandLine.arguments.contains("--verify-calculator") {
    CalculatorVerificationCommand.run()
}
if CommandLine.arguments.contains("--verify-clipboard") {
    ClipboardVerificationCommand.run()
}
if CommandLine.arguments.contains("--verify-timer") {
    TimerVerificationCommand.run()
}
if CommandLine.arguments.contains("--verify-capabilities") {
    CapabilityVerificationCommand.run()
}
if CommandLine.arguments.contains("--verify-pocket-surface") {
    PocketSurfaceVerificationCommand.run()
}
if CommandLine.arguments.contains("--verify-pocket-app") {
    PocketAppPackageVerificationCommand.run()
}
if CommandLine.arguments.contains("--verify-broker") {
    CapabilityBrokerVerificationCommand.run()
}
if CommandLine.arguments.contains("--verify-panel-layout") {
    PanelLayoutVerificationCommand.run()
}
if CommandLine.arguments.contains("--verify-weather") {
    WeatherVerificationCommand.run()
}
if CommandLine.arguments.contains("--verify-voice-foundation") {
    let app = NSApplication.shared
    Task { @MainActor in
        do {
            try await VoiceFoundationVerificationCommand.run()
            print("PASS voice-foundation verify: default-off inert, root scope, bounded credential-safe transcript, app-lifetime UI detach, compact/expanded geometry")
            exit(0)
        } catch {
            print("FAIL voice-foundation verify: \(error)")
            exit(1)
        }
    }
    app.run()
    exit(1)
}

if CommandLine.arguments.contains("--verify-codex-app-server")
    || CommandLine.arguments.contains("--require-codex-app-server-ready") {
    let requireInstalledReady = CommandLine.arguments.contains(
        "--require-codex-app-server-ready"
    )
    Task { @MainActor in
        do {
            let result = try await CodexAppServerVerificationCommand.run()
            print("PASS codex app-server foundation: schema and exact tool route, ChatGPT account policy, cached probe, Broker bridge, WebRTC contract")
            if !result.installedCompatibility.gate.isReady {
                let code = result.installedCompatibility.gate.safeErrorCode
                    ?? "codex_app_server_not_ready"
                print("BLOCKED codex app-server installed readiness: \(code)")
                if requireInstalledReady {
                    exit(2)
                }
            } else if requireInstalledReady {
                print("PASS codex app-server installed readiness")
            }
            exit(0)
        } catch {
            print("FAIL codex app-server foundation: \(error)")
            exit(1)
        }
    }
    RunLoop.main.run()
}
if CommandLine.arguments.contains("--verify-codex-app-server-realtime") {
    let app = NSApplication.shared
    Task { @MainActor in
        do {
            let result = try await CodexAppServerRealtimeVerificationCommand.run()
            print("codex_app_server_realtime_account=chatgpt")
            print("codex_app_server_realtime_voices=\(result.voiceCount)")
            print("codex_app_server_realtime_thread=ephemeral")
            print("codex_app_server_realtime_sdp=connected")
            print("codex_app_server_realtime_process=\(result.processClosed ? "closed" : "open")")
            print("PASS codex app-server realtime: account, voices, ephemeral thread, SDP, WebRTC, teardown")
            exit(0)
        } catch {
            print("FAIL codex app-server realtime: \(error)")
            exit(1)
        }
    }
    app.run()
    exit(1)
}
if CommandLine.arguments.contains("--verify-voice-e2e-isolation") {
    MacOSVoiceE2EIsolationVerificationCommand.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
