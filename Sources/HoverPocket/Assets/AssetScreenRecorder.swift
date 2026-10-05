import Foundation
@preconcurrency import AVFoundation
@preconcurrency import ScreenCaptureKit
import CoreMedia

// ScreenCaptureKit callbacks and writer state are confined to one queue.
final class AssetScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "HoverPocket.asset-recording")
    private let directory: URL
    private let systemAudio: Bool
    private let microphone: Bool
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var video: AVAssetWriterInput?
    private var audio: AVAssetWriterInput?
    private var microphoneRecorder: AVAudioRecorder?
    private var started: CMTime?
    private var microphoneStarted: CMTime?
    private var lastCapacityCheck = Date.distantPast
    private var initialContentSize: CGSize?
    private(set) var didCaptureSystemAudio = false
    private var stopped = false
    private var error: String?
    var onFailure: (@Sendable (String) -> Void)?

    init(directory: URL, systemAudio: Bool, microphone: Bool) throws {
        self.directory = directory; self.systemAudio = systemAudio; self.microphone = microphone
        super.init()
    }
    @MainActor func start(filter: SCContentFilter, size: CGSize) async throws {
        let ratio = min(1, 1920 / max(1, size.width), 1080 / max(1, size.height))
        let width = max(2, Int(size.width * ratio) / 2 * 2), height = max(2, Int(size.height * ratio) / 2 * 2)
        let writer = try AVAssetWriter(outputURL: directory.appendingPathComponent("screen.mp4"), fileType: .mp4)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height, AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000, AVVideoExpectedSourceFrameRateKey: 30]])
        video.expectsMediaDataInRealTime = true; writer.add(video)
        var audio: AVAssetWriterInput?
        if systemAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000])
            input.expectsMediaDataInRealTime = true; writer.add(input); audio = input
        }
        self.writer = writer; self.video = video; self.audio = audio
        if microphone {
            let recorder = try AVAudioRecorder(url: directory.appendingPathComponent("microphone.m4a"), settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000])
            guard recorder.prepareToRecord() else { throw LibraryError.message("マイク収録を準備できません。") }
            microphoneStarted = CMClockGetTime(CMClockGetHostTimeClock())
            guard recorder.record() else { throw LibraryError.message("マイク収録を開始できません。") }
            microphoneRecorder = recorder
        }
        let config = SCStreamConfiguration(); config.width = width; config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30); config.queueDepth = 5
        config.capturesAudio = systemAudio; config.sampleRate = 48_000; config.channelCount = 2
        config.showsCursor = true; config.excludesCurrentProcessAudio = false
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if systemAudio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        self.stream = stream
        do { try await stream.startCapture() }
        catch { microphoneRecorder?.stop(); writer.cancelWriting(); throw error }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !stopped, sample.isValid, CMSampleBufferDataIsReady(sample), let writer else { return }
        if type == .screen {
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue else { return }
            if let rect = attachments.first?[.contentRect] as? CGRect {
                if let original = initialContentSize, abs(original.width - rect.width) > 1 || abs(original.height - rect.height) > 1 {
                    fail("収録対象のサイズが変わったため停止しました。新しいサイズで再開してください。"); return
                }
                initialContentSize = rect.size
            }
            if started == nil {
                let time = CMSampleBufferGetPresentationTimeStamp(sample)
                guard writer.startWriting() else { fail("収録ファイルを作成できません。空き容量を確認してください。"); return }
                writer.startSession(atSourceTime: time); started = time
            }
            if video?.isReadyForMoreMediaData == true, video?.append(sample) == false { fail("動画の保存に失敗しました。") }
        } else if type == .audio, let started, CMSampleBufferGetPresentationTimeStamp(sample) >= started, audio?.isReadyForMoreMediaData == true {
            if audio?.append(sample) == true { didCaptureSystemAudio = true }
            else { fail("システム音の保存に失敗しました。") }
        }
        if Date().timeIntervalSince(lastCapacityCheck) >= 2 {
            lastCapacityCheck = Date()
            if let free = try? FileManager.default.attributesOfFileSystem(forPath: directory.path)[.systemFreeSize] as? NSNumber,
               free.int64Value < 512 * 1024 * 1024 { fail("空き容量が少ないため収録を停止しました。") }
        }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { queue.async { self.fail("収録対象が終了したか、画面取得が停止しました。") } }
    private func fail(_ message: String) {
        guard error == nil else { return }; error = message; onFailure?(message)
    }
    func stop() async throws -> URL {
        if let stream { try? await stream.stopCapture() }; stream = nil
        microphoneRecorder?.stop(); microphoneRecorder = nil
        let writer = await withCheckedContinuation { continuation in
            queue.async {
                self.stopped = true; self.video?.markAsFinished(); self.audio?.markAsFinished()
                continuation.resume(returning: self.writer)
            }
        }
        guard let writer, started != nil else { throw LibraryError.message("収録映像を取得できませんでした。") }
        await writer.finishWriting()
        guard writer.status == .completed else { throw LibraryError.message("動画を確定できませんでした。未完了ファイルを保持します。") }
        let screen = AVURLAsset(url: directory.appendingPathComponent("screen.mp4"))
        let duration = try await screen.load(.duration)
        guard duration.seconds.isFinite, duration.seconds > 0 else { throw LibraryError.message("収録時間を確認できません。") }
        let final = directory.appendingPathComponent("画面収録.mp4")
        let recordedAudio = try await screen.loadTracks(withMediaType: .audio)
        let needsSilentAudio = systemAudio && recordedAudio.isEmpty
        if !microphone && !needsSilentAudio { try FileManager.default.copyItem(at: directory.appendingPathComponent("screen.mp4"), to: final) }
        else {
            let composition = AVMutableComposition()
            guard let sourceVideo = try await screen.loadTracks(withMediaType: .video).first,
                  let targetVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw LibraryError.message("収録映像を読み取れません。") }
            try targetVideo.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: sourceVideo, at: .zero)
            var parameters: [AVMutableAudioMixInputParameters] = []
            var sources: [(AVURLAsset, Bool)] = [(screen, false)]
            if microphone { sources.append((AVURLAsset(url: directory.appendingPathComponent("microphone.m4a")), true)) }
            if needsSilentAudio && !microphone {
                let silent = directory.appendingPathComponent("silence.m4a")
                try Self.writeAudio(to: silent, duration: duration.seconds)
                sources.append((AVURLAsset(url: silent), false))
            }
            for (source, isMicrophone) in sources {
                if let track = try await source.loadTracks(withMediaType: .audio).first,
                   let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                    let available = try await source.load(.duration)
                    let offset = isMicrophone ? max(.zero, CMTimeSubtract(started ?? .zero, microphoneStarted ?? started ?? .zero)) : .zero
                    guard available > offset else { throw LibraryError.message("マイク音声の時間を確認できません。収録元は保持します。") }
                    try target.insertTimeRange(CMTimeRange(start: offset, duration: min(duration, available - offset)), of: track, at: .zero)
                    let param = AVMutableAudioMixInputParameters(track: target); param.setVolume(1, at: .zero); parameters.append(param)
                }
            }
            let mix = AVMutableAudioMix(); mix.inputParameters = parameters
            guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPreset1920x1080) else { throw LibraryError.message("音声を合成できません。") }
            export.outputURL = final; export.outputFileType = .mp4; export.audioMix = mix
            await export.export()
            guard export.status == .completed else { throw LibraryError.message("音声付き動画の保存に失敗しました。収録元は保持します。") }
        }
        let check = AVURLAsset(url: final)
        guard !(try await check.loadTracks(withMediaType: .video)).isEmpty else { throw LibraryError.message("保存した動画を検証できません。") }
        try Data("complete".utf8).write(to: directory.appendingPathComponent("complete"), options: .atomic)
        return final
    }
    static func writeAudio(to url: URL, duration: Double, tone: Bool = false) throws {
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000])
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
        var written: Int64 = 0, remaining = Int64(ceil(duration * 48_000))
        while remaining > 0 {
            buffer.frameLength = AVAudioFrameCount(min(remaining, 4096))
            for channel in 0..<Int(buffer.format.channelCount) {
                guard let samples = buffer.floatChannelData?[channel] else { throw LibraryError.message("音声形式を準備できません。") }
                for frame in 0..<Int(buffer.frameLength) { samples[frame] = tone ? Float(sin(Double(written + Int64(frame)) * 2 * .pi * 440 / 48_000) * 0.04) : 0 }
            }
            try file.write(from: buffer); written += Int64(buffer.frameLength); remaining -= Int64(buffer.frameLength)
        }
    }
}
