import AppKit
import SwiftUI

struct ControlsView: View {
    @ObservedObject private var settings: AppSettings
    @ObservedObject private var store: ControlsStore
    private let isActive: Bool

    init(settings: AppSettings, isActive: Bool, store: ControlsStore = .shared) {
        self.settings = settings
        self.store = store
        self.isActive = isActive
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                displaysSection
                volumeSection
                nowPlayingSection
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .scrollIndicators(.never)
        .onAppear {
            updatePolling(isActive)
        }
        .onDisappear {
            store.stopPolling()
        }
        .onChange(of: isActive) { _, newValue in
            updatePolling(newValue)
        }
    }

    private var displaysSection: some View {
        ControlsSection(title: text(.controlsDisplays), symbolName: "display.2") {
            if store.displays.isEmpty {
                ControlsEmptyRow(message: text(.controlsNoDisplays))
            } else {
                VStack(spacing: 7) {
                    ForEach(store.displays) { display in
                        ControlsDisplayRow(
                            display: display,
                            brightness: brightnessBinding(for: display),
                            kindText: displayKindText(for: display),
                            unsupportedText: text(.controlsUnsupported),
                            maxBrightnessLabel: text(.controlsMaxBrightness),
                            minBrightnessLabel: text(.controlsMinBrightness),
                            onToggle: {
                                store.toggleDisplayBrightness(for: display.id)
                            }
                        )
                    }
                }
            }
        }
    }

    private var volumeSection: some View {
        ControlsSection(title: text(.controlsVolume), symbolName: "speaker.wave.2.fill") {
            HStack(spacing: 9) {
                Image(systemName: volumeIconName)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(0.72))
                    .frame(width: 20)

                ControlsSlider(value: volumeBinding, accent: .cyan.opacity(0.82))

                Text(percentText(store.volume.level))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.54))
                    .frame(width: 36, alignment: .trailing)

                ControlsCircleButton(
                    symbolName: store.volume.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    accent: store.volume.isMuted ? .yellow.opacity(0.88) : .white.opacity(0.58),
                    isActive: store.volume.isMuted,
                    action: store.toggleMute
                )
                .help(store.volume.isMuted ? text(.controlsUnmute) : text(.controlsMute))
            }
            .frame(height: 32)
        }
    }

    private var nowPlayingSection: some View {
        ControlsSection(title: text(.controlsNowPlaying), symbolName: "play.rectangle.fill") {
            VStack(alignment: .leading, spacing: 8) {
                if store.nowPlaying.hasMedia {
                    HStack(spacing: 10) {
                        ControlsVideoThumbnail(track: store.nowPlaying, fallbackSourceName: text(.controlsMedia))
                            .frame(width: 98, height: 55)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(store.nowPlaying.title.isEmpty ? text(.controlsMedia) : store.nowPlaying.title)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white.opacity(0.86))
                                .lineLimit(2)

                            Text(store.nowPlaying.sourceName.isEmpty ? text(.controlsMedia) : store.nowPlaying.sourceName)
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.42))
                                .lineLimit(1)
                        }

                        Spacer(minLength: 0)
                    }
                } else {
                    ControlsEmptyRow(message: text(.controlsNoMedia))
                }

                ControlsSlider(
                    value: playbackBinding,
                    range: 0...max(store.nowPlaying.duration, 1),
                    accent: .white.opacity(0.80),
                    isEnabled: store.nowPlaying.hasMedia && store.nowPlaying.duration > 0
                )
                .frame(height: 18)
                .opacity(store.nowPlaying.hasMedia ? 1 : 0.38)

                HStack(spacing: 8) {
                    Text(timeText(store.nowPlaying.progress))
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.48))
                        .frame(width: 38, alignment: .leading)

                    Spacer(minLength: 0)

                    ControlsMediaButton(symbolName: "gobackward.10") {
                        store.skipPlayback(by: -10)
                    }
                    .disabled(!store.nowPlaying.hasMedia)
                    .opacity(store.nowPlaying.hasMedia ? 1 : 0.38)
                    .help(text(.controlsBack10))

                    ControlsMediaButton(
                        symbolName: store.nowPlaying.isPlaying ? "pause.fill" : "play.fill",
                        isPrimary: true,
                        action: store.togglePlayback
                    )
                    .disabled(!store.nowPlaying.hasMedia)
                    .opacity(store.nowPlaying.hasMedia ? 1 : 0.38)
                    .help(store.nowPlaying.isPlaying ? text(.controlsPause) : text(.controlsPlay))

                    ControlsMediaButton(symbolName: "goforward.10") {
                        store.skipPlayback(by: 10)
                    }
                    .disabled(!store.nowPlaying.hasMedia)
                    .opacity(store.nowPlaying.hasMedia ? 1 : 0.38)
                    .help(text(.controlsForward10))

                    Spacer(minLength: 0)

                    Text(timeText(store.nowPlaying.duration))
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.48))
                        .frame(width: 38, alignment: .trailing)
                }
                .frame(height: 27)
            }
        }
    }

    private var volumeBinding: Binding<Double> {
        Binding(
            get: { store.volume.level },
            set: { store.setVolumeLevel($0) }
        )
    }

    private var playbackBinding: Binding<Double> {
        Binding(
            get: { store.nowPlaying.progress },
            set: { store.setPlaybackProgress($0) }
        )
    }

    private func brightnessBinding(for display: ControlsDisplay) -> Binding<Double> {
        Binding(
            get: {
                store.displays.first(where: { $0.id == display.id })?.brightness ?? display.brightness
            },
            set: {
                store.setBrightness($0, for: display.id)
            }
        )
    }

    private func displayKindText(for display: ControlsDisplay) -> String {
        switch display.kind {
        case .internalDisplay:
            return text(.controlsInternalDisplay)
        case .externalDisplay:
            return text(.controlsExternalDisplay)
        }
    }

    private var volumeIconName: String {
        if store.volume.isMuted || store.volume.level <= 0.01 {
            return "speaker.fill"
        }
        if store.volume.level < 0.45 {
            return "speaker.wave.1.fill"
        }
        return "speaker.wave.2.fill"
    }

    private func percentText(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private func timeText(_ time: TimeInterval) -> String {
        let totalSeconds = max(0, Int(time.rounded(.down)))
        return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
    }

    private func text(_ key: AppTextKey) -> String {
        settings.text(key)
    }

    private func updatePolling(_ active: Bool) {
        if active {
            store.startPolling()
        } else {
            store.stopPolling()
        }
    }
}

private struct ControlsSection<Content: View>: View {
    let title: String
    let symbolName: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbolName)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.64))

            content()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.white.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.white.opacity(0.065), lineWidth: 1)
        )
    }
}

private struct ControlsDisplayRow: View {
    let display: ControlsDisplay
    @Binding var brightness: Double
    let kindText: String
    let unsupportedText: String
    let maxBrightnessLabel: String
    let minBrightnessLabel: String
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            VStack(alignment: .leading, spacing: 2) {
                Text(display.name)
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(.white.opacity(0.84))
                    .lineLimit(1)

                Text(kindText)
                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.34))
                    .lineLimit(1)
            }
            .frame(width: 104, alignment: .leading)

            ControlsSlider(
                value: $brightness,
                accent: .yellow.opacity(0.86),
                isEnabled: display.isControllable
            )

            Text(display.isControllable ? "\(Int((brightness * 100).rounded()))%" : unsupportedText)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.54))
                .frame(width: 42, alignment: .trailing)
                .minimumScaleFactor(0.7)
                .lineLimit(1)

            ControlsCircleButton(
                symbolName: brightnessIconName,
                accent: brightness <= 0.02 ? .indigo.opacity(0.88) : .yellow.opacity(0.88),
                isActive: brightness <= 0.02 || brightness >= 0.98,
                action: onToggle
            )
            .disabled(!display.isControllable)
            .opacity(display.isControllable ? 1 : 0.42)
            .help(brightness <= 0.02 ? maxBrightnessLabel : minBrightnessLabel)
        }
        .frame(height: 33)
    }

    private var brightnessIconName: String {
        if brightness <= 0.02 {
            return "moon.fill"
        }
        if brightness >= 0.98 {
            return "sun.max.fill"
        }
        return "sun.min.fill"
    }
}

private struct ControlsSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var accent: Color
    var isEnabled = true

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let progress = normalizedProgress

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.12))
                    .frame(height: 5)

                Capsule()
                    .fill(accent)
                    .frame(width: width * progress, height: 5)

                Circle()
                    .fill(Color.white.opacity(0.94))
                    .frame(width: 12, height: 12)
                    .shadow(color: Color.black.opacity(0.28), radius: 3, y: 1)
                    .offset(x: max(0, min(width - 12, width * progress - 6)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard isEnabled else { return }
                        setValue(from: gesture.location.x, width: width)
                    }
            )
        }
        .frame(height: 18)
        .opacity(isEnabled ? 1 : 0.42)
    }

    private var normalizedProgress: CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        let normalized = (value - range.lowerBound) / span
        return CGFloat(min(max(normalized, 0), 1))
    }

    private func setValue(from xPosition: CGFloat, width: CGFloat) {
        let normalized = min(max(Double(xPosition / max(width, 1)), 0), 1)
        value = range.lowerBound + (range.upperBound - range.lowerBound) * normalized
    }
}

private struct ControlsCircleButton: View {
    let symbolName: String
    let accent: Color
    var isActive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbolName)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .foregroundStyle(accent)
        .background(
            Circle()
                .fill(isActive ? accent.opacity(0.18) : Color.white.opacity(0.045))
        )
        .overlay(
            Circle()
                .stroke(Color.white.opacity(isActive ? 0.16 : 0.08), lineWidth: 1)
        )
        .contentShape(Circle())
    }
}

private struct ControlsMediaButton: View {
    let symbolName: String
    var isPrimary = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbolName)
                .font(.system(size: isPrimary ? 12 : 10.5, weight: .bold))
                .frame(width: isPrimary ? 29 : 25, height: isPrimary ? 29 : 25)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(isPrimary ? 0.92 : 0.68))
        .background(
            Circle()
                .fill(isPrimary ? Color.white.opacity(0.13) : Color.white.opacity(0.052))
        )
        .overlay(
            Circle()
                .stroke(Color.white.opacity(isPrimary ? 0.16 : 0.08), lineWidth: 1)
        )
        .contentShape(Circle())
    }
}

private struct ControlsVideoThumbnail: View {
    let track: ControlsNowPlayingState
    let fallbackSourceName: String

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let image = artworkImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                placeholder
            }

            LinearGradient(
                colors: [.clear, .black.opacity(0.56)],
                startPoint: .center,
                endPoint: .bottom
            )

            Text(track.sourceName.isEmpty ? fallbackSourceName : track.sourceName)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.09), lineWidth: 1)
        )
    }

    private var artworkImage: NSImage? {
        guard let artworkData = track.artworkData else { return nil }
        return NSImage(data: artworkData)
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(red: 0.10, green: 0.11, blue: 0.13))

            HStack(spacing: 5) {
                ForEach(0..<4, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.white.opacity(index.isMultiple(of: 2) ? 0.12 : 0.06))
                        .frame(width: 14)
                }
            }
            .rotationEffect(.degrees(-18))
            .offset(x: 25, y: -5)

            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white.opacity(0.76))
        }
    }
}

private struct ControlsEmptyRow: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.38))
            .frame(height: 30, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}
