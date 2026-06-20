import AppKit
import CoreGraphics

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")

        if let number = deviceDescription[key] as? NSNumber {
            return CGDirectDisplayID(number.uint32Value)
        }

        return deviceDescription[key] as? CGDirectDisplayID
    }
}
