import AppKit
import CoreImage
import ScreenCaptureKit

private final class LiquidEdgeFrames: NSObject, SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    private let context = CIContext(options: [.useSoftwareRenderer: true])
    private var images: [CGImage] = []
    private var latest: CGImage?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of outputType: SCStreamOutputType) {
        guard outputType == .screen, sampleBuffer.isValid,
              let info = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let status = info.first?[.status] as? Int, SCFrameStatus(rawValue: status) == .complete,
              let buffer = sampleBuffer.imageBuffer else { return }
        let image = CIImage(cvPixelBuffer: buffer)
        guard let copy = context.createCGImage(image, from: image.extent) else { return }
        lock.lock()
        if images.count < 120 { images.append(copy) }
        latest = copy
        lock.unlock()
    }

    var snapshot: [CGImage] {
        lock.lock()
        defer { lock.unlock() }
        return images
    }

    var finalImage: CGImage? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }
}

@MainActor
enum LiquidScreenEdgeVerification {
    static func run(screen: NSScreen, frame: NSRect, attachment: PanelAttachmentMetrics,
                    style: PanelAttachmentStyle, evidenceDirectory: URL,
                    expectsDisplacement: Bool = false,
                    open: () -> Void, settle: () async throws -> Void,
                    close: () async throws -> Void) async throws {
        guard CGPreflightScreenCaptureAccess() else {
            print("liquid_screen_edge=skipped style=\(style.rawValue) screen_capture_permission_unavailable")
            return
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw PanelSoakVerificationError.failed("liquid_screen_edge_display")
        }
        let height = frame.height
        // A white surface behind the test panel makes a displaced black edge observable on any wallpaper.
        let background = NSPanel(contentRect: NSRect(x: frame.minX, y: screen.frame.maxY - height,
                                                     width: frame.width, height: height),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        background.isReleasedWhenClosed = false
        background.backgroundColor = .white
        background.isOpaque = true
        background.hasShadow = false
        background.animationBehavior = .none
        background.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        background.ignoresMouseEvents = true
        background.orderFrontRegardless()
        defer { background.orderOut(nil); background.close() }
        let scale = screen.backingScaleFactor
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = CGRect(x: frame.minX - screen.frame.minX, y: 0, width: frame.width, height: height)
        configuration.width = Int(frame.width * scale)
        configuration.height = Int(height * scale)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 120)
        configuration.queueDepth = 6
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.ignoreShadowsDisplay = true
        let stream = SCStream(filter: SCContentFilter(display: display, excludingApplications: [], exceptingWindows: []),
                              configuration: configuration, delegate: nil)
        let frames = LiquidEdgeFrames()
        let queue = DispatchQueue(label: "local.codex.hover-pocket.liquid-edge.verify", qos: .userInteractive)
        try stream.addStreamOutput(frames, type: .screen, sampleHandlerQueue: queue)
        do {
            try await stream.startCapture()
            try await Task.sleep(for: .milliseconds(100))
            open()
            try await settle()
            try await Task.sleep(for: .milliseconds(100))
            try await stream.stopCapture()
        } catch {
            try? await stream.stopCapture()
            try? await close()
            throw error
        }
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
        try await close()
        let name = (expectsDisplacement ? "default-ordering-control-" : "screen-edge-") + style.rawValue
        let directory = evidenceDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let images = frames.snapshot
        func black(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int, threshold: CGFloat = 0.1) -> Bool {
            guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
            return max(color.redComponent, color.greenComponent, color.blueComponent) < threshold
        }
        func marked(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> Bool {
            guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
            return min(color.redComponent, color.greenComponent, color.blueComponent) < 0.99
        }
        guard let finalImage = frames.finalImage, images.count >= 5 else {
            throw PanelSoakVerificationError.failed("liquid_screen_edge_missing_frames")
        }
        let final = NSBitmapImageRep(cgImage: finalImage)
        var activeFrames = 0, maxGap = 0, notchBandPixels = 0, simultaneousGrowthFrames = 0
        var joinSeamPixels = 0
        var joinTopRows: Set<Int> = []
        var minBodyWidth = final.pixelsWide, maxBodyWidth = 0
        var bodyWidths: Set<Int> = []
        var previousWidth: Int?, previousDepth: Int?
        var report: [[String: Int]] = []
        let expectedTop = style == .preserveMenu ? Int(ceil(attachment.preservedNeckTop * scale)) : 0
        let joinBase = Int(attachment.contentTop * scale)
        let hasMeniscus = style == .preserveMenu && attachment.notchWidth > 0
        let allowedJoinHalfWidth = Int(ceil((attachment.notchWidth / 2 + 6) * scale))
        let expectedOriginWidth = Int((attachment.notchWidth > 0
            ? attachment.notchWidth + attachment.pixelOverlap * 2 : PanelLayout.miniBarExpandedWidth) * scale)
        let expectedOriginDepth = Int(attachment.headerHeight * scale)
        var originObserved = false
        for (index, image) in images.enumerated() {
            let rep = NSBitmapImageRep(cgImage: image)
            if let png = rep.representation(using: .png, properties: [:]) {
                try png.write(to: directory.appendingPathComponent(String(format: "frame-%03d.png", index)))
            }
            var forbiddenPixels = 0
            var frameSeamPixels = 0
            if style == .preserveMenu {
                for y in 0..<expectedTop {
                    for x in 0..<rep.pixelsWide where marked(rep, x, y) { forbiddenPixels += 1 }
                }
                if hasMeniscus {
                    for y in expectedTop..<joinBase {
                        for x in 0..<rep.pixelsWide where abs(x - rep.pixelsWide / 2) > allowedJoinHalfWidth
                            && marked(rep, x, y) { forbiddenPixels += 1 }
                    }
                }
                notchBandPixels += forbiddenPixels
            }
            let x = rep.pixelsWide / 2 - Int(20 * scale)
            guard let firstBlack = (0..<min(rep.pixelsHigh, Int((attachment.headerHeight + 24) * scale))).first(where: { black(rep, x, $0) }) else {
                report.append(["frame": index, "gap_pixels": -1, "notch_band_pixels": forbiddenPixels,
                               "body_width": 0, "depth_pixels": 0])
                continue
            }
            let gap = max(0, firstBlack - (hasMeniscus ? joinBase : expectedTop))
            activeFrames += 1
            maxGap = max(maxGap, gap)
            let bodyY = style == .coverMenu ? Int(attachment.headerHeight / 2 * scale)
                : Int((attachment.headerHeight + 12) * scale)
            let bodyWidth = (0..<rep.pixelsWide).filter { black(rep, $0, bodyY) }.count
            let depth = ((0..<rep.pixelsHigh).last(where: { black(rep, x, $0) }) ?? -1) + 1
            if let previousWidth, let previousDepth, bodyWidth > previousWidth && depth > previousDepth {
                simultaneousGrowthFrames += 1
            }
            previousWidth = bodyWidth; previousDepth = depth
            if style == .coverMenu && abs(bodyWidth - expectedOriginWidth) <= 2 && abs(depth - expectedOriginDepth) <= 1 {
                originObserved = true
            }
            minBodyWidth = min(minBodyWidth, bodyWidth); maxBodyWidth = max(maxBodyWidth, bodyWidth)
            bodyWidths.insert(bodyWidth)
            if style == .preserveMenu {
                guard expectsDisplacement || (hasMeniscus
                    ? (expectedTop...joinBase).contains(firstBlack) : firstBlack == expectedTop) else {
                    throw PanelSoakVerificationError.failed("liquid_screen_edge_join_top actual=\(firstBlack) allowed=\(expectedTop)...\(joinBase)")
                }
                if hasMeniscus {
                    joinTopRows.insert(firstBlack)
                    if depth > joinBase + 2 {
                        // The connection must stay black through the hardware's lower edge, without a separator.
                        for y in firstBlack...joinBase + 1 {
                            for coreX in [rep.pixelsWide / 2 - Int(20 * scale), rep.pixelsWide / 2, rep.pixelsWide / 2 + Int(20 * scale)] {
                                if !black(rep, coreX, y, threshold: y >= joinBase ? 0.02 : 0.1) { frameSeamPixels += 1 }
                            }
                        }
                    }
                }
            }
            joinSeamPixels += frameSeamPixels
            report.append(["frame": index, "gap_pixels": gap, "notch_band_pixels": forbiddenPixels,
                           "body_width": bodyWidth, "depth_pixels": depth,
                           "join_top_pixels": firstBlack, "join_seam_pixels": frameSeamPixels])
        }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("measurements.json"))
        guard activeFrames >= 5, bodyWidths.count >= 3 else {
            throw PanelSoakVerificationError.failed("liquid_screen_edge_missing_motion control=\(expectsDisplacement ? "default" : "none") style=\(style.rawValue)")
        }
        if expectsDisplacement && maxGap == 0 {
            print("liquid_screen_edge_control=skipped reason=native_displacement_unavailable detection_unproven=true")
            return
        }
        guard expectsDisplacement || (maxGap == 0 && notchBandPixels == 0) else {
            throw PanelSoakVerificationError.failed("liquid_screen_edge control=none style=\(style.rawValue) active_frames=\(activeFrames) gap=\(maxGap) notch_band_pixels=\(notchBandPixels) body_width=\(minBodyWidth)...\(maxBodyWidth)")
        }
        if style == .coverMenu && !expectsDisplacement {
            guard (attachment.notchWidth == 0 || originObserved), simultaneousGrowthFrames >= 3 else {
                throw PanelSoakVerificationError.failed("liquid_screen_edge_notch_growth origin=\(originObserved) simultaneous_frames=\(simultaneousGrowthFrames)")
            }
            if attachment.notchWidth == 0 { print("liquid_notch_origin=skipped reason=no_notch_fade") }
        }
        if hasMeniscus && !expectsDisplacement {
            guard joinSeamPixels == 0, joinTopRows.count >= 2, joinTopRows.min() == expectedTop else {
                throw PanelSoakVerificationError.failed("liquid_screen_edge_meniscus seam_pixels=\(joinSeamPixels) top_rows=\(joinTopRows.sorted())")
            }
        }
        print("liquid_screen_edge=ok control=\(expectsDisplacement ? "default" : "none") style=\(style.rawValue) frames=\(activeFrames) gap_pixels=\(maxGap) notch_band_pixels=\(notchBandPixels) clear_band_height_pixels=\(expectedTop) body_width=\(minBodyWidth)...\(maxBodyWidth) notch_origin=\(originObserved) simultaneous_growth_frames=\(simultaneousGrowthFrames) join_seam_pixels=\(joinSeamPixels) join_growth_rows=\(joinTopRows.count)")
    }
}
