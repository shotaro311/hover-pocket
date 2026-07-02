import AppKit
import Combine
import Foundation

@MainActor
final class TimerStore: ObservableObject {
    static let shared = TimerStore()
    static let maxConcurrentTimers = 2
    static let presetCount = 4

    @Published private(set) var presets: [TimerPreset] = []
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

    private var presetsURL: URL {
        storageDirectory.appendingPathComponent("presets.json", isDirectory: false)
    }

    private var runningURL: URL {
        storageDirectory.appendingPathComponent("running.json", isDirectory: false)
    }

    private init() {
        loadPresets()
        restoreRunningTimers()
        observeWake()
        syncTickTimer()
    }

    var canStartTimer: Bool {
        runningTimers.count < Self.maxConcurrentTimers
    }

    // MARK: - Timer lifecycle

    func start(preset: TimerPreset) {
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
            breakDuration: preset.breakDuration
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

    // MARK: - Presets

    func updatePreset(_ preset: TimerPreset) {
        guard let index = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        guard presets[index] != preset else { return }
        presets[index] = preset
        persistPresets()
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

    private func loadPresets() {
        if let data = try? Data(contentsOf: presetsURL),
           let decoded = try? JSONDecoder().decode([TimerPreset].self, from: data),
           decoded.count == Self.presetCount {
            presets = decoded
        } else {
            presets = TimerPreset.defaultPresets()
        }
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

    private func persistPresets() {
        persist(presets, to: presetsURL)
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
