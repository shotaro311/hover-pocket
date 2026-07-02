import AppKit
import SwiftUI

struct CalendarDateTimeInputView: View {
    @Binding var date: Date

    let label: String
    let language: AppLanguage
    let includesTime: Bool
    let onDateChanged: () -> Void

    private let calendar = Calendar.current
    private let accentColor = Color(red: 1.0, green: 0.73, blue: 0.08)

    @State private var activeUnit: DateTimeUnit?
    @State private var dragBaseDate: Date?
    @State private var appliedDragSteps = 0
    @State private var dragOffset: CGFloat = 0
    @State private var scrollRemainder: CGFloat = 0
    @State private var scrollPulseOffset: CGFloat = 0
    @State private var isDraggingRail = false

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.42))
                .lineLimit(1)
                .frame(width: 32, alignment: .leading)
                .padding(.top, 6)

            inputLane
        }
    }

    private var inputLane: some View {
        ZStack(alignment: .topLeading) {
            HStack(alignment: .top, spacing: 3) {
                DateTimeSegmentField(
                    date: $date,
                    activeUnit: $activeUnit,
                    unit: .year,
                    calendar: calendar,
                    language: language,
                    accentColor: accentColor,
                    onDateChanged: onDateChanged,
                    onDragChanged: updateDrag(unit:translationWidth:),
                    onDragEnded: endDrag
                )
                DateTimeSeparator("/")
                DateTimeSegmentField(
                    date: $date,
                    activeUnit: $activeUnit,
                    unit: .month,
                    calendar: calendar,
                    language: language,
                    accentColor: accentColor,
                    onDateChanged: onDateChanged,
                    onDragChanged: updateDrag(unit:translationWidth:),
                    onDragEnded: endDrag
                )
                DateTimeSeparator("/")
                DateTimeSegmentField(
                    date: $date,
                    activeUnit: $activeUnit,
                    unit: .day,
                    calendar: calendar,
                    language: language,
                    accentColor: accentColor,
                    onDateChanged: onDateChanged,
                    onDragChanged: updateDrag(unit:translationWidth:),
                    onDragEnded: endDrag
                )

                if includesTime {
                    Spacer(minLength: 4)
                    DateTimeSegmentField(
                        date: $date,
                        activeUnit: $activeUnit,
                        unit: .hour,
                        calendar: calendar,
                        language: language,
                        accentColor: accentColor,
                        onDateChanged: onDateChanged,
                        onDragChanged: updateDrag(unit:translationWidth:),
                        onDragEnded: endDrag
                    )
                    DateTimeSeparator(":")
                    DateTimeSegmentField(
                        date: $date,
                        activeUnit: $activeUnit,
                        unit: .minute,
                        calendar: calendar,
                        language: language,
                        accentColor: accentColor,
                        onDateChanged: onDateChanged,
                        onDragChanged: updateDrag(unit:translationWidth:),
                        onDragEnded: endDrag
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let activeUnit {
                fixedAdjustmentRail(for: activeUnit)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .topLeading)
    }

    private func fixedAdjustmentRail(for unit: DateTimeUnit) -> some View {
        AdjustmentRail(isActive: true, offset: railOffset, accentColor: accentColor)
            .frame(width: DateTimeUnit.fixedRailWidth, height: 24)
            .contentShape(Rectangle())
            .overlay {
                RailInputCaptureView(
                    onScroll: handleScroll(delta:),
                    onDragChanged: { updateDrag(unit: unit, translationWidth: $0) },
                    onDragEnded: endDrag
                )
                .frame(width: DateTimeUnit.fixedRailWidth, height: 24)
            }
            .offset(x: DateTimeUnit.fixedRailXOffset, y: 30)
            .zIndex(1)
    }

    private var railOffset: CGFloat {
        isDraggingRail ? dragOffset : scrollPulseOffset
    }

    private func clampedOffset(_ value: CGFloat) -> CGFloat {
        min(DateTimeUnit.fixedRailOffsetLimit, max(-DateTimeUnit.fixedRailOffsetLimit, value))
    }

    private func updateDrag(unit: DateTimeUnit, translationWidth: CGFloat) {
        activeUnit = unit

        if dragBaseDate == nil {
            dragBaseDate = date
            appliedDragSteps = 0
            scrollPulseOffset = 0
        }

        isDraggingRail = true
        dragOffset = clampedOffset(translationWidth)
        let steps = Int((translationWidth / unit.pointsPerStep).rounded(.towardZero))
        guard steps != appliedDragSteps, let dragBaseDate else { return }

        date = unit.adding(steps: steps, to: dragBaseDate, calendar: calendar)
        appliedDragSteps = steps
        onDateChanged()
    }

    private func endDrag() {
        dragBaseDate = nil
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

        date = activeUnit.adding(steps: steps, to: date, calendar: calendar)
        onDateChanged()

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard !isDraggingRail else { return }
            withAnimation(.easeOut(duration: 0.16)) {
                scrollPulseOffset = 0
            }
        }
    }
}

private struct DateTimeSeparator: View {
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

private struct DateTimeSegmentField: View {
    @Binding var date: Date
    @Binding var activeUnit: DateTimeUnit?

    let unit: DateTimeUnit
    let calendar: Calendar
    let language: AppLanguage
    let accentColor: Color
    let onDateChanged: () -> Void
    let onDragChanged: (DateTimeUnit, CGFloat) -> Void
    let onDragEnded: () -> Void

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(unit.placeholder, text: $text)
            .focused($isFocused)
            .modifier(DateTimeSegmentFieldStyle(width: unit.width, isActive: isActive, accentColor: accentColor))
            .onSubmit(applyTypedValue)
            .onChange(of: isFocused) { _, focused in
                handleFocusChange(focused)
            }
            .onChange(of: text) { _, newValue in
                sanitizeText(newValue)
            }
            .onChange(of: date) { _, _ in
                syncText()
            }
            .simultaneousGesture(dragGesture)
        .onAppear {
            syncText()
        }
        .help(unit.helpText(language: language))
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

        date = unit.setting(value: value, in: date, calendar: calendar)
        onDateChanged()
        syncText()
    }

    private func syncText() {
        text = unit.formattedValue(from: date, calendar: calendar)
    }

    private func sanitizeText(_ value: String) {
        let digits = value.filter { character in
            character.isNumber
        }
        let filtered = String(digits.prefix(unit.maxDigits))
        if filtered != value {
            text = filtered
        }
    }
}

private struct DateTimeSegmentFieldStyle: ViewModifier {
    let width: CGFloat
    let isActive: Bool
    let accentColor: Color

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(Color.white.opacity(0.86))
            .multilineTextAlignment(.center)
            .frame(width: width, height: 26)
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

private enum DateTimeUnit: Equatable {
    case year
    case month
    case day
    case hour
    case minute

    static let fixedRailWidth: CGFloat = 150
    static let fixedRailXOffset: CGFloat = 44
    static let fixedRailOffsetLimit: CGFloat = 64

    var placeholder: String {
        switch self {
        case .year:
            return "YYYY"
        case .month:
            return "MM"
        case .day:
            return "DD"
        case .hour:
            return "HH"
        case .minute:
            return "mm"
        }
    }

    var maxDigits: Int {
        self == .year ? 4 : 2
    }

    var width: CGFloat {
        self == .year ? 44 : 28
    }

    var pointsPerStep: CGFloat {
        self == .minute ? 8 : 12
    }

    var scrollPointsPerStep: CGFloat {
        self == .minute ? 8 : 10
    }

    var scrollPulseDistance: CGFloat {
        self == .year ? 22 : 18
    }

    func helpText(language: AppLanguage) -> String {
        AppText.text(.dateTimeInputHelp, language: language)
    }

    func formattedValue(from date: Date, calendar: Calendar) -> String {
        let value = value(from: date, calendar: calendar)
        switch self {
        case .year:
            return String(format: "%04d", value)
        default:
            return String(format: "%02d", value)
        }
    }

    func setting(value: Int, in date: Date, calendar: Calendar) -> Date {
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        components.second = 0

        switch self {
        case .year:
            components.year = min(9999, max(1, value))
        case .month:
            components.month = min(12, max(1, value))
        case .day:
            components.day = value
        case .hour:
            components.hour = min(23, max(0, value))
        case .minute:
            components.minute = min(59, max(0, value))
        }

        let year = components.year ?? calendar.component(.year, from: date)
        let month = components.month ?? calendar.component(.month, from: date)
        let maxDay = Self.daysInMonth(year: year, month: month, calendar: calendar)
        components.day = min(maxDay, max(1, components.day ?? 1))

        return calendar.date(from: components) ?? date
    }

    func adding(steps: Int, to date: Date, calendar: Calendar) -> Date {
        let value = steps * dragValue
        return calendar.date(byAdding: calendarComponent, value: value, to: date) ?? date
    }

    private var dragValue: Int {
        self == .minute ? 5 : 1
    }

    private var calendarComponent: Calendar.Component {
        switch self {
        case .year:
            return .year
        case .month:
            return .month
        case .day:
            return .day
        case .hour:
            return .hour
        case .minute:
            return .minute
        }
    }

    private func value(from date: Date, calendar: Calendar) -> Int {
        switch self {
        case .year:
            return calendar.component(.year, from: date)
        case .month:
            return calendar.component(.month, from: date)
        case .day:
            return calendar.component(.day, from: date)
        case .hour:
            return calendar.component(.hour, from: date)
        case .minute:
            return calendar.component(.minute, from: date)
        }
    }

    private static func daysInMonth(year: Int, month: Int, calendar: Calendar) -> Int {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = 1
        guard let date = calendar.date(from: components),
              let range = calendar.range(of: .day, in: .month, for: date) else {
            return 31
        }
        return range.count
    }
}
