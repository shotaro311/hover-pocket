import Foundation
import os

private let adapterLog = Logger(subsystem: "local.codex.hover-pocket", category: "MediaRemoteAdapter")

/// macOS 15.4 以降、第三者バイナリからの MediaRemote 呼び出し（再生/停止・シーク等の
/// コマンド送信）はエンタイトルメントがないと無音で失敗する。そのため、Apple 署名の
/// /usr/bin/perl に同梱の mediaremote-adapter dylib をロードさせ、コマンドを中継する。
final class MediaRemoteAdapterClient: @unchecked Sendable {
    private let dylibPath: String?
    private let scriptPath: String?

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
