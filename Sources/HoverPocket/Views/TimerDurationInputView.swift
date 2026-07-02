import AppKit
import SwiftUI

/// HH:MM:SS duration editor with the same interaction model as the Calendar
/// date/time editor: direct typing plus an inline adjustment rail that supports
/// drag and scroll fine-tuning.
struct TimerDurationInputView: View {
    @Binding var duration: TimeInterval

    let accentColor: Color
    let onChanged: () -> Void

    @State private var activeUnit: TimerDurationUnit?
    @State private var dragBaseDuration: TimeInterval?
    @State private var appliedDragSteps = 0
    @State private var dragOffset: CGFloat = 0
    @State private var scrollRemainder: CGFloat = 0
    @State private var scrollPulseOffset: CGFloat = 0
    @State private var isDraggingRail = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(alignment: .top, spacing: 3) {
                segmentField(for: .hour)
                TimerDurationSeparator(":")
                segmentField(for: .minute)
                TimerDurationSeparator(":")
                segmentField(for: .second)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let activeUnit {
                fixedAdjustmentRail(for: activeUnit)
            }
        }
        .frame(maxWidth: .infinity, minHeight: activeUnit == nil ? 26 : 54, alignment: .topLeading)
    }

    private func segmentField(for unit: TimerDurationUnit) -> some View {
        TimerDurationSegmentField(
            duration: $duration,
            activeUnit: $activeUnit,
            unit: unit,
            accentColor: accentColor,
            onChanged: onChanged,
            onDragChanged: updateDrag(unit:translationWidth:),
            onDragEnded: endDrag
        )
    }

    private func fixedAdjustmentRail(for unit: TimerDurationUnit) -> some View {
        AdjustmentRail(isActive: true, offset: railOffset, accentColor: accentColor)
            .frame(width: TimerDurationUnit.fixedRailWidth, height: 24)
            .contentShape(Rectangle())
            .overlay {
                RailInputCaptureView(
                    onScroll: handleScroll(delta:),
                    onDragChanged: { updateDrag(unit: unit, translationWidth: $0) },
                    onDragEnded: endDrag
                )
                .frame(width: TimerDurationUnit.fixedRailWidth, height: 24)
            }
            .offset(x: 0, y: 30)
            .zIndex(1)
    }

    private var railOffset: CGFloat {
        isDraggingRail ? dragOffset : scrollPulseOffset
    }

    private func clampedOffset(_ value: CGFloat) -> CGFloat {
        min(TimerDurationUnit.fixedRailOffsetLimit, max(-TimerDurationUnit.fixedRailOffsetLimit, value))
    }

    private func updateDrag(unit: TimerDurationUnit, translationWidth: CGFloat) {
        activeUnit = unit

        if dragBaseDuration == nil {
            dragBaseDuration = duration
            appliedDragSteps = 0
            scrollPulseOffset = 0
        }

        isDraggingRail = true
        dragOffset = clampedOffset(translationWidth)
        let steps = Int((translationWidth / unit.pointsPerStep).rounded(.towardZero))
        guard steps != appliedDragSteps, let dragBaseDuration else { return }

        duration = unit.adding(steps: steps, to: dragBaseDuration)
        appliedDragSteps = steps
        onChanged()
    }

    private func endDrag() {
        dragBaseDuration = nil
        appliedDragSteps = 0
        isDraggingRail = false
        withAnimation(.easeOut(duration: 0.14)) {
            dragOffset = 0
        }
    }

    private func handleScroll(delta: CGFloat) {
        guard let activeUnit else { return }

        scrollRemainder += -delta
        let steps = Int((scrollRemainder / activeUnit.scrollPointsPerStep).rounded(.towardZero))
        guard steps != 0 else { return }

        scrollRemainder -= CGFloat(steps) * activeUnit.scrollPointsPerStep
        let visualStep = steps > 0 ? 1 : -1

        withAnimation(.interactiveSpring(response: 0.18, dampingFraction: 0.82)) {
            scrollPulseOffset = clampedOffset(CGFloat(visualStep) * activeUnit.scrollPulseDistance)
        }

        duration = activeUnit.adding(steps: steps, to: duration)
        onChanged()

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard !isDraggingRail else { return }
            withAnimation(.easeOut(duration: 0.16)) {
                scrollPulseOffset = 0
            }
        }
    }
}

private struct TimerDurationSeparator: View {
    let value: String

    init(_ value: String) {
        self.value = value
    }

    var body: some View {
        Text(value)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(Color.white.opacity(0.28))
            .frame(height: 26, alignment: .center)
    }
}

private struct TimerDurationSegmentField: View {
    @Binding var duration: TimeInterval
    @Binding var activeUnit: TimerDurationUnit?

    let unit: TimerDurationUnit
    let accentColor: Color
    let onChanged: () -> Void
    let onDragChanged: (TimerDurationUnit, CGFloat) -> Void
    let onDragEnded: () -> Void

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(unit.placeholder, text: $text)
            .focused($isFocused)
            .modifier(TimerDurationSegmentFieldStyle(isActive: isActive, accentColor: accentColor))
            .onSubmit(applyTypedValue)
            .onChange(of: isFocused) { _, focused in
                handleFocusChange(focused)
            }
            .onChange(of: text) { _, newValue in
                sanitizeText(newValue)
            }
            .onChange(of: duration) { _, _ in
                syncText()
            }
            .simultaneousGesture(dragGesture)
            .onAppear {
                syncText()
            }
    }

    private var isActive: Bool {
        activeUnit == unit
    }

    private func handleFocusChange(_ focused: Bool) {
        if focused {
            activeUnit = unit
            syncText()
        } else {
            applyTypedValue()
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                activeUnit = unit
                applyTypedValue()
                onDragChanged(unit, value.translation.width)
            }
            .onEnded { _ in
                onDragEnded()
            }
    }

    private func applyTypedValue() {
        guard let value = Int(text) else {
            syncText()
            return
        }

        duration = unit.setting(value: value, in: duration)
        onChanged()
        syncText()
    }

    private func syncText() {
        text = String(format: "%02d", unit.value(from: duration))
    }

    private func sanitizeText(_ value: String) {
        let digits = value.filter { character in
            character.isNumber
        }
        let filtered = String(digits.prefix(2))
        if filtered != value {
            text = filtered
        }
    }
}

private struct TimerDurationSegmentFieldStyle: ViewModifier {
    let isActive: Bool
    let accentColor: Color

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(Color.white.opacity(0.86))
            .multilineTextAlignment(.center)
            .frame(width: 28, height: 26)
            .background(backgroundShape)
            .overlay(borderShape)
    }

    private var backgroundShape: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(isActive ? Color.white.opacity(0.13) : Color.white.opacity(0.055))
    }

    private var borderShape: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(isActive ? accentColor.opacity(0.9) : Color.white.opacity(0.06), lineWidth: 1)
    }
}

private enum TimerDurationUnit: Equatable {
    case hour
    case minute
    case second

    static let fixedRailWidth: CGFloat = 150
    static let fixedRailOffsetLimit: CGFloat = 64
    static let maxDuration: TimeInterval = 24 * 3600 - 1

    var placeholder: String {
        switch self {
        case .hour:
            return "HH"
        case .minute:
            return "mm"
        case .second:
            return "ss"
        }
    }

    var pointsPerStep: CGFloat {
        self == .second ? 8 : 12
    }

    var scrollPointsPerStep: CGFloat {
        self == .second ? 8 : 10
    }

    var scrollPulseDistance: CGFloat {
        18
    }

    /// One drag/scroll step in seconds.
    private var stepSeconds: TimeInterval {
        switch self {
        case .hour:
            return 3600
        case .minute:
            return 60
        case .second:
            return 5
        }
    }

    func value(from duration: TimeInterval) -> Int {
        let total = Int(duration.rounded())
        switch self {
        case .hour:
            return total / 3600
        case .minute:
            return (total % 3600) / 60
        case .second:
            return total % 60
        }
    }

    func setting(value: Int, in duration: TimeInterval) -> TimeInterval {
        let hours = self == .hour ? min(23, max(0, value)) : TimerDurationUnit.hour.value(from: duration)
        let minutes = self == .minute ? min(59, max(0, value)) : TimerDurationUnit.minute.value(from: duration)
        let seconds = self == .second ? min(59, max(0, value)) : TimerDurationUnit.second.value(from: duration)
        return TimeInterval(hours * 3600 + minutes * 60 + seconds)
    }

    func adding(steps: Int, to duration: TimeInterval) -> TimeInterval {
        let next = duration + TimeInterval(steps) * stepSeconds
        return next.clamped(to: 0...Self.maxDuration)
    }
}
