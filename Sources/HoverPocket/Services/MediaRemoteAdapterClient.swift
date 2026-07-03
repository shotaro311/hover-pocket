import Foundation
import os

private let adapterLog = Logger(subsystem: "local.codex.hover-pocket", category: "MediaRemoteAdapter")

/// macOS 15.4 以降、第三者バイナリからの MediaRemote 呼び出し（再生/停止・シーク等の
/// コマンド送信）はエンタイトルメントがないと無音で失敗する。そのため、Apple 署名の
/// /usr/bin/perl に同梱の mediaremote-adapter dylib をロードさせ、コマンドを中継する。
/// adapter が返す Now Playing ペイロード（マイクロ秒単位の生値を保持する）
struct AdapterNowPlaying: Sendable {
    var title: String = ""
    var artist: String = ""
    var album: String = ""
    var applicationName: String = ""
    var bundleIdentifier: String = ""
    var isPlaying = false
    var duration: TimeInterval = 0
    var elapsed: TimeInterval = 0
    var playbackRate: Double = 0
    var artworkData: Data?
    var timestamp: Date?

    /// イベント受信後の経過を再生レートで外挿した現在位置
    var extrapolatedElapsed: TimeInterval {
        guard isPlaying, let timestamp else { return elapsed }
        let delta = Date().timeIntervalSince(timestamp)
        guard delta > 0 else { return elapsed }
        let rate = playbackRate > 0 ? playbackRate : 1
        let value = elapsed + delta * rate
        return duration > 0 ? min(value, duration) : value
    }

    init?(payload: [String: Any]) {
        func string(_ key: String) -> String {
            payload[key] as? String ?? ""
        }
        func number(_ key: String) -> Double? {
            (payload[key] as? NSNumber)?.doubleValue
        }
        title = string("title")
        artist = string("artist")
        album = string("album")
        applicationName = string("applicationName")
        bundleIdentifier = string("bundleIdentifier")
        duration = (number("durationMicros") ?? 0) / 1_000_000
        elapsed = (number("elapsedTimeMicros") ?? 0) / 1_000_000
        playbackRate = number("playbackRate") ?? 0
        if let isPlayingValue = payload["isPlaying"] as? NSNumber {
            isPlaying = isPlayingValue.boolValue
        } else {
            isPlaying = playbackRate > 0
        }
        if let base64 = payload["artworkDataBase64"] as? String, !base64.isEmpty {
            artworkData = Data(base64Encoded: base64)
        }
        if let timestampMicros = number("timestampEpochMicros"), timestampMicros > 0 {
            timestamp = Date(timeIntervalSince1970: timestampMicros / 1_000_000)
        }
        let hasContent = !title.isEmpty || !artist.isEmpty || !album.isEmpty || duration > 0
            || !bundleIdentifier.isEmpty || !applicationName.isEmpty
        guard hasContent else { return nil }
    }
}

final class MediaRemoteAdapterClient: @unchecked Sendable {
    private let dylibPath: String?
    private let scriptPath: String?

    private let streamLock = NSLock()
    private var streamProcess: Process?
    private var streamBuffer = Data()
    private var mergedPayload: [String: Any] = [:]
    private var isListening = false
    private var streamRestartCount = 0
    private var onStreamEvent: (@Sendable (AdapterNowPlaying?) -> Void)?

    init() {
        dylibPath = Self.locateDylib()
        scriptPath = Self.locateRunScript()
        if dylibPath == nil || scriptPath == nil {
            adapterLog.error("mediaremote-adapter unavailable (dylib: \(self.dylibPath ?? "missing"), script: \(self.scriptPath ?? "missing"))")
        }
    }

    var isAvailable: Bool {
        dylibPath != nil && scriptPath != nil
    }

    func togglePlayPause() async -> Bool {
        await run(command: "toggle_play_pause")
    }

    func setElapsedTime(_ seconds: TimeInterval) async -> Bool {
        await run(command: "set_time", arguments: [String(max(0, seconds))])
    }

    // MARK: - One-shot get

    func fetchNowPlaying() async -> AdapterNowPlaying? {
        guard let dylibPath, let scriptPath else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [scriptPath, dylibPath, "get"]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        let completion = ProcessCompletionGate()
        // 出力（アートワーク込みで数百KB になり得る）はパイプ容量を超えるため、
        // 終了を待ってから読むのではなく逐次読み出して溜める
        let outputBox = DataAccumulator()
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            outputBox.append(data)
        }
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in
                guard completion.tryClaim() else { return }
                let remaining = try? outputPipe.fileHandleForReading.readToEnd()
                outputPipe.fileHandleForReading.readabilityHandler = nil
                if let remaining {
                    outputBox.append(remaining)
                }
                continuation.resume(returning: Self.parseEventLine(outputBox.value))
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                if completion.tryClaim() {
                    adapterLog.error("adapter get launch failed: \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                }
                return
            }
            Task.detached(priority: .utility) {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard completion.tryClaim() else { return }
                adapterLog.error("adapter get timed out")
                if process.isRunning {
                    process.terminate()
                }
                continuation.resume(returning: nil)
            }
        }
    }

    // MARK: - Streaming (loop)

    /// Now Playing の変更イベント購読を開始する。イベントは任意のスレッドから届く。
    /// `nil` は「再生中メディアなし」を意味する。
    func startListening(onEvent: @escaping @Sendable (AdapterNowPlaying?) -> Void) {
        streamLock.lock()
        defer { streamLock.unlock() }
        onStreamEvent = onEvent
        guard !isListening else { return }
        isListening = true
        streamRestartCount = 0
        startStreamProcessLocked()
    }

    func stopListening() {
        streamLock.lock()
        let process = streamProcess
        streamProcess = nil
        isListening = false
        onStreamEvent = nil
        streamBuffer = Data()
        mergedPayload = [:]
        streamLock.unlock()
        process?.terminationHandler = nil
        if let process, process.isRunning {
            process.terminate()
        }
    }

    private func startStreamProcessLocked() {
        guard let dylibPath, let scriptPath else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [scriptPath, dylibPath, "loop"]
        // stdin を繋いでおくと、親プロセス終了時に perl 側が EOF を検知して自終了する
        process.standardInput = Pipe()
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.consumeStreamData(data)
        }
        process.terminationHandler = { [weak self] _ in
            self?.handleStreamTermination()
        }
        do {
            try process.run()
            streamProcess = process
        } catch {
            adapterLog.error("adapter loop launch failed: \(error.localizedDescription)")
            isListening = false
        }
    }

    private func handleStreamTermination() {
        streamLock.lock()
        streamProcess = nil
        streamBuffer = Data()
        let shouldRestart = isListening
        let restartCount = streamRestartCount
        streamRestartCount += 1
        streamLock.unlock()
        guard shouldRestart else { return }
        let delay = min(Double(restartCount) * 1.0 + 0.5, 5.0)
        adapterLog.error("adapter loop terminated; restarting in \(delay, format: .fixed(precision: 1))s")
        Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            self?.restartStreamIfNeeded()
        }
    }

    private func restartStreamIfNeeded() {
        streamLock.lock()
        defer { streamLock.unlock() }
        guard isListening, streamProcess == nil else { return }
        startStreamProcessLocked()
    }

    private func consumeStreamData(_ data: Data) {
        var events: [AdapterNowPlaying?] = []
        streamLock.lock()
        streamBuffer.append(data)
        while let newlineIndex = streamBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = streamBuffer.prefix(upTo: newlineIndex)
            streamBuffer.removeSubrange(...newlineIndex)
            guard !lineData.isEmpty else { continue }
            if lineData == Data("NIL".utf8) {
                mergedPayload = [:]
                events.append(nil)
                continue
            }
            guard let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let payload = object["payload"] as? [String: Any]
            else {
                adapterLog.debug("adapter loop line could not be parsed (\(lineData.count) bytes)")
                continue
            }
            let isDiff = (object["diff"] as? NSNumber)?.boolValue ?? false
            if !isDiff {
                mergedPayload = [:]
            }
            for (key, value) in payload {
                if value is NSNull {
                    mergedPayload.removeValue(forKey: key)
                } else {
                    mergedPayload[key] = value
                }
            }
            events.append(AdapterNowPlaying(payload: mergedPayload))
        }
        let callback = onStreamEvent
        streamLock.unlock()
        guard let callback else { return }
        for event in events {
            callback(event)
        }
    }

    private static func parseEventLine(_ data: Data) -> AdapterNowPlaying? {
        let line: Data
        if let newlineIndex = data.firstIndex(of: UInt8(ascii: "\n")) {
            line = data.prefix(upTo: newlineIndex)
        } else {
            line = data
        }
        guard !line.isEmpty, line != Data("NIL".utf8) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = object["payload"] as? [String: Any]
        else {
            return nil
        }
        return AdapterNowPlaying(payload: payload)
    }

    private func run(command: String, arguments: [String] = [], timeout: TimeInterval = 3.0) async -> Bool {
        guard let dylibPath, let scriptPath else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [scriptPath, dylibPath, command] + arguments
        process.standardOutput = Pipe()
        let errorPipe = Pipe()
        process.standardError = errorPipe

        let completion = ProcessCompletionGate()
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { finished in
                guard completion.tryClaim() else { return }
                let succeeded = finished.terminationStatus == 0
                if !succeeded {
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    let message = String(data: errorData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    adapterLog.error("adapter command \(command) failed (status \(finished.terminationStatus)): \(message)")
                }
                continuation.resume(returning: succeeded)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                if completion.tryClaim() {
                    adapterLog.error("adapter perl launch failed: \(error.localizedDescription)")
                    continuation.resume(returning: false)
                }
                return
            }
            Task.detached(priority: .utility) {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard completion.tryClaim() else { return }
                adapterLog.error("adapter command \(command) timed out after \(timeout, format: .fixed(precision: 1))s")
                if process.isRunning {
                    process.terminate()
                }
                continuation.resume(returning: false)
            }
        }
    }

    private static func locateDylib() -> String? {
        let fileName = "libMediaRemoteAdapter.dylib"
        var candidates: [URL] = []
        if let frameworksURL = Bundle.main.privateFrameworksURL {
            candidates.append(frameworksURL.appendingPathComponent(fileName))
        }
        if let executableURL = Bundle.main.executableURL {
            // swift build / swift run では実行ファイルと同じディレクトリに生成される
            candidates.append(executableURL.deletingLastPathComponent().appendingPathComponent(fileName))
        }
        return candidates.first { FileManager.default.isReadableFile(atPath: $0.path) }?.path
    }

    private static func locateRunScript() -> String? {
        var candidates: [URL] = []
        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent("mediaremote-adapter.pl"))
        }
        if let executableURL = Bundle.main.executableURL {
            candidates.append(
                executableURL.deletingLastPathComponent()
                    .appendingPathComponent("MediaRemoteAdapter_MediaRemoteAdapter.bundle/run.pl")
            )
        }
        return candidates.first { FileManager.default.isReadableFile(atPath: $0.path) }?.path
    }
}

private final class DataAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

private final class ProcessCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isClaimed = false

    func tryClaim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if isClaimed { return false }
        isClaimed = true
        return true
    }
}
