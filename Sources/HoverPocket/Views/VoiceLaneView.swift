import SwiftUI

struct VoiceLaneView: View {
    @ObservedObject var model: VoiceLaneViewModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        Group {
            switch model.effectiveDisplayMode {
            case .disabled:
                EmptyView()
            case .compact:
                compactBar
            case .expanded:
                VStack(spacing: 0) {
                    compactBar

                    HStack(spacing: 0) {
                        transcriptColumn
                        Divider()
                            .overlay(Color.white.opacity(0.08))
                        sessionColumn
                    }
                }
            }
        }
        .background(Color.white.opacity(0.025))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localized(japanese: "音声会話", english: "Voice conversation"))
    }

    private var compactBar: some View {
        HStack(spacing: 10) {
            Button {
                model.setMuted(!model.isMuted)
            } label: {
                Image(systemName: model.isMuted ? "mic.fill" : "waveform")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(model.isSessionActive ? Color.white : Color.secondary)
                    .frame(width: 38, height: 38)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.055))
                            .overlay(
                                Circle()
                                    .stroke(Color.blue.opacity(0.8), lineWidth: 2)
                            )
                    )
            }
            .buttonStyle(.plain)
            .disabled(!model.isSessionActive)
            .accessibilityLabel(
                model.isMuted
                    ? localized(japanese: "マイクを有効にする", english: "Enable microphone")
                    : localized(japanese: "マイクをミュート", english: "Mute microphone")
            )

            VoiceWaveformView(isActive: model.isSessionActive && !model.isMuted)
                .frame(width: 64, height: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(statusText)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(model.expansionBlocked ? Color.orange : Color.cyan)
                    .lineLimit(1)

                Text(lastConversationText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .frame(minWidth: 110, maxWidth: .infinity, alignment: .leading)

            Label(
                localized(
                    japanese: "セッション \(model.sessions.count)",
                    english: "Sessions \(model.sessions.count)"
                ),
                systemImage: "rectangle.stack"
            )
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
            .lineLimit(1)

            Button {
                model.setMuted(!model.isMuted)
            } label: {
                Image(systemName: model.isMuted ? "mic.slash" : "mic")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(!model.isSessionActive)
            .accessibilityLabel(
                model.isMuted
                    ? localized(japanese: "ミュート解除", english: "Unmute")
                    : localized(japanese: "ミュート", english: "Mute")
            )

            Button {
                settings.codexVoiceLayoutMode = model.effectiveDisplayMode == .expanded
                    ? .compact
                    : .expanded
            } label: {
                Image(systemName: model.effectiveDisplayMode == .expanded ? "chevron.down" : "chevron.up")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(
                model.effectiveDisplayMode == .expanded
                    ? localized(japanese: "会話欄を折りたたむ", english: "Collapse conversation")
                    : localized(japanese: "会話欄を拡張", english: "Expand conversation")
            )
            .accessibilityValue(model.effectiveDisplayMode == .expanded ? "expanded" : "collapsed")

            Button {
                model.endSession()
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(!model.isSessionActive)
            .accessibilityLabel(localized(japanese: "会話を終了", english: "End conversation"))
        }
        .padding(.horizontal, 12)
        .frame(height: PanelLayout.compactVoiceLaneHeight)
    }

    private var transcriptColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(localized(japanese: "会話", english: "Conversation"))
                .font(.system(size: 11, weight: .bold))

            if model.transcript.isEmpty {
                Text(
                    localized(
                        japanese: "会話を開始すると、ここに現在のセッションだけが表示されます。",
                        english: "The current session transcript will appear here."
                    )
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(model.transcript) { line in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(speakerTitle(line.speaker))
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                Text(line.text)
                                    .font(.system(size: 11))
                                    .textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var sessionColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(localized(japanese: "Codexセッション", english: "Codex sessions"))
                .font(.system(size: 11, weight: .bold))

            if model.sessions.isEmpty {
                Text(
                    localized(
                        japanese: "この会話から開始した子セッションはありません。",
                        english: "No child sessions were started from this conversation."
                    )
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(model.sessions) { session in
                            VoiceLaneSessionCardView(session: session)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var statusText: String {
        if model.expansionBlocked {
            return localized(
                japanese: "画面の高さが不足しているためコンパクト表示です",
                english: "Compact view is used because screen height is limited"
            )
        }
        if let statusText = model.statusText {
            return statusText
        }
        return localized(japanese: "音声セッションを開始", english: "Start a voice session")
    }

    private var lastConversationText: String {
        model.transcript.last?.text
            ?? localized(
                japanese: "マイクを押してCodexに話しかけます",
                english: "Press the microphone to talk to Codex"
            )
    }

    private func speakerTitle(_ speaker: VoiceLaneSpeaker) -> String {
        switch speaker {
        case .user:
            return localized(japanese: "あなた", english: "You")
        case .assistant:
            return "Codex"
        }
    }

    private func localized(japanese: String, english: String) -> String {
        settings.appLanguage == .japanese ? japanese : english
    }
}

private struct VoiceWaveformView: View {
    let isActive: Bool
    private let heights: [CGFloat] = [5, 10, 16, 8, 20, 12, 7, 15, 9, 5]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(heights.enumerated()), id: \.offset) { index, height in
                Capsule(style: .continuous)
                    .fill(Color.cyan.opacity(isActive ? 0.95 : 0.55))
                    .frame(width: 3, height: isActive && index.isMultiple(of: 2) ? height : max(4, height * 0.65))
            }
        }
    }
}

private struct VoiceLaneSessionCardView: View {
    let session: VoiceLaneSessionCard

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(stateColor)
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Text(session.detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Text(elapsedText)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.07), lineWidth: 1)
                )
        )
    }

    private var stateColor: Color {
        switch session.state {
        case .running:
            return .yellow
        case .completed:
            return .green
        case .failed:
            return .red
        }
    }

    private var elapsedText: String {
        let minutes = session.elapsedSeconds / 60
        let seconds = session.elapsedSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
