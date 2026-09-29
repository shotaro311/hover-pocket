import AppKit
import Combine
import Foundation

/// The note remains unacknowledged on disk until the user dismisses its alert.
/// A timer temporarily takes precedence without consuming a note's reminder.
@MainActor
final class StickyReminderController: ObservableObject {
    static let shared = StickyReminderController(notes: .shared, timers: .shared)

    @Published private(set) var activeNote: StickyNoteItem?
    @Published private(set) var startedAt: Date?

    private let notes: StickyNotesStore
    private let timers: TimerStore
    private let clock: () -> Date
    private let schedulesAutomatically: Bool
    private let soundEnabled: Bool
    private var subscriptions = Set<AnyCancellable>()
    private var deadlineTimer: Timer?
    private var sound: NSSound?
    private var wakeObserver: NSObjectProtocol?

    init(
        notes: StickyNotesStore,
        timers: TimerStore,
        clock: @escaping () -> Date = Date.init,
        schedulesAutomatically: Bool = true,
        soundEnabled: Bool = true
    ) {
        self.notes = notes
        self.timers = timers
        self.clock = clock
        self.schedulesAutomatically = schedulesAutomatically
        self.soundEnabled = soundEnabled
        if schedulesAutomatically {
            // Published values arrive before the store has finished changing.
            notes.$notes.receive(on: RunLoop.main).sink { [weak self] _ in
                self?.refresh()
            }.store(in: &subscriptions)
            timers.$activeAlert.receive(on: RunLoop.main).sink { [weak self] _ in
                self?.refresh()
            }.store(in: &subscriptions)
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
        refresh()
    }

    func refresh() {
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        let now = clock()
        let due = notes.dueReminders(at: now)
        let next = timers.activeAlert == nil
            ? (due.first { $0.id == activeNote?.id } ?? due.first) : nil
        let changesPresentation = next?.id != activeNote?.id
            || next?.reminder?.scheduledAt != activeNote?.reminder?.scheduledAt
        if changesPresentation {
            sound?.stop()
            sound = nil
            startedAt = next == nil ? nil : now
        }
        if activeNote != next { activeNote = next }
        if changesPresentation, next != nil, soundEnabled {
            let alertSound = NSSound(named: "Glass")
            alertSound?.loops = true
            sound = alertSound
            alertSound?.play()
        }
        guard schedulesAutomatically,
              let upcoming = notes.activeNotes.compactMap(\.reminder)
                .filter({ $0.acknowledgedAt == nil && $0.scheduledAt > now })
                .map(\.scheduledAt).min()
        else { return }
        let timer = Timer(fire: upcoming, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = 0.1
        deadlineTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @discardableResult
    func acknowledge() -> Bool {
        guard let note = activeNote, let reminder = note.reminder else { return false }
        do {
            let acknowledged = try notes.acknowledgeReminder(
                noteID: note.id, scheduledAt: reminder.scheduledAt, at: clock()
            )
            refresh()
            return acknowledged
        } catch {
            // Keep the alert and its stop action visible if saving failed.
            return false
        }
    }

    func stop() {
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        subscriptions.removeAll()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        wakeObserver = nil
        sound?.stop()
        sound = nil
        activeNote = nil
        startedAt = nil
    }
}
