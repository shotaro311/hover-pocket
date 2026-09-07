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

if CommandLine.arguments.contains(CodexManagedLoginVerificationHelper.argument) {
    exit(CodexManagedLoginVerificationHelper.run())
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
if CommandLine.arguments.contains("--verify-panel-soak") {
    let app = NSApplication.shared
    Task { @MainActor in
        do {
            let packageDirectory = CommandLine.arguments.firstIndex(of: "--pocket-package").flatMap { index in
                index + 1 < CommandLine.arguments.count ? URL(fileURLWithPath: CommandLine.arguments[index + 1]) : nil
            }
            let result = try await PanelSoakVerificationCommand.run(packageDirectory: packageDirectory)
            print("panel_soak_verify=ok")
            print("panel_soak_iterations=\(result.iterations)")
            print("panel_soak_provider_switches=\(result.providerSwitches)")
            print("panel_soak_recovery_cycles=\(result.recoveryCycles)")
            print("panel_soak_animated_transition_cycles=\(result.animatedTransitionCycles)")
            print(String(format: "panel_soak_warm_open_max_ms=%.3f", result.warmOpenMaximumMilliseconds))
            print("panel_soak_windows=\(result.baselineWindowCount)->\(result.finalWindowCount)")
            print("panel_soak_threads=\(result.baselineThreadCount)->\(result.finalThreadCount),max=\(result.maximumThreadCount)")
            print(String(format: "panel_soak_rss_mib=%.3f->%.3f", result.baselineResidentMiB, result.finalResidentMiB))
            print("panel_soak_rss_growth_limit_mib=64")
            print("panel_soak_sockets=\(result.baselineSocketCount)->\(result.finalSocketCount)")
            print("panel_soak_children=\(result.baselineChildProcessCount)->\(result.finalChildProcessCount)")
            print("PASS panel soak: Voice OFF, 100 open/close, local provider switching, recovery, and bounded resources")
            exit(0)
        } catch {
            print("FAIL panel soak: \(error)")
            exit(1)
        }
    }
    app.run()
    exit(1)
}
if CommandLine.arguments.contains("--export-personal-tool-contracts") {
    let operations = PersonalToolOperation.allCases.map { operation -> [String: Any] in
        ["capabilityId": operation.key.id, "version": operation.key.version, "permission": operation.permission,
         "write": operation.isWrite, "destructive": operation.isDestructive, "tool": operation.tool]
    }
    let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "operations": operations], options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
    exit(0)
}
if let argument = CommandLine.arguments.firstIndex(of: "--preview-pocket-tools-panel"), argument + 1 < CommandLine.arguments.count {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    Task { @MainActor in
        do {
            let initial = CommandLine.arguments.firstIndex(of: "--initial-tool").flatMap { $0 + 1 < CommandLine.arguments.count ? URL(fileURLWithPath: CommandLine.arguments[$0 + 1]) : nil }
            try await PocketToolsPreviewVerification.showPanel(root: URL(fileURLWithPath: CommandLine.arguments[argument + 1]), initialPackage: initial)
        }
        catch { print("FAIL pocket tools panel: \(error)"); exit(1) }
    }
    app.run()
    exit(0)
}

if let argument = CommandLine.arguments.firstIndex(of: "--preview-pocket-tools"), argument + 1 < CommandLine.arguments.count {
    let directory = URL(fileURLWithPath: CommandLine.arguments[argument + 1])
    let app = NSApplication.shared
    Task { @MainActor in
        do { try await PocketToolsPreviewVerification.show(packageDirectory: directory) }
        catch { print("FAIL pocket tools preview: \(error)"); exit(1) }
    }
    app.run()
    exit(0)
}
if let argument = CommandLine.arguments.firstIndex(of: "--verify-pocket-tools-generated-ui"), argument + 1 < CommandLine.arguments.count {
    let directory = URL(fileURLWithPath: CommandLine.arguments[argument + 1])
    let app = NSApplication.shared
    Task { @MainActor in
        do {
            let previousIndex = CommandLine.arguments.firstIndex(of: "--previous-tool")
            let previous = previousIndex.flatMap { $0 + 1 < CommandLine.arguments.count ? URL(fileURLWithPath: CommandLine.arguments[$0 + 1]) : nil }
            try await PocketToolsHTMLVerification.runGenerated(packageDirectory: directory, previousDirectory: previous)
            exit(0)
        } catch {
            print("FAIL generated pocket tool UI: \(error)")
            exit(1)
        }
    }
    app.run()
    exit(1)
}
if CommandLine.arguments.contains("--verify-pocket-tools-html") {
    let app = NSApplication.shared
    Task { @MainActor in
        do {
            try await PocketToolsHTMLVerification.run()
            exit(0)
        } catch {
            print("FAIL pocket tools HTML: \(error)")
            exit(1)
        }
    }
    app.run()
    exit(1)
}
if CommandLine.arguments.contains("--verify-pocket-tools-workflow") {
    Task { @MainActor in
        do { try await PocketToolsPlatformVerification.runLiveWorkflow(); exit(0) }
        catch { print("FAIL pocket tools workflow generation: \(type(of: error))"); exit(1) }
    }
    dispatchMain()
}

if let argument = CommandLine.arguments.firstIndex(of: "--verify-pocket-tools-actions"), argument + 1 < CommandLine.arguments.count {
    let app = NSApplication.shared
    Task { @MainActor in
        do { try await PocketToolsPlatformVerification.verifyGeneratedActions(packageDirectory: URL(fileURLWithPath: CommandLine.arguments[argument + 1])); exit(0) }
        catch { print("FAIL generated actions: \(error)"); exit(1) }
    }
    app.run()
    exit(1)
}
if let argument = CommandLine.arguments.firstIndex(of: "--verify-pocket-tools-edit"), argument + 1 < CommandLine.arguments.count {
    let directory = URL(fileURLWithPath: CommandLine.arguments[argument + 1])
    Task { @MainActor in
        do {
            try await PocketToolsPlatformVerification.runLiveEdit(packageDirectory: directory)
            exit(0)
        } catch {
            print("FAIL pocket tools live edit: \(type(of: error))")
            exit(1)
        }
    }
    dispatchMain()
}
if let argument = CommandLine.arguments.firstIndex(of: "--verify-pocket-generated-preview"), argument + 1 < CommandLine.arguments.count {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    Task { @MainActor in
        do {
            let package = try PocketAppPackageRuntime().load(directory: URL(fileURLWithPath: CommandLine.arguments[argument + 1]))
            print("PASS generated preview: " + (try await PocketGeneratedPreviewValidator.validate(package)))
            exit(0)
        } catch { print("FAIL generated preview: \(error)"); exit(1) }
    }
    app.run()
    exit(0)
}
if CommandLine.arguments.contains("--verify-voice-weather-live") {
    Task { @MainActor in
        do { try await PocketAppOSVoiceVerification.run(operation: "weather"); exit(0) }
        catch { print("FAIL live voice weather: \(error)"); exit(1) }
    }
    dispatchMain()
}
if CommandLine.arguments.contains("--verify-voice-weather") {
    Task { @MainActor in
        do { try await WeatherVoiceVerification.run(); exit(0) }
        catch { print("FAIL voice weather: \(error)"); exit(1) }
    }
    dispatchMain()
}
if CommandLine.arguments.contains("--verify-voice-only-confirmation") {
    Task { @MainActor in
        do { try await VoiceOnlyVerificationCommand.run(); exit(0) }
        catch { print("FAIL voice-only confirmation: \(error)"); exit(1) }
    }
    dispatchMain()
}
if CommandLine.arguments.contains("--verify-pocket-app-os-voice") {
    Task { @MainActor in
        do { try await PocketAppOSVoiceVerification.run(); exit(0) }
        catch { print("FAIL Pocket App OS voice: \(error)"); exit(1) }
    }
    dispatchMain()
}
if CommandLine.arguments.contains("--verify-pocket-app-os") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    Task { @MainActor in
        do { try await PocketAppOSVerification.run(); exit(0) }
        catch { print("FAIL Pocket App OS: \(error)"); exit(1) }
    }
    app.run()
    exit(0)
}
if CommandLine.arguments.contains("--verify-pocket-tools-generation") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    Task { @MainActor in
        do {
            try await PocketToolsPlatformVerification.runLiveGeneration()
            exit(0)
        } catch {
            if let error = error as? PocketAppGenerationError { print("FAIL live pocket tools generation: \(error.code)") }
            else { print("FAIL live pocket tools generation: \(type(of: error))") }
            exit(1)
        }
    }
    app.run()
    exit(0)
}
if CommandLine.arguments.contains("--verify-pocket-tools-platform") {
    Task { @MainActor in
        do {
            try PocketToolsPlatformVerification.run()
            exit(0)
        } catch {
            print("FAIL pocket tools platform: \(error)")
            exit(1)
        }
    }
    dispatchMain()
}
if CommandLine.arguments.contains("--verify-personal-tools") || CommandLine.arguments.contains("--verify-personal-calendar-read") {
    Task { @MainActor in
        do {
            if CommandLine.arguments.contains("--verify-personal-calendar-read") {
                try await PersonalToolVerificationCommand.verifyLiveCalendarRead()
            } else {
                try await PersonalToolVerificationCommand.run()
            }
            exit(0)
        } catch {
            print("FAIL personal tools: \(error.localizedDescription)")
            exit(1)
        }
    }
    dispatchMain()
}
if CommandLine.arguments.contains("--verify-weather-location") {
    let app = NSApplication.shared
    Task { @MainActor in
        do {
            try await WeatherLocationVerificationCommand.run()
            exit(0)
        } catch {
            print("FAIL weather location: \(error.localizedDescription)")
            exit(1)
        }
    }
    app.run()
    exit(1)
}
if CommandLine.arguments.contains("--verify-weather") {
    WeatherVerificationCommand.run()
}
if CommandLine.arguments.contains("--verify-voice-foundation") {
    let app = NSApplication.shared
    Task { @MainActor in
        do {
            try await VoiceFoundationVerificationCommand.run()
            print("PASS voice-foundation verify: default-off inert, root scope, bounded credential-safe transcript, app-lifetime UI detach and explicit resume, compact/expanded geometry")
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
            print(
                "codex_app_server_managed_login_scenarios="
                    + "\(result.managedLoginLifecycle.scenarioCount)"
            )
            print(
                "codex_app_server_managed_login_process_count="
                    + "\(result.managedLoginLifecycle.processCount)"
            )
            print(
                "codex_app_server_managed_login_browser="
                    + "stubbed_\(result.managedLoginLifecycle.browserOpenCount)"
            )
            print(
                "codex_app_server_managed_login_credential_reuse="
                    + "\(result.managedLoginLifecycle.credentialReuseVerified ? "verified" : "failed")"
            )
            print(
                "codex_app_server_managed_login_process_state="
                    + "\(result.managedLoginLifecycle.processesClosed ? "closed" : "open")"
            )
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
            let voiceChoice = CommandLine.arguments.firstIndex(of: "--voice-choice").flatMap { $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil }
            let result = try await CodexAppServerRealtimeVerificationCommand.run(voiceSelection: voiceChoice)
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
if CommandLine.arguments.contains("--verify-codex-app-server-model-tool") {
    Task { @MainActor in
        do {
            let result = try await CodexAppServerVerificationCommand
                .runModelToolVerification()
            print("codex_app_server_requested_model=\(result.requestedModel)")
            print("codex_app_server_requested_effort=\(result.requestedEffort)")
            print("codex_app_server_model_account=chatgpt")
            print("codex_app_server_model_tool=\(result.toolName)")
            print("codex_app_server_model_approval_count=\(result.approvalCount)")
            print("codex_app_server_model_readback=verified")
            print("codex_app_server_model_process=\(result.processClosed ? "closed" : "open")")
            print("PASS codex app-server model tool: ChatGPT account, requested model and effort, Broker approval, temporary Timer, readback, teardown")
            exit(0)
        } catch {
            print("FAIL codex app-server model tool: \(error)")
            exit(1)
        }
    }
    RunLoop.main.run()
}
if CommandLine.arguments.contains("--verify-voice-e2e-isolation") {
    MacOSVoiceE2EIsolationVerificationCommand.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
