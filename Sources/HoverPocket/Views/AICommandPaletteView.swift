import SwiftUI

struct AICommandPaletteView: View {
    @ObservedObject var store: AICommandStore
    @ObservedObject var settings: AppSettings
    let isVisible: Bool
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: "command")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.42))

                TextField("今日の予定 / 明日14時 打ち合わせ", text: $store.input)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .panelTextFont(size: 12, weight: .medium)
                    .foregroundStyle(Color.white.opacity(0.88))
                    .onSubmit {
                        store.submit()
                    }

                Button {
                    store.submit()
                } label: {
                    Image(systemName: store.isRunning ? "hourglass" : "paperplane.fill")
                        .font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(IconButtonStyle(selected: true))
                .disabled(store.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isRunning)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(0.055))
            )

            if let pendingAction = store.pendingAction {
                ApprovalCard(action: pendingAction, store: store, language: settings.appLanguage)
            } else if !store.candidates.isEmpty {
                CandidateRow(actions: store.candidates, store: store, language: settings.appLanguage)
            } else if let result = store.result {
                ResultRow(result: result)
            } else if let statusMessage = store.statusMessage {
                Text(localizedStatusMessage(statusMessage))
                    .panelTextFont(size: 11, weight: .medium)
                    .foregroundStyle(Color.white.opacity(0.48))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // 高さは親（HoverPanelShell）が aiPaletteHeight で固定する。
        // ここで伸ばすと Provider 領域を押し潰すので、レーン内で上詰めにする。
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            focusInputIfNeeded()
        }
        .onChange(of: isVisible) { _, visible in
            if visible {
                focusInputIfNeeded()
            }
        }
    }

    private func focusInputIfNeeded() {
        guard isVisible, store.pendingAction == nil else { return }
        DispatchQueue.main.async {
            isFocused = true
        }
    }

    private func localizedStatusMessage(_ message: String) -> String {
        switch message {
        case AppText.text(.statusCanceled, language: .english):
            return settings.text(.statusCanceled)
        case AppText.text(.statusPlanning, language: .english):
            return settings.text(.statusPlanning)
        case AppText.text(.statusCouldNotMap, language: .english):
            return settings.text(.statusCouldNotMap)
        case AppText.text(.chooseIntendedAction, language: .english):
            return settings.text(.chooseIntendedAction)
        case AppText.text(.statusApprovalRequired, language: .english):
            return settings.text(.statusApprovalRequired)
        case AppText.text(.statusRunning, language: .english):
            return settings.text(.statusRunning)
        case AppText.text(.statusDone, language: .english):
            return settings.text(.statusDone)
        case AppText.text(.statusCommandCouldNotBePlanned, language: .english):
            return settings.text(.statusCommandCouldNotBePlanned)
        default:
            return message
        }
    }
}

private struct ApprovalCard: View {
    let action: PocketAction
    @ObservedObject var store: AICommandStore
    let language: AppLanguage

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            VStack(alignment: .leading, spacing: 4) {
                Text(action.approvalTitle(language: language))
                    .panelTextFont(size: 11, weight: .semibold)
                    .foregroundStyle(Color.white.opacity(0.9))
                    .lineLimit(1)

                if let parameters = action.createEventParameters {
                    CalendarWriteApprovalSummary(parameters: parameters, language: language)
                }

                // フィールドは省略しない（承認原則）。固定レーンに収まらない場合はスクロールで全件確認できるようにする
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(action.approvalFields(language: language)) { field in
                            HStack(alignment: .firstTextBaseline, spacing: 7) {
                                Text(field.label.uppercased())
                                    .panelTextFont(size: 8, weight: .bold)
                                    .foregroundStyle(Color.white.opacity(0.32))
                                    .frame(width: 52, alignment: .leading)

                                Text(field.value)
                                    .panelTextFont(size: 10, weight: .medium)
                                    .foregroundStyle(Color.white.opacity(0.68))
                                    .lineLimit(field.id == "notes" ? 2 : 1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            }

            Spacer(minLength: 6)

            HStack(spacing: 4) {
                Button {
                    store.rejectPendingAction()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(IconButtonStyle(selected: false))

                Button {
                    store.approvePendingAction()
                } label: {
                    Image(systemName: "checkmark")
                }
                .buttonStyle(IconButtonStyle(selected: true))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
    }
}

private struct CalendarWriteApprovalSummary: View {
    let parameters: CalendarCreateEventParameters
    let language: AppLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "calendar.badge.plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.green.opacity(0.9))

                Text(parameters.title.isEmpty ? AppText.text(.untitledEvent, language: language) : parameters.title)
                    .panelTextFont(size: 12, weight: .bold)
                    .foregroundStyle(Color.white.opacity(0.92))
                    .lineLimit(1)
            }

            approvalLine(systemImage: parameters.isAllDay ? "calendar" : "clock", text: timeText, isPrimary: true)

            if let location = normalized(parameters.location) {
                approvalLine(systemImage: "mappin.and.ellipse", text: location)
            }

            if let notes = normalized(parameters.notes) {
                approvalLine(systemImage: "note.text", text: notes)
            }

            if let calendarTitle = normalized(parameters.calendarTitle) {
                approvalLine(systemImage: "calendar", text: calendarTitle)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.green.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.green.opacity(0.18), lineWidth: 1)
        )
    }

    private func approvalLine(systemImage: String, text: String, isPrimary: Bool = false) -> some View {
        Label(text, systemImage: systemImage)
            .panelTextFont(size: 10, weight: isPrimary ? .semibold : .medium, design: isPrimary ? .monospaced : .default)
            .foregroundStyle(Color.white.opacity(isPrimary ? 0.76 : 0.58))
            .lineLimit(1)
    }

    private func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private var timeText: String {
        if parameters.isAllDay {
            return language.formattedDate(parameters.start, template: "yMMMd")
        }
        return "\(language.formattedDate(parameters.start, template: "yMMMdHm")) - \(language.formattedDate(parameters.end, template: "Hm"))"
    }
}

private struct CandidateRow: View {
    let actions: [PocketAction]
    @ObservedObject var store: AICommandStore
    let language: AppLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(AppText.text(.chooseIntendedAction, language: language))
                .panelTextFont(size: 10, weight: .semibold)
                .foregroundStyle(Color.white.opacity(0.42))
                .lineLimit(1)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(actions) { action in
                        Button {
                            store.selectCandidate(action)
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(action.displayTitle(language: language))
                                    .panelTextFont(size: 10, weight: .semibold)
                                    .foregroundStyle(Color.white.opacity(0.86))
                                    .lineLimit(1)
                                Text(action.displaySubtitle(language: language))
                                    .panelTextFont(size: 9, weight: .medium)
                                    .foregroundStyle(Color.white.opacity(0.42))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 9)
                            .frame(height: 32)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color.white.opacity(0.055))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

private struct ResultRow: View {
    let result: ToolResult

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: result.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(result.succeeded ? Color.green.opacity(0.8) : Color.yellow.opacity(0.86))

            VStack(alignment: .leading, spacing: 2) {
                Text(result.title)
                    .panelTextFont(size: 11, weight: .semibold)
                    .foregroundStyle(Color.white.opacity(0.85))
                    .lineLimit(1)
                Text(result.message)
                    .panelTextFont(size: 10, weight: .medium)
                    .foregroundStyle(Color.white.opacity(0.5))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
