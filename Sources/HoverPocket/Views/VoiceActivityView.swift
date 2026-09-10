import SwiftUI

/// Presentation only: the session runtime remains the source of audio and mute state.
struct VoiceActivityPresentation: Equatable {
    let showsConversation: Bool
    let muted: Bool
    let activity: VoiceLaneActivity

    init(snapshot: VoiceLaneSnapshot) {
        showsConversation = snapshot.mode != .disabled && snapshot.providerID != .off
            && snapshot.connection != .disconnected
        muted = snapshot.muted
        activity = snapshot.activity
    }

    var animates: Bool {
        showsConversation && !muted && (activity == .listening || activity == .speaking)
    }

    func barHeight(index: Int, time: TimeInterval) -> CGFloat {
        guard animates else { return 3 }
        let speaking = activity == .speaking
        let phase = time * (speaking ? 9 : 3) + Double(index) * 0.85
        return CGFloat(3 + (speaking ? 14 : 6) * abs(sin(phase) * cos(phase * 0.43)))
    }
}

struct VoiceWaveformView: View {
    let presentation: VoiceActivityPresentation
    var barCount = 7
    var tint: Color = Color(red: 0.75, green: 0.72, blue: 1)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !presentation.animates || reduceMotion)) { context in
            HStack(spacing: 2) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule()
                        .fill(presentation.muted ? Color.secondary : tint)
                        .frame(width: 2, height: presentation.barHeight(
                            index: index, time: reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate))
                }
            }
            .frame(height: 20)
        }
        .accessibilityHidden(true)
    }
}

struct VoiceConversationIcon: View {
    let muted: Bool

    var body: some View {
        Image(systemName: muted ? "mic.slash" : "mic")
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(muted ? Color.gray : Color(red: 0.75, green: 0.72, blue: 1))
            .accessibilityHidden(true)
    }
}

struct VoiceAccessIndicator: View {
    let presentation: VoiceActivityPresentation
    let language: AppLanguage
    var notchWidth: CGFloat = 0
    var height: CGFloat = PanelLayout.pillHeight
    let onMuteToggle: (() -> Void)?
    let onEndVoiceSession: (() -> Void)?
    let onCenterTap: (() -> Void)?
    let onCenterHover: ((Bool) -> Void)?

    /// A no-notch access surface keeps a small center hit region for opening
    /// the panel while the two side regions remain dedicated voice controls.
    static let noNotchCenterWidth: CGFloat = 12
    static let noNotchSideControlWidth: CGFloat =
        (PanelLayout.notchHandleWidth * 2 - noNotchCenterWidth) / 2

    init(
        presentation: VoiceActivityPresentation,
        language: AppLanguage,
        notchWidth: CGFloat = 0,
        height: CGFloat = PanelLayout.pillHeight,
        onMuteToggle: (() -> Void)? = nil,
        onEndVoiceSession: (() -> Void)? = nil,
        onCenterTap: (() -> Void)? = nil,
        onCenterHover: ((Bool) -> Void)? = nil
    ) {
        self.presentation = presentation
        self.language = language
        self.notchWidth = max(0, notchWidth)
        self.height = height
        self.onMuteToggle = onMuteToggle
        self.onEndVoiceSession = onEndVoiceSession
        self.onCenterTap = onCenterTap
        self.onCenterHover = onCenterHover
    }

    var body: some View {
        HStack(spacing: 0) {
            Button {
                onMuteToggle?()
            } label: {
                VoiceConversationIcon(muted: presentation.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .buttonStyle(.plain)
            .frame(width: sideControlWidth, height: height)
            .contentShape(Rectangle())
            .disabled(onMuteToggle == nil)
            .help(muteAccessibilityLabel)
            .accessibilityLabel(muteAccessibilityLabel)
            .accessibilityValue(muteAccessibilityValue)

            Color.clear
                .frame(width: centerWidth, height: height)
                .contentShape(Rectangle())
                .onTapGesture {
                    onCenterTap?()
                }
                .onHover { inside in
                    onCenterHover?(inside)
                }

            Button {
                onEndVoiceSession?()
            } label: {
                VoiceWaveformView(presentation: presentation, barCount: 9)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .buttonStyle(.plain)
            .frame(width: sideControlWidth, height: height)
            .contentShape(Rectangle())
            .disabled(onEndVoiceSession == nil)
            .help(endAccessibilityLabel)
            .accessibilityLabel(endAccessibilityLabel)
            .accessibilityValue(endAccessibilityValue)
        }
        .frame(height: height)
        .background(TopDockedPillShape(radius: 10).fill(.black))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(language == .japanese
            ? (presentation.muted ? "音声会話・ミュート中" : "音声会話中")
            : (presentation.muted ? "Voice conversation muted" : "Voice conversation active"))
    }

    private var sideControlWidth: CGFloat {
        notchWidth > 0 ? PanelLayout.notchHandleWidth : Self.noNotchSideControlWidth
    }

    private var centerWidth: CGFloat {
        notchWidth > 0 ? notchWidth : Self.noNotchCenterWidth
    }

    private var muteAccessibilityLabel: String {
        language == .japanese
            ? (presentation.muted ? "音声のミュートを解除" : "音声をミュート")
            : (presentation.muted ? "Unmute Voice" : "Mute Voice")
    }

    private var muteAccessibilityValue: String {
        language == .japanese
            ? (presentation.muted ? "ミュート中。押すと解除" : "ミュートしていません。押すとミュート")
            : (presentation.muted ? "Muted. Press to unmute" : "Unmuted. Press to mute")
    }

    private var endAccessibilityLabel: String {
        language == .japanese ? "音声会話を終了" : "End Voice conversation"
    }

    private var endAccessibilityValue: String {
        language == .japanese ? "波形を押すと終了" : "Press the waveform to end"
    }
}
