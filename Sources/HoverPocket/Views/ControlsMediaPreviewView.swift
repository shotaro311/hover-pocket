import AppKit
import CoreMedia
import CoreVideo
import IOSurface
import QuartzCore
import ScreenCaptureKit
import SwiftUI
import os

private let mediaPreviewLog = Logger(subsystem: "local.codex.hover-pocket", category: "MediaPreview")

struct ControlsVideoThumbnail: View {
    let track: ControlsNowPlayingState
    let fallbackSourceName: String

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            fallbackPreview

            ControlsLiveWindowPreview(windowID: track.previewWindowID)
                .allowsHitTesting(false)

            LinearGradient(
                colors: [.clear, .black.opacity(0.56)],
                startPoint: .center,
                endPoint: .bottom
            )

            Text(track.sourceName.isEmpty ? fallbackSourceName : track.sourceName)
                .panelTextFont(size: 8, weight: .bold, design: .monospaced)
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.09), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var fallbackPreview: some View {
        if let image = artworkImage {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            placeholder
        }
    }

    private var artworkImage: NSImage? {
        guard let artworkData = track.artworkData else { return nil }
        return NSImage(data: artworkData)
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(red: 0.10, green: 0.11, blue: 0.13))

            HStack(spacing: 5) {
                ForEach(0..<4, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.white.opacity(index.isMultiple(of: 2) ? 0.12 : 0.06))
                        .frame(width: 14)
                }
            }
            .rotationEffect(.degrees(-18))
            .offset(x: 25, y: -5)

            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white.opacity(0.76))
        }
    }
}

private struct ControlsLiveWindowPreview: NSViewRepresentable {
    let windowID: UInt32?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> ControlsLivePreviewSurfaceView {
        let view = ControlsLivePreviewSurfaceView()
        context.coordinator.attach(view)
        context.coordinator.update(windowID: windowID)
        return view
    }

    func updateNSView(_ nsView: ControlsLivePreviewSurfaceView, context: Context) {
        context.coordinator.attach(nsView)
        context.coordinator.update(windowID: windowID)
    }

    static func dismantleNSView(_ nsView: ControlsLivePreviewSurfaceView, coordinator: Coordinator) {
        coordinator.stop()
        nsView.display(surface: nil)
    }

    @MainActor
    final class Coordinator {
        private weak var previewView: ControlsLivePreviewSurfaceView?
        private var currentWindowID: UInt32?
        private var captureSession: ControlsWindowCaptureSession?

        func attach(_ view: ControlsLivePreviewSurfaceView) {
            previewView = view
        }

        func update(windowID: UInt32?) {
            guard currentWindowID != windowID else { return }
            stopCapture(clearWindowID: false)
            currentWindowID = windowID
            guard let windowID, let previewView else { return }
            guard CGPreflightScreenCaptureAccess() else {
                mediaPreviewLog.debug("live preview unavailable because screen capture permission is not granted")
                return
            }
            let session = ControlsWindowCaptureSession(previewView: previewView)
            captureSession = session
            session.start(windowID: windowID)
        }

        func stop() {
            stopCapture(clearWindowID: true)
        }

        private func stopCapture(clearWindowID: Bool) {
            captureSession?.stop()
            captureSession = nil
            previewView?.display(surface: nil)
            if clearWindowID {
                currentWindowID = nil
            }
        }
    }
}

@MainActor
private final class ControlsLivePreviewSurfaceView: NSView, @unchecked Sendable {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspectFill
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        nil
    }

    func display(surface: IOSurface?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = surface
        CATransaction.commit()
    }
}

private final class ControlsWindowCaptureSession: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private struct SendableSurface: @unchecked Sendable {
        let value: IOSurface
    }

    private final class SendableStream: @unchecked Sendable {
        let value: SCStream

        init(_ value: SCStream) {
            self.value = value
        }
    }

    private let outputQueue = DispatchQueue(
        label: "local.codex.hover-pocket.media-preview.frames",
        qos: .userInteractive
    )
    private let lock = NSLock()
    private weak var previewView: ControlsLivePreviewSurfaceView?
    private var stream: SCStream?
    private var startTask: Task<Void, Never>?
    private var startupTimeoutTask: Task<Void, Never>?
    private var pendingSurface: SendableSurface?
    private var isDisplayScheduled = false
    private var receivedFirstFrame = false
    private var isStopped = false

    init(previewView: ControlsLivePreviewSurfaceView) {
        self.previewView = previewView
    }

    func start(windowID: UInt32) {
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.startStream(windowID: windowID)
        }
        lock.lock()
        startTask = task
        lock.unlock()
    }

    func stop() {
        lock.lock()
        guard !isStopped else {
            lock.unlock()
            return
        }
        isStopped = true
        let stream = self.stream
        self.stream = nil
        let startTask = self.startTask
        self.startTask = nil
        let timeoutTask = startupTimeoutTask
        startupTimeoutTask = nil
        pendingSurface = nil
        lock.unlock()

        startTask?.cancel()
        timeoutTask?.cancel()
        clearPreview()
        if let stream {
            let sendableStream = SendableStream(stream)
            Task.detached(priority: .utility) {
                try? await sendableStream.value.stopCapture()
            }
        }
    }

    private func startStream(windowID: UInt32) async {
        guard !Task.isCancelled else { return }
        do {
            guard let window = try await ControlsMediaPreviewCaptureSupport.resolveWindow(windowID: windowID) else {
                mediaPreviewLog.debug("live preview window \(windowID) is unavailable; using artwork fallback")
                clearPreview()
                return
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let stream = SCStream(
                filter: filter,
                configuration: ControlsMediaPreviewCaptureSupport.configuration(),
                delegate: self
            )
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
            guard install(stream: stream) else { return }
            try await stream.startCapture()
            scheduleStartupTimeout(for: stream)
        } catch is CancellationError {
            return
        } catch {
            mediaPreviewLog.error("live preview start failed: \(error.localizedDescription)")
            failCurrentStream()
        }
    }

    private func install(stream: SCStream) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isStopped else { return false }
        self.stream = stream
        return true
    }

    private func scheduleStartupTimeout(for stream: SCStream) {
        let sendableStream = SendableStream(stream)
        let task = Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.handleStartupTimeout(for: sendableStream.value)
        }
        lock.lock()
        if isStopped || self.stream !== stream {
            lock.unlock()
            task.cancel()
            return
        }
        startupTimeoutTask = task
        lock.unlock()
    }

    private func handleStartupTimeout(for stream: SCStream) {
        lock.lock()
        let shouldFail = !isStopped && self.stream === stream && !receivedFirstFrame
        lock.unlock()
        guard shouldFail else { return }
        mediaPreviewLog.error("live preview produced no frame within 2 seconds; using artwork fallback")
        fail(stream: stream)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        mediaPreviewLog.error("live preview stopped: \(error.localizedDescription)")
        fail(stream: stream)
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen, sampleBuffer.isValid else { return }
        lock.lock()
        let isCurrent = !isStopped && self.stream === stream
        lock.unlock()
        guard isCurrent else { return }
        guard ControlsMediaPreviewCaptureSupport.isCompleteFrame(sampleBuffer),
              let pixelBuffer = sampleBuffer.imageBuffer,
              let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue()
        else {
            return
        }

        lock.lock()
        receivedFirstFrame = true
        let timeoutTask = startupTimeoutTask
        startupTimeoutTask = nil
        lock.unlock()
        timeoutTask?.cancel()
        enqueueDisplay(SendableSurface(value: surface))
    }

    private func failCurrentStream() {
        lock.lock()
        let stream = self.stream
        lock.unlock()
        if let stream {
            fail(stream: stream)
        } else {
            clearPreview()
        }
    }

    private func fail(stream: SCStream) {
        lock.lock()
        guard !isStopped, self.stream === stream else {
            lock.unlock()
            return
        }
        self.stream = nil
        let timeoutTask = startupTimeoutTask
        startupTimeoutTask = nil
        pendingSurface = nil
        lock.unlock()
        timeoutTask?.cancel()
        clearPreview()
        let sendableStream = SendableStream(stream)
        Task.detached(priority: .utility) {
            try? await sendableStream.value.stopCapture()
        }
    }

    private func enqueueDisplay(_ surface: SendableSurface) {
        lock.lock()
        guard !isStopped, stream != nil else {
            lock.unlock()
            return
        }
        pendingSurface = surface
        let shouldSchedule = !isDisplayScheduled
        isDisplayScheduled = true
        lock.unlock()
        guard shouldSchedule else { return }
        Task { @MainActor [weak self] in
            self?.displayLatestSurface()
        }
    }

    @MainActor
    private func displayLatestSurface() {
        lock.lock()
        let canDisplay = !isStopped && stream != nil
        let surface = pendingSurface
        pendingSurface = nil
        isDisplayScheduled = false
        let previewView = self.previewView
        lock.unlock()
        guard canDisplay, let surface else { return }
        previewView?.display(surface: surface.value)
    }

    private func clearPreview() {
        Task { @MainActor [weak previewView] in
            previewView?.display(surface: nil)
        }
    }
}

private enum ControlsMediaPreviewCaptureSupport {
    static func configuration() -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = 392
        configuration.height = 220
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 3
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.capturesAudio = false
        if #available(macOS 15.0, *) {
            configuration.captureMicrophone = false
        }
        return configuration
    }

    static func resolveWindow(windowID: UInt32) async throws -> SCWindow? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return content.windows.first(where: { $0.windowID == CGWindowID(windowID) })
    }

    static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard sampleBuffer.isValid,
              let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer,
                createIfNecessary: false
              ) as? [[SCStreamFrameInfo: Any]],
              let attachments = attachmentsArray.first,
              let statusRawValue = attachments[.status] as? Int
        else {
            return false
        }
        return SCFrameStatus(rawValue: statusRawValue) == .complete
    }
}

struct ControlsMediaPreviewVerificationResult: Sendable {
    let mode: String
    let frameCount: Int
    let livePreviewActive: Bool
    let fallbackActive: Bool
    let verified: Bool

    static let skipped = ControlsMediaPreviewVerificationResult(
        mode: "skipped",
        frameCount: 0,
        livePreviewActive: false,
        fallbackActive: false,
        verified: true
    )
}

enum ControlsMediaPreviewVerifier {
    static func verify(
        windowID: UInt32?,
        requireLivePreview: Bool
    ) async -> ControlsMediaPreviewVerificationResult {
        guard CGPreflightScreenCaptureAccess() else {
            return fallback(mode: "fallback_permission", verified: !requireLivePreview)
        }
        guard let windowID else {
            return fallback(mode: "fallback_no_window", verified: !requireLivePreview)
        }
        do {
            guard let window = try await ControlsMediaPreviewCaptureSupport.resolveWindow(windowID: windowID) else {
                return fallback(mode: "fallback_window_unavailable", verified: !requireLivePreview)
            }
            let counter = ControlsMediaPreviewFrameCounter()
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let stream = SCStream(
                filter: filter,
                configuration: ControlsMediaPreviewCaptureSupport.configuration(),
                delegate: nil
            )
            try stream.addStreamOutput(counter, type: .screen, sampleHandlerQueue: counter.outputQueue)
            do {
                try await stream.startCapture()
                try await Task.sleep(nanoseconds: 700_000_000)
                try await stream.stopCapture()
            } catch {
                try? await stream.stopCapture()
                throw error
            }
            let frameCount = counter.frameCount
            guard frameCount > 0 else {
                return fallback(mode: "fallback_no_frames", verified: !requireLivePreview)
            }
            return ControlsMediaPreviewVerificationResult(
                mode: "live",
                frameCount: frameCount,
                livePreviewActive: true,
                fallbackActive: false,
                verified: true
            )
        } catch {
            mediaPreviewLog.error("live preview verification fell back: \(error.localizedDescription)")
            return fallback(mode: "fallback_stream_error", verified: !requireLivePreview)
        }
    }

    private static func fallback(mode: String, verified: Bool) -> ControlsMediaPreviewVerificationResult {
        ControlsMediaPreviewVerificationResult(
            mode: mode,
            frameCount: 0,
            livePreviewActive: false,
            fallbackActive: true,
            verified: verified
        )
    }
}

private final class ControlsMediaPreviewFrameCounter: NSObject, SCStreamOutput, @unchecked Sendable {
    let outputQueue = DispatchQueue(
        label: "local.codex.hover-pocket.media-preview.verify",
        qos: .userInteractive
    )
    private let lock = NSLock()
    private var count = 0

    var frameCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen,
              ControlsMediaPreviewCaptureSupport.isCompleteFrame(sampleBuffer)
        else {
            return
        }
        lock.lock()
        count += 1
        lock.unlock()
    }
}
