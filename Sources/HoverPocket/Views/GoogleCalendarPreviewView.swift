import SwiftUI

struct GoogleCalendarPreviewView: View {
    let isActive: Bool
    @ObservedObject var settings: AppSettings

    @ObservedObject private var store = GoogleCalendarStore.shared
    @State private var displayedMonth = Calendar.current.startOfMonth(for: Date())
    @State private var selectedDate = Date()
    @State private var lockedDate: Date?
    @State private var hoveredDate: Date?
    @State private var draft: GoogleCalendarEventDraft?
    @State private var deleteTarget: GoogleCalendarEventOccurrence?

    private let columns = Array(repeating: GridItem(.fixed(36), spacing: 5), count: 7)

    var body: some View {
        Group {
            switch store.connectionState {
            case .missingConfiguration:
                configurationView
            case .restoring:
                calendarView
            case .signedOut, .needsReconnect, .signingIn:
                signedOutView
            case .signedIn:
                calendarView
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .onAppear {
            refreshIfNeeded()
        }
        .onChange(of: isActive) { _, active in
            if active {
                refreshIfNeeded()
            }
        }
        .alert(settings.text(.deleteEventAlertTitle), isPresented: deleteAlertBinding, presenting: deleteTarget) { event in
            Button(settings.text(.delete), role: .destructive) {
                deleteEvent(event)
            }
            Button(settings.text(.cancel), role: .cancel) {
                deleteTarget = nil
            }
        } message: { event in
            Text(event.title)
        }
    }

    private var language: AppLanguage {
        settings.appLanguage
    }

    private var calendarView: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 10) {
                monthHeader
                weekdayHeader
                dayGrid
            }
            .frame(width: 282)

            Divider()
                .overlay(Color.white.opacity(0.08))

            detailPane
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .overlay(alignment: .bottomLeading) {
            if case .loading(let previous) = store.loadState, previous != nil {
                ProgressView()
                    .controlSize(.small)
                    .padding(.bottom, 2)
            }
        }
    }

    private var monthHeader: some View {
        HStack(spacing: 8) {
            Button {
                moveMonth(by: -1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(IconButtonStyle(selected: false))
            .help(settings.text(.previousMonth))

            Text(language.formattedDate(displayedMonth, template: "yMMMM"))
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(maxWidth: .infinity)

            Button {
                moveMonth(by: 1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(IconButtonStyle(selected: false))
            .help(settings.text(.nextMonth))
        }
    }

    private var weekdayHeader: some View {
        let symbols = Calendar.current.shortStandaloneWeekdaySymbols
        return HStack(spacing: 5) {
            ForEach(0..<7, id: \.self) { index in
                let weekdayIndex = (Calendar.current.firstWeekday - 1 + index) % 7
                Text(String(symbols[weekdayIndex].prefix(1)))
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.38))
                    .frame(width: 36)
            }
        }
    }

    private var dayGrid: some View {
        LazyVGrid(columns: columns, spacing: 5) {
            ForEach(store.days(for: displayedMonth, hoveredDate: hoveredDate)) { day in
                dayCell(day)
            }
        }
    }

    private func dayCell(_ day: CalendarDayCell) -> some View {
        let isSelected = Calendar.current.isDate(day.date, inSameDayAs: detailDate)
        return VStack(spacing: 3) {
            Text("\(day.dayNumber)")
                .font(.system(size: 11, weight: day.isToday ? .bold : .semibold, design: .monospaced))
                .foregroundStyle(day.isInDisplayedMonth ? Color.white : Color.white.opacity(0.28))
                .lineLimit(1)

            HStack(spacing: 2) {
                ForEach(day.events.prefix(3)) { event in
                    Circle()
                        .fill(color(for: event.calendarColorHex))
                        .frame(width: 4, height: 4)
                }
            }
            .frame(height: 5)
        }
        .frame(width: 36, height: 32)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(dayBackground(isSelected: isSelected, isToday: day.isToday))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(day.isToday ? Color.white.opacity(0.42) : Color.white.opacity(isSelected ? 0.18 : 0), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .gesture(
            TapGesture(count: 2)
                .onEnded {
                    beginNewEvent(on: day.date)
                }
                .exclusively(before: TapGesture()
                    .onEnded {
                        selectDay(day.date)
                    }
                )
        )
        .buttonStyle(.plain)
        .onHover { inside in
            guard lockedDate == nil, draft == nil else { return }
            hoveredDate = inside ? day.date : nil
        }
        .help(day.date.formatted(date: .abbreviated, time: .omitted))
    }

    @ViewBuilder
    private var detailPane: some View {
        if draft != nil {
            CalendarEventEditorView(
                draft: draftBinding,
                sources: store.writableSources(),
                isSaving: store.isMutatingEvent,
                errorMessage: store.lastErrorMessage,
                language: language,
                onSave: saveDraft,
                onCancel: {
                    draft = nil
                },
                onDelete: draft?.eventID == nil ? nil : {
                    if let event = eventForCurrentDraft {
                        deleteTarget = event
                    }
                }
            )
        } else {
            dayDetailPane
        }
    }

    private var dayDetailPane: some View {
        let events = store.events(for: detailDate)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(language.formattedDate(detailDate, template: "MMMdEEEE"))
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Text(updatedText)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.36))
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Button {
                    beginNewEvent(on: detailDate)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(IconButtonStyle(selected: false))
                .disabled(store.writableSources().isEmpty || store.isMutatingEvent)
                .help(settings.text(.addEvent))

                if lockedDate != nil {
                    Button {
                        lockedDate = nil
                        draft = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(IconButtonStyle(selected: false))
                    .help(settings.text(.clearSelectedDay))
                }
            }

            if let message = currentErrorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.yellow.opacity(0.9))
                    .lineLimit(2)
            }

            if events.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: store.writableSources().isEmpty ? "calendar.badge.exclamationmark" : "calendar.badge.plus")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.28))
                    Text(store.writableSources().isEmpty ? settings.text(.readOnly) : settings.text(.noEvents))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.62))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(events) { event in
                            eventRow(event)
                        }
                    }
                }
                .scrollIndicators(.never)
            }

            Spacer(minLength: 0)
        }
    }

    private func eventRow(_ event: GoogleCalendarEventOccurrence) -> some View {
        HStack(alignment: .top, spacing: 7) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color(for: event.calendarColorHex))
                .frame(width: 4, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(eventTitle(for: event))
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(2)

                Text(timeText(for: event))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.44))
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            HStack(spacing: 4) {
                Button {
                    beginEditing(event)
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(IconButtonStyle(selected: false))
                .disabled(!event.calendarCanWrite || store.isMutatingEvent)
                .help(settings.text(.editEvent))

                Button {
                    deleteTarget = event
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(IconButtonStyle(selected: false))
                .disabled(!event.calendarCanWrite || store.isMutatingEvent)
                .help(settings.text(.delete))
            }
        }
    }

    private var signedOutView: some View {
        VStack(spacing: 14) {
            Image(systemName: "calendar")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))

            VStack(spacing: 5) {
                Text(settings.text(.googleCalendar))
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                Text(calendarConnectionPrompt)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.48))
            }

            Button {
                store.connect()
            } label: {
                HStack(spacing: 7) {
                    if store.connectionState == .signingIn {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "person.crop.circle.badge.plus")
                    }
                    Text(calendarConnectTitle)
                }
                .font(.system(size: 12, weight: .bold, design: .monospaced))
            }
            .disabled(store.connectionState == .signingIn)

            if let message = store.lastErrorMessage {
                Text(message)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.yellow.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var configurationView: some View {
        VStack(spacing: 12) {
            Image(systemName: "key.slash")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white.opacity(0.48))

            Text(settings.text(.calendarConfigMissing))
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)

            Text(settings.text(.calendarConfigMissingDetail))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { deleteTarget != nil },
            set: { isPresented in
                if !isPresented {
                    deleteTarget = nil
                }
            }
        )
    }

    private var draftBinding: Binding<GoogleCalendarEventDraft> {
        Binding(
            get: {
                draft ?? GoogleCalendarEventDraft(
                    calendarID: store.writableSources().first?.id ?? "",
                    eventID: nil,
                    title: "",
                    location: "",
                    notes: "",
                    start: detailDate,
                    end: detailDate.addingTimeInterval(3_600),
                    isAllDay: false
                )
            },
            set: { draft = $0 }
        )
    }

    private var eventForCurrentDraft: GoogleCalendarEventOccurrence? {
        guard let draft, let eventID = draft.eventID else {
            return nil
        }
        return store.events(for: detailDate).first {
            $0.calendarID == draft.calendarID && $0.googleEventID == eventID
        }
    }

    private var detailDate: Date {
        if let lockedDate {
            return lockedDate
        }
        return hoveredDate ?? selectedDate
    }

    private var updatedText: String {
        guard let snapshot = store.loadState.snapshot else {
            return settings.text(.notLoaded)
        }
        return "\(settings.text(.updated)) \(formattedTime(snapshot.updatedAt))"
    }

    private var currentErrorMessage: String? {
        if case .failed(let message, _) = store.loadState {
            return message
        }
        return nil
    }

    private var calendarConnectionPrompt: String {
        switch store.connectionState {
        case .restoring:
            return settings.text(.calendarConnectionChecking)
        case .needsReconnect:
            return settings.text(.calendarConnectionReconnectDetail)
        case .signingIn:
            return settings.text(.calendarConnectionSignInDetail)
        default:
            return settings.text(.calendarConnectionSignedOutDetail)
        }
    }

    private var calendarConnectTitle: String {
        switch store.connectionState {
        case .signingIn:
            return settings.text(.calendarConnectConnecting)
        case .restoring:
            return settings.text(.calendarConnectChecking)
        case .needsReconnect:
            return settings.text(.calendarConnectReconnect)
        default:
            return settings.text(.calendarConnectOpenLogin)
        }
    }

    private func refreshIfNeeded() {
        guard isActive else { return }
        store.restoreConnectionIfNeeded()
        store.refreshMonth(containing: displayedMonth)
    }

    private func moveMonth(by value: Int) {
        guard let next = Calendar.current.date(byAdding: .month, value: value, to: displayedMonth) else {
            return
        }
        displayedMonth = Calendar.current.startOfMonth(for: next)
        selectedDate = displayedMonth
        lockedDate = nil
        hoveredDate = nil
        draft = nil
        store.refreshMonth(containing: displayedMonth, force: true)
    }

    private func selectDay(_ day: Date) {
        selectedDate = day
        lockedDate = day
        hoveredDate = nil
        draft = nil
    }

    private func beginNewEvent(on day: Date) {
        guard let newDraft = GoogleCalendarEventDraft.new(on: day, sources: store.writableSources()) else {
            selectDay(day)
            return
        }
        selectedDate = day
        lockedDate = day
        hoveredDate = nil
        draft = newDraft
    }

    private func beginEditing(_ event: GoogleCalendarEventOccurrence) {
        selectedDate = event.start
        lockedDate = event.start
        hoveredDate = nil
        draft = .editing(event)
    }

    private func saveDraft() {
        guard let draft else { return }
        Task {
            let didSave = await store.saveEvent(draft, refreshing: displayedMonth)
            if didSave {
                self.draft = nil
            }
        }
    }

    private func deleteEvent(_ event: GoogleCalendarEventOccurrence) {
        deleteTarget = nil
        Task {
            let didDelete = await store.deleteEvent(event, refreshing: displayedMonth)
            if didDelete, draft?.eventID == event.googleEventID {
                draft = nil
            }
        }
    }

    private func timeText(for event: GoogleCalendarEventOccurrence) -> String {
        if event.isAllDay {
            return settings.text(.allDay)
        }
        return "\(formattedTime(event.start))-\(formattedTime(event.end))"
    }

    private func eventTitle(for event: GoogleCalendarEventOccurrence) -> String {
        let trimmedTitle = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedTitle.isEmpty ? settings.text(.untitledEvent) : trimmedTitle
    }

    private func formattedTime(_ date: Date) -> String {
        language.formattedDate(date, template: "Hm")
    }

    private func dayBackground(isSelected: Bool, isToday: Bool) -> Color {
        if isSelected {
            return Color.white.opacity(0.12)
        }
        if isToday {
            return Color.white.opacity(0.06)
        }
        return Color.white.opacity(0.035)
    }

    private func color(for hex: String?) -> Color {
        guard let hex else {
            return .cyan.opacity(0.78)
        }
        return Color(hex: hex) ?? .cyan.opacity(0.78)
    }
}

private struct CalendarEventEditorView: View {
    @Binding var draft: GoogleCalendarEventDraft

    let sources: [GoogleCalendarSource]
    let isSaving: Bool
    let errorMessage: String?
    let language: AppLanguage
    let onSave: () -> Void
    let onCancel: () -> Void
    let onDelete: (() -> Void)?

    @FocusState private var focusedField: CalendarEditorFocusField?

    private var calendar: Calendar {
        .current
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(draft.isNew ? text(.newEvent) : text(.editEvent))
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                    Text(language.formattedDate(draft.start, template: "MMMEd"))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.38))
                }

                Spacer(minLength: 0)

                Button {
                    onCancel()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(IconButtonStyle(selected: false))
                .help(text(.cancel))
            }

            TextField(text(.title), text: $draft.title)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, weight: .medium))
                .focused($focusedField, equals: .title)

            Picker(text(.calendar), selection: $draft.calendarID) {
                ForEach(sources) { source in
                    Text(source.title).tag(source.id)
                }
            }
            .controlSize(.small)
            .labelsHidden()
            .disabled(!draft.isNew || sources.isEmpty || isSaving)

            Toggle(text(.allDay), isOn: $draft.isAllDay)
                .toggleStyle(.checkbox)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .disabled(isSaving)
                .onChange(of: draft.isAllDay) { _, _ in
                    normalizeDraftDates()
                }

            if draft.isAllDay {
                CalendarDateTimeInputView(
                    date: allDayDateBinding,
                    label: text(.date),
                    language: language,
                    includesTime: false,
                    onDateChanged: normalizeDraftDates
                )
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    CalendarDateTimeInputView(
                        date: $draft.start,
                        label: text(.start),
                        language: language,
                        includesTime: true,
                        onDateChanged: normalizeDraftDates
                    )
                    CalendarDateTimeInputView(
                        date: $draft.end,
                        label: text(.end),
                        language: language,
                        includesTime: true,
                        onDateChanged: normalizeDraftDates
                    )
                }
                .onChange(of: draft.start) { _, _ in
                    normalizeDraftDates()
                }
                .onChange(of: draft.end) { _, _ in
                    normalizeDraftDates()
                }
            }

            TextField(text(.location), text: $draft.location)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 10, weight: .medium))

            TextField(text(.notes), text: $draft.notes, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(2...3)

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.yellow.opacity(0.9))
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                if let onDelete {
                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Label(text(.delete), systemImage: "trash")
                    }
                    .controlSize(.small)
                    .disabled(isSaving)
                }

                Spacer(minLength: 0)

                Button {
                    onSave()
                } label: {
                    HStack(spacing: 6) {
                        if isSaving {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "checkmark")
                        }
                        Text(text(.save))
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .controlSize(.small)
                .disabled(isSaving || sources.isEmpty)
            }
        }
        .onAppear {
            normalizeDraftDates()
            if draft.isNew {
                DispatchQueue.main.async {
                    focusedField = .title
                }
            }
        }
    }

    private var allDayDateBinding: Binding<Date> {
        Binding(
            get: { draft.start },
            set: { newValue in
                let start = calendar.startOfDay(for: newValue)
                draft.start = start
                draft.end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
            }
        )
    }

    private func normalizeDraftDates() {
        let normalized = draft.normalized(calendar: calendar)
        if normalized != draft {
            draft = normalized
        }
    }

    private func text(_ key: AppTextKey) -> String {
        AppText.text(key, language: language)
    }
}

private enum CalendarEditorFocusField: Hashable {
    case title
}

private extension Color {
    init?(hex: String) {
        let trimmed = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard trimmed.count == 6, let value = UInt64(trimmed, radix: 16) else {
            return nil
        }
        let red = Double((value >> 16) & 0xff) / 255.0
        let green = Double((value >> 8) & 0xff) / 255.0
        let blue = Double(value & 0xff) / 255.0
        self = Color(red: red, green: green, blue: blue)
    }
}
