import Foundation

enum MediaVerificationCommand {
    static func run() -> Never {
        let outputURL = outputFileURL()
        let semaphore = DispatchSemaphore(value: 0)
        let resultBox = MediaVerificationResultBox()
        let requestedRate = requestedPlaybackRate()
        let requestedMediaURLString = requestedMediaURLString()

        let shouldTogglePlayback = CommandLine.arguments.contains("--toggle-playback")
        let shouldVerifyLivePreview = CommandLine.arguments.contains("--verify-live-preview")
        let shouldVerifyLivePreviewFallback = CommandLine.arguments.contains("--verify-live-preview-fallback")

        Task<Void, Never> {
            let service = MediaRemoteService()
            let initialState = await service.nowPlaying()
            let verificationMediaURLString = requestedMediaURLString ?? initialState.mediaURLString
            let verificationTitle = requestedMediaURLString == nil ? initialState.title : ""
            let rateVerification = await verifyPlaybackRate(
                service: service,
                mediaURLString: verificationMediaURLString,
                preferredTitle: verificationTitle,
                requestedRate: requestedRate
            )
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
            let didVerify = state.hasMedia
                && rateVerification.changeVerified
                && rateVerification.restoreVerified
                && (toggleVerified ?? true)
                && livePreviewResult.verified
            let displayedRate = rateVerification.readback ?? state.playbackRate
            let readbackSource = requestedRate == nil
                ? "not_requested"
                : (rateVerification.readback == nil ? "unavailable" : "browser_dom")
            let restoredRateText = rateVerification.restored.map { String($0) } ?? ""
            let restoreVerifiedText = requestedRate == nil
                ? "skipped"
                : String(rateVerification.restoreVerified)
            resultBox.outputLines = [
                "media_has_media=\(state.hasMedia)",
                "media_title=\(state.title)",
                "media_source=\(state.sourceName)",
                "media_duration=\(state.duration)",
                "media_progress=\(state.progress)",
                "media_is_playing=\(state.isPlaying)",
                "media_playback_rate_before=\(rateVerification.before ?? initialState.playbackRate)",
                "media_playback_rate=\(displayedRate)",
                "media_requested_playback_rate=\(requestedRateText)",
                "media_playback_rate_verified=\(rateVerification.changeVerified)",
                "media_playback_rate_readback_source=\(readbackSource)",
                "media_playback_rate_restored=\(restoredRateText)",
                "media_playback_rate_restore_verified=\(restoreVerifiedText)",
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

    private static func requestedMediaURLString() -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--media-url") else {
            return nil
        }
        let valueIndex = arguments.index(after: index)
        guard arguments.indices.contains(valueIndex) else {
            return nil
        }
        let value = arguments[valueIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func playbackRateVerificationResult(
        finalRate: Double?,
        requestedRate: Double
    ) -> Bool {
        guard let finalRate else { return false }
        return abs(finalRate - requestedRate) <= 0.06
    }

    private static func verifyPlaybackRate(
        service: MediaRemoteService,
        mediaURLString: String?,
        preferredTitle: String,
        requestedRate: Double?
    ) async -> PlaybackRateVerification {
        guard let requestedRate else {
            return .skipped
        }
        guard let before = await service.browserPlaybackRate(
            mediaURLString: mediaURLString,
            preferredTitle: preferredTitle
        ) else {
            return .unavailable
        }

        _ = await service.setPlaybackSpeed(
            requestedRate,
            delta: requestedRate - before,
            mediaURLString: mediaURLString,
            preferredTitle: preferredTitle
        )
        try? await Task.sleep(nanoseconds: 650_000_000)
        let readback = await service.browserPlaybackRate(
            mediaURLString: mediaURLString,
            preferredTitle: preferredTitle
        )
        let changeVerified = playbackRateVerificationResult(
            finalRate: readback,
            requestedRate: requestedRate
        )

        _ = await service.setPlaybackSpeed(
            before,
            delta: before - (readback ?? requestedRate),
            mediaURLString: mediaURLString,
            preferredTitle: preferredTitle
        )
        try? await Task.sleep(nanoseconds: 650_000_000)
        let restored = await service.browserPlaybackRate(
            mediaURLString: mediaURLString,
            preferredTitle: preferredTitle
        )
        let restoreVerified = restored.map { abs($0 - before) <= 0.06 } ?? false
        return PlaybackRateVerification(
            before: before,
            readback: readback,
            restored: restored,
            changeVerified: changeVerified,
            restoreVerified: restoreVerified
        )
    }
}

private struct PlaybackRateVerification {
    let before: Double?
    let readback: Double?
    let restored: Double?
    let changeVerified: Bool
    let restoreVerified: Bool

    static let skipped = PlaybackRateVerification(
        before: nil,
        readback: nil,
        restored: nil,
        changeVerified: true,
        restoreVerified: true
    )

    static let unavailable = PlaybackRateVerification(
        before: nil,
        readback: nil,
        restored: nil,
        changeVerified: false,
        restoreVerified: false
    )
}

private final class MediaVerificationResultBox: @unchecked Sendable {
    var outputLines: [String] = []
    var exitCode: Int32 = 1
}
