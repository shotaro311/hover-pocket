import AppKit
import Combine
import Foundation

@MainActor
final class TimerStore: ObservableObject {
    static let shared = TimerStore()
    static let maxConcurrentStopwatches = 4
    static let maxConcurrentTimers = 4
    static let maxPinnedPresets = 4

    @Published private(set) var draftStopwatch = StopwatchPreset.defaultDraft()
    @Published private(set) var draftTimer = TimerPreset.defaultTimerDraft()
    @Published private(set) var draftPomodoro = TimerPreset.defaultPomodoroDraft()
    @Published private(set) var pinnedPresets: [TimerPreset] = []
    @Published private(set) var runningStopwatches: [RunningStopwatch] = []
    @Published private(set) var runningTimers: [RunningTimer] = []
    @Published private(set) var activeAlert: TimerAlert?
    @Published private(set) var now = Date()

    private let fileManager: FileManager
    private let storageDirectory: URL
    private let persistenceEnabled: Bool
    private var tickTimer: Timer?
    private var alertSound: NSSound?
    private var pendingWriteTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?

    private var draftsURL: URL {
        storageDirectory.appendingPathComponent("drafts.json", isDirectory: false)
    }

    private var pinnedURL: URL {
        storageDirectory.appendingPathComponent("pinned.json", isDirectory: false)
    }

    private var runningURL: URL {
        storageDirectory.appendingPathComponent("running.json", isDirectory: false)
    }

    init(
        storageDirectory: URL? = nil,
        fileManager: FileManager = .default,
        observesWake: Bool = true,
        persistenceEnabled: Bool = true
    ) {
        self.fileManager = fileManager
        self.storageDirectory = storageDirectory ?? Self.defaultStorageDirectory(
            fileManager: fileManager
        )
        self.persistenceEnabled = persistenceEnabled
        loadDrafts()
        loadPinnedPresets()
        restoreRunningTimers()
        if observesWake {
            observeWake()
        }
        syncTickTimer()
    }

    private static func defaultStorageDirectory(fileManager: FileManager) -> URL {
        HoverPocketApplicationData.directory("Timer", fileManager: fileManager)
    }

    var canStartTimer: Bool {
        runningTimers.count < Self.maxConcurrentTimers
    }

    var canStartStopwatch: Bool {
        runningStopwatches.count < Self.maxConcurrentStopwatches
    }

    var canPin: Bool {
        pinnedPresets.count < Self.maxPinnedPresets
    }

    // MARK: - Timer lifecycle

    @discardableResult
    func start(
        preset: TimerPreset,
        pinnedPresetID: UUID? = nil,
        id: UUID = UUID(),
        at date: Date = Date()
    ) -> RunningTimer? {
        guard canStartTimer else { return nil }
        let phaseDuration = preset.isPomodoro ? preset.workDuration : preset.duration
        guard phaseDuration > 0 else { return nil }
        let timer = RunningTimer(
            id: id,
            title: preset.title,
            color: preset.color,
            soundEnabled: preset.soundEnabled,
            isPomodoro: preset.isPomodoro,
            phase: .work,
            completedWorkCycles: 0,
            endDate: date.addingTimeInterval(phaseDuration),
            phaseDuration: phaseDuration,
            pausedRemaining: nil,
            workDuration: preset.workDuration,
            breakDuration: preset.breakDuration,
            pinnedPresetID: pinnedPresetID
        )
        runningTimers.append(timer)
        now = date
        syncTickTimer()
        persistRunningTimers()
        return timer
    }

    func runningTimer(id: UUID) -> RunningTimer? {
        runningTimers.first { $0.id == id }
    }

    @discardableResult
    func startForCapability(
        preset: TimerPreset,
        id: UUID,
        at date: Date
    ) async throws -> RunningTimer? {
        await pendingWriteTask?.value
        guard canStartTimer else { return nil }
        let phaseDuration = preset.isPomodoro ? preset.workDuration : preset.duration
        guard phaseDuration > 0 else { return nil }
        let previousTimers = runningTimers
        let previousNow = now
        let timer = RunningTimer(
            id: id,
            title: preset.title,
            color: preset.color,
            soundEnabled: preset.soundEnabled,
            isPomodoro: preset.isPomodoro,
            phase: .work,
            completedWorkCycles: 0,
            endDate: date.addingTimeInterval(phaseDuration),
            phaseDuration: phaseDuration,
            pausedRemaining: nil,
            workDuration: preset.workDuration,
            breakDuration: preset.breakDuration,
            pinnedPresetID: nil
        )
        runningTimers.append(timer)
        now = date
        do {
            try persistRunningTimersImmediately()
            syncTickTimer()
            return timer
        } catch {
            runningTimers = previousTimers
            now = previousNow
            syncTickTimer()
            throw error
        }
    }

    func pauseForCapability(id: UUID, at date: Date) async throws {
        await pendingWriteTask?.value
        guard let index = runningTimers.firstIndex(where: { $0.id == id }),
              !runningTimers[index].isPaused else { return }
        let previousTimers = runningTimers
        runningTimers[index].pausedRemaining = runningTimers[index].remaining(at: date)
        do {
            try persistRunningTimersImmediately()
            syncTickTimer()
        } catch {
            runningTimers = previousTimers
            syncTickTimer()
            throw error
        }
    }

    func resumeForCapability(id: UUID, at date: Date) async throws {
        await pendingWriteTask?.value
        guard let index = runningTimers.firstIndex(where: { $0.id == id }),
              let remaining = runningTimers[index].pausedRemaining else { return }
        let previousTimers = runningTimers
        let previousNow = now
        runningTimers[index].pausedRemaining = nil
        runningTimers[index].endDate = date.addingTimeInterval(remaining)
        now = date
        do {
            try persistRunningTimersImmediately()
            syncTickTimer()
        } catch {
            runningTimers = previousTimers
            now = previousNow
            syncTickTimer()
            throw error
        }
    }

    func stopForCapability(id: UUID) async throws {
        await pendingWriteTask?.value
        let previousTimers = runningTimers
        runningTimers.removeAll { $0.id == id }
        do {
            try persistRunningTimersImmediately()
            if activeAlert?.id == id {
                stopAlert()
            }
            syncTickTimer()
        } catch {
            runningTimers = previousTimers
            syncTickTimer()
            throw error
        }
    }

    func pause(id: UUID, at date: Date = Date()) {
        guard let index = runningTimers.firstIndex(where: { $0.id == id }),
              !runningTimers[index].isPaused
        else { return }
        runningTimers[index].pausedRemaining = runningTimers[index].remaining(at: date)
        syncTickTimer()
        persistRunningTimers()
    }

    func resume(id: UUID, at date: Date = Date()) {
        guard let index = runningTimers.firstIndex(where: { $0.id == id }),
              let remaining = runningTimers[index].pausedRemaining
        else { return }
        runningTimers[index].pausedRemaining = nil
        runningTimers[index].endDate = date.addingTimeInterval(remaining)
        now = date
        syncTickTimer()
        persistRunningTimers()
    }

    func stop(id: UUID) {
        runningTimers.removeAll { $0.id == id }
        if activeAlert?.id == id {
            stopAlert()
        }
        syncTickTimer()
        persistRunningTimers()
    }

    func stopAlert() {
        alertSound?.stop()
        alertSound = nil
        activeAlert = nil
    }

    func startStopwatch(preset: StopwatchPreset? = nil, at date: Date = Date()) {
        guard canStartStopwatch else { return }
        let preset = preset ?? draftStopwatch
        runningStopwatches.append(
            RunningStopwatch(
                id: UUID(),
                title: preset.title,
                color: preset.color,
                startedAt: date
            )
        )
    }

    func pauseStopwatch(id: UUID, at date: Date = Date()) {
        guard let index = runningStopwatches.firstIndex(where: { $0.id == id }),
              runningStopwatches[index].isRunning
        else { return }
        runningStopwatches[index].accumulated = runningStopwatches[index].elapsed(at: date)
        runningStopwatches[index].startedAt = nil
    }

    func resumeStopwatch(id: UUID, at date: Date = Date()) {
        guard let index = runningStopwatches.firstIndex(where: { $0.id == id }),
              !runningStopwatches[index].isRunning
        else { return }
        runningStopwatches[index].startedAt = date
    }

    func stopStopwatch(id: UUID) {
        runningStopwatches.removeAll { $0.id == id }
    }

    // MARK: - Drafts and pinned presets

    func updateDraftStopwatch(_ preset: StopwatchPreset) {
        guard draftStopwatch != preset else { return }
        draftStopwatch = preset
        persistDrafts()
    }

    func updateDraftTimer(_ preset: TimerPreset) {
        guard draftTimer != preset else { return }
        draftTimer = preset
        persistDrafts()
    }

    func updateDraftPomodoro(_ preset: TimerPreset) {
        guard draftPomodoro != preset else { return }
        draftPomodoro = preset
        persistDrafts()
    }

    /// Pins the running timer's configuration for reuse, or removes the pin if
    /// the timer is already linked to a pinned preset.
    func togglePin(timerID: UUID) {
        guard let index = runningTimers.firstIndex(where: { $0.id == timerID }) else { return }
        if let presetID = runningTimers[index].pinnedPresetID {
            removePinnedPreset(id: presetID)
        } else {
            guard canPin else { return }
            let timer = runningTimers[index]
            let preset = TimerPreset(
                id: UUID(),
                title: timer.title,
                isPomodoro: timer.isPomodoro,
                duration: timer.isPomodoro ? timer.workDuration : timer.phaseDuration,
                workDuration: timer.workDuration,
                breakDuration: timer.breakDuration,
                color: timer.color,
                soundEnabled: timer.soundEnabled
            )
            pinnedPresets.append(preset)
            runningTimers[index].pinnedPresetID = preset.id
            persistPinnedPresets()
            persistRunningTimers()
        }
    }

    func removePinnedPreset(id: UUID) {
        guard pinnedPresets.contains(where: { $0.id == id }) else { return }
        pinnedPresets.removeAll { $0.id == id }
        for index in runningTimers.indices where runningTimers[index].pinnedPresetID == id {
            runningTimers[index].pinnedPresetID = nil
        }
        persistPinnedPresets()
        persistRunningTimers()
    }

    // MARK: - Countdown

    private func syncTickTimer() {
        let needsTick = runningTimers.contains { !$0.isPaused }
        if needsTick {
            guard tickTimer == nil else { return }
            let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.tick()
                }
            }
            timer.tolerance = 0.1
            tickTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        } else {
            tickTimer?.invalidate()
            tickTimer = nil
        }
    }

    private func tick() {
        now = Date()
        let expired = runningTimers.filter { !$0.isPaused && $0.endDate <= now }
        guard !expired.isEmpty else { return }
        for timer in expired {
            fire(timer)
        }
        syncTickTimer()
        persistRunningTimers()
    }

    private func fire(_ timer: RunningTimer) {
        guard let index = runningTimers.firstIndex(where: { $0.id == timer.id }) else { return }

        activeAlert = TimerAlert(
            id: timer.id,
            title: timer.title,
            color: timer.color,
            startedAt: Date(),
            soundEnabled: timer.soundEnabled
        )
        if timer.soundEnabled {
            playAlertSound()
        }

        if timer.isPomodoro {
            var next = runningTimers[index]
            switch next.phase {
            case .work:
                next.completedWorkCycles += 1
                next.phase = .rest
                next.phaseDuration = max(next.breakDuration, 1)
            case .rest:
                next.phase = .work
                next.phaseDuration = max(next.workDuration, 1)
            }
            next.endDate = Date().addingTimeInterval(next.phaseDuration)
            runningTimers[index] = next
        } else {
            runningTimers.remove(at: index)
        }
    }

    private func playAlertSound() {
        alertSound?.stop()
        guard let sound = NSSound(named: "Glass") else { return }
        sound.loops = true
        alertSound = sound
        sound.play()
    }

    private func observeWake() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
    }

    // MARK: - Persistence

    private struct DraftsSnapshot: Codable, Sendable {
        var stopwatch: StopwatchPreset?
        var timer: TimerPreset
        var pomodoro: TimerPreset
    }

    private func loadDrafts() {
        guard let data = try? Data(contentsOf: draftsURL),
              let decoded = try? JSONDecoder().decode(DraftsSnapshot.self, from: data)
        else { return }
        draftStopwatch = decoded.stopwatch ?? .defaultDraft()
        draftTimer = decoded.timer
        draftPomodoro = decoded.pomodoro
    }

    private func loadPinnedPresets() {
        guard let data = try? Data(contentsOf: pinnedURL),
              let decoded = try? JSONDecoder().decode([TimerPreset].self, from: data)
        else { return }
        pinnedPresets = Array(decoded.prefix(Self.maxPinnedPresets))
    }

    /// Timers that expired while the app was not running are discarded quietly;
    /// re-firing an alarm minutes late would be more confusing than helpful.
    private func restoreRunningTimers() {
        guard let data = try? Data(contentsOf: runningURL),
              let decoded = try? JSONDecoder().decode([RunningTimer].self, from: data)
        else { return }
        let now = Date()
        runningTimers = decoded.filter { $0.isPaused || $0.endDate > now }
        if runningTimers.count != decoded.count {
            persistRunningTimers()
        }
    }

    private func persistDrafts() {
        persist(
            DraftsSnapshot(
                stopwatch: draftStopwatch,
                timer: draftTimer,
                pomodoro: draftPomodoro
            ),
            to: draftsURL
        )
    }

    private func persistPinnedPresets() {
        persist(pinnedPresets, to: pinnedURL)
    }

    private func persistRunningTimers() {
        persist(runningTimers, to: runningURL)
    }

    private func persistRunningTimersImmediately() throws {
        guard persistenceEnabled else { return }
        try fileManager.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(runningTimers)
        try data.write(to: runningURL, options: .atomic)
    }

    private func persist<Value: Encodable & Sendable>(_ value: Value, to url: URL) {
        guard persistenceEnabled else { return }
        let storageDirectory = self.storageDirectory
        let previousWrite = pendingWriteTask
        pendingWriteTask = Task.detached(priority: .utility) {
            await previousWrite?.value
            do {
                try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(value)
                try data.write(to: url, options: .atomic)
            } catch {
                // Losing a timer snapshot is not user-visible data loss; ignore.
            }
        }
    }
}
