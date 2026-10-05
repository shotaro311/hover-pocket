import AppKit
@preconcurrency import AVFoundation
import ScreenCaptureKit

@MainActor
enum AssetMediaVerification {
    static func snapshot(window: NSWindow, to url: URL) async throws {
        guard CGPreflightScreenCaptureAccess() else { return }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let target = content.windows.first(where: { $0.windowID == UInt32(window.windowNumber) }) else { return }
        let scale = window.screen?.backingScaleFactor ?? 1
        let config = SCStreamConfiguration(); config.width = Int(window.frame.width * scale); config.height = Int(window.frame.height * scale)
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: config)
        try AssetMedia.png(image).write(to: url)
    }
    static func movie(at url: URL, image: CGImage) async throws {
        let width = 640, height = 360
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        writer.add(input)
        guard writer.startWriting() else { throw LibraryError.message("fixture writer") }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<120 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var pixel: CVPixelBuffer?
            guard let pool = adapter.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixel) == kCVReturnSuccess, let pixel else { throw LibraryError.message("fixture pixel") }
            CVPixelBufferLockBaseAddress(pixel, [])
            let context = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: frame * 4, y: 160, width: 8, height: 30))
            CVPixelBufferUnlockBaseAddress(pixel, [])
            guard adapter.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else { throw LibraryError.message("fixture append") }
        }
        input.markAsFinished(); await writer.finishWriting()
        guard writer.status == .completed else { throw LibraryError.message("fixture finalization") }
    }

    static func capture(to evidence: URL) async throws -> [String: Any] {
        guard CGPreflightScreenCaptureAccess() else { return ["status": "skipped", "reason": "screen capture permission unavailable"] }
        let image = try AssetLibraryVerification.fixtureImage()
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 640, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "HoverPocket capture fixture"
        let view = NSImageView(frame: CGRect(x: 0, y: 0, width: 640, height: 360)); view.image = NSImage(cgImage: image, size: view.frame.size); view.imageScaling = .scaleAxesIndependently
        window.contentView = view; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(300))
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let target = content.windows.first(where: { $0.windowID == UInt32(window.windowNumber) }) else { throw LibraryError.message("fixture capture window missing") }
        let filter = SCContentFilter(desktopIndependentWindow: target)
        let config = SCStreamConfiguration(); config.width = 1280; config.height = 720; config.showsCursor = false
        let screenshot = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        try AssetMedia.png(screenshot).write(to: evidence.appendingPathComponent("screen-capture.png"))
        let directory = evidence.appendingPathComponent("recording-fixture")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let recorder = try AssetScreenRecorder(directory: directory, systemAudio: false, microphone: false)
        try await recorder.start(filter: filter, size: target.frame.size)
        try await Task.sleep(for: .seconds(3))
        let movie = try await recorder.stop(), asset = AVURLAsset(url: movie)
        let duration = try await asset.load(.duration).seconds
        let generator = AVAssetImageGenerator(asset: asset); generator.appliesPreferredTrackTransform = true
        let poster = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
        try AssetMedia.png(poster).write(to: evidence.appendingPathComponent("recording-frame.png"))
        guard duration > 1, poster.width > 0 else { throw LibraryError.message("recording decode failed") }
        var audioChecks: [[String: Any]] = []
        let toneURL = evidence.appendingPathComponent("audio-fixture.m4a")
        try AssetScreenRecorder.writeAudio(to: toneURL, duration: 3, tone: true)
        let player = try AVAudioPlayer(contentsOf: toneURL)
        let microphoneAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        for (system, microphone) in [(true, false), (false, true), (true, true)] {
            if microphone && !microphoneAllowed { audioChecks.append(["system": system, "microphone": microphone, "status": "skipped: microphone permission unavailable"]); continue }
            let audioDirectory = evidence.appendingPathComponent("recording-system-\(system)-mic-\(microphone)")
            try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
            let recorder = try AssetScreenRecorder(directory: audioDirectory, systemAudio: system, microphone: microphone)
            try await recorder.start(filter: filter, size: target.frame.size)
            if system { player.currentTime = 0; player.play() }
            try await Task.sleep(for: .seconds(2))
            player.stop()
            let recorded = AVURLAsset(url: try await recorder.stop())
            let audioTracks = try await recorded.loadTracks(withMediaType: .audio)
            guard !audioTracks.isEmpty, !(try await recorded.loadTracks(withMediaType: .video)).isEmpty else { throw LibraryError.message("audio recording track missing") }
            audioChecks.append(["system": system, "microphone": microphone, "status": "passed", "systemSamplesCaptured": recorder.didCaptureSystemAudio, "audioTracks": audioTracks.count, "duration": try await recorded.load(.duration).seconds])
        }
        let presentation = try await AssetCaptureController.shared.verifyScreenshotPresentation()
        return ["status": "passed", "duration": duration, "width": poster.width, "height": poster.height, "audio": audioChecks, "presentation": presentation]
    }
}
