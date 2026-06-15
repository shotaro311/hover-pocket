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
    @State private var isDragging = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 2) {
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

            AdjustmentRail(isActive: isFocused || isDragging, offset: railOffset, accentColor: accentColor)
                .frame(width: unit.railWidth)
                .frame(width: unit.width, height: 12, alignment: .center)
                .contentShape(Rectangle())
                .gesture(dragGesture)
        }
        .onAppear {
            syncText()
        }
        .help(unit.helpText)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if dragBaseDate == nil {
                    applyTypedValue()
                    dragBaseDate = date
                    appliedDragSteps = 0
                }

                isDragging = true
                let steps = Int((value.translation.width / unit.pointsPerStep).rounded(.towardZero))
                guard steps != appliedDragSteps, let dragBaseDate else { return }

                date = unit.adding(steps: steps, to: dragBaseDate, calendar: calendar)
                appliedDragSteps = steps
                onDateChanged()
                syncText()
            }
            .onEnded { _ in
                dragBaseDate = nil
                appliedDragSteps = 0
                isDragging = false
                syncText()
            }
    }

    private var railOffset: CGFloat {
        let raw = CGFloat(appliedDragSteps) * 3
        return min(18, max(-18, raw))
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
            HStack(spacing: 3) {
                ForEach(0..<17, id: \.self) { index in
                    Capsule()
                        .fill(tickColor(for: index))
                        .frame(width: 1, height: index % 4 == 0 ? 7 : 4)
                }
            }

            Capsule()
                .fill(accentColor.opacity(isActive ? 0.72 : 0))
                .frame(width: 2, height: 10)

            Circle()
                .fill(accentColor.opacity(isActive ? 1 : 0))
                .frame(width: 9, height: 9)
                .shadow(color: accentColor.opacity(isActive ? 0.42 : 0), radius: 5, x: 0, y: 0)
                .offset(x: offset)
        }
        .frame(height: 12)
        .opacity(isActive ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: isActive)
    }

    private func tickColor(for index: Int) -> Color {
        guard isActive else {
            return .clear
        }
        return index == 8 ? accentColor.opacity(0.9) : Color.white.opacity(index % 4 == 0 ? 0.36 : 0.22)
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
        self == .year ? 82 : 68
    }

    var pointsPerStep: CGFloat {
        self == .minute ? 7 : 10
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
