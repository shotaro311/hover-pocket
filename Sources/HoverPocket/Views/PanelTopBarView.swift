import SwiftUI

struct PanelTopBarView: View {
    @ObservedObject var providerStore: ProviderStore
    @ObservedObject var settings: AppSettings
    let metrics: PanelAttachmentMetrics
    @ObservedObject private var timers = TimerStore.shared
    @ObservedObject private var voice = VoiceLaneRuntime.shared

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                if let timer = timers.runningTimers.first {
                    Button {
                        providerStore.select(TimerProvider.pluginID)
                    } label: {
                        Label(TimerView.timeText(timer.remaining(at: timers.now)), systemImage: "timer")
                            .monospacedDigit()
                    }
                    .buttonStyle(.plain)
                    .disabled(!providerStore.visibleManifests.contains { $0.id == TimerProvider.pluginID })
                    .accessibilityLabel(settings.appLanguage == .japanese ? "タイマーを表示" : "Show timer")
                } else if let manifest = providerStore.selectedProvider?.manifest {
                    Label(manifest.title(language: settings.appLanguage), systemImage: manifest.symbolName)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .clipped()

            Color.clear
                .frame(width: metrics.reservedNotchWidth)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            HStack(spacing: 6) {
                Spacer(minLength: 0)
                if VoiceActivityPresentation(snapshot: voice.snapshot).showsConversation {
                    Button {
                        voice.setMuted(!voice.snapshot.muted)
                    } label: {
                        Image(systemName: voice.snapshot.muted ? "mic.slash" : "mic")
                            .frame(width: 20, height: 22)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(settings.appLanguage == .japanese
                        ? (voice.snapshot.muted ? "ミュート解除" : "ミュート")
                        : (voice.snapshot.muted ? "Unmute" : "Mute"))
                } else {
                    Image(systemName: "waveform")
                }
                Text(VoiceLaneLocalization.status(snapshot: voice.snapshot, language: settings.appLanguage))
                if VoiceActivityPresentation(snapshot: voice.snapshot).showsConversation {
                    Button {
                        voice.endAudioSession()
                    } label: {
                        Image(systemName: "stop.fill").frame(width: 20, height: 22)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(settings.appLanguage == .japanese ? "音声を終了" : "End voice session")
                }
            }
            .frame(maxWidth: .infinity)
            .clipped()
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.white.opacity(0.82))
        .lineLimit(1)
        .padding(.horizontal, 16)
        .frame(height: metrics.headerHeight)
        .accessibilityElement(children: .contain)
    }
}
