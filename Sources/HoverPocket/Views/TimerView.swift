import SwiftUI

struct TimerView: View {
    @ObservedObject private var settings: AppSettings
    @ObservedObject private var store: TimerStore
    private let isActive: Bool

    init(settings: AppSettings, isActive: Bool, store: TimerStore = .shared) {
        self.settings = settings
        self.store = store
        self.isActive = isActive
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                runningSection

                if !store.pinnedPresets.isEmpty {
                    pinnedSection
                }

                TimerSection(title: text(.timer)) {
                    TimerEntryCard(
                        preset: draftTimerBinding,
                        canStart: store.canStartTimer,
                        settings: settings,
                        onStart: { store.start(preset: $0) }
                    )
                }

                TimerSection(title: text(.timerPomodoroSection)) {
                    TimerEntryCard(
                        preset: draftPomodoroBinding,
                        canStart: store.canStartTimer,
                        settings: settings,
                        onStart: { store.start(preset: $0) }
                    )
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .scrollIndicators(.never)
    }

    // MARK: - Running timers

    private var runningSection: some View {
        TimerSection(title: text(.timerRunningSection)) {
            if store.runningTimers.isEmpty, store.activeAlert == nil {
                TimerEmptyRow(message: text(.timerNoRunning))
            } else {
                VStack(spacing: 8) {
                    if !store.canStartTimer {
                        Text(text(.timerSlotsFull))
                            .panelTextFont(size: 9, weight: .medium, design: .monospaced)
                            .foregroundStyle(.yellow.opacity(0.75))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let alert = store.activeAlert,
                       !store.runningTimers.contains(where: { $0.id == alert.id }) {
                        finishedAlertRow(alert)
                    }
                    ForEach(store.runningTimers) { timer in
                        runningRow(timer)
                    }
                }
            }
        }
    }

    private func finishedAlertRow(_ alert: TimerAlert) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(alert.color.color)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(alert.title.isEmpty ? text(.timerFinished) : alert.title)
                    .panelTextFont(size: 11, weight: .bold)
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                Text(text(.timerFinished))
                    .panelTextFont(size: 9, weight: .medium, design: .monospaced)
                    .foregroundStyle(alert.color.color.opacity(0.9))
            }

            Spacer(minLength: 8)

            stopAlarmButton(color: alert.color.color)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(alert.color.color.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(alert.color.color.opacity(0.5), lineWidth: 1)
        )
    }

    private func runningRow(_ timer: RunningTimer) -> some View {
        let isAlerting = store.activeAlert?.id == timer.id
        return HStack(spacing: 10) {
            progressRing(for: timer)
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(timer.title.isEmpty ? text(.timer) : timer.title)
                    .panelTextFont(size: 11, weight: .bold)
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(remainingText(for: timer))
                        .panelTextFont(size: 12, weight: .bold, design: .monospaced)
                        .foregroundStyle(timer.color.color)

                    if timer.isPomodoro {
                        Text(pomodoroPhaseText(for: timer))
                            .panelTextFont(size: 9, weight: .bold, design: .monospaced)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
            }

            Spacer(minLength: 8)

            if isAlerting {
                stopAlarmButton(color: timer.color.color)
            } else {
                TimerIconButton(
                    symbolName: timer.isPaused ? "play.fill" : "pause.fill",
                    accent: .white.opacity(0.7)
                ) {
                    timer.isPaused ? store.resume(id: timer.id) : store.pause(id: timer.id)
                }
                .help(timer.isPaused ? text(.timerResume) : text(.timerPause))
            }

            TimerIconButton(symbolName: "stop.fill", accent: .white.opacity(0.55)) {
                store.stop(id: timer.id)
            }
            .help(text(.timerStop))
        }
        .padding(.top, 10)
        .padding([.horizontal, .bottom], 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isAlerting ? timer.color.color.opacity(0.12) : Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isAlerting ? timer.color.color.opacity(0.5) : Color.white.opacity(0.05), lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            pinButton(for: timer)
                .offset(x: -5, y: 4)
        }
    }

    /// Top-right pin toggle on a running timer: pinning stores the timer's
    /// configuration for reuse, up to four pins.
    private func pinButton(for timer: RunningTimer) -> some View {
        let isPinned = timer.pinnedPresetID != nil
        let isEnabled = isPinned || store.canPin
        return Button {
            store.togglePin(timerID: timer.id)
        } label: {
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(isPinned ? timer.color.color : .white.opacity(isEnabled ? 0.5 : 0.22))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(isPinned ? text(.timerUnpin) : (store.canPin ? text(.timerPin) : text(.timerPinLimit)))
    }

    private func stopAlarmButton(color: Color) -> some View {
        Button(action: store.stopAlert) {
            Text(text(.timerStopAlarm))
                .panelTextFont(size: 10, weight: .bold)
                .foregroundStyle(.black.opacity(0.85))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(color))
        }
        .buttonStyle(.plain)
        .help(text(.timerStopAlarm))
    }

    private func progressRing(for timer: RunningTimer) -> some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.1), lineWidth: 3)
            Circle()
                .trim(from: 0, to: timer.progress(at: store.now))
                .stroke(timer.color.color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if timer.isPaused {
                Image(systemName: "pause.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    // MARK: - Pinned presets

    private var pinnedSection: some View {
        TimerSection(title: text(.timerPinnedSection)) {
            VStack(spacing: 6) {
                ForEach(store.pinnedPresets) { preset in
                    pinnedRow(preset)
                }
            }
        }
    }

    private func pinnedRow(_ preset: TimerPreset) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "pin.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(preset.color.color)

            VStack(alignment: .leading, spacing: 1) {
                Text(pinnedTitle(preset))
                    .panelTextFont(size: 10, weight: .bold)
                    .foregroundStyle(.white.opacity(0.86))
                    .lineLimit(1)
                Text(pinnedDurationText(preset))
                    .panelTextFont(size: 9, weight: .bold, design: .monospaced)
                    .foregroundStyle(.white.opacity(0.48))
            }

            Spacer(minLength: 8)

            TimerIconButton(symbolName: "play.fill", accent: preset.color.color) {
                store.start(preset: preset, pinnedPresetID: preset.id)
            }
            .disabled(!store.canStartTimer)
            .opacity(store.canStartTimer ? 1 : 0.38)
            .help(text(.timerStart))

            TimerIconButton(symbolName: "pin.slash", accent: .white.opacity(0.45)) {
                store.removePinnedPreset(id: preset.id)
            }
            .help(text(.timerUnpin))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(preset.color.color.opacity(0.24), lineWidth: 1)
        )
    }

    private func pinnedTitle(_ preset: TimerPreset) -> String {
        if !preset.title.isEmpty {
            return preset.title
        }
        return preset.isPomodoro ? text(.timerPomodoroSection) : text(.timer)
    }

    private func pinnedDurationText(_ preset: TimerPreset) -> String {
        if preset.isPomodoro {
            let work = Self.timeText(preset.workDuration)
            let rest = Self.timeText(preset.breakDuration)
            return "\(text(.timerWork)) \(work) / \(text(.timerBreak)) \(rest)"
        }
        return Self.timeText(preset.duration)
    }

    // MARK: - Bindings and helpers

    private var draftTimerBinding: Binding<TimerPreset> {
        Binding(
            get: { store.draftTimer },
            set: { store.updateDraftTimer($0) }
        )
    }

    private var draftPomodoroBinding: Binding<TimerPreset> {
        Binding(
            get: { store.draftPomodoro },
            set: { store.updateDraftPomodoro($0) }
        )
    }

    private func remainingText(for timer: RunningTimer) -> String {
        Self.timeText(timer.remaining(at: store.now))
    }

    private func pomodoroPhaseText(for timer: RunningTimer) -> String {
        let phase = timer.phase == .work ? text(.timerWork) : text(.timerBreak)
        return "\(phase) · \(timer.completedWorkCycles + (timer.phase == .work ? 1 : 0))"
    }

    static func timeText(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func text(_ key: AppTextKey) -> String {
        settings.text(key)
    }
}

// MARK: - Entry card (normal or pomodoro, decided by the bound preset)

private struct TimerEntryCard: View {
    @Binding var preset: TimerPreset
    let canStart: Bool
    @ObservedObject var settings: AppSettings
    let onStart: (TimerPreset) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                colorPicker

                TextField(text(.timerTitlePlaceholder), text: $preset.title)
                    .textFieldStyle(.plain)
                    .panelTextFont(size: 10, weight: .bold)
                    .foregroundStyle(.white.opacity(0.86))
                    .frame(maxWidth: .infinity)

                TimerIconButton(
                    symbolName: preset.soundEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill",
                    accent: preset.soundEnabled ? .white.opacity(0.72) : .yellow.opacity(0.8),
                    isActive: !preset.soundEnabled
                ) {
                    preset.soundEnabled.toggle()
                }
                .help(text(.timerSoundToggle))
            }

            HStack(alignment: .top, spacing: 10) {
                if preset.isPomodoro {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(text(.timerWork))
                            .panelTextFont(size: 8, weight: .bold, design: .monospaced)
                            .foregroundStyle(.white.opacity(0.42))
                        TimerDurationInputView(
                            duration: $preset.workDuration,
                            accentColor: preset.color.color,
                            onChanged: {}
                        )
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(text(.timerBreak))
                            .panelTextFont(size: 8, weight: .bold, design: .monospaced)
                            .foregroundStyle(.white.opacity(0.42))
                        TimerDurationInputView(
                            duration: $preset.breakDuration,
                            accentColor: preset.color.color,
                            onChanged: {}
                        )
                    }
                } else {
                    TimerDurationInputView(
                        duration: $preset.duration,
                        accentColor: preset.color.color,
                        onChanged: {}
                    )
                }

                Spacer(minLength: 0)

                startButton
                    .padding(.top, 1)
            }
        }
    }

    private var colorPicker: some View {
        HStack(spacing: 5) {
            ForEach(TimerColor.allCases, id: \.self) { color in
                Circle()
                    .fill(color.color.opacity(preset.color == color ? 1 : 0.35))
                    .frame(width: 10, height: 10)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(preset.color == color ? 0.85 : 0), lineWidth: 1)
                    )
                    .contentShape(Circle())
                    .onTapGesture {
                        preset.color = color
                    }
            }
        }
    }

    private var isStartEnabled: Bool {
        canStart && (preset.isPomodoro ? preset.workDuration > 0 : preset.duration > 0)
    }

    private var startButton: some View {
        Button {
            onStart(preset)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "play.fill")
                    .font(.system(size: 8, weight: .bold))
                Text(text(.timerStart))
                    .panelTextFont(size: 10, weight: .bold)
            }
            .foregroundStyle(.black.opacity(0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(preset.color.color.opacity(isStartEnabled ? 1 : 0.3)))
        }
        .buttonStyle(.plain)
        .disabled(!isStartEnabled)
        .help(text(.timerStart))
    }

    private func text(_ key: AppTextKey) -> String {
        settings.text(key)
    }
}

// MARK: - Shared pieces

private struct TimerSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .panelTextFont(size: 10, weight: .bold, design: .monospaced)
                .foregroundStyle(.white.opacity(0.64))

            content()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.065), lineWidth: 1)
        )
    }
}

private struct TimerEmptyRow: View {
    let message: String

    var body: some View {
        Text(message)
            .panelTextFont(size: 10, weight: .medium, design: .monospaced)
            .foregroundStyle(.white.opacity(0.38))
            .frame(height: 30, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}

private struct TimerIconButton: View {
    let symbolName: String
    let accent: Color
    var isActive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbolName)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(accent)
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(Color.white.opacity(isActive ? 0.12 : 0.05))
                )
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
    }
}
