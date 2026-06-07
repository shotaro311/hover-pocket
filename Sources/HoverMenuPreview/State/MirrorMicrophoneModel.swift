@preconcurrency import AVFoundation
import Foundation
import OSLog

enum MirrorMicrophoneStatus: Equatable {
    case idle
    case requestingPermission
    case running
    case denied
    case restricted
    case unavailable
    case failed(String)
}

enum MirrorMicrophoneRecordingState: Equatable {
    case idle
    case recording
    case readyToPlay
    case playing
}

@MainActor
final class MirrorMicrophoneModel: ObservableObject {
    private static let logger = Logger(subsystem: "local.codex.hover-menu-preview", category: "mirror-microphone")
    static let shared = MirrorMicrophoneModel()

    @Published private(set) var status: MirrorMicrophoneStatus = .idle
    @Published private(set) var level: Double = 0
    @Published private(set) var inputName: String = "Default Input"
    @Published private(set) var recordingState: MirrorMicrophoneRecordingState = .idle

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let levelPublisher = MicrophoneLevelPublisher()
    private let recordingStore = MicrophoneRecordingStore()
    private var isEngineConfigured = false
    private var isPlayerAttached = false
    private var wantsMonitoring = false
    private var currentTapFormat: AVAudioFormat?
    private var playbackID: UUID?

    private init() {
        updateInputName()
    }

    var isRunning: Bool {
        if case .running = status {
            return true
        }
        return false
    }

    var canUseRecordingControl: Bool {
        isRunning || recordingState == .readyToPlay || recordingState == .playing
    }

    func setMonitoringActive(_ active: Bool) {
        guard wantsMonitoring != active else {
            if active {
                startMonitoring()
            }
            return
        }

        wantsMonitoring = active
        active ? startMonitoring() : stopMonitoring()
    }

    func toggleRecordingPlayback() {
        switch recordingState {
        case .idle:
            startRecording()
        case .recording:
            stopRecording()
        case .readyToPlay:
            playRecording()
        case .playing:
            stopPlayback(clearRecording: true)
        }
    }

    private func startMonitoring() {
        updateInputName()

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startEngine()
        case .notDetermined:
            requestPermission()
        case .denied:
            status = .denied
        case .restricted:
            status = .restricted
        @unknown default:
            status = .failed("Unknown microphone permission state.")
        }
    }

    private func stopMonitoring() {
        playbackID = nil
        recordingStore.clear()
        recordingState = .idle

        if isPlayerAttached {
            playerNode.stop()
        }

        guard isEngineConfigured else {
            status = .idle
            level = 0
            currentTapFormat = nil
            return
        }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isEngineConfigured = false
        currentTapFormat = nil
        level = 0
        status = .idle
    }

    private func requestPermission() {
        status = .requestingPermission
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                guard self.wantsMonitoring else {
                    self.status = .idle
                    return
                }
                granted ? self.startEngine() : (self.status = .denied)
            }
        }
    }

    private func startEngine() {
        guard wantsMonitoring else {
            status = .idle
            level = 0
            return
        }

        guard !engine.isRunning else {
            status = .running
            return
        }

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            status = .unavailable
            return
        }
        currentTapFormat = format
        Self.logger.notice(
            "microphone tap format: \(Int(format.channelCount), privacy: .public)ch \(format.sampleRate, privacy: .public)Hz"
        )

        configurePlayerIfNeeded(format: format)

        inputNode.removeTap(onBus: 0)
        let levelPublisher = levelPublisher
        let recordingStore = recordingStore
        let levelTarget = MicrophoneLevelUpdateTarget { [weak self] normalized in
            self?.level = normalized
        }
        inputNode.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: format,
            block: MicrophoneAudioTap.makeTap(
                levelPublisher: levelPublisher,
                recordingStore: recordingStore,
                target: levelTarget
            )
        )
        isEngineConfigured = true

        do {
            engine.prepare()
            try engine.start()
            status = .running
        } catch {
            inputNode.removeTap(onBus: 0)
            isEngineConfigured = false
            currentTapFormat = nil
            level = 0
            status = .failed("Microphone could not start.")
        }
    }

    private func configurePlayerIfNeeded(format: AVAudioFormat) {
        if !isPlayerAttached {
            engine.attach(playerNode)
            isPlayerAttached = true
        }

        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
    }

    private func startRecording() {
        guard isRunning, let format = currentTapFormat else {
            setMonitoringActive(true)
            return
        }

        stopPlayback(clearRecording: true)
        recordingStore.start(format: format, maxDuration: 20)
        recordingState = .recording
        Self.logger.notice("microphone temp recording started")
    }

    private func stopRecording() {
        guard recordingState == .recording else { return }
        let snapshot = recordingStore.stop()

        if snapshot == nil {
            recordingStore.clear()
            recordingState = .idle
        } else {
            recordingState = .readyToPlay
        }
        Self.logger.notice("microphone temp recording stopped")
    }

    private func playRecording() {
        guard recordingState == .readyToPlay,
              let snapshot = recordingStore.snapshot(),
              !snapshot.buffers.isEmpty
        else {
            recordingStore.clear()
            recordingState = .idle
            return
        }

        if !engine.isRunning {
            startEngine()
        }

        guard engine.isRunning else {
            status = .failed("Microphone playback could not start.")
            return
        }

        playerNode.stop()
        configurePlayerIfNeeded(format: snapshot.format)

        let id = UUID()
        playbackID = id
        let completionTarget = MicrophonePlaybackCompletionTarget { [weak self] completedID in
            self?.finishPlayback(id: completedID)
        }
        for (index, buffer) in snapshot.buffers.enumerated() {
            if index == snapshot.buffers.indices.last {
                playerNode.scheduleBuffer(buffer, completionHandler: {
                    completionTarget.complete(id)
                })
            } else {
                playerNode.scheduleBuffer(buffer, completionHandler: nil)
            }
        }

        playerNode.play()
        recordingState = .playing
        Self.logger.notice("microphone temp recording playback started")
    }

    private func stopPlayback(clearRecording: Bool) {
        playbackID = nil
        if isPlayerAttached {
            playerNode.stop()
        }

        if clearRecording {
            recordingStore.clear()
            recordingState = .idle
        } else if recordingStore.hasRecording {
            recordingState = .readyToPlay
        } else {
            recordingState = .idle
        }
    }

    private func finishPlayback(id: UUID) {
        guard playbackID == id else { return }
        stopPlayback(clearRecording: true)
        Self.logger.notice("microphone temp recording playback finished and cleared")
    }

    private func updateInputName() {
        if let device = AVCaptureDevice.default(for: .audio) {
            inputName = device.localizedName
        } else {
            inputName = "No Input"
        }
    }
}

private enum MicrophoneAudioTap {
    static func makeTap(
        levelPublisher: MicrophoneLevelPublisher,
        recordingStore: MicrophoneRecordingStore,
        target: MicrophoneLevelUpdateTarget
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in
            if recordingStore.isRecording {
                recordingStore.append(buffer)
            }

            guard let normalized = level(from: buffer),
                  levelPublisher.shouldPublish(normalized)
            else {
                return
            }

            target.publish(normalized)
        }
    }

    private static func level(from buffer: AVAudioPCMBuffer) -> Double? {
        guard let channelData = buffer.floatChannelData else { return nil }
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        guard channelCount > 0, frameLength > 0 else { return nil }

        var sum: Float = 0
        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for frame in 0..<frameLength {
                let sample = samples[frame]
                sum += sample * sample
            }
        }

        let mean = sum / Float(channelCount * frameLength)
        let rms = Double(sqrt(mean))
        guard rms.isFinite, rms > 0 else { return 0 }

        let decibels = 20 * log10(rms)
        let noiseFloor = -64.0
        let ceiling = -12.0
        let normalized = (decibels - noiseFloor) / (ceiling - noiseFloor)
        return pow(min(max(normalized, 0), 1), 0.65)
    }
}

private struct MicrophoneLevelUpdateTarget: @unchecked Sendable {
    private let update: @MainActor @Sendable (Double) -> Void

    init(update: @escaping @MainActor @Sendable (Double) -> Void) {
        self.update = update
    }

    func publish(_ level: Double) {
        Task { @MainActor in
            update(level)
        }
    }
}

private struct MicrophonePlaybackCompletionTarget: @unchecked Sendable {
    private let completePlayback: @MainActor @Sendable (UUID) -> Void

    init(completePlayback: @escaping @MainActor @Sendable (UUID) -> Void) {
        self.completePlayback = completePlayback
    }

    func complete(_ id: UUID) {
        Task { @MainActor in
            completePlayback(id)
        }
    }
}

private final class MicrophoneLevelPublisher: @unchecked Sendable {
    private let lock = NSLock()
    private var lastPublishedLevel: Double = 0
    private var lastPublishTime: TimeInterval = 0

    func shouldPublish(_ level: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let now = Date().timeIntervalSinceReferenceDate
        guard now - lastPublishTime > 1.0 / 24.0 || abs(level - lastPublishedLevel) > 0.05 else {
            return false
        }

        lastPublishTime = now
        lastPublishedLevel = level
        return true
    }
}

private struct MicrophoneRecordingSnapshot {
    let format: AVAudioFormat
    let buffers: [AVAudioPCMBuffer]
}

private final class MicrophoneRecordingStore: @unchecked Sendable {
    private let lock = NSLock()
    private var recordingFormat: AVAudioFormat?
    private var recordedBuffers: [AVAudioPCMBuffer] = []
    private var maxFrameCount: AVAudioFramePosition = 0
    private var recordedFrameCount: AVAudioFramePosition = 0
    private var recording = false

    var isRecording: Bool {
        lock.lock()
        defer { lock.unlock() }
        return recording
    }

    var hasRecording: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !recordedBuffers.isEmpty
    }

    func start(format: AVAudioFormat, maxDuration: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }

        recordingFormat = format
        recordedBuffers.removeAll(keepingCapacity: true)
        maxFrameCount = AVAudioFramePosition(format.sampleRate * maxDuration)
        recordedFrameCount = 0
        recording = true
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }

        guard recording,
              let format = recordingFormat,
              recordedFrameCount < maxFrameCount,
              let copy = Self.copy(buffer, format: format, remainingFrames: maxFrameCount - recordedFrameCount)
        else {
            return
        }

        recordedBuffers.append(copy)
        recordedFrameCount += AVAudioFramePosition(copy.frameLength)
        if recordedFrameCount >= maxFrameCount {
            recording = false
        }
    }

    func stop() -> MicrophoneRecordingSnapshot? {
        lock.lock()
        defer { lock.unlock() }

        recording = false
        guard let recordingFormat, !recordedBuffers.isEmpty else { return nil }
        return MicrophoneRecordingSnapshot(format: recordingFormat, buffers: recordedBuffers)
    }

    func snapshot() -> MicrophoneRecordingSnapshot? {
        lock.lock()
        defer { lock.unlock() }

        guard let recordingFormat, !recordedBuffers.isEmpty else { return nil }
        return MicrophoneRecordingSnapshot(format: recordingFormat, buffers: recordedBuffers)
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }

        recording = false
        recordingFormat = nil
        recordedBuffers.removeAll(keepingCapacity: false)
        recordedFrameCount = 0
        maxFrameCount = 0
    }

    private static func copy(
        _ buffer: AVAudioPCMBuffer,
        format: AVAudioFormat,
        remainingFrames: AVAudioFramePosition
    ) -> AVAudioPCMBuffer? {
        guard let sourceData = buffer.floatChannelData else { return nil }
        let frameLength = min(buffer.frameLength, AVAudioFrameCount(max(remainingFrames, 0)))
        guard frameLength > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength),
              let destinationData = copy.floatChannelData
        else {
            return nil
        }

        copy.frameLength = frameLength
        let channelCount = Int(min(buffer.format.channelCount, format.channelCount))
        let sampleCount = Int(frameLength)
        for channel in 0..<channelCount {
            destinationData[channel].update(from: sourceData[channel], count: sampleCount)
        }
        return copy
    }
}
