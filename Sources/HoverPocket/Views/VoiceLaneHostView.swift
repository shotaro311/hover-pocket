import SwiftUI

struct VoiceLaneHostView: View {
    @ObservedObject var runtime: VoiceLaneRuntime
    @ObservedObject var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if settings.voiceEnabled {
                if runtime.snapshot.mode == .expanded {
                    expanded
                } else {
                    compact
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Voice Lane")
    }

    private var compact: some View {
        HStack(spacing: 10) {
            Button(action: {}) {
                Image(systemName: "mic.slash")
            }
            .buttonStyle(.plain)
            .disabled(true)
            .accessibilityLabel("Microphone unavailable until Voice runtime activation")

            waveform

            VStack(alignment: .leading, spacing: 2) {
                Text(statusText)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(runtime.snapshot.transcriptPreview ?? conversationPlaceholder)
                    .font(.system(size: 12))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("\(runtime.snapshot.visibleSessionCount)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .accessibilityLabel("\(runtime.snapshot.visibleSessionCount) sessions")

            Button {
                runtime.setMuted(!runtime.snapshot.muted)
            } label: {
                Image(systemName: runtime.snapshot.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(runtime.snapshot.muted ? "Unmute Voice Lane" : "Mute Voice Lane")

            Button {
                settings.voiceLaneLayoutPreference = .expanded
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Expand Voice Lane")
            .accessibilityValue("collapsed")

            Button {
                runtime.endAudioSession()
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("End Voice audio session")
        }
        .padding(.horizontal, 14)
        .frame(height: VoiceLaneGeometry.compactHeight)
        .background(Color.white.opacity(0.025))
        .overlay(alignment: .top) {
            Divider().overlay(Color.white.opacity(0.08))
        }
    }

    private var expanded: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(statusText)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text("\(runtime.snapshot.visibleSessionCount)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                Button {
                    settings.voiceLaneLayoutPreference = .compact
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Collapse Voice Lane")
                .accessibilityValue("expanded")
                Button {
                    runtime.endAudioSession()
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("End Voice audio session")
            }
            .padding(.horizontal, 14)
            .frame(height: 38)

            Divider().overlay(Color.white.opacity(0.08))

            GeometryReader { geometry in
                HStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            if runtime.snapshot.transcript.isEmpty {
                                Text(conversationPlaceholder)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(runtime.snapshot.transcript) { event in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(event.role.rawValue)
                                            .font(.system(size: 9, weight: .semibold))
                                            .foregroundStyle(.secondary)
                                        Text(event.text)
                                            .font(.system(size: 12))
                                            .textSelection(.enabled)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .padding(12)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Voice transcript")

                    Divider().overlay(Color.white.opacity(0.08))

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            if runtime.snapshot.sessions.isEmpty {
                                Text("No sessions in this root")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(runtime.snapshot.sessions) { session in
                                    sessionCard(session)
                                }
                            }
                        }
                        .padding(10)
                    }
                    .frame(width: max(150, geometry.size.width * 0.38))
                    .accessibilityLabel("Root scoped sessions")
                }
            }
        }
        .frame(
            height: VoiceLaneGeometry.expandedHeight(
                panelSizeRawValue: settings.panelSize.rawValue
            )
        )
        .background(Color.white.opacity(0.025))
        .overlay(alignment: .top) {
            Divider().overlay(Color.white.opacity(0.08))
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: runtime.snapshot.sessions)
    }

    private var waveform: some View {
        HStack(spacing: 2) {
            ForEach([5.0, 10.0, 7.0, 12.0, 6.0], id: \.self) { height in
                Capsule()
                    .fill(Color.secondary.opacity(0.6))
                    .frame(width: 2, height: height)
            }
        }
        .frame(width: 34)
        .accessibilityHidden(true)
    }

    private func sessionCard(_ session: VoiceSessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
            Text(session.status.rawValue)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
            if let summary = session.safeSummary {
                Text(summary)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            if let progress = session.progress {
                ProgressView(value: Double(progress.completed), total: Double(progress.total))
                    .controlSize(.small)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var statusText: String {
        if let reason = runtime.snapshot.layoutBlockedReason {
            return reason
        }
        if let error = runtime.snapshot.safeErrorCode {
            return error
        }
        return "\(runtime.snapshot.connection.rawValue) · \(runtime.snapshot.activity.rawValue)"
    }

    private var conversationPlaceholder: String {
        "Voice transport is unavailable in AN3-A."
    }
}
