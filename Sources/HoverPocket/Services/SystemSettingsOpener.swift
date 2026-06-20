import AppKit

@MainActor
enum SystemSettingsOpener {
    static func openCameraPrivacy() {
        openFirstAvailable([
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Camera",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
        ])
    }

    static func openMicrophonePrivacy() {
        openFirstAvailable([
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        ])
    }

    private static func openFirstAvailable(_ urlStrings: [String]) {
        for urlString in urlStrings {
            guard let url = URL(string: urlString) else { continue }
            if NSWorkspace.shared.open(url) {
                return
            }
        }
    }
}
