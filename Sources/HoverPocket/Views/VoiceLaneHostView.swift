import SwiftUI

struct VoiceLaneHostView: View {
    @ObservedObject var runtime: VoiceLaneRuntime
    @ObservedObject var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if runtime.snapshot.mode != .disabled {
                if runtime.snapshot.mode == .expanded {
                    expanded
                } else {
                    compact
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localized(japanese: "音声レーン", english: "Voice Lane"))
        .background(alignment: .bottomLeading) {
            if runtime.snapshot.providerID == .openAIRealtimeBYOK {
                OpenAIRealtimeMacOSTransportHostView()
                    .frame(width: 1, height: 1)
                    .opacity(0.001)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            } else if runtime.snapshot.providerID == .codexAppServer {
                CodexVoiceWebRTCTransportView(driver: CodexAppServerMacOSRuntime.driver)
                    .frame(width: 1, height: 1)
                    .opacity(0.001)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    private var compact: some View {
        HStack(spacing: 10) {
            microphoneButton

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
                .accessibilityLabel(sessionCountAccessibilityLabel)

            Button {
                runtime.setMuted(!runtime.snapshot.muted)
            } label: {
                Image(systemName: runtime.snapshot.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
            .buttonStyle(.plain)
            .disabled(runtime.snapshot.muted && runtime.snapshot.connection != .connected)
            .accessibilityLabel(runtime.snapshot.muted
                ? localized(japanese: "音声レーンのミュートを解除", english: "Unmute Voice Lane")
                : localized(japanese: "音声レーンをミュート", english: "Mute Voice Lane"))

            Button {
                settings.voiceLaneLayoutPreference = .expanded
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(localized(japanese: "音声レーンを展開", english: "Expand Voice Lane"))
            .accessibilityValue(localized(japanese: "折りたたみ", english: "collapsed"))

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
                microphoneButton

                waveform

                Text(statusText)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text("\(runtime.snapshot.visibleSessionCount)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(sessionCountAccessibilityLabel)
                Button {
                    runtime.setMuted(!runtime.snapshot.muted)
                } label: {
                    Image(systemName: runtime.snapshot.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
                .buttonStyle(.plain)
                .disabled(runtime.snapshot.muted && runtime.snapshot.connection != .connected)
                .accessibilityLabel(runtime.snapshot.muted
                    ? localized(japanese: "音声レーンのミュートを解除", english: "Unmute Voice Lane")
                    : localized(japanese: "音声レーンをミュート", english: "Mute Voice Lane"))
                Button {
                    settings.voiceLaneLayoutPreference = .compact
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(localized(japanese: "音声レーンを折りたたむ", english: "Collapse Voice Lane"))
                .accessibilityValue(localized(japanese: "展開", english: "expanded"))
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
                                        Text(VoiceLaneLocalization.transcriptRole(
                                            event.role,
                                            language: settings.appLanguage
                                        ))
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
                    .accessibilityLabel(localized(japanese: "会話履歴", english: "Voice transcript"))

                    Divider().overlay(Color.white.opacity(0.08))

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            if runtime.snapshot.sessions.isEmpty {
                                Text(localized(
                                    japanese: "この会話にはセッションがありません",
                                    english: "No sessions in this root"
                                ))
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
                    .accessibilityLabel(localized(
                        japanese: "現在の会話に属するセッション",
                        english: "Root scoped sessions"
                    ))
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

    private var microphoneButton: some View {
        Button {
            if canEndAudioSession || canCancelAudioStart {
                runtime.endAudioSession()
            } else if canResumeAudioSession {
                runtime.setMuted(false)
            } else {
                runtime.beginAudioSession()
            }
        } label: {
            Image(systemName: microphoneSymbolName)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 36, height: 36)
                .foregroundStyle(canUseMicrophoneButton ? Color.accentColor : Color.secondary)
                .background(
                    Circle()
                        .fill(canUseMicrophoneButton
                            ? Color.accentColor.opacity(0.16)
                            : Color.white.opacity(0.04))
                )
                .overlay {
                    Circle()
                        .stroke(
                            canUseMicrophoneButton
                                ? Color.accentColor.opacity(0.8)
                                : Color.white.opacity(0.08),
                            lineWidth: 1
                        )
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!canUseMicrophoneButton)
        .help(microphoneAccessibilityLabel)
        .accessibilityLabel(microphoneAccessibilityLabel)
        .accessibilityValue(microphoneAccessibilityValue)
    }

    private func sessionCard(_ session: VoiceSessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(VoiceLaneLocalization.sessionStatus(
                    session.status,
                    language: settings.appLanguage
                ))
                Text(session.updatedAt.formatted(date: .omitted, time: .shortened))
                    .accessibilityLabel(localized(
                        japanese: "更新日時 \(session.updatedAt.formatted())",
                        english: "Updated \(session.updatedAt.formatted())"
                    ))
            }
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
        VoiceLaneLocalization.status(
            snapshot: runtime.snapshot,
            language: settings.appLanguage
        )
    }

    private var conversationPlaceholder: String {
        VoiceLaneLocalization.conversationPrompt(
            providerID: runtime.snapshot.providerID,
            connection: runtime.snapshot.connection,
            muted: runtime.snapshot.muted,
            language: settings.appLanguage
        )
    }

    private var sessionCountAccessibilityLabel: String {
        localized(
            japanese: "セッション \(runtime.snapshot.visibleSessionCount)件",
            english: "\(runtime.snapshot.visibleSessionCount) sessions"
        )
    }

    private var canBeginAudioSession: Bool {
        runtime.snapshot.providerID != .off
            && runtime.snapshot.connection == .disconnected
            && runtime.snapshot.uiAttached
            && !voiceStartBlockedByConfiguration
    }

    private var canResumeAudioSession: Bool {
        runtime.snapshot.providerID != .off
            && runtime.snapshot.connection == .connected
            && runtime.snapshot.muted
            && runtime.snapshot.uiAttached
    }

    private var canEndAudioSession: Bool {
        runtime.snapshot.providerID != .off
            && runtime.snapshot.connection == .connected
            && !runtime.snapshot.muted
            && runtime.snapshot.uiAttached
    }

    private var canCancelAudioStart: Bool {
        runtime.snapshot.providerID != .off
            && (runtime.snapshot.connection == .connecting || runtime.snapshot.connection == .recovering)
            && runtime.snapshot.uiAttached
    }

    private var canUseMicrophoneButton: Bool {
        canBeginAudioSession || canResumeAudioSession || canEndAudioSession || canCancelAudioStart
    }

    private var voiceStartBlockedByConfiguration: Bool {
        [
            "openai_realtime_key_missing",
            "openai_realtime_key_unavailable",
            "openai_realtime_macos_transport_unavailable",
            "codex_not_found",
            "codex_identity_unavailable",
            "codex_schema_probe_failed",
            "codex_schema_incomplete",
            "codex_realtime_schema_missing",
            "codex_broker_only_tool_policy_missing",
            "codex_capability_runtime_unavailable"
        ].contains(runtime.snapshot.safeErrorCode)
    }

    private var microphoneAccessibilityLabel: String {
        switch runtime.snapshot.connection {
        case .connecting, .recovering:
            localized(japanese: "音声接続をキャンセル", english: "Cancel Voice connection")
        case .connected:
            if canEndAudioSession {
                localized(japanese: "音声会話を終了", english: "End Voice conversation")
            } else if canResumeAudioSession {
                localized(japanese: "音声会話を再開", english: "Resume Voice conversation")
            } else {
                localized(japanese: "音声セッションは接続済み", english: "Voice session is connected")
            }
        case .disconnected:
            canBeginAudioSession
                ? localized(japanese: "音声セッションを開始", english: "Start Voice session")
                : localized(japanese: "マイクは現在利用できません", english: "Microphone is currently unavailable")
        }
    }

    private var microphoneSymbolName: String {
        if runtime.snapshot.connection == .connected {
            return runtime.snapshot.muted ? "mic.slash.fill" : "mic.fill"
        }
        return canBeginAudioSession ? "mic.fill" : "mic.slash.fill"
    }

    private var microphoneAccessibilityValue: String {
        switch runtime.snapshot.connection {
        case .connecting, .recovering:
            localized(japanese: "接続中。押すとキャンセル", english: "Connecting. Press to cancel")
        case .connected where canEndAudioSession:
            localized(japanese: "会話中。押すと終了", english: "In conversation. Press to end")
        case .connected where canResumeAudioSession:
            localized(japanese: "一時停止中。押すと再開", english: "Paused. Press to resume")
        case .connected:
            localized(japanese: "接続済み", english: "Connected")
        case .disconnected where canBeginAudioSession:
            localized(japanese: "停止中。押すと開始", english: "Stopped. Press to start")
        case .disconnected:
            localized(japanese: "利用不可", english: "Unavailable")
        }
    }

    private func localized(japanese: String, english: String) -> String {
        VoiceLaneLocalization.text(
            japanese: japanese,
            english: english,
            language: settings.appLanguage
        )
    }
}

enum VoiceLaneLocalization {
    static func text(japanese: String, english: String, language: AppLanguage) -> String {
        language == .japanese ? japanese : english
    }

    static func status(snapshot: VoiceLaneSnapshot, language: AppLanguage) -> String {
        if snapshot.layoutBlockedReason != nil {
            return text(
                japanese: "展開表示に必要な画面の高さがありません",
                english: "Not enough screen height for Expanded view",
                language: language
            )
        }
        if let error = snapshot.safeErrorCode {
            return errorText(error, language: language)
        }
        if snapshot.uiAttached,
           (snapshot.connection == .connecting || snapshot.connection == .recovering) {
            return text(
                japanese: "接続中 · マイクを押してキャンセル",
                english: "Connecting · Press the microphone to cancel",
                language: language
            )
        }
        if snapshot.connection == .connected,
           snapshot.muted,
           snapshot.uiAttached {
            return text(
                japanese: "一時停止中 · マイクを押して再開",
                english: "Paused · Press the microphone to resume",
                language: language
            )
        }
        if snapshot.providerID != .off,
           snapshot.connection == .disconnected,
           snapshot.activity == .idle,
           snapshot.uiAttached {
            return text(
                japanese: "開始前 · マイクを押してください",
                english: "Ready · Press the microphone",
                language: language
            )
        }
        return "\(connection(snapshot.connection, language: language)) · \(activity(snapshot.activity, language: language))"
    }

    static func startPrompt(providerID: VoiceProviderID, language: AppLanguage) -> String {
        switch providerID {
        case .off:
            return text(
                japanese: "音声Providerはオフです。",
                english: "Voice provider is Off.",
                language: language
            )
        case .openAIRealtimeBYOK:
            return text(
                japanese: "マイクを押すとOpenAI Realtimeとの音声セッションを開始します。",
                english: "Press the microphone to start an OpenAI Realtime voice session.",
                language: language
            )
        case .codexAppServer:
            return text(
                japanese: "マイクを押すとCodexとの音声セッションを開始します。",
                english: "Press the microphone to start a voice session with Codex.",
                language: language
            )
        }
    }

    static func conversationPrompt(
        providerID: VoiceProviderID,
        connection: VoiceLaneConnection,
        muted: Bool,
        language: AppLanguage
    ) -> String {
        switch connection {
        case .disconnected:
            return startPrompt(providerID: providerID, language: language)
        case .connecting, .recovering:
            return text(
                japanese: "音声セッションへ接続しています…",
                english: "Connecting the Voice session…",
                language: language
            )
        case .connected:
            if muted {
                return text(
                    japanese: "マイクを押すと音声会話を再開します。",
                    english: "Press the microphone to resume the Voice conversation.",
                    language: language
                )
            }
            return text(
                japanese: "話しかけてください。",
                english: "Start speaking.",
                language: language
            )
        }
    }

    static func connection(_ value: VoiceLaneConnection, language: AppLanguage) -> String {
        switch value {
        case .disconnected:
            return text(japanese: "切断", english: "Disconnected", language: language)
        case .connecting:
            return text(japanese: "接続中", english: "Connecting", language: language)
        case .connected:
            return text(japanese: "接続済み", english: "Connected", language: language)
        case .recovering:
            return text(japanese: "再接続中", english: "Recovering", language: language)
        }
    }

    static func activity(_ value: VoiceLaneActivity, language: AppLanguage) -> String {
        switch value {
        case .idle:
            return text(japanese: "待機中", english: "Idle", language: language)
        case .listening:
            return text(japanese: "聞き取り中", english: "Listening", language: language)
        case .thinking:
            return text(japanese: "考え中", english: "Thinking", language: language)
        case .speaking:
            return text(japanese: "応答中", english: "Speaking", language: language)
        case .waitingForApproval:
            return text(japanese: "承認待ち", english: "Waiting for approval", language: language)
        case .reconnecting:
            return text(japanese: "再接続中", english: "Reconnecting", language: language)
        case .failed:
            return text(japanese: "失敗", english: "Failed", language: language)
        }
    }

    static func sessionStatus(_ value: VoiceSessionStatus, language: AppLanguage) -> String {
        switch value {
        case .queued:
            return text(japanese: "待機", english: "Queued", language: language)
        case .running:
            return text(japanese: "実行中", english: "Running", language: language)
        case .waitingForUser:
            return text(japanese: "ユーザー操作待ち", english: "Waiting for user", language: language)
        case .succeeded:
            return text(japanese: "完了", english: "Succeeded", language: language)
        case .failed:
            return text(japanese: "失敗", english: "Failed", language: language)
        case .cancelled:
            return text(japanese: "キャンセル", english: "Cancelled", language: language)
        }
    }

    static func transcriptRole(_ value: VoiceTranscriptEvent.Role, language: AppLanguage) -> String {
        switch value {
        case .user:
            return text(japanese: "あなた", english: "You", language: language)
        case .assistant:
            return "Codex"
        case .system:
            return text(japanese: "システム", english: "System", language: language)
        }
    }

    private static func errorText(_ code: String, language: AppLanguage) -> String {
        switch code {
        case "voice_adapter_unavailable":
            return text(
                japanese: "音声接続はまだ利用できません",
                english: "Voice transport is not available yet",
                language: language
            )
        case "voice_transport_crashed":
            return text(japanese: "音声接続が切断されました", english: "Voice transport disconnected", language: language)
        case "unexpected_server_request":
            return text(japanese: "未対応の要求を安全に停止しました", english: "An unsupported request was stopped safely", language: language)
        case "voice_restart_exhausted":
            return text(japanese: "音声接続を再開できませんでした", english: "Voice transport could not be restarted", language: language)
        case "voice_compatibility_blocked":
            return text(japanese: "現在の環境では音声機能を利用できません", english: "Voice is unavailable in this environment", language: language)
        case "microphone_permission_denied":
            return text(
                japanese: "マイクの使用が許可されていません。システム設定で許可してください",
                english: "Microphone access is denied. Allow it in System Settings.",
                language: language
            )
        case "microphone_request_not_armed":
            return text(
                japanese: "マイクの開始操作をやり直してください",
                english: "Start the microphone again from the voice control.",
                language: language
            )
        case "microphone_request_expired":
            return text(
                japanese: "マイクの開始要求が期限切れです。もう一度お試しください",
                english: "The microphone start request expired. Try again.",
                language: language
            )
        case "microphone_request_exhausted":
            return text(
                japanese: "マイクを開始できませんでした。もう一度お試しください",
                english: "The microphone could not be started. Try again.",
                language: language
            )
        case "microphone_not_found":
            return text(
                japanese: "利用できるマイクがありません",
                english: "No microphone is available.",
                language: language
            )
        case "microphone_unreadable":
            return text(
                japanese: "マイクを利用できません。ほかのアプリを閉じて再試行してください",
                english: "The microphone is busy or unavailable. Close other apps and try again.",
                language: language
            )
        case "microphone_constraints_unsupported":
            return text(
                japanese: "マイクの互換性を確認できませんでした。もう一度お試しください",
                english: "The microphone constraints were not supported. Try again.",
                language: language
            )
        case "webrtc_failed", "webrtc_start_failed", "webrtc_answer_failed", "webrtc_negotiation_failed":
            return text(
                japanese: "音声接続に失敗しました。もう一度お試しください",
                english: "The voice connection failed. Try again.",
                language: language
            )
        case "webrtc_start_timed_out", "sdp_timed_out":
            return text(
                japanese: "音声接続がタイムアウトしました。もう一度お試しください",
                english: "The voice connection timed out. Try again.",
                language: language
            )
        case "voice_start_failed":
            return text(japanese: "音声接続を開始できませんでした", english: "Voice transport could not start", language: language)
        case "openai_realtime_key_missing":
            return text(japanese: "OpenAI APIキーが未設定です", english: "OpenAI API key is not configured", language: language)
        case "openai_realtime_timeout":
            return text(japanese: "音声接続がタイムアウトしました", english: "Voice connection timed out", language: language)
        case "openai_realtime_remote_error", "openai_realtime_answer_invalid":
            return text(japanese: "音声サービスとの接続に失敗しました", english: "Voice service connection failed", language: language)
        case "codex_voice_compatibility_blocked":
            return text(japanese: "Codex Voiceの互換性確認を通過していません", english: "Codex Voice compatibility is blocked", language: language)
        default:
            return text(japanese: "音声機能を利用できません", english: "Voice is unavailable", language: language)
        }
    }
}
