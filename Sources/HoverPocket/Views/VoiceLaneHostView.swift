import SwiftUI

struct VoiceLaneHostView: View {
    @ObservedObject var runtime: VoiceLaneRuntime
    @ObservedObject var settings: AppSettings
    var height: CGFloat? = nil
    var onOpenSettings: () -> Void = {}
    @ObservedObject private var chat = CodexChatController.shared
    @State private var showsVoiceHistory = false
    @State private var showsSidebar = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            historyHeader
            if chat.panelHeight > CodexChatPanelLayout.composerHeight {
                HStack(spacing: 0) {
                    if showsSidebar { conversationSidebar }
                    if showsVoiceHistory && runtime.snapshot.providerID != .off {
                        voiceHistory
                    } else {
                        CodexChatTranscript(model: chat, language: settings.appLanguage)
                    }
                }
            }
            composer
        }
        .frame(height: height ?? chat.panelHeight)
        .background(Color.white.opacity(0.025))
        .overlay(alignment: .top) { Divider().overlay(Color.white.opacity(0.08)) }
        .onAppear { chat.configure(settings: settings) }
        .task { await chat.loadModels() }
        .onChange(of: chat.messages.count) { _, _ in showsVoiceHistory = false }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localized(japanese: "チャットと音声", english: "Chat and Voice"))
        .background(alignment: .bottomLeading) {
            if runtime.snapshot.mode != .disabled {
                if runtime.snapshot.providerID == .openAIRealtimeBYOK {
                    OpenAIRealtimeMacOSTransportHostView()
                        .frame(width: 1, height: 1)
                        .opacity(0.001)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                } else if runtime.snapshot.providerID == .codexAppServer {
                    CodexVoiceWebRTCTransportView(driver: PocketCodexLibrary.driver)
                        .frame(width: 1, height: 1)
                        .opacity(0.001)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 5) {
            VStack(spacing: 4) {
                CodexChatComposer(model: chat, placeholder: localized(japanese: "メッセージを入力…", english: "Write a message…"))
                    .frame(height: 34)
                    .help(localized(japanese: "Enterで送信 · Shift+Enterで改行", english: "Enter to send · Shift+Enter for a new line"))
                HStack(spacing: 8) {
                    ChatChoiceMenu(choices: chat.models.map { .init(id: $0.model, title: $0.displayName) },
                        selectedID: settings.chatModel,
                        placeholder: !chat.models.isEmpty ? settings.chatModel + localized(japanese: "（利用不可）", english: " (unavailable)")
                            : chat.loadingModels ? localized(japanese: "モデルを確認中…", english: "Loading models…")
                                : localized(japanese: "モデル未取得", english: "Models unavailable"),
                        enabled: !chat.busy && !chat.loadingModels, onChoose: chat.chooseModel)
                    .frame(maxWidth: 150).frame(height: 20)
                    .help(localized(japanese: "モデルを選択", english: "Choose model"))
                    ChatChoiceMenu(choices: (chat.models.first(where: { $0.model == settings.chatModel })?.efforts ?? []).map {
                            .init(id: $0, title: ChatEffortPresentation.title($0, language: settings.appLanguage))
                        }, selectedID: settings.chatEffort,
                        placeholder: ChatEffortPresentation.title(settings.chatEffort, language: settings.appLanguage),
                        enabled: !chat.busy, onChoose: chat.chooseEffort)
                    .frame(maxWidth: 120).frame(height: 20)
                    .help(localized(japanese: "推論の強さ", english: "Reasoning effort"))
                    if chat.models.isEmpty && !chat.loadingModels {
                        Button { Task { await chat.loadModels() } } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.plain).disabled(chat.busy)
                            .help(localized(japanese: "モデルを再読み込み", english: "Reload models"))
                    }
                    Spacer(minLength: 0)
                    Button {} label: { Image(systemName: "mic").frame(width: 24, height: 28) }
                        .buttonStyle(.plain).disabled(true).help(CodexChatController.dictationNotice)
                        .accessibilityLabel(localized(japanese: "音声文字起こしは利用できません", english: "Dictation is unavailable"))
                    voiceSessionButton
                    if runtime.snapshot.connection == .connected { muteButton }
                    Button { chat.busy ? chat.stop() : chat.send() } label: {
                        Image(systemName: chat.busy ? "stop.fill" : "arrow.up")
                            .frame(width: 30, height: 30)
                            .background(Color.accentColor.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                        .disabled(!chat.busy && (chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chat.loadingModels))
                        .help(localized(japanese: chat.busy ? "応答を停止" : "送信", english: chat.busy ? "Stop response" : "Send"))
                        .accessibilityLabel(localized(japanese: chat.busy ? "応答を停止" : "送信", english: chat.busy ? "Stop response" : "Send"))
                }.font(.system(size: 10))
            }
            .padding(8).background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.08)))
            if !canUseVoiceSessionButton {
                Text(statusText).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).help(statusText)
            }
        }.padding(.horizontal, 12).padding(.bottom, 6)
            .frame(height: CodexChatPanelLayout.composerHeight - 28)
    }

    private var historyHeader: some View {
        HStack(spacing: 10) {
            Button {
                showsSidebar.toggle(); if showsSidebar { chat.panelExpanded = true }
            } label: { Image(systemName: "sidebar.left") }
                .help(localized(japanese: "チャット履歴", english: "Chat history"))
                .accessibilityLabel(localized(japanese: "チャット履歴", english: "Chat history"))
            Button(action: chat.newConversation) { Image(systemName: "plus") }
                .disabled(chat.busy || chat.loadingModels)
                .help(localized(japanese: "新規チャット", english: "New chat"))
                .accessibilityLabel(localized(japanese: "新規チャット", english: "New chat"))
            Text(chat.status).lineLimit(1).foregroundStyle(.secondary).help(chat.status)
            Spacer(minLength: 0)
            if !chat.status.isEmpty && chat.status != "停止しました。" && !chat.busy {
                Button(localized(japanese: "設定を開く", english: "Settings"), action: onOpenSettings)
                    .help(localized(japanese: "AIの接続設定を確認", english: "Check AI connection settings"))
                    .fixedSize()
            }
            if runtime.snapshot.connection != .disconnected {
                Button(localized(japanese: showsVoiceHistory ? "チャット" : "音声会話", english: showsVoiceHistory ? "Chat" : "Voice")) {
                    showsVoiceHistory.toggle(); chat.panelExpanded = true
                }
            }
        }.buttonStyle(.plain).font(.system(size: 11))
            .padding(.horizontal, 14).frame(height: 28)
    }

    private var conversationSidebar: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                if chat.conversations.isEmpty {
                    Text(localized(japanese: "会話履歴はまだありません", english: "No conversations yet")).foregroundStyle(.secondary)
                }
                ForEach(chat.conversations.reversed()) { conversation in
                    Button { chat.selectConversation(conversation.id); showsVoiceHistory = false } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(conversation.title).lineLimit(2)
                            Text(conversation.createdAt, style: .date).font(.system(size: 9)).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                            .background(conversation.id == chat.currentConversationID ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain).disabled(chat.busy || chat.loadingModels)
                        .accessibilityValue(conversation.id == chat.currentConversationID ? localized(japanese: "選択中", english: "Selected") : "")
                }
            }.font(.system(size: 11)).padding(8)
        }.frame(width: 150).background(Color.white.opacity(0.025))
            .accessibilityLabel(localized(japanese: "チャット一覧", english: "Conversations"))
    }

    private var voiceHistory: some View {
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

    private var voiceSessionButton: some View {
        Button {
            if canEndAudioSession || canCancelAudioStart {
                runtime.endAudioSession()
            } else {
                runtime.beginAudioSession()
            }
        } label: {
            Image(systemName: "waveform")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 28)
                .foregroundStyle(voiceSessionButtonTint)
                .background(
                    Circle()
                        .fill(canUseVoiceSessionButton
                            ? voiceSessionButtonTint.opacity(0.16)
                            : Color.white.opacity(0.04))
                )
                .overlay {
                    Circle()
                        .stroke(
                            canUseVoiceSessionButton
                                ? voiceSessionButtonTint.opacity(0.8)
                                : Color.white.opacity(0.08),
                            lineWidth: 1
                        )
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!canUseVoiceSessionButton)
        .help(voiceSessionAccessibilityLabel)
        .accessibilityLabel(voiceSessionAccessibilityLabel)
        .accessibilityValue(voiceSessionAccessibilityValue)
    }

    private var muteButton: some View {
        Button {
            runtime.setMuted(!runtime.snapshot.muted)
        } label: {
            Image(systemName: runtime.snapshot.muted ? "mic.slash" : "mic")
        }
        .buttonStyle(.plain)
        .disabled(!canToggleMute)
        .help(muteAccessibilityLabel)
        .accessibilityLabel(muteAccessibilityLabel)
        .accessibilityValue(muteAccessibilityValue)
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

    private var canBeginAudioSession: Bool {
        runtime.snapshot.providerID != .off
            && runtime.snapshot.connection == .disconnected
            && runtime.snapshot.uiAttached
            && !voiceStartBlockedByConfiguration
    }

    private var canEndAudioSession: Bool {
        runtime.snapshot.providerID != .off
            && runtime.snapshot.connection == .connected
            && runtime.snapshot.uiAttached
    }

    private var canCancelAudioStart: Bool {
        runtime.snapshot.providerID != .off
            && (runtime.snapshot.connection == .connecting || runtime.snapshot.connection == .recovering)
            && runtime.snapshot.uiAttached
    }

    private var canUseVoiceSessionButton: Bool {
        canBeginAudioSession || canEndAudioSession || canCancelAudioStart
    }

    private var canToggleMute: Bool {
        runtime.snapshot.providerID != .off
            && runtime.snapshot.connection == .connected
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

    private var voiceSessionAccessibilityLabel: String {
        switch runtime.snapshot.connection {
        case .connecting, .recovering:
            localized(japanese: "音声接続をキャンセル", english: "Cancel Voice connection")
        case .connected:
            localized(japanese: "音声会話を終了", english: "End Voice conversation")
        case .disconnected:
            canBeginAudioSession
                ? localized(japanese: "音声セッションを開始", english: "Start Voice session")
                : localized(japanese: "音声は現在利用できません", english: "Voice is currently unavailable")
        }
    }

    private var voiceSessionButtonTint: Color {
        if runtime.snapshot.connection == .connected {
            return .green
        }
        return canUseVoiceSessionButton ? .accentColor : .secondary
    }

    private var voiceSessionAccessibilityValue: String {
        switch runtime.snapshot.connection {
        case .connecting, .recovering:
            localized(japanese: "接続中。押すとキャンセル", english: "Connecting. Press to cancel")
        case .connected:
            localized(japanese: "会話中。押すと終了", english: "In conversation. Press to end")
        case .disconnected where canBeginAudioSession:
            localized(japanese: "停止中。押すと開始", english: "Stopped. Press to start")
        case .disconnected:
            localized(japanese: "利用不可", english: "Unavailable")
        }
    }

    private var muteAccessibilityLabel: String {
        runtime.snapshot.muted
            ? localized(japanese: "音声レーンのミュートを解除", english: "Unmute Voice Lane")
            : localized(japanese: "音声レーンをミュート", english: "Mute Voice Lane")
    }

    private var muteAccessibilityValue: String {
        runtime.snapshot.muted
            ? localized(japanese: "ミュート中。押すと解除", english: "Muted. Press to unmute")
            : localized(japanese: "ミュートしていません。押すとミュート", english: "Unmuted. Press to mute")
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
                japanese: "接続中 · 波形を押してキャンセル",
                english: "Connecting · Press the waveform to cancel",
                language: language
            )
        }
        if snapshot.connection == .connected,
           snapshot.muted,
           snapshot.uiAttached {
            return text(
                japanese: "ミュート中 · マイクを押して解除",
                english: "Muted · Press the microphone to unmute",
                language: language
            )
        }
        if snapshot.providerID != .off,
           snapshot.connection == .disconnected,
           snapshot.activity == .idle,
           snapshot.uiAttached {
            return text(
                japanese: "開始前 · 波形を押してください",
                english: "Ready · Press the waveform",
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
                japanese: "波形を押すとOpenAI Realtimeとの音声セッションを開始します。",
                english: "Press the waveform to start an OpenAI Realtime voice session.",
                language: language
            )
        case .codexAppServer:
            return text(
                japanese: "波形を押すとCodexとの音声セッションを開始します。",
                english: "Press the waveform to start a voice session with Codex.",
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
        case "codex_executable_changed":
            return text(
                japanese: "Codexが更新されたため、音声接続を再確認できませんでした。HoverPocketを再起動してお試しください",
                english: "Codex was updated, so Voice compatibility could not be rechecked. Restart HoverPocket and try again.",
                language: language
            )
        case "codex_executable_configuration_conflict":
            return text(
                japanese: "Codexの接続状態が変わったため、音声接続を開始できません。HoverPocketを再起動してお試しください",
                english: "The Codex connection state changed, so Voice could not start. Restart HoverPocket and try again.",
                language: language
            )
        case "codex_not_found", "codex_executable_not_pinned":
            return text(
                japanese: "Codexが見つかりません。Codexをインストールしてからお試しください",
                english: "Codex was not found. Install Codex and try again.",
                language: language
            )
        case "codex_identity_unavailable", "codex_version_probe_failed":
            return text(
                japanese: "Codexを確認できません。CodexとHoverPocketを更新して再起動してください",
                english: "Codex could not be checked. Update Codex and HoverPocket, then restart.",
                language: language
            )
        case "codex_voice_profile_invalid", "codex_dynamic_tools_invalid",
             "codex_capability_runtime_unavailable", "codex_broker_only_tool_policy_missing",
             "codex_compatibility_not_ready", "codex_app_server_unavailable",
             "app_server_transport_failed", "codex_voice_compatibility_blocked":
            return text(
                japanese: "Codexの音声機能を準備できません。CodexとHoverPocketを更新して再起動してください",
                english: "Codex Voice could not be prepared. Update Codex and HoverPocket, then restart.",
                language: language
            )
        case "codex_realtime_schema_missing", "codex_thread_tool_contract_missing":
            return text(
                japanese: "現在のCodexの音声機能には対応していません。CodexとHoverPocketを更新してください",
                english: "This Codex version does not support Voice. Update Codex and HoverPocket.",
                language: language
            )
        case "codex_broker_only_tool_route_mismatch":
            return text(
                japanese: "Codexへの音声接続を確認できませんでした。もう一度お試しください",
                english: "Could not verify the Voice connection to Codex. Try again.",
                language: language
            )
        case "codex_tool_route_probe_timed_out":
            return text(
                japanese: "Codexへの音声接続の確認がタイムアウトしました。もう一度お試しください",
                english: "The Voice connection check to Codex timed out. Try again.",
                language: language
            )
        case "codex_chatgpt_account_required", "signed_out":
            return text(
                japanese: "Codex Voiceを使うにはChatGPTアカウントでログインしてください",
                english: "Sign in with a ChatGPT account to use Codex Voice.",
                language: language
            )
        case "account_response_invalid":
            return text(
                japanese: "Codexのログイン状態を確認できません。Codexを再起動してお試しください",
                english: "Could not check the Codex sign-in status. Restart Codex and try again.",
                language: language
            )
        default:
            if code.hasPrefix("codex_schema_") {
                return text(
                    japanese: "Codexの音声機能を確認できませんでした。もう一度お試しください",
                    english: "Could not verify the Codex Voice feature. Try again.",
                    language: language
                )
            }
            if code.hasPrefix("codex_tool_route_probe_") {
                return text(
                    japanese: "Codexへの音声接続を確認できませんでした。もう一度お試しください",
                    english: "Could not verify the Voice connection to Codex. Try again.",
                    language: language
                )
            }
            return text(japanese: "音声機能を利用できません", english: "Voice is unavailable", language: language)
        }
    }
}
