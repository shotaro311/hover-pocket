import AppKit
import AVFoundation
import ScreenCaptureKit

@MainActor
enum RegionRecordingVerification {
    static func run() async throws {
        guard CGPreflightScreenCaptureAccess(), let screen = NSScreen.main,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            throw LibraryError.message("region_verification_screen_permission_missing")
        }
        let panel = NSPanel(contentRect: CGRect(x: screen.visibleFrame.midX - 250, y: screen.visibleFrame.midY - 160, width: 500, height: 320),
            styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.level = .floating; panel.contentView = Colors()
        panel.makeKeyAndOrderFront(nil); defer { panel.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(200))
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else { throw LibraryError.message("region_display_missing") }
        let rect = CGRect(x: panel.frame.minX - screen.frame.minX + 280, y: screen.frame.maxY - panel.frame.maxY + 40, width: 180, height: 140)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HoverPocket-RegionVerify-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let size = CGSize(width: rect.width * screen.backingScaleFactor, height: rect.height * screen.backingScaleFactor)
        let recorder = try AssetScreenRecorder(directory: directory, systemAudio: false, microphone: false)
        try await recorder.start(filter: SCContentFilter(display: display, excludingWindows: []), size: size, sourceRect: rect)
        try await Task.sleep(for: .milliseconds(1100))
        let file = try await recorder.stop(), asset = AVURLAsset(url: file)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw LibraryError.message("region_video_missing") }
        let dimensions = try await video.load(.naturalSize)
        guard dimensions == size else { throw LibraryError.message("region_output_dimensions_wrong") }
        let image = try await AVAssetImageGenerator(asset: asset).image(at: CMTime(seconds: 0.4, preferredTimescale: 600)).image
        var pixel = [UInt8](repeating: 0, count: 4)
        let green = pixel.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            let value = bytes.bindMemory(to: UInt8.self)
            return value[1] > 150 && value[0] < 80 && value[2] < 80
        }
        guard green else { throw LibraryError.message("region_pixels_include_unselected_content") }
        print("PASS region recording: selected green area decoded, unselected red area excluded, output=\(Int(dimensions.width))x\(Int(dimensions.height)) evidence=\(directory.path)")
    }
    private final class Colors: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor.red.setFill(); bounds.fill()
            NSColor.green.setFill(); CGRect(x: bounds.midX, y: 0, width: bounds.width / 2, height: bounds.height).fill()
        }
    }
}
