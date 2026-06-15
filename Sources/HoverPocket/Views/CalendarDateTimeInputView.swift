import AppKit
import SwiftUI

struct CalendarDateTimeInputView: View {
    @Binding var date: Date

    let label: String
    let includesTime: Bool
    let onDateChanged: () -> Void

    private let calendar = Calendar.current

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.42))
                .lineLimit(1)
                .frame(width: 32, alignment: .leading)
                .padding(.top, 6)

            HStack(alignment: .top, spacing: 3) {
                DateTimeSegmentField(date: $date, unit: .year, calendar: calendar, onDateChanged: onDateChanged)
                DateTimeSeparator("/")
                DateTimeSegmentField(date: $date, unit: .month, calendar: calendar, onDateChanged: onDateChanged)
                DateTimeSeparator("/")
                DateTimeSegmentField(date: $date, unit: .day, calendar: calendar, onDateChanged: onDateChanged)

                if includesTime {
                    Spacer(minLength: 4)
                    DateTimeSegmentField(date: $date, unit: .hour, calendar: calendar, onDateChanged: onDateChanged)
                    DateTimeSeparator(":")
                    DateTimeSegmentField(date: $date, unit: .minute, calendar: calendar, onDateChanged: onDateChanged)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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

    let unit: DateTimeUnit
    let calendar: Calendar
    let onDateChanged: () -> Void

    private let accentColor = Color(red: 1.0, green: 0.73, blue: 0.08)

    @State private var text = ""
    @State private var dragBaseDate: Date?
    @State private var appliedDragSteps = 0
    @State private var dragOffset: CGFloat = 0
    @State private var scrollRemainder: CGFloat = 0
    @State private var scrollPulseOffset: CGFloat = 0
    @State private var isDragging = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 4) {
            TextField(unit.placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.86))
                .multilineTextAlignment(.center)
                .focused($isFocused)
                .frame(width: unit.width, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill((isFocused || isDragging) ? Color.white.opacity(0.13) : Color.white.opacity(0.055))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke((isFocused || isDragging) ? accentColor.opacity(0.9) : Color.white.opacity(0.06), lineWidth: 1)
                )
                .onSubmit {
                    applyTypedValue()
                }
                .onChange(of: isFocused) { _, focused in
                    focused ? syncText() : applyTypedValue()
                }
                .onChange(of: text) { _, newValue in
                    let filtered = String(newValue.filter(\.isNumber).prefix(unit.maxDigits))
                    if filtered != newValue {
                        text = filtered
                    }
                }
                .simultaneousGesture(dragGesture)

            Color.clear
                .frame(width: unit.width, height: 24)
                .overlay {
                    AdjustmentRail(isActive: isRailVisible, offset: railOffset, accentColor: accentColor)
                        .frame(width: unit.railWidth, height: 24)
                        .contentShape(Rectangle())
                        .overlay {
                            if isRailVisible {
                                RailInputCaptureView(
                                    onScroll: handleScroll(delta:),
                                    onDragChanged: updateDrag(translationWidth:),
                                    onDragEnded: endDrag
                                )
                                .frame(width: unit.railWidth, height: 24)
                            }
                        }
                        .allowsHitTesting(isRailVisible)
                }
                .zIndex(isRailVisible ? 1 : 0)
        }
        .onAppear {
            syncText()
        }
        .help(unit.helpText)
    }

    private var isRailVisible: Bool {
        isFocused || isDragging
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                updateDrag(translationWidth: value.translation.width)
            }
            .onEnded { _ in
                endDrag()
            }
    }

    private var railOffset: CGFloat {
        isDragging ? dragOffset : scrollPulseOffset
    }

    private func clampedOffset(_ value: CGFloat) -> CGFloat {
        min(unit.railOffsetLimit, max(-unit.railOffsetLimit, value))
    }

    private func updateDrag(translationWidth: CGFloat) {
        if dragBaseDate == nil {
            applyTypedValue()
            dragBaseDate = date
            appliedDragSteps = 0
            scrollPulseOffset = 0
        }

        isDragging = true
        dragOffset = clampedOffset(translationWidth)
        let steps = Int((translationWidth / unit.pointsPerStep).rounded(.towardZero))
        guard steps != appliedDragSteps, let dragBaseDate else { return }

        date = unit.adding(steps: steps, to: dragBaseDate, calendar: calendar)
        appliedDragSteps = steps
        onDateChanged()
        syncText()
    }

    private func endDrag() {
        dragBaseDate = nil
        appliedDragSteps = 0
        isDragging = false
        withAnimation(.easeOut(duration: 0.14)) {
            dragOffset = 0
        }
        syncText()
    }

    private func handleScroll(delta: CGFloat) {
        guard isRailVisible else { return }

        scrollRemainder += -delta
        let steps = Int((scrollRemainder / unit.scrollPointsPerStep).rounded(.towardZero))
        guard steps != 0 else { return }

        scrollRemainder -= CGFloat(steps) * unit.scrollPointsPerStep
        let visualStep = steps > 0 ? 1 : -1

        withAnimation(.interactiveSpring(response: 0.18, dampingFraction: 0.82)) {
            scrollPulseOffset = clampedOffset(CGFloat(visualStep) * unit.scrollPulseDistance)
        }

        date = unit.adding(steps: steps, to: date, calendar: calendar)
        onDateChanged()
        syncText()

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard !isDragging else { return }
            withAnimation(.easeOut(duration: 0.16)) {
                scrollPulseOffset = 0
            }
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
}

private struct AdjustmentRail: View {
    let isActive: Bool
    let offset: CGFloat
    let accentColor: Color

    var body: some View {
        ZStack(alignment: .center) {
            Capsule()
                .fill(Color.white.opacity(isActive ? 0.06 : 0))
                .frame(height: 14)

            HStack(spacing: 4) {
                ForEach(0..<23, id: \.self) { index in
                    Capsule()
                        .fill(tickColor(for: index))
                        .frame(width: 1.4, height: index % 4 == 0 ? 12 : 7)
                }
            }

            Capsule()
                .fill(accentColor.opacity(isActive ? 0.72 : 0))
                .frame(width: 3, height: 18)

            Circle()
                .fill(accentColor.opacity(isActive ? 1 : 0))
                .frame(width: 15, height: 15)
                .shadow(color: accentColor.opacity(isActive ? 0.48 : 0), radius: 8, x: 0, y: 0)
                .offset(x: offset)
        }
        .frame(height: 24)
        .opacity(isActive ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: isActive)
    }

    private func tickColor(for index: Int) -> Color {
        guard isActive else {
            return .clear
        }
        return index == 11 ? accentColor.opacity(0.9) : Color.white.opacity(index % 4 == 0 ? 0.42 : 0.26)
    }
}

private struct RailInputCaptureView: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: () -> Void

    func makeNSView(context: Context) -> RailInputCaptureNSView {
        let view = RailInputCaptureNSView()
        view.onScroll = onScroll
        view.onDragChanged = onDragChanged
        view.onDragEnded = onDragEnded
        return view
    }

    func updateNSView(_ nsView: RailInputCaptureNSView, context: Context) {
        nsView.onScroll = onScroll
        nsView.onDragChanged = onDragChanged
        nsView.onDragEnded = onDragEnded
    }
}

private final class RailInputCaptureNSView: NSView {
    var onScroll: (CGFloat) -> Void = { _ in }
    var onDragChanged: (CGFloat) -> Void = { _ in }
    var onDragEnded: () -> Void = {}

    private var dragStartX: CGFloat?

    override func hitTest(_ point: NSPoint) -> NSView? {
        self
    }

    override func mouseDown(with event: NSEvent) {
        dragStartX = convert(event.locationInWindow, from: nil).x
    }

    override func mouseDragged(with event: NSEvent) {
        let currentX = convert(event.locationInWindow, from: nil).x
        let startX = dragStartX ?? currentX
        dragStartX = startX
        onDragChanged(currentX - startX)
    }

    override func mouseUp(with event: NSEvent) {
        dragStartX = nil
        onDragEnded()
    }

    override func mouseExited(with event: NSEvent) {
        dragStartX = nil
    }

    override func scrollWheel(with event: NSEvent) {
        let dominantDelta = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX)
            ? event.scrollingDeltaY
            : event.scrollingDeltaX

        guard dominantDelta != 0 else {
            super.scrollWheel(with: event)
            return
        }

        onScroll(dominantDelta)
    }
}

private enum DateTimeUnit {
    case year
    case month
    case day
    case hour
    case minute

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

    var railWidth: CGFloat {
        self == .year ? 132 : 116
    }

    var railOffsetLimit: CGFloat {
        self == .year ? 54 : 46
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

    var helpText: String {
        "Type a value, or drag left/right to adjust."
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
