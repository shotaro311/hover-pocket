import SwiftUI

struct TimerLayoutMetrics {
    static let horizontalPadding: CGFloat = 16
    static let entrySectionSpacing: CGFloat = 8
    static let minimumEntryCardWidth: CGFloat = 150
    static let compactSectionVerticalPadding: CGFloat = 6
    static let runningCardHeight: CGFloat = 38
    static let runningCardSpacing: CGFloat = 4
    static let setupCardHeight: CGFloat = 174

    let availableWidth: CGFloat

    var entryCardWidth: CGFloat {
        max(
            0,
            (availableWidth - (Self.horizontalPadding * 2) - (Self.entrySectionSpacing * 2)) / 3
        )
    }

    var fitsSideBySide: Bool {
        entryCardWidth >= Self.minimumEntryCardWidth
    }
}

struct TimerView: View {
    static let stopwatchSymbolName = "stopwatch.fill"
    static let timerSymbolName = "hourglass"
    static let pomodoroSymbolName = "target"

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
                addSection

                if !store.pinnedPresets.isEmpty {
                    pinnedSection
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, TimerLayoutMetrics.horizontalPadding)
            .padding(.vertical, 10)
        }
        .scrollIndicators(.never)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(text(.timer))
    }

    // MARK: - Running list

    private var runningSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Circle()
                    .fill(runningItemCount > 0 ? Color.green : Color.white.opacity(0.24))
                    .frame(width: 7, height: 7)

                Text(text(.timerRunningSection))
                    .panelTextFont(size: 10, weight: .bold, design: .monospaced)
                    .foregroundStyle(runningItemCount > 0 ? Color.green.opacity(0.9) : Color.white.opacity(0.5))

                if runningItemCount > 0 {
                    Text("\(runningItemCount)")
                        .panelTextFont(size: 8.5, weight: .bold, design: .monospaced)
                        .foregroundStyle(.white.opacity(0.68))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                        .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
                }

                Spacer(minLength: 8)
            }

            if runningItemCount == 0 {
                TimerEmptyRow(message: text(.timerNoRunning))
            } else {
                VStack(spacing: TimerLayoutMetrics.runningCardSpacing) {
                    ForEach(store.runningStopwatches) { stopwatch in
                        stopwatchRunningRow(stopwatch)
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
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.026))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
        )
    }

    private var runningItemCount: Int {
        let detachedAlertCount: Int
        if let alert = store.activeAlert,
           !store.runningTimers.contains(where: { $0.id == alert.id }) {
            detachedAlertCount = 1
        } else {
            detachedAlertCount = 0
        }
        return store.runningStopwatches.count + store.runningTimers.count + detachedAlertCount
    }

    private func stopwatchRunningRow(_ stopwatch: RunningStopwatch) -> some View {
        HStack(spacing: 7) {
            TimerRunningTypeIcon(
                symbolName: Self.stopwatchSymbolName,
                color: stopwatch.color
            )

            Text(text(.timerStopwatch))
                .panelTextFont(size: 9.5, weight: .bold)
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(1)

            TimerRowDivider()

            Text(displayName(stopwatch.title))
                .panelTextFont(size: 9, weight: .medium)
                .foregroundStyle(.white.opacity(stopwatch.title.isEmpty ? 0.28 : 0.62))
                .lineLimit(1)

            Spacer(minLength: 6)

            StopwatchElapsedText(
                state: stopwatch,
                color: stopwatch.color.color,
                fontSize: 13
            )
            .frame(minWidth: 78, alignment: .trailing)

            TimerIconButton(
                symbolName: stopwatch.isRunning ? "pause.fill" : "play.fill",
                accent: stopwatch.color.color,
                isActive: stopwatch.isRunning
            ) {
                stopwatch.isRunning
                    ? store.pauseStopwatch(id: stopwatch.id)
                    : store.resumeStopwatch(id: stopwatch.id)
            }
            .help(stopwatch.isRunning ? text(.timerPause) : text(.timerResume))

            TimerIconButton(symbolName: "stop.fill", accent: .red.opacity(0.78)) {
                store.stopStopwatch(id: stopwatch.id)
            }
            .help(text(.timerStop))
        }
        .modifier(TimerRunningRowStyle(color: stopwatch.color.color))
    }

    private func finishedAlertRow(_ alert: TimerAlert) -> some View {
        HStack(spacing: 7) {
            TimerRunningTypeIcon(symbolName: "bell.badge.fill", color: alert.color)

            Text(text(.timerFinished))
                .panelTextFont(size: 9.5, weight: .bold)
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)

            TimerRowDivider()

            Text(displayName(alert.title))
                .panelTextFont(size: 9, weight: .medium)
                .foregroundStyle(.white.opacity(alert.title.isEmpty ? 0.3 : 0.68))
                .lineLimit(1)

            Spacer(minLength: 8)

            stopAlarmButton(color: alert.color.color)
        }
        .modifier(TimerRunningRowStyle(color: alert.color.color, isAlerting: true))
    }

    private func runningRow(_ timer: RunningTimer) -> some View {
        let isAlerting = store.activeAlert?.id == timer.id
        return HStack(spacing: 7) {
            runningIcon(for: timer)

            Text(timer.isPomodoro ? text(.timerPomodoroShort) : text(.timer))
                .panelTextFont(size: 9.5, weight: .bold)
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(1)

            TimerRowDivider()

            Text(displayName(timer.title))
                .panelTextFont(size: 9, weight: .medium)
                .foregroundStyle(.white.opacity(timer.title.isEmpty ? 0.28 : 0.62))
                .lineLimit(1)

            Spacer(minLength: 6)

            if timer.isPomodoro {
                Text(pomodoroPhaseText(for: timer))
                    .panelTextFont(size: 8, weight: .bold, design: .monospaced)
                    .foregroundStyle(.white.opacity(0.42))
                    .lineLimit(1)
            }

            Text(remainingText(for: timer))
                .panelTextFont(size: 13, weight: .bold, design: .monospaced)
                .foregroundStyle(timer.color.color)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .monospacedDigit()

            pinButton(for: timer)

            if isAlerting {
                stopAlarmButton(color: timer.color.color)
            } else {
                TimerIconButton(
                    symbolName: timer.isPaused ? "play.fill" : "pause.fill",
                    accent: timer.color.color,
                    isActive: !timer.isPaused
                ) {
                    timer.isPaused ? store.resume(id: timer.id) : store.pause(id: timer.id)
                }
                .help(timer.isPaused ? text(.timerResume) : text(.timerPause))
            }

            TimerIconButton(symbolName: "stop.fill", accent: .red.opacity(0.78)) {
                store.stop(id: timer.id)
            }
            .help(text(.timerStop))
        }
        .modifier(
            TimerRunningRowStyle(
                color: timer.color.color,
                isAlerting: isAlerting
            )
        )
    }

    private func runningIcon(for timer: RunningTimer) -> some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.1), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: timer.progress(at: store.now))
                .stroke(
                    timer.color.color,
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            Image(systemName: timer.isPomodoro ? Self.pomodoroSymbolName : Self.timerSymbolName)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(timer.color.color)
        }
        .frame(width: 25, height: 25)
    }

    private func pinButton(for timer: RunningTimer) -> some View {
        let isPinned = timer.pinnedPresetID != nil
        let isEnabled = isPinned || store.canPin
        return Button {
            store.togglePin(timerID: timer.id)
        } label: {
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(isPinned ? timer.color.color : .white.opacity(isEnabled ? 0.46 : 0.2))
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
                .panelTextFont(size: 8.5, weight: .bold)
                .foregroundStyle(.black.opacity(0.85))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(color))
        }
        .buttonStyle(.plain)
        .help(text(.timerStopAlarm))
    }

    // MARK: - New timer setup

    private var addSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.cyan.opacity(0.9))

                Text(text(.timerAddSection))
                    .panelTextFont(size: 10, weight: .bold, design: .monospaced)
                    .foregroundStyle(.cyan.opacity(0.9))

                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.cyan.opacity(0.58),
                                Color.white.opacity(0.12),
                                Color.clear
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(height: 1)
            }

            HStack(alignment: .top, spacing: TimerLayoutMetrics.entrySectionSpacing) {
                StopwatchEntryCard(
                    preset: draftStopwatchBinding,
                    canStart: store.canStartStopwatch,
                    settings: settings,
                    onStart: { store.startStopwatch(preset: store.draftStopwatch) },
                    onReset: { store.updateDraftStopwatch(.defaultDraft()) }
                )
                .frame(minWidth: 0, maxWidth: .infinity)

                TimerEntryCard(
                    preset: draftTimerBinding,
                    canStart: store.canStartTimer,
                    settings: settings,
                    onStart: { store.start(preset: $0) }
                )
                .frame(minWidth: 0, maxWidth: .infinity)

                TimerEntryCard(
                    preset: draftPomodoroBinding,
                    canStart: store.canStartTimer,
                    settings: settings,
                    onStart: { store.start(preset: $0) }
                )
                .frame(minWidth: 0, maxWidth: .infinity)
            }
        }
        .padding(.top, 1)
        .padding(.horizontal, 1)
        .padding(.bottom, 1)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.white.opacity(0.012))
                .padding(.top, 20)
        )
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

            Text(pinnedTitle(preset))
                .panelTextFont(size: 10, weight: .bold)
                .foregroundStyle(.white.opacity(0.86))
                .lineLimit(1)

            Text(pinnedDurationText(preset))
                .panelTextFont(size: 9, weight: .bold, design: .monospaced)
                .foregroundStyle(.white.opacity(0.48))
                .lineLimit(1)

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

    private var draftStopwatchBinding: Binding<StopwatchPreset> {
        Binding(
            get: { store.draftStopwatch },
            set: { store.updateDraftStopwatch($0) }
        )
    }

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

    private func displayName(_ title: String) -> String {
        title.isEmpty ? "—" : title
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

    static func stopwatchTimeText(_ interval: TimeInterval) -> String {
        let totalHundredths = max(0, Int((interval * 100).rounded(.down)))
        let hours = totalHundredths / 360_000
        let minutes = (totalHundredths / 6_000) % 60
        let seconds = (totalHundredths / 100) % 60
        let hundredths = totalHundredths % 100
        if hours > 0 {
            return String(format: "%d:%02d:%02d.%02d", hours, minutes, seconds, hundredths)
        }
        return String(format: "%02d:%02d.%02d", minutes, seconds, hundredths)
    }

    private func text(_ key: AppTextKey) -> String {
        settings.text(key)
    }
}

private struct StopwatchElapsedText: View {
    let state: RunningStopwatch
    let color: Color
    let fontSize: CGFloat

    var body: some View {
        Group {
            if state.isRunning {
                TimelineView(.periodic(from: .now, by: 0.05)) { context in
                    elapsedText(at: context.date)
                }
            } else {
                elapsedText(at: .now)
            }
        }
    }

    private func elapsedText(at date: Date) -> some View {
        Text(TimerView.stopwatchTimeText(state.elapsed(at: date)))
            .panelTextFont(size: fontSize, weight: .bold, design: .monospaced)
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .monospacedDigit()
    }
}

private struct StopwatchEntryCard: View {
    @Binding var preset: StopwatchPreset
    let canStart: Bool
    @ObservedObject var settings: AppSettings
    let onStart: () -> Void
    let onReset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            setupHeader

            TimerNameField(
                placeholder: text(.timerTitlePlaceholder),
                text: $preset.title
            )

            Text("00:00.00")
                .panelTextFont(size: 17, weight: .bold, design: .monospaced)
                .foregroundStyle(.white.opacity(0.88))
                .monospacedDigit()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

            HStack(spacing: 6) {
                TimerIconButton(
                    symbolName: "arrow.counterclockwise",
                    accent: .white.opacity(preset == .defaultDraft() ? 0.24 : 0.62)
                ) {
                    onReset()
                }
                .disabled(preset == .defaultDraft())
                .help(text(.timerReset))

                Spacer(minLength: 4)

                TimerStartButton(
                    title: text(.timerStart),
                    color: preset.color.color,
                    isEnabled: canStart,
                    action: onStart
                )
            }
        }
        .modifier(TimerSetupCardStyle())
    }

    private var setupHeader: some View {
        HStack(spacing: 6) {
            TimerColorMenu(
                selection: $preset.color,
                symbolName: TimerView.stopwatchSymbolName,
                language: settings.appLanguage,
                help: text(.timerColorPicker)
            )

            Text(text(.timerStopwatch))
                .panelTextFont(size: 10, weight: .bold)
                .foregroundStyle(.white.opacity(0.86))
                .lineLimit(1)

            Spacer(minLength: 0)
        }
    }

    private func text(_ key: AppTextKey) -> String {
        settings.text(key)
    }
}

private struct TimerEntryCard: View {
    @Binding var preset: TimerPreset
    let canStart: Bool
    @ObservedObject var settings: AppSettings
    let onStart: (TimerPreset) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            setupHeader

            TimerNameField(
                placeholder: text(.timerTitlePlaceholder),
                text: $preset.title
            )

            durationEditor
                .frame(maxHeight: .infinity, alignment: .center)

            HStack(spacing: 6) {
                TimerIconButton(
                    symbolName: "arrow.counterclockwise",
                    accent: .white.opacity(0.58)
                ) {
                    resetDuration()
                }
                .help(text(.timerReset))

                Spacer(minLength: 4)

                TimerStartButton(
                    title: text(.timerStart),
                    color: preset.color.color,
                    isEnabled: isStartEnabled
                ) {
                    onStart(preset)
                }
            }
        }
        .modifier(TimerSetupCardStyle())
    }

    private var setupHeader: some View {
        HStack(spacing: 6) {
            TimerColorMenu(
                selection: $preset.color,
                symbolName: preset.isPomodoro
                    ? TimerView.pomodoroSymbolName
                    : TimerView.timerSymbolName,
                language: settings.appLanguage,
                help: text(.timerColorPicker)
            )

            Text(preset.isPomodoro ? text(.timerPomodoroSection) : text(.timer))
                .panelTextFont(size: 10, weight: .bold)
                .foregroundStyle(.white.opacity(0.86))
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            Spacer(minLength: 0)

            TimerIconButton(
                symbolName: preset.soundEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill",
                accent: preset.soundEnabled ? .white.opacity(0.72) : .yellow.opacity(0.8),
                isActive: !preset.soundEnabled
            ) {
                preset.soundEnabled.toggle()
            }
            .help(text(.timerSoundToggle))
        }
    }

    @ViewBuilder
    private var durationEditor: some View {
        if preset.isPomodoro {
            VStack(spacing: 4) {
                pomodoroDurationRow(
                    title: text(.timerWork),
                    duration: $preset.workDuration
                )
                pomodoroDurationRow(
                    title: text(.timerBreak),
                    duration: $preset.breakDuration
                )
            }
        } else {
            TimerDurationInputView(
                duration: $preset.duration,
                accentColor: preset.color.color,
                onChanged: {}
            )
        }
    }

    private func pomodoroDurationRow(
        title: String,
        duration: Binding<TimeInterval>
    ) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text(title)
                .panelTextFont(size: 7.5, weight: .bold, design: .monospaced)
                .foregroundStyle(.white.opacity(0.42))
                .frame(width: 24, height: 24, alignment: .leading)

            TimerDurationInputView(
                duration: duration,
                accentColor: preset.color.color,
                onChanged: {}
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var isStartEnabled: Bool {
        canStart && (preset.isPomodoro ? preset.workDuration > 0 : preset.duration > 0)
    }

    private func resetDuration() {
        if preset.isPomodoro {
            preset.workDuration = 25 * 60
            preset.breakDuration = 5 * 60
        } else {
            preset.duration = 10 * 60
        }
    }

    private func text(_ key: AppTextKey) -> String {
        settings.text(key)
    }
}

private struct TimerColorMenu: View {
    @Binding var selection: TimerColor
    let symbolName: String
    let language: AppLanguage
    let help: String

    var body: some View {
        ZStack {
            HStack(spacing: 2) {
                Image(systemName: symbolName)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(selection.color)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(selection.color.opacity(0.11)))
                    .overlay(Circle().stroke(selection.color.opacity(0.72), lineWidth: 1.5))

                Image(systemName: "chevron.down")
                    .font(.system(size: 6.5, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.trailing, 3)

            Menu {
                ForEach(TimerColor.allCases, id: \.self) { color in
                    Button {
                        selection = color
                    } label: {
                        Label(
                            colorTitle(color),
                            systemImage: selection == color ? "checkmark.circle.fill" : "circle"
                        )
                    }
                }
            } label: {
                Color.clear
                    .frame(width: 32, height: 22)
                    .contentShape(Capsule())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        }
        .frame(width: 32, height: 22)
        .fixedSize()
        .help(help)
    }

    private func colorTitle(_ color: TimerColor) -> String {
        switch (language, color) {
        case (.japanese, .blue): return "ブルー"
        case (.japanese, .green): return "グリーン"
        case (.japanese, .orange): return "オレンジ"
        case (.japanese, .pink): return "ピンク"
        case (.english, .blue): return "Blue"
        case (.english, .green): return "Green"
        case (.english, .orange): return "Orange"
        case (.english, .pink): return "Pink"
        }
    }
}

private struct TimerNameField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .panelTextFont(size: 9, weight: .medium)
            .foregroundStyle(.white.opacity(0.84))
            .padding(.horizontal, 8)
            .frame(height: 27)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.black.opacity(0.16))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.white.opacity(0.095), lineWidth: 1)
            )
    }
}

private struct TimerStartButton: View {
    let title: String
    let color: Color
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "play.fill")
                    .font(.system(size: 8, weight: .bold))
                Text(title)
                    .panelTextFont(size: 9, weight: .bold)
            }
            .foregroundStyle(.black.opacity(0.85))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(isEnabled ? 1 : 0.3)))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(title)
    }
}

private struct TimerRunningTypeIcon: View {
    let symbolName: String
    let color: TimerColor

    var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(color.color)
            .frame(width: 25, height: 25)
            .background(Circle().fill(color.color.opacity(0.1)))
            .overlay(Circle().stroke(color.color.opacity(0.74), lineWidth: 1.5))
    }
}

private struct TimerRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(width: 1, height: 16)
    }
}

private struct TimerRunningRowStyle: ViewModifier {
    let color: Color
    var isAlerting = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .frame(minHeight: TimerLayoutMetrics.runningCardHeight)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(color.opacity(isAlerting ? 0.12 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(color.opacity(isAlerting ? 0.5 : 0.18), lineWidth: 1)
            )
    }
}

private struct TimerSetupCardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: TimerLayoutMetrics.setupCardHeight, maxHeight: TimerLayoutMetrics.setupCardHeight, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(0.034))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color.white.opacity(0.07), lineWidth: 1)
            )
    }
}

private struct TimerSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    init(
        title: String,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .panelTextFont(size: 10, weight: .bold, design: .monospaced)
                .foregroundStyle(Color.white.opacity(0.64))

            content()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, TimerLayoutMetrics.compactSectionVerticalPadding)
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
            .panelTextFont(size: 9.5, weight: .medium, design: .monospaced)
            .foregroundStyle(.white.opacity(0.36))
            .padding(.horizontal, 8)
            .frame(height: 30, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.black.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.white.opacity(0.05), lineWidth: 1)
            )
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
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(accent)
                .frame(width: 23, height: 23)
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
