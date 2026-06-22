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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
