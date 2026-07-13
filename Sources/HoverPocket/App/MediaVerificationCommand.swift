import Foundation

enum MediaVerificationCommand {
    static func run() -> Never {
        let outputURL = outputFileURL()
        let semaphore = DispatchSemaphore(value: 0)
        let resultBox = MediaVerificationResultBox()
        let requestedRate = requestedPlaybackRate()

        let shouldTogglePlayback = CommandLine.arguments.contains("--toggle-playback")
        let shouldVerifyLivePreview = CommandLine.arguments.contains("--verify-live-preview")
        let shouldVerifyLivePreviewFallback = CommandLine.arguments.contains("--verify-live-preview-fallback")

        Task<Void, Never> {
            let service = MediaRemoteService()
            let initialState = await service.nowPlaying()
            if let requestedRate {
                _ = await service.setPlaybackSpeed(
                    requestedRate,
                    delta: requestedRate - initialState.playbackRate,
                    mediaURLString: initialState.mediaURLString,
                    preferredTitle: initialState.title
                )
                try? await Task.sleep(nanoseconds: 1_800_000_000)
            }
            // 再生/停止コマンドが実際に効くか（状態が反転するか）を検証し、元の状態へ戻す。
            // 読み取りが成功するだけでは macOS 15.4+ のコマンド遮断を検出できない。
            var toggleVerified: Bool?
            let usesCommandStream = shouldTogglePlayback && service.isAdapterAvailable
            if usesCommandStream {
                service.startNowPlayingStream { _ in }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            if shouldTogglePlayback, initialState.hasMedia {
                let wasPlaying = initialState.isPlaying
                await service.togglePlayPause()
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                let toggledState = await service.nowPlaying()
                toggleVerified = toggledState.hasMedia && toggledState.isPlaying != wasPlaying
                await service.togglePlayPause()
                try? await Task.sleep(nanoseconds: 800_000_000)
            } else if shouldTogglePlayback {
                toggleVerified = false
            }
            if usesCommandStream {
                service.stopNowPlayingStream()
            }
            let state = await service.nowPlaying()
            let livePreviewResult = shouldVerifyLivePreview || shouldVerifyLivePreviewFallback
                ? await ControlsMediaPreviewVerifier.verify(
                    windowID: shouldVerifyLivePreviewFallback ? nil : state.previewWindowID,
                    requireLivePreview: shouldVerifyLivePreview
                )
                : .skipped
            let requestedRateText = requestedRate.map { String($0) } ?? ""
            let playbackRateVerified = playbackRateVerificationResult(
                initialRate: initialState.playbackRate,
                finalRate: state.playbackRate,
                requestedRate: requestedRate
            )
            let didVerify = state.hasMedia
                && playbackRateVerified
                && (toggleVerified ?? true)
                && livePreviewResult.verified
            resultBox.outputLines = [
                "media_has_media=\(state.hasMedia)",
                "media_title=\(state.title)",
                "media_source=\(state.sourceName)",
                "media_duration=\(state.duration)",
                "media_progress=\(state.progress)",
                "media_is_playing=\(state.isPlaying)",
                "media_playback_rate_before=\(initialState.playbackRate)",
                "media_playback_rate=\(state.playbackRate)",
                "media_requested_playback_rate=\(requestedRateText)",
                "media_playback_rate_verified=\(playbackRateVerified)",
                "media_toggle_verified=\(toggleVerified.map(String.init) ?? "skipped")",
                "media_toggle_transport=\(usesCommandStream ? "adapter_stream" : "one_shot")",
                "media_has_artwork=\(state.artworkData != nil)",
                "media_url=\(state.mediaURLString ?? "")",
                "media_preview_window_id=\(state.previewWindowID.map(String.init) ?? "")",
                "media_live_preview_mode=\(livePreviewResult.mode)",
                "media_live_preview_frames=\(livePreviewResult.frameCount)",
                "media_live_preview_active=\(livePreviewResult.livePreviewActive)",
                "media_live_preview_fallback=\(livePreviewResult.fallbackActive)",
                "media_live_preview_verified=\(livePreviewResult.verified)",
                "media_verify=\(didVerify ? "ok" : "failed")"
            ]
            resultBox.exitCode = didVerify ? 0 : 1
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + 16) == .timedOut {
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

    private static func requestedPlaybackRate() -> Double? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--set-playback-rate") else {
            return nil
        }
        let valueIndex = arguments.index(after: index)
        guard arguments.indices.contains(valueIndex) else {
            return nil
        }
        return Double(arguments[valueIndex])
    }

    private static func playbackRateVerificationResult(
        initialRate: Double,
        finalRate: Double,
        requestedRate: Double?
    ) -> Bool {
        guard let requestedRate else {
            return true
        }
        return abs(finalRate - requestedRate) <= 0.06
    }
}

private final class MediaVerificationResultBox: @unchecked Sendable {
    var outputLines: [String] = []
    var exitCode: Int32 = 1
}
