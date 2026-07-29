import Foundation

enum TimerVerificationCommand {
    @MainActor
    static func run() -> Never {
        let result = verify()
        let outputLines = [
            "timer_verify=\(result.ok ? "ok" : "failed")",
            "timer_defaults=\(result.defaultsValid ? "ok" : "failed")",
            "timer_formatting=\(result.formattingValid ? "ok" : "failed")",
            "timer_progress=\(result.progressValid ? "ok" : "failed")",
            "timer_lifecycle=\(result.lifecycleValid ? "ok" : "failed")",
            "timer_pin=\(result.pinValid ? "ok" : "failed")",
            "timer_storage_isolation=\(result.storageIsolationValid ? "ok" : "failed")",
            "timer_layout_side_by_side=\(result.layoutFits ? "true" : "false")",
            "timer_layout_compact=\(result.compactLayoutValid ? "true" : "false")",
            "timer_entry_widths=\(result.entryWidths)"
        ]

        outputLines.forEach { print($0) }
        if let outputURL = outputFileURL {
            let output = outputLines.joined(separator: "\n") + "\n"
            try? output.write(to: outputURL, atomically: true, encoding: .utf8)
        }
        exit(result.ok ? 0 : 1)
    }

    @MainActor
    private static func verify() -> TimerVerificationResult {
        let timerDraft = TimerPreset.defaultTimerDraft()
        let pomodoroDraft = TimerPreset.defaultPomodoroDraft()
        let defaultsValid = !timerDraft.isPomodoro
            && timerDraft.duration == 10 * 60
            && timerDraft.soundEnabled
            && pomodoroDraft.isPomodoro
            && pomodoroDraft.workDuration == 25 * 60
            && pomodoroDraft.breakDuration == 5 * 60
            && pomodoroDraft.soundEnabled

        let formattingValid = TimerView.timeText(65) == "01:05"
            && TimerView.timeText(3_661) == "1:01:01"
            && TimerView.timeText(-1) == "00:00"

        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        let running = RunningTimer(
            id: UUID(),
            title: "Verify",
            color: .blue,
            soundEnabled: false,
            isPomodoro: false,
            phase: .work,
            completedWorkCycles: 0,
            endDate: now.addingTimeInterval(30),
            phaseDuration: 60,
            pausedRemaining: nil,
            workDuration: 60,
            breakDuration: 15,
            pinnedPresetID: nil
        )
        var paused = running
        paused.pausedRemaining = 24
        let progressValid = abs(running.remaining(at: now) - 30) < 0.001
            && abs(running.progress(at: now) - 0.5) < 0.001
            && paused.isPaused
            && abs(paused.remaining(at: now.addingTimeInterval(100)) - 24) < 0.001
        let storeOperations = verifyStoreOperations()

        let layoutResults = PanelSizeOption.allCases.map { option in
            let width = PanelLayout.previewSize(for: option).width
            return (
                option: option,
                metrics: TimerLayoutMetrics(availableWidth: width)
            )
        }
        let layoutFits = layoutResults.allSatisfy(\.metrics.fitsSideBySide)
        let compactLayoutValid = TimerLayoutMetrics.compactSectionVerticalPadding <= 6
            && TimerLayoutMetrics.runningCardHeight <= 44
            && TimerLayoutMetrics.runningCardSpacing <= 5
        let entryWidths = layoutResults.map { result in
            "\(result.option.rawValue):\(format(result.metrics.entryCardWidth))"
        }
        .joined(separator: ",")

        return TimerVerificationResult(
            ok: defaultsValid
                && formattingValid
                && progressValid
                && storeOperations.lifecycleValid
                && storeOperations.pinValid
                && storeOperations.storageIsolationValid
                && layoutFits
                && compactLayoutValid,
            defaultsValid: defaultsValid,
            formattingValid: formattingValid,
            progressValid: progressValid,
            lifecycleValid: storeOperations.lifecycleValid,
            pinValid: storeOperations.pinValid,
            storageIsolationValid: storeOperations.storageIsolationValid,
            layoutFits: layoutFits,
            compactLayoutValid: compactLayoutValid,
            entryWidths: entryWidths
        )
    }

    @MainActor
    private static func verifyStoreOperations() -> (
        lifecycleValid: Bool,
        pinValid: Bool,
        storageIsolationValid: Bool
    ) {
        let storageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "hoverpocket-timer-verifier-\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            try? FileManager.default.removeItem(at: storageDirectory)
        }

        let store = TimerStore(
            storageDirectory: storageDirectory,
            observesWake: false,
            persistenceEnabled: false
        )
        var preset = TimerPreset.defaultTimerDraft()
        preset.title = "Verify"
        preset.duration = 120
        preset.soundEnabled = false

        store.start(preset: preset)
        guard let timerID = store.runningTimers.first?.id else {
            return (false, false, !FileManager.default.fileExists(atPath: storageDirectory.path))
        }
        let startValid = store.runningTimers.count == 1
            && store.runningTimers[0].title == preset.title
            && !store.runningTimers[0].isPaused

        store.pause(id: timerID)
        let pauseValid = store.runningTimers.first?.isPaused == true
            && (store.runningTimers.first?.pausedRemaining ?? 0) > 0

        store.resume(id: timerID)
        let resumeValid = store.runningTimers.first?.isPaused == false
            && (store.runningTimers.first?.endDate ?? .distantPast) > Date()

        store.togglePin(timerID: timerID)
        let pinnedPresetID = store.runningTimers.first?.pinnedPresetID
        let pinValid = pinnedPresetID != nil
            && store.pinnedPresets.count == 1
            && store.pinnedPresets.first?.id == pinnedPresetID

        store.togglePin(timerID: timerID)
        let unpinValid = store.runningTimers.first?.pinnedPresetID == nil
            && store.pinnedPresets.isEmpty

        store.stop(id: timerID)
        let stopValid = store.runningTimers.isEmpty
        let storageIsolationValid = !FileManager.default.fileExists(
            atPath: storageDirectory.path
        )

        return (
            startValid && pauseValid && resumeValid && stopValid,
            pinValid && unpinValid,
            storageIsolationValid
        )
    }

    private static var outputFileURL: URL? {
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

    private static func format(_ value: CGFloat) -> String {
        String(format: "%.1f", Double(value))
    }
}

private struct TimerVerificationResult {
    let ok: Bool
    let defaultsValid: Bool
    let formattingValid: Bool
    let progressValid: Bool
    let lifecycleValid: Bool
    let pinValid: Bool
    let storageIsolationValid: Bool
    let layoutFits: Bool
    let compactLayoutValid: Bool
    let entryWidths: String
}
