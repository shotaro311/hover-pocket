import AppKit
import Foundation

if CommandLine.arguments.contains("--verify-google-calendar") {
    GoogleCalendarVerificationCommand.run()
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
            print("PASS voice-foundation verify: default-off inert, root scope, bounded redacted transcript, app-lifetime UI detach, compact/expanded geometry")
            exit(0)
        } catch {
            print("FAIL voice-foundation verify: \(error)")
            exit(1)
        }
    }
    app.run()
    exit(1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
