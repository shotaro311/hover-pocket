import AVFoundation
import AppKit
import IOKit
import SwiftUI

struct MirrorProvider: PocketProvider {
    static let pluginID = PluginID(rawValue: "mirror")

    let manifest = PluginManifest(
        id: Self.pluginID,
        title: "Mirror",
        symbolName: "person.crop.rectangle",
        defaultEnabled: true,
        requestedPermissions: [.camera, .microphone],
        refreshPolicy: .eventDriven
    )

    @MainActor
    func makePreview(
        snapshot: ProviderSnapshot?,
        state: ProviderState,
        actions: ProviderActions
    ) -> AnyView {
        AnyView(MirrorPreviewView(isActive: actions.isPreviewActive, settings: actions.settings))
    }
}

struct MirrorAvailabilitySnapshot: Equatable {
    let isExternalOnlyClamshell: Bool
    let hasConnectedCamera: Bool
    let hasUsableCamera: Bool

    var shouldHideProvider: Bool {
        isExternalOnlyClamshell && !hasUsableCamera
    }
}

enum MirrorCameraAvailability {
    static func currentSnapshot() -> MirrorAvailabilitySnapshot {
        let isExternalOnlyClamshell = isExternalOnlyClamshell()
        let devices = videoDevices()
        let hasConnectedCamera = !devices.isEmpty
        let hasUsableCamera = isExternalOnlyClamshell
            ? devices.contains(where: isExternalCamera)
            : hasConnectedCamera

        return MirrorAvailabilitySnapshot(
            isExternalOnlyClamshell: isExternalOnlyClamshell,
            hasConnectedCamera: hasConnectedCamera,
            hasUsableCamera: hasUsableCamera
        )
    }

    static func preferredCameraDevice() -> AVCaptureDevice? {
        let devices = videoDevices()
        if isExternalOnlyClamshell() {
            return devices.first(where: isExternalCamera)
        }

        return devices.first { device in
            device.deviceType == .builtInWideAngleCamera && device.position == .front
        } ?? devices.first { device in
            device.position == .front
        } ?? devices.first
    }

    private static func videoDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInWideAngleCamera,
                .external,
                .continuityCamera,
                .deskViewCamera
            ],
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    private static func isExternalCamera(_ device: AVCaptureDevice) -> Bool {
        switch device.deviceType {
        case .external, .continuityCamera:
            return true
        default:
            return false
        }
    }

    private static func isExternalOnlyClamshell() -> Bool {
        let activeDisplays = displayIDs(using: CGGetActiveDisplayList)
        let hasActiveExternalDisplay = activeDisplays.contains(where: isExternalDisplay)
        let hasActiveBuiltInDisplay = activeDisplays.contains(where: isBuiltInDisplay)

        guard hasActiveExternalDisplay, !hasActiveBuiltInDisplay else {
            return false
        }

        if let clamshellState = currentClamshellState() {
            return clamshellState
        }

        let onlineDisplays = displayIDs(using: CGGetOnlineDisplayList)
        return onlineDisplays.contains(where: isBuiltInDisplay)
    }

    private static func currentClamshellState() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        let property = IORegistryEntryCreateCFProperty(
            service,
            "AppleClamshellState" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue()

        return property as? Bool
    }

    private static func displayIDs(
        using getter: (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?) -> CGError
    ) -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard getter(0, nil, &count) == .success, count > 0 else { return [] }

        var displays = Array(repeating: CGDirectDisplayID(), count: Int(count))
        let error = displays.withUnsafeMutableBufferPointer { buffer in
            getter(count, buffer.baseAddress, &count)
        }

        guard error == .success else { return [] }
        return Array(displays.prefix(Int(count)))
    }

    private static func isBuiltInDisplay(_ displayID: CGDirectDisplayID) -> Bool {
        CGDisplayIsBuiltin(displayID) != 0
    }

    private static func isExternalDisplay(_ displayID: CGDirectDisplayID) -> Bool {
        !isBuiltInDisplay(displayID)
    }
}
