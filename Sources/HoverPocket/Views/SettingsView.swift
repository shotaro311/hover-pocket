import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var providerStore: ProviderStore
    @ObservedObject private var calendarStore = GoogleCalendarStore.shared
    @ObservedObject private var appUpdater = AppUpdater.shared
    @ObservedObject private var aiNativeRuntime = AINativeRuntime.shared
    @ObservedObject private var codexVoiceAccount = CodexVoiceAccountLoginController.shared
    @StateObject private var weatherLocationModel = WeatherLocationSettingsModel()
    @State private var capabilityDataSnapshot: CapabilityDataGovernanceSnapshot?
    @State private var capabilityDataError: String?
    @State private var isShowingCapabilityHistoryDeleteConfirmation = false
    @State private var openAIRealtimeKeyDraft = ""
    @State private var openAIRealtimeKeyConfigured = false
    @State private var voiceCredentialError: String?
    @State private var isShowingVoiceCalendarAccessConfirmation = false
    private let openAIRealtimeKeychain = OpenAIRealtimeCredentialStoreFactory.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                languageSection

                Divider()

                displaySection

                Divider()

                entryPointSection

                Divider()

                panelsSection

                Divider()

                providersSection

                Divider()

                pocketAppsSection

                Divider()

                voiceSection

                Divider()

                stickyNotesSection

                if HoverPocketRuntimeEnvironment.shared.externalIntegrationsEnabled {
                    Divider()

                    mirrorSection

                    Divider()

                    weatherSection

                    Divider()

                    googleCalendarSection

                    Divider()

                    updatesSection
                }
            }
            .padding(20)
        }
        .frame(width: 460, height: 500)
        .onAppear {
            refreshCapabilityDataSnapshot()
            refreshVoiceCredentialState()
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
                japanese: "今日の予定の読み取りを許可します。予定の作成は、この設定に加えて毎回macOSの確認画面で許可が必要です。",
                english: "This permits reading today's events. Creating an event still requires approval in a native macOS confirmation every time."
            ))
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
            Text("Pocket Apps")
                .font(.system(size: 13, weight: .bold))

            Toggle(
                localized(japanese: "AIネイティブ機能", english: "AI-native features"),
                isOn: $settings.aiNativeEnabled
            )

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

            if let package = aiNativeRuntime.pocketAppExecutionRuntime?.package {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Image(systemName: "target")
                            .foregroundStyle(.secondary)
                        Text(package.manifest.name)
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Text("v\(package.manifest.version)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    Text(PocketSurfaceHostModel.sanitizeVisibleText(package.intent).prefixingUnicodeScalars(500))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(package.manifest.requestedCapabilities.map { $0.key.id }.sorted().joined(separator: " · "))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)

                    Label(
                        localized(
                            japanese: "定義、ユーザーデータ、実行履歴は分離して保持",
                            english: "Definition, user data, and receipts are stored separately"
                        ),
                        systemImage: "externaldrive.badge.checkmark"
                    )
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(.quaternary.opacity(0.28))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Text(localized(
                    japanese: "有効なPocket Appはありません。AIネイティブ機能は既定でオフです。",
                    english: "No Pocket App is active. AI-native features are off by default."
                ))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            if settings.aiNativeEnabled,
               let generationController = aiNativeRuntime.pocketAppGenerationController {
                Divider()
                PocketAppGenerationSettingsView(
                    controller: generationController,
                    language: language
                )
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

            Toggle(
                localized(japanese: "Voice Laneを有効化", english: "Enable Voice Lane"),
                isOn: $settings.voiceEnabled
            )
            .disabled(settings.voiceProvider == .off)

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
                        japanese: "OpenAI Realtime BYOKは任意の代替経路です。利用時だけAPI料金が発生します。CalendarとTimerはCapability Broker、ネイティブ承認、実行後readbackを通ります。",
                        english: "OpenAI Realtime BYOK is an optional alternative and incurs API charges only when used. Calendar and Timer cross Capability Broker, native approval, and post-execution readback."
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
                weatherLocationModel.requestCurrentLocation(language: language) { location in
                    if let location {
                        settings.weatherLocation = location
                    }
                }
            } label: {
                Label(
                    localized(
                        japanese: "現在地を使用",
                        english: "Use current location"
                    ),
                    systemImage: "location.fill"
                )
            }
            .disabled(weatherLocationModel.isLocating)

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
