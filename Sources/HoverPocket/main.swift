import AppKit
import Foundation

if CommandLine.arguments.contains("--verify-google-calendar") {
    GoogleCalendarVerificationCommand.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
