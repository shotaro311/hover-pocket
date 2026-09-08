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
            .overlay {
                if presentation.muted {
                    Rectangle()
                        .fill(Color.secondary)
                        .frame(width: CGFloat(barCount * 4), height: 1.5)
                        .rotationEffect(.degrees(-38))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

struct VoiceConversationIcon: View {
    let muted: Bool

    var body: some View {
        Image(systemName: muted ? "mic.slash.fill" : "person.wave.2.fill")
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

    var body: some View {
        HStack(spacing: 0) {
            VoiceConversationIcon(muted: presentation.muted)
                .frame(width: PanelLayout.notchHandleWidth)
            if notchWidth > 0 {
                Spacer(minLength: notchWidth)
            }
            VoiceWaveformView(presentation: presentation, barCount: 9)
                .frame(width: PanelLayout.notchHandleWidth)
        }
        .frame(height: height)
        .background(TopDockedPillShape(radius: 10).fill(.black))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(language == .japanese
            ? (presentation.muted ? "音声会話・ミュート中" : "音声会話中")
            : (presentation.muted ? "Voice conversation muted" : "Voice conversation active"))
    }
}
