import SwiftUI

struct AICommandPaletteView: View {
    @ObservedObject var store: AICommandStore
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: "command")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.42))

                TextField("Ask Calendar...", text: $store.input)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .font(.system(size: 12, weight: .medium))
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
                ApprovalCard(action: pendingAction, store: store)
            } else if !store.candidates.isEmpty {
                CandidateRow(actions: store.candidates, store: store)
            } else if let result = store.result {
                ResultRow(result: result)
            } else if let statusMessage = store.statusMessage {
                Text(statusMessage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.48))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(height: 112)
    }
}

private struct ApprovalCard: View {
    let action: PocketAction
    @ObservedObject var store: AICommandStore

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            VStack(alignment: .leading, spacing: 4) {
                Text(action.approvalTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.9))
                    .lineLimit(1)

                HStack(spacing: 8) {
                    ForEach(action.approvalFields.prefix(3)) { field in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(field.label.uppercased())
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Color.white.opacity(0.32))
                            Text(field.value)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.68))
                                .lineLimit(1)
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

private struct CandidateRow: View {
    let actions: [PocketAction]
    @ObservedObject var store: AICommandStore

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Choose the intended action")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.42))
                .lineLimit(1)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(actions) { action in
                        Button {
                            store.selectCandidate(action)
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(action.displayTitle)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Color.white.opacity(0.86))
                                    .lineLimit(1)
                                Text(action.displaySubtitle)
                                    .font(.system(size: 9, weight: .medium))
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
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .lineLimit(1)
                Text(result.message)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
