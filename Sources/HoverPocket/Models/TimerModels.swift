import Foundation
import SwiftUI

enum TimerAlertAnimation {
    /// Shared period of the bar bounce and the ripple spawn so both stay in phase.
    static let bouncePeriod: TimeInterval = 0.9
}

enum TimerColor: String, Codable, CaseIterable, Sendable {
    case blue
    case green
    case orange
    case pink

    var color: Color {
        switch self {
        case .blue:
            return Color(red: 0.36, green: 0.64, blue: 1.0)
        case .green:
            return Color(red: 0.38, green: 0.83, blue: 0.55)
        case .orange:
            return Color(red: 1.0, green: 0.63, blue: 0.28)
        case .pink:
            return Color(red: 1.0, green: 0.46, blue: 0.62)
        }
    }
}

enum PomodoroPhase: String, Codable, Sendable {
    case work
    case rest
}

struct TimerPreset: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var title: String
    var isPomodoro: Bool
    var duration: TimeInterval
    var workDuration: TimeInterval
    var breakDuration: TimeInterval
    var color: TimerColor
    var soundEnabled: Bool

    static func defaultTimerDraft() -> TimerPreset {
        TimerPreset(
            id: UUID(),
            title: "",
            isPomodoro: false,
            duration: 10 * 60,
            workDuration: 25 * 60,
            breakDuration: 5 * 60,
            color: .blue,
            soundEnabled: true
        )
    }

    static func defaultPomodoroDraft() -> TimerPreset {
        TimerPreset(
            id: UUID(),
            title: "",
            isPomodoro: true,
            duration: 25 * 60,
            workDuration: 25 * 60,
            breakDuration: 5 * 60,
            color: .green,
            soundEnabled: true
        )
    }
}

struct RunningTimer: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var title: String
    var color: TimerColor
    var soundEnabled: Bool
    var isPomodoro: Bool
    var phase: PomodoroPhase
    var completedWorkCycles: Int
    /// Countdown is anchored to an absolute end date, so timer coalescing
    /// and sleep/wake cannot drift the remaining time.
    var endDate: Date
    var phaseDuration: TimeInterval
    var pausedRemaining: TimeInterval?
    var workDuration: TimeInterval
    var breakDuration: TimeInterval
    /// Links to a pinned preset when this timer was started from (or pinned as)
    /// one, so the pin toggle on the running card reflects the pinned state.
    var pinnedPresetID: UUID?

    var isPaused: Bool {
        pausedRemaining != nil
    }

    func remaining(at now: Date) -> TimeInterval {
        if let pausedRemaining {
            return max(0, pausedRemaining)
        }
        return max(0, endDate.timeIntervalSince(now))
    }

    func progress(at now: Date) -> Double {
        guard phaseDuration > 0 else { return 0 }
        return (1 - remaining(at: now) / phaseDuration).clamped(to: 0...1)
    }
}

struct TimerAlert: Equatable, Identifiable, Sendable {
    let id: UUID
    let title: String
    let color: TimerColor
    /// Reference time shared by the pill bounce and the ripple overlay so
    /// both animations stay in phase.
    let startedAt: Date
    let soundEnabled: Bool
}
