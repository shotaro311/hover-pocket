import AppKit
import Foundation
import SwiftUI

enum TimerVerificationCommand {
    @MainActor
    static func run() -> Never {
        _ = NSApplication.shared
        let result = verify()
        var outputLines = [
            "timer_verify=\(result.ok ? "ok" : "failed")",
            "timer_defaults=\(result.defaultsValid ? "ok" : "failed")",
            "timer_formatting=\(result.formattingValid ? "ok" : "failed")",
            "timer_progress=\(result.progressValid ? "ok" : "failed")",
            "timer_lifecycle=\(result.lifecycleValid ? "ok" : "failed")",
            "timer_pin=\(result.pinValid ? "ok" : "failed")",
            "timer_storage_isolation=\(result.storageIsolationValid ? "ok" : "failed")",
            "timer_draft_migration=\(result.draftMigrationValid ? "ok" : "failed")",
            "timer_stopwatch=\(result.stopwatchValid ? "ok" : "failed")",
            "timer_concurrency=\(result.concurrencyValid ? "ok" : "failed")",
            "timer_icon_identity=\(result.iconIdentityValid ? "ok" : "failed")",
            "timer_layout_side_by_side=\(result.layoutFits ? "true" : "false")",
            "timer_layout_compact=\(result.compactLayoutValid ? "true" : "false")",
            "timer_entry_widths=\(result.entryWidths)"
        ]

        var renderValid = true
        if CommandLine.arguments.contains("--render-timer-preview") {
            do {
                for previewURL in try renderPreviews() {
                    outputLines.append("timer_preview=\(previewURL.path)")
                }
            } catch {
                renderValid = false
                outputLines.append("timer_preview_error=\(error.localizedDescription)")
            }
        }

        outputLines.forEach { print($0) }
        if let outputURL = outputFileURL {
            let output = outputLines.joined(separator: "\n") + "\n"
            try? output.write(to: outputURL, atomically: true, encoding: .utf8)
        }
        exit(result.ok && renderValid ? 0 : 1)
    }

    @MainActor
    private static func verify() -> TimerVerificationResult {
        let timerDraft = TimerPreset.defaultTimerDraft()
        let pomodoroDraft = TimerPreset.defaultPomodoroDraft()
        let stopwatchDraft = StopwatchPreset.defaultDraft()
        let defaultsValid = stopwatchDraft.title.isEmpty
            && stopwatchDraft.color == .blue
            && !timerDraft.isPomodoro
            && timerDraft.duration == 10 * 60
            && timerDraft.soundEnabled
            && pomodoroDraft.isPomodoro
            && pomodoroDraft.workDuration == 25 * 60
            && pomodoroDraft.breakDuration == 5 * 60
            && pomodoroDraft.soundEnabled

        let formattingValid = TimerView.timeText(65) == "01:05"
            && TimerView.timeText(3_661) == "1:01:01"
            && TimerView.timeText(-1) == "00:00"
            && TimerView.stopwatchTimeText(65.43) == "01:05.43"
            && TimerView.stopwatchTimeText(3_661.09) == "1:01:01.09"

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
        let draftMigrationValid = verifyLegacyDraftMigration()
        let iconIdentityValid = Set([
            TimerView.stopwatchSymbolName,
            TimerView.timerSymbolName,
            TimerView.pomodoroSymbolName
        ]).count == 3

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
            && TimerLayoutMetrics.setupCardHeight <= 180
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
                && draftMigrationValid
                && storeOperations.stopwatchValid
                && storeOperations.concurrencyValid
                && iconIdentityValid
                && layoutFits
                && compactLayoutValid,
            defaultsValid: defaultsValid,
            formattingValid: formattingValid,
            progressValid: progressValid,
            lifecycleValid: storeOperations.lifecycleValid,
            pinValid: storeOperations.pinValid,
            storageIsolationValid: storeOperations.storageIsolationValid,
            draftMigrationValid: draftMigrationValid,
            stopwatchValid: storeOperations.stopwatchValid,
            concurrencyValid: storeOperations.concurrencyValid,
            iconIdentityValid: iconIdentityValid,
            layoutFits: layoutFits,
            compactLayoutValid: compactLayoutValid,
            entryWidths: entryWidths
        )
    }

    @MainActor
    private static func verifyLegacyDraftMigration() -> Bool {
        struct LegacyDraftsSnapshot: Codable {
            var timer: TimerPreset
            var pomodoro: TimerPreset
        }

        let storageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "hoverpocket-timer-migration-\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            try? FileManager.default.removeItem(at: storageDirectory)
        }

        do {
            try FileManager.default.createDirectory(
                at: storageDirectory,
                withIntermediateDirectories: true
            )
            var timer = TimerPreset.defaultTimerDraft()
            timer.title = "Legacy timer"
            var pomodoro = TimerPreset.defaultPomodoroDraft()
            pomodoro.title = "Legacy pomodoro"
            let data = try JSONEncoder().encode(
                LegacyDraftsSnapshot(timer: timer, pomodoro: pomodoro)
            )
            try data.write(
                to: storageDirectory.appendingPathComponent("drafts.json"),
                options: .atomic
            )

            let store = TimerStore(
                storageDirectory: storageDirectory,
                observesWake: false,
                persistenceEnabled: false
            )
            return store.draftStopwatch == .defaultDraft()
                && store.draftTimer.title == timer.title
                && store.draftPomodoro.title == pomodoro.title
        } catch {
            return false
        }
    }

    @MainActor
    private static func verifyStoreOperations() -> (
        lifecycleValid: Bool,
        pinValid: Bool,
        storageIsolationValid: Bool,
        stopwatchValid: Bool,
        concurrencyValid: Bool
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
            return (
                false,
                false,
                !FileManager.default.fileExists(atPath: storageDirectory.path),
                false,
                false
            )
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

        var stopwatchDraft = StopwatchPreset.defaultDraft()
        stopwatchDraft.title = "Shoot"
        stopwatchDraft.color = .pink
        store.updateDraftStopwatch(stopwatchDraft)

        let stopwatchStart = Date(timeIntervalSinceReferenceDate: 20_000)
        store.startStopwatch(preset: stopwatchDraft, at: stopwatchStart)
        guard let firstStopwatchID = store.runningStopwatches.first?.id else {
            return (
                false,
                pinValid && unpinValid,
                !FileManager.default.fileExists(atPath: storageDirectory.path),
                false,
                false
            )
        }
        let stopwatchRunningValid = store.runningStopwatches[0].isRunning
            && store.runningStopwatches[0].title == stopwatchDraft.title
            && store.runningStopwatches[0].color == stopwatchDraft.color
            && abs(store.runningStopwatches[0].elapsed(at: stopwatchStart.addingTimeInterval(2.25)) - 2.25) < 0.001
        store.pauseStopwatch(id: firstStopwatchID, at: stopwatchStart.addingTimeInterval(3.5))
        let stopwatchPausedValid = !store.runningStopwatches[0].isRunning
            && abs(store.runningStopwatches[0].elapsed(at: stopwatchStart.addingTimeInterval(100)) - 3.5) < 0.001
        store.resumeStopwatch(id: firstStopwatchID, at: stopwatchStart.addingTimeInterval(200))
        let stopwatchResumedValid = abs(
            store.runningStopwatches[0].elapsed(at: stopwatchStart.addingTimeInterval(201.25)) - 4.75
        ) < 0.001
        for index in 1..<TimerStore.maxConcurrentStopwatches {
            var nextDraft = stopwatchDraft
            nextDraft.title = "Stopwatch \(index + 1)"
            store.startStopwatch(preset: nextDraft, at: stopwatchStart.addingTimeInterval(Double(index)))
        }
        let multipleStopwatchesValid = store.runningStopwatches.count == TimerStore.maxConcurrentStopwatches
            && !store.canStartStopwatch
            && Set(store.runningStopwatches.map(\.id)).count == TimerStore.maxConcurrentStopwatches
        store.startStopwatch(preset: stopwatchDraft, at: stopwatchStart)
        let fifthStopwatchBlocked = store.runningStopwatches.count == TimerStore.maxConcurrentStopwatches
        store.stopStopwatch(id: firstStopwatchID)
        let independentStopValid = store.runningStopwatches.count == TimerStore.maxConcurrentStopwatches - 1

        var timerOne = TimerPreset.defaultTimerDraft()
        timerOne.title = "Timer 1"
        var timerTwo = TimerPreset.defaultTimerDraft()
        timerTwo.title = "Timer 2"
        var pomodoroOne = TimerPreset.defaultPomodoroDraft()
        pomodoroOne.title = "Pomodoro 1"
        var pomodoroTwo = TimerPreset.defaultPomodoroDraft()
        pomodoroTwo.title = "Pomodoro 2"
        [timerOne, timerTwo, pomodoroOne, pomodoroTwo].forEach { store.start(preset: $0) }
        let fourTimersValid = store.runningTimers.count == TimerStore.maxConcurrentTimers
            && store.runningTimers.filter { !$0.isPomodoro }.count == 2
            && store.runningTimers.filter(\.isPomodoro).count == 2
            && !store.canStartTimer
        store.start(preset: timerOne)
        let fifthTimerBlocked = store.runningTimers.count == TimerStore.maxConcurrentTimers
        store.runningTimers.map(\.id).forEach(store.stop(id:))
        let storageIsolationValid = !FileManager.default.fileExists(
            atPath: storageDirectory.path
        )

        return (
            startValid && pauseValid && resumeValid && stopValid,
            pinValid && unpinValid,
            storageIsolationValid,
            stopwatchRunningValid
                && stopwatchPausedValid
                && stopwatchResumedValid
                && multipleStopwatchesValid
                && fifthStopwatchBlocked
                && independentStopValid,
            TimerStore.maxConcurrentStopwatches == 4
                && TimerStore.maxConcurrentTimers == 4
                && fourTimersValid
                && fifthTimerBlocked
        )
    }

    @MainActor
    private static func renderPreviews() throws -> [URL] {
        let outputDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("dist/verification", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let suiteName = "local.codex.hover-pocket.timer-preview.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        let store = TimerStore(observesWake: false, persistenceEnabled: false)
        var stopwatch = StopwatchPreset.defaultDraft()
        stopwatch.title = "撮影"
        store.updateDraftStopwatch(stopwatch)
        store.startStopwatch(preset: stopwatch, at: Date().addingTimeInterval(-83.45))
        stopwatch.title = "編集"
        stopwatch.color = .pink
        store.startStopwatch(preset: stopwatch, at: Date().addingTimeInterval(-24.2))
        stopwatch.title = ""
        stopwatch.color = .blue
        store.updateDraftStopwatch(stopwatch)

        var timerOne = TimerPreset.defaultTimerDraft()
        timerOne.title = "休憩"
        timerOne.duration = 12 * 60 + 34
        timerOne.soundEnabled = false
        store.start(preset: timerOne)

        var timerTwo = TimerPreset.defaultTimerDraft()
        timerTwo.title = "書き出し"
        timerTwo.duration = 4 * 60 + 20
        timerTwo.color = .pink
        timerTwo.soundEnabled = false
        store.start(preset: timerTwo)

        var pomodoroOne = TimerPreset.defaultPomodoroDraft()
        pomodoroOne.title = "集中作業"
        pomodoroOne.workDuration = 18 * 60 + 52
        pomodoroOne.color = .orange
        pomodoroOne.soundEnabled = false
        store.start(preset: pomodoroOne)

        var pomodoroTwo = TimerPreset.defaultPomodoroDraft()
        pomodoroTwo.title = "読書"
        pomodoroTwo.workDuration = 3 * 60 + 15
        pomodoroTwo.color = .green
        pomodoroTwo.soundEnabled = false
        store.start(preset: pomodoroTwo)

        var outputURLs: [URL] = []
        for panelSize in [PanelSizeOption.small, .large, .extraLarge] {
            settings.panelSize = panelSize
            let panel = PanelLayout.previewSize(for: panelSize)
            let content = TimerView(settings: settings, isActive: false, store: store)
                .frame(width: panel.width, height: panel.height - 55)
                .background(Color(red: 0.02, green: 0.02, blue: 0.025))
                .environment(\.panelTextSize, .medium)

            let contentSize = NSSize(width: panel.width, height: panel.height - 55)
            let host = NSHostingView(rootView: content)
            host.frame = NSRect(origin: .zero, size: contentSize)
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                throw CocoaError(.fileWriteUnknown)
            }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let outputURL = outputDirectory.appendingPathComponent(
                "timer-stopwatch-\(panelSize.rawValue)-preview.png"
            )
            try pngData.write(to: outputURL, options: .atomic)
            outputURLs.append(outputURL)
        }
        return outputURLs
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
    let draftMigrationValid: Bool
    let stopwatchValid: Bool
    let concurrencyValid: Bool
    let iconIdentityValid: Bool
    let layoutFits: Bool
    let compactLayoutValid: Bool
    let entryWidths: String
}
