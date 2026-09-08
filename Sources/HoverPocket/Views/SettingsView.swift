import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var providerStore: ProviderStore
    var onOpenPocketApp: ((String) -> Void)? = nil
    @ObservedObject private var calendarStore = GoogleCalendarStore.shared
    @ObservedObject private var appUpdater = AppUpdater.shared
    @ObservedObject private var aiNativeRuntime = AINativeRuntime.shared
    @ObservedObject private var codexVoiceHost = PocketCodexLibrary.host
    @ObservedObject private var codexVoiceAccount = CodexVoiceAccountLoginController.shared
    @StateObject private var weatherLocationModel = WeatherLocationSettingsModel()
    @State private var selectedCategory: SettingsCategory? = .appearance
    @State private var capabilityDataSnapshot: CapabilityDataGovernanceSnapshot?
    @State private var capabilityDataError: String?
    @State private var isShowingCapabilityHistoryDeleteConfirmation = false
    @State private var openAIRealtimeKeyDraft = ""
    @State private var openAIRealtimeKeyConfigured = false
    @State private var voiceCredentialError: String?
    @State private var isShowingVoiceCalendarAccessConfirmation = false
    private let openAIRealtimeKeychain = OpenAIRealtimeCredentialStoreFactory.shared

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selectedCategory) {
                ForEach(availableCategories) { category in
                    Label(category.title(language: language), systemImage: category.symbol)
                        .tag(category)
                        .padding(.vertical, 5)
                }
            }
            .listStyle(.sidebar)
            .frame(width: 168)
            .accessibilityLabel(localized(japanese: "設定カテゴリ", english: "Settings categories"))

            Divider()

            // Keep each page mounted so switching categories preserves an unfinished tool request.
            ZStack {
                ForEach(availableCategories) { category in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(category.title(language: language))
                                    .font(.title2.weight(.semibold))
                                Text(category.detail(language: language))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Divider()
                            categoryContent(category)
                        }
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .opacity(selectedCategory == category ? 1 : 0)
                    .allowsHitTesting(selectedCategory == category)
                    .disabled(selectedCategory != category)
                    .accessibilityHidden(selectedCategory != category)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            refreshCapabilityDataSnapshot()
            refreshVoiceCredentialState()
            if HoverPocketRuntimeEnvironment.shared.externalIntegrationsEnabled {
                calendarStore.restoreConnectionIfNeeded()
            }
        }
        .onChange(of: settings.voiceProvider) { _, provider in
            openAIRealtimeKeyDraft = ""
            voiceCredentialError = nil
            if provider != .codexAppServer {
                codexVoiceAccount.deactivate()
            }
            if provider == .off {
                settings.voiceEnabled = false
                openAIRealtimeKeyConfigured = false
            } else {
                refreshVoiceCredentialState()
            }
        }
        .onChange(of: settings.capabilityDataRetentionPeriod) { _, period in
            applyCapabilityDataRetention(period)
        }
        .onChange(of: aiNativeRuntime.capabilityDataGovernanceController != nil) { _, _ in
            refreshCapabilityDataSnapshot()
        }
        .alert(
            localized(
                japanese: "監査ログと実行履歴を削除しますか？",
                english: "Delete audit logs and execution history?"
            ),
            isPresented: $isShowingCapabilityHistoryDeleteConfirmation
        ) {
            Button(localized(japanese: "キャンセル", english: "Cancel"), role: .cancel) {}
            Button(localized(japanese: "削除", english: "Delete"), role: .destructive) {
                clearCapabilityHistory()
            }
        } message: {
            Text(localized(
                japanese: "再実行防止用の実行済み情報は残し、内容と監査ログだけを削除します。",
                english: "Receipt content and audit logs are deleted. Minimal completion tombstones remain to prevent duplicate execution."
            ))
        }
        .alert(
            localized(
                japanese: "Voice Laneにカレンダーアクセスを許可しますか？",
                english: "Allow Voice Lane to access Calendar?"
            ),
            isPresented: $isShowingVoiceCalendarAccessConfirmation
        ) {
            Button(localized(japanese: "キャンセル", english: "Cancel"), role: .cancel) {}
            Button(localized(japanese: "許可", english: "Allow")) {
                settings.voiceCalendarAccessEnabled = true
            }
        } message: {
            Text(localized(
                japanese: "今日の予定の読み取りを許可します。予定の変更には、この設定に加えて音声カテゴリの確認設定が適用されます。",
                english: "This permits reading today's events. Calendar changes also follow the confirmation options in Voice settings."
            ))
        }
    }

    private var availableCategories: [SettingsCategory] {
        SettingsCategory.allCases.filter {
            $0 != .connections || HoverPocketRuntimeEnvironment.shared.externalIntegrationsEnabled
        }
    }

    @ViewBuilder
    private func categoryContent(_ category: SettingsCategory) -> some View {
        switch category {
        case .appearance:
            panelsSection
            Divider()
            displaySection
            Divider()
            entryPointSection
        case .features:
            providersSection
            Divider()
            stickyNotesSection
            if HoverPocketRuntimeEnvironment.shared.externalIntegrationsEnabled {
                Divider()
                mirrorSection
            }
        case .tools:
            pocketAppsSection
        case .voice:
            voiceSection
        case .connections:
            googleCalendarSection
            Divider()
            weatherSection
        case .data:
            capabilityHistorySection
        case .general:
            languageSection
            if HoverPocketRuntimeEnvironment.shared.externalIntegrationsEnabled {
                Divider()
                updatesSection
            }
        }
    }

    private var language: AppLanguage {
        settings.appLanguage
    }

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(settings.text(.language))
                .font(.system(size: 13, weight: .bold))

            Picker(settings.text(.language), selection: $settings.appLanguage) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.title).tag(language)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(settings.text(.displaySectionTitle))
                .font(.system(size: 13, weight: .bold))

            Picker(settings.text(.displayPickerTitle), selection: $settings.displayPlacementMode) {
                ForEach(DisplayPlacementMode.allCases) { mode in
                    Text(mode.title(language: language)).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Text(settings.displayPlacementMode.detail(language: language))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                Toggle(settings.text(.showMirrorOnSecondaryDisplays), isOn: $settings.showMirrorOnSecondaryDisplays)

                Text(settings.text(.showMirrorOnSecondaryDisplaysDetail))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var entryPointSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(settings.text(.entryPointSectionTitle))
                .font(.system(size: 13, weight: .bold))

            VStack(alignment: .leading, spacing: 6) {
                Toggle(settings.text(.showSideHandle), isOn: $settings.showNotchSideHandleArea)

                Text(handleIconDetail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Picker(settings.text(.handleIcon), selection: $settings.pillHandleIconStyle) {
                    ForEach(PillHandleIconStyle.allCases) { style in
                        Text(style.title(language: language)).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!settings.showNotchSideHandleArea)
            }
        }
    }

    private var panelsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(settings.text(.panelsSectionTitle))
                .font(.system(size: 13, weight: .bold))

            Toggle(settings.text(.openLastUsedPanel), isOn: $settings.rememberLastSelectedProvider)

            VStack(alignment: .leading, spacing: 6) {
                Picker(settings.text(.panelSize), selection: $settings.panelSize) {
                    ForEach(PanelSizeOption.allCases) { option in
                        Text(option.title(language: language)).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                Text(settings.panelSize.detail(language: language))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Picker(settings.text(.panelTextSize), selection: $settings.panelTextSize) {
                    ForEach(PanelTextSizeOption.allCases) { option in
                        Text(option.title(language: language)).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                Text(settings.panelTextSize.detail(language: language))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !settings.rememberLastSelectedProvider, !providerStore.visibleManifests.isEmpty {
                Picker(settings.text(.defaultPanel), selection: preferredProviderSelection) {
                    ForEach(providerStore.visibleManifests) { manifest in
                        Label(manifest.title(language: language), systemImage: manifest.symbolName)
                            .tag(manifest.id.rawValue)
                    }
                }
            }
        }
    }

    private var providersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(settings.text(.providersSectionTitle))
                .font(.system(size: 13, weight: .bold))

            VStack(alignment: .leading, spacing: 6) {
                Picker(settings.text(.iconSwitching), selection: $settings.providerSwitchingMode) {
                    ForEach(ProviderSwitchingMode.allCases) { mode in
                        Text(mode.title(language: language)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(settings.providerSwitchingMode.detail(language: language))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(settings.text(.providerOrderHint))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(settings.orderedManifests(providerStore.availableManifests)) { manifest in
                    HStack(spacing: 8) {
                        Image(systemName: manifest.symbolName)
                            .frame(width: 18)
                            .foregroundStyle(.secondary)

                        Text(manifest.title(language: language))
                            .font(.system(size: 12))

                        Spacer()

                        Toggle(
                            "",
                            isOn: providerVisibilityBinding(for: manifest)
                        )
                        .labelsHidden()
                        .disabled(isOnlyVisibleProvider(manifest))
                    }
                }
            }
        }
    }

    private var handleIconDetail: String {
        if !settings.showNotchSideHandleArea {
            return settings.text(.handleIconHiddenDetail)
        }
        return settings.pillHandleIconStyle.detail(language: language)
    }

    private var pocketAppsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(localized(japanese: "ツールの作成と管理", english: "Create and manage tools"))
                .font(.system(size: 13, weight: .bold))

            Toggle(
                localized(japanese: "AIネイティブ機能", english: "AI-native features"),
                isOn: $settings.aiNativeEnabled
            )

            if !settings.aiNativeEnabled {
                Text(localized(
                    japanese: "有効にすると、自分用のツールを作成してパネルへ追加できます。",
                    english: "Enable this to create personal tools and add them to your panel."
                ))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            if settings.aiNativeEnabled,
               let generationController = aiNativeRuntime.pocketAppGenerationController {
                Divider()
                PocketAppGenerationSettingsView(
                    controller: generationController,
                    settings: settings,
                    language: language,
                    onOpenTool: onOpenPocketApp
                )
            }
        }
    }

    private var capabilityHistorySection: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text(localized(japanese: "監査ログと実行履歴", english: "Audit logs and execution history"))
                    .font(.system(size: 11, weight: .semibold))

                Picker(
                    localized(japanese: "保持期間", english: "Retention"),
                    selection: $settings.capabilityDataRetentionPeriod
                ) {
                    ForEach(CapabilityDataRetentionPeriod.allCases) { period in
                        Text(period.title(language: language)).tag(period)
                    }
                }
                .pickerStyle(.segmented)

                if let snapshot = capabilityDataSnapshot {
                    Text(localized(
                        japanese: "監査ファイル \(snapshot.auditFileCount)件・保存済み履歴 \(snapshot.storedReceiptCount)件・削除済み墓標 \(snapshot.redactedTombstoneCount)件",
                        english: "\(snapshot.auditFileCount) audit files, \(snapshot.storedReceiptCount) stored receipts, \(snapshot.redactedTombstoneCount) redacted tombstones"
                    ))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }

                if let capabilityDataError {
                    Text(capabilityDataError)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                }

                Button(role: .destructive) {
                    isShowingCapabilityHistoryDeleteConfirmation = true
                } label: {
                    Label(
                        localized(japanese: "履歴を削除", english: "Delete history"),
                        systemImage: "trash"
                    )
                }
                .buttonStyle(.bordered)
                .disabled(aiNativeRuntime.capabilityDataGovernanceController == nil)
            }
            .padding(10)
            .background(.quaternary.opacity(0.22))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))


        }
    }

    private func applyCapabilityDataRetention(_ period: CapabilityDataRetentionPeriod) {
        guard let controller = aiNativeRuntime.capabilityDataGovernanceController else {
            refreshCapabilityDataSnapshot()
            return
        }
        do {
            capabilityDataSnapshot = try controller.applyRetention(period)
            capabilityDataError = nil
        } catch {
            capabilityDataError = localized(
                japanese: "保持期間を適用できませんでした。",
                english: "Could not apply the retention period."
            )
        }
    }

    private func clearCapabilityHistory() {
        guard let controller = aiNativeRuntime.capabilityDataGovernanceController else { return }
        do {
            capabilityDataSnapshot = try controller.clearHistory()
            capabilityDataError = nil
        } catch {
            capabilityDataError = localized(
                japanese: "履歴を削除できませんでした。",
                english: "Could not delete history."
            )
        }
    }

    private func refreshCapabilityDataSnapshot() {
        guard let controller = aiNativeRuntime.capabilityDataGovernanceController else {
            capabilityDataSnapshot = nil
            return
        }
        do {
            capabilityDataSnapshot = try controller.snapshot()
            capabilityDataError = nil
        } catch {
            capabilityDataSnapshot = nil
            capabilityDataError = localized(
                japanese: "履歴の状態を読み取れませんでした。",
                english: "Could not read history status."
            )
        }
    }

    private var voiceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(localized(japanese: "Voice Lane", english: "Voice Lane"))
                .font(.system(size: 13, weight: .bold))

            Picker(
                localized(japanese: "音声Provider", english: "Voice provider"),
                selection: $settings.voiceProvider
            ) {
                Text(localized(japanese: "オフ", english: "Off")).tag(VoiceProviderID.off)
                Text(localized(japanese: "Codex app-server（推奨）", english: "Codex app-server (Recommended)"))
                    .tag(VoiceProviderID.codexAppServer)
                Text("Realtime BYOK").tag(VoiceProviderID.openAIRealtimeBYOK)
            }
            .pickerStyle(.segmented)

            if settings.voiceProvider == .codexAppServer {
                Picker(localized(japanese: "対話の声", english: "Conversation voice"), selection: $settings.codexVoiceSelection) {
                    Text(localized(japanese: "接続先の既定", english: "Server default")).tag("")
                    ForEach(codexVoiceHost.availableVoices, id: \.self) { voice in Text(voice.capitalized).tag(voice) }
                    if !settings.codexVoiceSelection.isEmpty && !codexVoiceHost.availableVoices.contains(settings.codexVoiceSelection) {
                        Text(settings.codexVoiceSelection + "（未確認）").tag(settings.codexVoiceSelection)
                    }
                }
                Text(localized(japanese: "声は次回の音声接続から反映します。候補は接続先の確認後に表示されます。", english: "Applies on your next voice connection. Choices appear after checking the server."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Toggle(
                localized(japanese: "Voice Laneを有効化", english: "Enable Voice Lane"),
                isOn: $settings.voiceEnabled
            )
            .disabled(settings.voiceProvider == .off)

            VStack(alignment: .leading, spacing: 4) {
                Toggle(
                    localized(
                        japanese: "パネルを閉じても音声を続ける",
                        english: "Continue voice when the panel is hidden"
                    ),
                    isOn: $settings.voiceContinueWhenPanelHidden
                )
                .disabled(settings.voiceProvider == .off || !settings.voiceEnabled)

                Text(localized(
                    japanese: "接続済みでミュート解除中のときだけ、パネルを閉じても音声を維持します。接続中・ミュート中に自動開始や解除はしません。",
                    english: "Keeps audio only when the session is already connected and unmuted. It never starts or unmutes a connecting or muted session."
                ))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle(
                    localized(
                        japanese: "通常操作を音声で確認",
                        english: "Confirm regular actions by voice"
                    ),
                    isOn: $settings.voiceActionConfirmationEnabled
                )
                .disabled(settings.voiceProvider == .off || !settings.voiceEnabled)

                Text(localized(
                    japanese: "追加・編集・開始などの前に音声で確認します。オフでは依頼した操作をそのまま実行します。",
                    english: "Ask by voice before adding, editing, or starting. When off, execute the requested action directly."
                ))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle(
                    localized(japanese: "削除・取消操作を音声で確認", english: "Confirm deletions and cancellations by voice"),
                    isOn: $settings.voiceDestructiveConfirmationEnabled
                )
                .disabled(settings.voiceProvider == .off || !settings.voiceEnabled)
                Text(localized(
                    japanese: "予定・付箋・記録の削除、タイマーの取消、追加ツールの取り外しを対象にします。両方オフなら確認画面も追加の音声確認も出しません。macOSの権限許可は別途必要です。",
                    english: "Covers deleting events, notes and records, cancelling timers, and removing added tools. With both options off, there are no confirmation dialogs or follow-up voice approvals. macOS permissions still apply."
                ))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            if settings.voiceProvider == .codexAppServer {
                codexVoiceAccountSection
            }

            if settings.voiceProvider == .openAIRealtimeBYOK {
                VStack(alignment: .leading, spacing: 8) {
                    SecureField(
                        localized(japanese: "OpenAI APIキー", english: "OpenAI API key"),
                        text: $openAIRealtimeKeyDraft
                    )
                    .textFieldStyle(.roundedBorder)

                    HStack(spacing: 8) {
                        Button(HoverPocketRuntimeEnvironment.shared.isIsolatedVoiceE2E
                            ? localized(japanese: "このテスト起動に保存", english: "Save for this test run")
                            : localized(japanese: "Keychainへ保存", english: "Save to Keychain")) {
                            saveOpenAIRealtimeKey()
                        }
                        .disabled(openAIRealtimeKeyDraft.isEmpty)

                        Button(localized(japanese: "APIキーを削除", english: "Delete API key"), role: .destructive) {
                            deleteOpenAIRealtimeKey()
                        }
                        .disabled(!openAIRealtimeKeyConfigured)
                    }

                    Text(openAIRealtimeKeyConfigured
                        ? HoverPocketRuntimeEnvironment.shared.isIsolatedVoiceE2E
                            ? localized(japanese: "APIキーはこのテストprocessのメモリだけに保持されています。", english: "The API key is held only in memory for this test process.")
                            : localized(japanese: "APIキーはmacOS Keychainに保存済みです。", english: "API key is stored in macOS Keychain.")
                        : localized(japanese: "APIキーは未設定です。", english: "API key is not configured."))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)

                    Text(localized(
                        japanese: "APIキーはネイティブ側だけで使用し、音声WebViewには渡しません。Voice Laneを有効にしただけではマイクを開始せず、パネルのマイクボタンを押した時だけ接続します。",
                        english: "The API key is used only by the native host and is never passed to the audio WebView. Enabling Voice Lane does not start the microphone; connection begins only after pressing the microphone button."
                    ))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(.quaternary.opacity(0.22))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            }

            if settings.voiceProvider != .off {
                Toggle(
                    localized(
                        japanese: "Voice Laneからカレンダーを利用",
                        english: "Allow Calendar in Voice Lane"
                    ),
                    isOn: Binding(
                        get: { settings.voiceCalendarAccessEnabled },
                        set: { enabled in
                            if enabled {
                                isShowingVoiceCalendarAccessConfirmation = true
                            } else {
                                settings.voiceCalendarAccessEnabled = false
                            }
                        }
                    )
                )
                .disabled(!settings.voiceEnabled)
            }

            if let voiceCredentialError {
                Text(voiceCredentialError)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
            }

            Picker(
                localized(japanese: "表示", english: "Layout"),
                selection: $settings.voiceLaneLayoutPreference
            ) {
                Text(localized(japanese: "コンパクト", english: "Compact"))
                    .tag(VoiceLaneLayoutPreference.compact)
                Text(localized(japanese: "展開", english: "Expanded"))
                    .tag(VoiceLaneLayoutPreference.expanded)
            }
            .pickerStyle(.segmented)
            .disabled(!settings.voiceEnabled)

            Text(settings.voiceProvider == .codexAppServer
                ? localized(
                    japanese: "Codex app-serverを使う標準経路です。Codexアプリのログインを安全に共有できない場合は、HoverPocket専用プロファイルからChatGPTへログインできます。APIキーは不要で、BYOKへ自動切替はしません。",
                    english: "This is the primary Codex app-server path. If the Codex app login cannot be shared safely, you can sign in to ChatGPT with a dedicated HoverPocket profile. No API key is required and it never falls back to BYOK automatically."
                )
                : settings.voiceProvider == .off
                    ? localized(
                        japanese: "Providerは既定でオフです。オフではcredential・network・transport処理を行いません。",
                        english: "The provider is Off by default. Off performs no credential, network, or transport work."
                    )
                    : localized(
                        japanese: "OpenAI Realtime BYOKは任意の代替経路です。利用時だけAPI料金が発生します。CalendarとTimerはCapability Broker、既定ONのVoice確認、実行後readbackを通ります（確認OFFでもBroker処理は維持）。",
                        english: "OpenAI Realtime BYOK is an optional alternative and incurs API charges only when used. Calendar and Timer cross Capability Broker, the default-on Voice confirmation, and post-execution readback; Broker processing remains when confirmation is off."
                    ))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var codexVoiceAccountSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch codexVoiceAccount.state {
            case .idle:
                Text(localized(
                    japanese: "ChatGPTのログイン状態は未確認です。",
                    english: "ChatGPT sign-in status has not been checked."
                ))
                Button(localized(japanese: "ログイン状態を確認", english: "Check sign-in status")) {
                    codexVoiceAccount.refresh()
                }
            case .checking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(localized(
                        japanese: "ChatGPTのログイン状態を確認しています…",
                        english: "Checking ChatGPT sign-in status…"
                    ))
                }
            case .signedOut(let managedLoginAvailable, _):
                Text(managedLoginAvailable
                    ? localized(
                        japanese: "HoverPocket専用のCodexプロファイルは未ログインです。",
                        english: "The dedicated HoverPocket Codex profile is signed out."
                    )
                    : localized(
                        japanese: "共有しているCodexログインではChatGPTアカウントを確認できません。Codexアプリでログインしてから再確認してください。",
                        english: "A ChatGPT account was not found in the shared Codex login. Sign in with the Codex app, then check again."
                    ))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    if managedLoginAvailable {
                        Button(localized(japanese: "ChatGPTでログイン", english: "Sign in with ChatGPT")) {
                            codexVoiceAccount.startLogin()
                        }
                    }
                    Button(localized(japanese: "再確認", english: "Check again")) {
                        codexVoiceAccount.refresh()
                    }
                }
            case .signingIn:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(localized(
                        japanese: "ブラウザでChatGPTへログインしてください。",
                        english: "Complete ChatGPT sign-in in your browser."
                    ))
                    Spacer()
                    Button(localized(japanese: "キャンセル", english: "Cancel")) {
                        codexVoiceAccount.cancelLogin()
                    }
                }
            case .signedIn:
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(localized(
                        japanese: "ChatGPTへログイン済みです。",
                        english: "Signed in to ChatGPT."
                    ))
                    Spacer()
                    Button(localized(japanese: "再確認", english: "Check again")) {
                        codexVoiceAccount.refresh()
                    }
                }
            case .failed:
                Text(localized(
                    japanese: "ログイン状態を確認できませんでした。Codex app-serverの互換性と接続状態を確認してください。",
                    english: "Could not check sign-in status. Check Codex app-server compatibility and connectivity."
                ))
                    .foregroundStyle(.red)
                Button(localized(japanese: "再試行", english: "Retry")) {
                    codexVoiceAccount.refresh()
                }
            }
        }
        .font(.system(size: 10))
        .padding(10)
        .background(.quaternary.opacity(0.22))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func refreshVoiceCredentialState() {
        if settings.voiceProvider == .codexAppServer {
            openAIRealtimeKeyConfigured = false
            codexVoiceAccount.refresh()
            return
        }
        guard settings.voiceProvider == .openAIRealtimeBYOK else {
            openAIRealtimeKeyConfigured = false
            return
        }
        do {
            openAIRealtimeKeyConfigured = try openAIRealtimeKeychain.hasCredential()
            voiceCredentialError = nil
        } catch {
            openAIRealtimeKeyConfigured = false
            voiceCredentialError = localized(
                japanese: "Keychainの状態を確認できませんでした。",
                english: "Could not read Keychain status."
            )
        }
    }

    private func saveOpenAIRealtimeKey() {
        do {
            let key = try OpenAIRealtimeAPIKey(openAIRealtimeKeyDraft)
            try openAIRealtimeKeychain.save(key)
            openAIRealtimeKeyDraft = ""
            openAIRealtimeKeyConfigured = true
            voiceCredentialError = nil
            MacOSVoiceE2EReceiptStore.shared?.recordCredentialCurrent(true)
            VoiceLaneRuntime.shared.credentialsDidChange()
        } catch {
            openAIRealtimeKeyDraft = ""
            openAIRealtimeKeyConfigured = false
            voiceCredentialError = localized(
                japanese: "APIキーをKeychainへ保存できませんでした。",
                english: "Could not save the API key to Keychain."
            )
        }
    }

    private func deleteOpenAIRealtimeKey() {
        do {
            try openAIRealtimeKeychain.delete()
            guard try !openAIRealtimeKeychain.hasCredential() else {
                throw OpenAIRealtimeKeychainError.deletionNotConfirmed
            }
            openAIRealtimeKeyConfigured = false
            openAIRealtimeKeyDraft = ""
            voiceCredentialError = nil
            MacOSVoiceE2EReceiptStore.shared?.recordCredentialCurrent(false)
            VoiceLaneRuntime.shared.credentialsDidChange()
        } catch {
            openAIRealtimeKeyDraft = ""
            openAIRealtimeKeyConfigured = true
            voiceCredentialError = localized(
                japanese: "APIキーの削除をKeychainから確認できませんでした。",
                english: "Could not verify API key removal from Keychain."
            )
        }
    }

    private var mirrorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(settings.text(.mirror))
                .font(.system(size: 13, weight: .bold))

            Toggle(settings.text(.showMicrophoneTest), isOn: $settings.showMirrorMicrophoneCheck)

            Text(settings.text(.microphoneTestDetail))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var stickyNotesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(settings.text(.stickyNotes))
                .font(.system(size: 13, weight: .bold))

            Toggle(settings.text(.showStickyNoteUndo), isOn: $settings.showStickyNoteUndoToast)
        }
    }

    private var weatherSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(settings.text(.weather))
                .font(.system(size: 13, weight: .bold))

            HStack(spacing: 8) {
                Image(systemName: locationSymbol)
                    .frame(width: 18)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(settings.weatherLocation.displayName(language: language))
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(settings.weatherLocation.detail(language: language))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if weatherLocationModel.isLocating {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Button {
                if weatherLocationModel.isLocating {
                    weatherLocationModel.cancelCurrentLocation()
                    return
                }
                weatherLocationModel.requestCurrentLocation(language: language) { location in
                    if let location {
                        settings.weatherLocation = location
                    }
                }
            } label: {
                Label(
                    localized(
                        japanese: weatherLocationModel.isLocating ? "現在地の取得をキャンセル" : "現在地を使用",
                        english: weatherLocationModel.isLocating ? "Cancel location request" : "Use current location"
                    ),
                    systemImage: "location.fill"
                )
            }

            HStack(spacing: 8) {
                TextField(
                    localized(
                        japanese: "都市名または郵便番号",
                        english: "City or postal code"
                    ),
                    text: $weatherLocationModel.searchText
                )
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    weatherLocationModel.search(language: language)
                }

                Button {
                    weatherLocationModel.search(language: language)
                } label: {
                    if weatherLocationModel.isSearching {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "magnifyingglass")
                    }
                }
                .disabled(weatherLocationModel.isSearching)
                .help(localized(japanese: "地域を検索", english: "Search locations"))
            }

            if !weatherLocationModel.searchResults.isEmpty {
                VStack(spacing: 0) {
                    ForEach(weatherLocationModel.searchResults.prefix(6)) { location in
                        Button {
                            settings.weatherLocation = location
                            weatherLocationModel.clearSearch()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "mappin")
                                    .frame(width: 14)
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(location.displayName(language: language))
                                        .font(.system(size: 11, weight: .medium))
                                    Text(location.detail(language: language))
                                        .font(.system(size: 9))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                        }
                        .buttonStyle(.plain)

                        if location.id != weatherLocationModel.searchResults.prefix(6).last?.id {
                            Divider()
                        }
                    }
                }
                .background(.quaternary.opacity(0.35))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }

            if let message = weatherLocationModel.message {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Picker(
                localized(
                    japanese: "日本の都道府県",
                    english: "Japanese prefecture"
                ),
                selection: japaneseRegionSelection
            ) {
                Text(localized(japanese: "選択してください", english: "Choose…"))
                    .tag("")
                ForEach(WeatherRegion.allRegions) { region in
                    Text(region.name(language: language))
                        .tag(region.id)
                }
            }

            Picker(
                localized(japanese: "温度単位", english: "Temperature unit"),
                selection: $settings.weatherTemperatureUnit
            ) {
                ForEach(WeatherTemperatureUnitOption.allCases) { option in
                    Text(option.title(language: language))
                        .tag(option)
                }
            }
            .pickerStyle(.segmented)

            Text(settings.text(.weatherRegionDetail))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var japaneseRegionSelection: Binding<String> {
        Binding(
            get: { settings.weatherLocation.legacyRegionID ?? "" },
            set: { regionID in
                guard let region = WeatherRegion.region(id: regionID) else { return }
                settings.weatherLocation = WeatherLocation.from(region: region)
                weatherLocationModel.clearSearch()
            }
        )
    }

    private var locationSymbol: String {
        settings.weatherLocation.source == .currentLocation
            ? "location.fill"
            : "mappin.and.ellipse"
    }

    private func localized(japanese: String, english: String) -> String {
        language == .japanese ? japanese : english
    }

    private var googleCalendarSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(settings.text(.calendarSectionTitle))
                .font(.system(size: 13, weight: .bold))

            HStack(spacing: 10) {
                calendarStatus

                Spacer()

                if calendarStore.isSignedIn {
                    Button(settings.text(.disconnect)) {
                        calendarStore.signOut()
                    }
                } else {
                    Button(calendarConnectTitle) {
                        calendarStore.connect()
                    }
                    .disabled(!calendarStore.isConfigured || calendarStore.connectionState == .signingIn || calendarStore.connectionState == .restoring)
                }
            }

            if let message = calendarStore.lastErrorMessage {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(settings.text(.updates))
                .font(.system(size: 13, weight: .bold))

            HStack(spacing: 10) {
                Label(appUpdater.statusText(language: language), systemImage: appUpdater.statusSystemImage)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                Spacer()

                Button(settings.text(.checkForUpdates)) {
                    appUpdater.checkForUpdates()
                }
                .disabled(!appUpdater.canCheckForUpdates)
            }
        }
    }

    private var preferredProviderSelection: Binding<String> {
        Binding(
            get: {
                let visible = providerStore.visibleManifests
                if let preferred = settings.preferredProviderRawValue,
                   visible.contains(where: { $0.id.rawValue == preferred }) {
                    return preferred
                }
                return visible.first?.id.rawValue ?? ""
            },
            set: { settings.preferredProviderRawValue = $0 }
        )
    }

    private func providerVisibilityBinding(for manifest: PluginManifest) -> Binding<Bool> {
        Binding(
            get: {
                settings.isProviderVisible(manifest.id)
            },
            set: { isVisible in
                providerStore.setProvider(manifest.id, isVisible: isVisible)
            }
        )
    }

    private func isOnlyVisibleProvider(_ manifest: PluginManifest) -> Bool {
        settings.isProviderVisible(manifest.id) && providerStore.visibleManifests.count <= 1
    }

    private var calendarStatus: some View {
        HStack(spacing: 8) {
            Image(systemName: calendarStatusSymbol)
                .foregroundStyle(calendarStore.isSignedIn ? .green : .secondary)

            Text(calendarStatusText)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var calendarStatusSymbol: String {
        switch calendarStore.connectionState {
        case .missingConfiguration:
            return "key.slash"
        case .restoring:
            return "arrow.triangle.2.circlepath"
        case .signedOut:
            return "person.crop.circle.badge.plus"
        case .needsReconnect:
            return "exclamationmark.arrow.triangle.2.circlepath"
        case .signingIn:
            return "arrow.triangle.2.circlepath"
        case .signedIn:
            return "checkmark.circle.fill"
        }
    }

    private var calendarStatusText: String {
        switch calendarStore.connectionState {
        case .missingConfiguration:
            return settings.text(.calendarConfigMissingDetail)
        case .restoring:
            return settings.text(.calendarConnectionChecking)
        case .signedOut:
            return settings.text(.calendarConnectionNotConnected)
        case .needsReconnect:
            return settings.text(.calendarConnectionReconnect)
        case .signingIn:
            return settings.text(.calendarConnectionConnecting)
        case .signedIn:
            return settings.text(.calendarConnectionConnected)
        }
    }

    private var calendarConnectTitle: String {
        switch calendarStore.connectionState {
        case .signingIn:
            return settings.text(.calendarConnectConnecting)
        case .restoring:
            return settings.text(.calendarConnectChecking)
        case .needsReconnect:
            return settings.text(.calendarConnectReconnect)
        default:
            return settings.text(.calendarConnectOpenLogin)
        }
    }

}
