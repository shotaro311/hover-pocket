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
if CommandLine.arguments.contains("--verify-broker") {
    CapabilityBrokerVerificationCommand.run()
}
if CommandLine.arguments.contains("--verify-panel-layout") {
    PanelLayoutVerificationCommand.run()
}
if CommandLine.arguments.contains("--verify-weather") {
    WeatherVerificationCommand.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
