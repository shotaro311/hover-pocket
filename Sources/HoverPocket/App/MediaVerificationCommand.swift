import Foundation

enum MediaVerificationCommand {
    static func run() -> Never {
        let outputURL = outputFileURL()
        let semaphore = DispatchSemaphore(value: 0)
        let resultBox = MediaVerificationResultBox()

        Task {
            let state = await MediaRemoteService().nowPlaying()
            resultBox.outputLines = [
                "media_has_media=\(state.hasMedia)",
                "media_title=\(state.title)",
                "media_source=\(state.sourceName)",
                "media_duration=\(state.duration)",
                "media_progress=\(state.progress)",
                "media_is_playing=\(state.isPlaying)",
                "media_playback_rate=\(state.playbackRate)",
                "media_has_artwork=\(state.artworkData != nil)",
                "media_verify=\(state.hasMedia ? "ok" : "failed")"
            ]
            resultBox.exitCode = state.hasMedia ? 0 : 1
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + 8) == .timedOut {
            resultBox.outputLines = [
                "media_has_media=false",
                "media_verify=timeout"
            ]
            resultBox.exitCode = 1
        }
        resultBox.outputLines.forEach { print($0) }
        if let outputURL {
            let output = resultBox.outputLines.joined(separator: "\n") + "\n"
            try? output.write(to: outputURL, atomically: true, encoding: .utf8)
        }
        exit(resultBox.exitCode)
    }

    private static func outputFileURL() -> URL? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--verify-output") else {
            return nil
        }
        let pathIndex = arguments.index(after: index)
        guard arguments.indices.contains(pathIndex) else {
            return nil
        }
        return URL(fileURLWithPath: arguments[pathIndex])
    }
}

private final class MediaVerificationResultBox: @unchecked Sendable {
    var outputLines: [String] = []
    var exitCode: Int32 = 1
}
