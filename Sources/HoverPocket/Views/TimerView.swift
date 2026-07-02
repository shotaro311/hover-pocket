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
                presetsSection
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
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                Text(text(.timerFinished))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
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
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(remainingText(for: timer))
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(timer.color.color)

                    if timer.isPomodoro {
                        Text(pomodoroPhaseText(for: timer))
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
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
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isAlerting ? timer.color.color.opacity(0.12) : Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isAlerting ? timer.color.color.opacity(0.5) : Color.white.opacity(0.05), lineWidth: 1)
        )
    }

    private func stopAlarmButton(color: Color) -> some View {
        Button(action: store.stopAlert) {
            Text(text(.timerStopAlarm))
                .font(.system(size: 10, weight: .bold))
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

    // MARK: - Presets

    private var presetsSection: some View {
        TimerSection(title: text(.timerPresetsSection)) {
            VStack(spacing: 8) {
                if !store.canStartTimer {
                    Text(text(.timerSlotsFull))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.yellow.opacity(0.75))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(store.presets) { preset in
                    TimerPresetCard(
                        preset: presetBinding(preset),
                        canStart: store.canStartTimer,
                        settings: settings,
                        onStart: { store.start(preset: $0) }
                    )
                }
            }
        }
    }

    private func presetBinding(_ preset: TimerPreset) -> Binding<TimerPreset> {
        Binding(
            get: { store.presets.first(where: { $0.id == preset.id }) ?? preset },
            set: { store.updatePreset($0) }
        )
    }

    // MARK: - Helpers

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

// MARK: - Preset card

private struct TimerPresetCard: View {
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
                    .font(.system(size: 10, weight: .bold))
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

                TimerIconButton(
                    symbolName: "repeat",
                    accent: preset.isPomodoro ? preset.color.color : .white.opacity(0.45),
                    isActive: preset.isPomodoro
                ) {
                    preset.isPomodoro.toggle()
                }
                .help(text(.timerPomodoro))
            }

            HStack(alignment: .top, spacing: 10) {
                if preset.isPomodoro {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(text(.timerWork))
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.42))
                        TimerDurationInputView(
                            duration: $preset.workDuration,
                            accentColor: preset.color.color,
                            onChanged: {}
                        )
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(text(.timerBreak))
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
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
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(preset.color.color.opacity(0.22), lineWidth: 1)
        )
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
                    .font(.system(size: 10, weight: .bold))
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
                .font(.system(size: 10, weight: .bold, design: .monospaced))
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
            .font(.system(size: 10, weight: .medium, design: .monospaced))
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
