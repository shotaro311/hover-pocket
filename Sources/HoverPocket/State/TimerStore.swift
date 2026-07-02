import AppKit
import Combine
import Foundation

@MainActor
final class TimerStore: ObservableObject {
    static let shared = TimerStore()
    static let maxConcurrentTimers = 2
    static let maxPinnedPresets = 4

    @Published private(set) var draftTimer = TimerPreset.defaultTimerDraft()
    @Published private(set) var draftPomodoro = TimerPreset.defaultPomodoroDraft()
    @Published private(set) var pinnedPresets: [TimerPreset] = []
    @Published private(set) var runningTimers: [RunningTimer] = []
    @Published private(set) var activeAlert: TimerAlert?
    @Published private(set) var now = Date()

    private let fileManager = FileManager.default
    private var tickTimer: Timer?
    private var alertSound: NSSound?
    private var pendingWriteTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?

    private lazy var storageDirectory: URL = {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base
            .appendingPathComponent("HoverPocket", isDirectory: true)
            .appendingPathComponent("Timer", isDirectory: true)
    }()

    private var draftsURL: URL {
        storageDirectory.appendingPathComponent("drafts.json", isDirectory: false)
    }

    private var pinnedURL: URL {
        storageDirectory.appendingPathComponent("pinned.json", isDirectory: false)
    }

    private var runningURL: URL {
        storageDirectory.appendingPathComponent("running.json", isDirectory: false)
    }

    private init() {
        loadDrafts()
        loadPinnedPresets()
        restoreRunningTimers()
        observeWake()
        syncTickTimer()
    }

    var canStartTimer: Bool {
        runningTimers.count < Self.maxConcurrentTimers
    }

    var canPin: Bool {
        pinnedPresets.count < Self.maxPinnedPresets
    }

    // MARK: - Timer lifecycle

    func start(preset: TimerPreset, pinnedPresetID: UUID? = nil) {
        guard canStartTimer else { return }
        let phaseDuration = preset.isPomodoro ? preset.workDuration : preset.duration
        guard phaseDuration > 0 else { return }
        let timer = RunningTimer(
            id: UUID(),
            title: preset.title,
            color: preset.color,
            soundEnabled: preset.soundEnabled,
            isPomodoro: preset.isPomodoro,
            phase: .work,
            completedWorkCycles: 0,
            endDate: Date().addingTimeInterval(phaseDuration),
            phaseDuration: phaseDuration,
            pausedRemaining: nil,
            workDuration: preset.workDuration,
            breakDuration: preset.breakDuration,
            pinnedPresetID: pinnedPresetID
        )
        runningTimers.append(timer)
        now = Date()
        syncTickTimer()
        persistRunningTimers()
    }

    func pause(id: UUID) {
        guard let index = runningTimers.firstIndex(where: { $0.id == id }),
              !runningTimers[index].isPaused
        else { return }
        runningTimers[index].pausedRemaining = runningTimers[index].remaining(at: Date())
        syncTickTimer()
        persistRunningTimers()
    }

    func resume(id: UUID) {
        guard let index = runningTimers.firstIndex(where: { $0.id == id }),
              let remaining = runningTimers[index].pausedRemaining
        else { return }
        runningTimers[index].pausedRemaining = nil
        runningTimers[index].endDate = Date().addingTimeInterval(remaining)
        now = Date()
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

    // MARK: - Drafts and pinned presets

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
        var timer: TimerPreset
        var pomodoro: TimerPreset
    }

    private func loadDrafts() {
        guard let data = try? Data(contentsOf: draftsURL),
              let decoded = try? JSONDecoder().decode(DraftsSnapshot.self, from: data)
        else { return }
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
        persist(DraftsSnapshot(timer: draftTimer, pomodoro: draftPomodoro), to: draftsURL)
    }

    private func persistPinnedPresets() {
        persist(pinnedPresets, to: pinnedURL)
    }

    private func persistRunningTimers() {
        persist(runningTimers, to: runningURL)
    }

    private func persist<Value: Encodable & Sendable>(_ value: Value, to url: URL) {
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
