import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var providerStore: ProviderStore
    var onOpenPocketApp: ((String) -> Void)? = nil
    @ObservedObject private var calendarStore = GoogleCalendarStore.shared
    @ObservedObject private var appUpdater = AppUpdater.shared
    @ObservedObject private var assetRuntime = AssetLibraryRuntime.shared
    @ObservedObject private var aiNativeRuntime = AINativeRuntime.shared
    @ObservedObject private var codexVoiceHost = PocketCodexLibrary.host
    @ObservedObject private var codexVoiceAccount = CodexVoiceAccountLoginController.shared
    @StateObject private var weatherLocationModel = WeatherLocationSettingsModel()
    @State private var selectedCategory: SettingsCategory? = .general
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
            .frame(width: 176)
            .accessibilityLabel(localized(japanese: "設定カテゴリ", english: "Settings categories"))

            Divider()

            // Keep each page mounted so switching categories preserves an unfinished tool request.
            ZStack {
                ForEach(availableCategories) { category in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(category.title(language: language))
                                .font(.title2.weight(.semibold))
                                .accessibilityAddTraits(.isHeader)
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
                japanese: "今日の予定の読み取りを許可します。予定の変更には、この設定に加えてAIの確認設定が適用されます。",
                english: "This permits reading today's events. Calendar changes also follow the confirmation options in AI settings."
            ))
        }
    }

    private var availableCategories: [SettingsCategory] {
        SettingsCategory.available(externalIntegrationsEnabled: HoverPocketRuntimeEnvironment.shared.externalIntegrationsEnabled)
    }

    @ViewBuilder
    private func categoryContent(_ category: SettingsCategory) -> some View {
        switch category {
        case .general:
            SettingsCard { languageSection }
            if HoverPocketRuntimeEnvironment.shared.externalIntegrationsEnabled {
                SettingsCard { updatesSection }
                SettingsCard {
                    SettingsDetails(title: localized(japanese: "カレンダーと天気", english: "Calendar & Weather")) {
                        googleCalendarSection
                        Divider()
                        weatherSection
                    }
                }
            }
            SettingsCard { stickyNotesSection }
        case .appearance:
            SettingsCard { panelsSection }
            SettingsCard { displaySection }
            SettingsCard {
                SettingsDetails(title: localized(japanese: "表示する機能", english: "Visible features")) { providersSection }
            }
        case .library:
            SettingsCard {
                Text(localized(japanese: "ライブラリへの取り込み", english: "Library import")).font(.headline)
                Toggle(localized(japanese: "コピーした画像をライブラリへ自動保存", english: "Automatically save copied images to the library"), isOn: $settings.libraryAutoImportClipboardImages)
                Text(localized(japanese: "オンにした後の画像を保存します。重複した画像やゴミ箱の画像は追加しません。オフにしても保存済みの素材は残ります。", english: "Saves images copied after enabling. Duplicate or trashed images are not added. Turning this off keeps saved assets."))
                    .font(.callout).foregroundStyle(.secondary)
                if let error = assetRuntime.clipboardImportError {
                    Text(error).font(.callout).foregroundStyle(.orange)
                }
            }
            AssetLibrarySyncSettings(language: language)
        case .capture:
            SettingsCard { mirrorSection }
            SettingsCard {
                Text(localized(japanese: "カメラとマイクの許可", english: "Camera & microphone permissions")).font(.headline)
                ViewThatFits(in: .horizontal) {
                    HStack { capturePermissionButtons }
                    VStack(alignment: .leading) { capturePermissionButtons }
                }
                Text(localized(japanese: "撮影・録音は、素材パネルのカメラボタンから開始できます。", english: "Start capturing or recording from the camera button in your library panel."))
                    .font(.callout).foregroundStyle(.secondary)
            }
        case .shortcuts:
            SettingsCard { ShortcutSettingsView(settings: settings) }
        case .ai:
            SettingsCard { voiceSection }
            SettingsCard { pocketAppsSection }
        case .advanced:
            SettingsCard { capabilityHistorySection }
        }
    }

    @ViewBuilder
    private var capturePermissionButtons: some View {
        Button(localized(japanese: "カメラの設定を開く", english: "Camera settings")) { SystemSettingsOpener.openCameraPrivacy() }
        Button(localized(japanese: "マイクの設定を開く", english: "Microphone settings")) { SystemSettingsOpener.openMicrophonePrivacy() }
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

            VStack(alignment: .leading, spacing: 4) {
                Toggle(settings.text(.showMirrorOnSecondaryDisplays), isOn: $settings.showMirrorOnSecondaryDisplays)
                    .help(settings.text(.showMirrorOnSecondaryDisplaysDetail))
            }
        }
    }

    private var panelsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(settings.text(.panelsSectionTitle))
                .font(.system(size: 13, weight: .bold))

            Toggle(settings.text(.openLastUsedPanel), isOn: $settings.rememberLastSelectedProvider)

            VStack(alignment: .leading, spacing: 6) {
                Picker(localized(japanese: "ノッチとパネルの接続", english: "Panel attachment"),
                       selection: $settings.panelAttachmentStyle) {
                    ForEach(PanelAttachmentStyle.allCases) { style in
                        Text(style.title(language: language)).tag(style)
                    }
                }
                .pickerStyle(.segmented)

                Toggle(localized(japanese: "ノッチがない画面では自動で上端モードにする",
                                 english: "Use top-edge mode on displays without a notch"),
                       isOn: $settings.automaticallyCoverMenuOnNoNotchDisplays)
                .help(localized(japanese: "ノッチがない画面で、パネルを開いている間だけ上端のメニューを覆います。",
                                english: "On displays without a notch, cover the menu area while the panel is open."))
            }

            VStack(alignment: .leading, spacing: 6) {
                Picker(settings.text(.panelSize), selection: $settings.panelSize) {
                    ForEach(PanelSizeOption.allCases) { option in
                        Text(option.title(language: language)).tag(option)
                    }
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 6) {
                Picker(settings.text(.panelTextSize), selection: $settings.panelTextSize) {
                    ForEach(PanelTextSizeOption.allCases) { option in
                        Text(option.title(language: language)).tag(option)
                    }
                }
                .pickerStyle(.segmented)
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
                            manifest.title(language: language),
                            isOn: providerVisibilityBinding(for: manifest)
                        )
                        .labelsHidden()
                        .disabled(isOnlyVisibleProvider(manifest))
                    }
                }
            }
        }
    }

    private var pocketAppsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(localized(japanese: "ツールの作成と管理", english: "Create and manage tools"))
                .font(.system(size: 13, weight: .bold))

            Toggle(
                localized(japanese: "自作ツールを使う", english: "Enable personal tools"),
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
                Text(localized(japanese: "AIの操作履歴", english: "AI action history"))
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
                        japanese: "保存済みの履歴：\(snapshot.storedReceiptCount)件",
                        english: "Saved history: \(snapshot.storedReceiptCount) entries"
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
        VStack(alignment: .leading, spacing: 14) {
            Text(localized(japanese: "チャットと音声", english: "Chat & voice")).font(.headline)
            Toggle(localized(japanese: "Codexにアプリ内の操作をすべて許可", english: "Allow Codex all app actions"), isOn: $settings.codexAllowAllAppActions)
            Text(localized(japanese: "追加・編集・削除・撮影など、対応する操作を追加確認なしで実行します。素材の削除はゴミ箱へ移動します。OSの権限許可は別途必要です。", english: "Run supported edits, deletions and captures without additional confirmation. Library deletions move assets to Trash. OS permissions still apply.")).font(.caption).foregroundStyle(.secondary)
            Picker(localized(japanese: "音声の接続先", english: "Voice service"), selection: $settings.voiceProvider) {
                Text(localized(japanese: "オフ", english: "Off")).tag(VoiceProviderID.off)
                Text("Codex / ChatGPT").tag(VoiceProviderID.codexAppServer)
                Text(localized(japanese: "OpenAI API（別途料金）", english: "OpenAI API (usage charges)"))
                    .tag(VoiceProviderID.openAIRealtimeBYOK)
            }
            .pickerStyle(.menu)

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
                Toggle(localized(japanese: "音声対話を使う", english: "Enable voice conversation"), isOn: $settings.voiceEnabled)
                if settings.voiceProvider == .codexAppServer {
                    Picker(localized(japanese: "対話の声", english: "Conversation voice"), selection: $settings.codexVoiceSelection) {
                        Text(localized(japanese: "接続先の既定", english: "Server default")).tag("")
                        ForEach(codexVoiceHost.availableVoices, id: \.self) { voice in Text(voice.capitalized).tag(voice) }
                        if !settings.codexVoiceSelection.isEmpty && !codexVoiceHost.availableVoices.contains(settings.codexVoiceSelection) {
                            Text(settings.codexVoiceSelection).tag(settings.codexVoiceSelection)
                        }
                    }
                    .help(localized(japanese: "次回の音声接続から反映します。", english: "Applies to your next voice connection."))
                }
                SettingsDetails(title: localized(japanese: "音声の詳細設定", english: "Voice options")) {
                    voiceOptions
                }
            }

            if let voiceCredentialError {
                Text(voiceCredentialError).font(.callout).foregroundStyle(.red)
            }
            Text(localized(japanese: "テキストチャットは、パネルの入力欄からいつでも利用できます。", english: "Use the text field in your panel to chat."))
                .font(.callout).foregroundStyle(.secondary)
            SettingsDetails(title: localized(japanese: "接続方式について", english: "About voice services")) {
                Text(localized(
                    japanese: "CodexはChatGPTログインを使い、APIキーは不要です。OpenAI APIは別途従量課金です。接続先を自動で切り替えることはありません。マイクは、パネルの音声ボタンを押した時にだけ接続します。",
                    english: "Codex uses ChatGPT sign-in, without an API key. OpenAI API has separate usage charges. Services never switch automatically. The microphone connects only after you press the voice button in the panel."
                )).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var voiceOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Toggle(
                    localized(
                        japanese: "パネルを閉じても音声を続ける",
                        english: "Continue voice when the panel is hidden"
                    ),
                    isOn: $settings.voiceContinueWhenPanelHidden
                )
                .disabled(settings.voiceProvider == .off || !settings.voiceEnabled)

                .help(localized(
                    japanese: "接続済みでミュート解除中のときだけ、パネルを閉じても音声を維持します。接続中・ミュート中に自動開始や解除はしません。",
                    english: "Keeps audio only when the session is already connected and unmuted. It never starts or unmutes a connecting or muted session."
                ))
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

                .help(localized(
                    japanese: "追加・編集・開始などの前に音声で確認します。オフでは依頼した操作をそのまま実行します。",
                    english: "Ask by voice before adding, editing, or starting. When off, execute the requested action directly."
                ))
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle(
                    localized(japanese: "削除・取消操作を音声で確認", english: "Confirm deletions and cancellations by voice"),
                    isOn: $settings.voiceDestructiveConfirmationEnabled
                )
                .disabled(settings.voiceProvider == .off || !settings.voiceEnabled)
                .help(localized(
                    japanese: "予定・付箋・記録の削除、タイマーの取消、追加ツールの取り外しを対象にします。両方オフなら確認画面も追加の音声確認も出しません。macOSの権限許可は別途必要です。",
                    english: "Covers deleting events, notes and records, cancelling timers, and removing added tools. With both options off, there are no confirmation dialogs or follow-up voice approvals. macOS permissions still apply."
                ))
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

            Text(localized(japanese: "確認をオフにすると、削除を含む依頼をそのまま実行します。", english: "With confirmations off, requested actions—including deletions—run immediately."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var codexVoiceAccountSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch codexVoiceAccount.state {
            case .idle:
                Text(localized(
                    japanese: "ChatGPTの接続を確認できます。",
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
                        japanese: "ChatGPTへログインしてください。",
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
                        japanese: "ChatGPTに接続済み",
                        english: "Connected to ChatGPT"
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
        .font(.callout)
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
