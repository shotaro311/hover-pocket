import SwiftUI

struct AiUsagePanelView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var usage: AiUsageStore
    let isActive: Bool
    let openSettings: () -> Void
    @Environment(\.panelTextSize) private var textSize

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if visible.contains(where: { usage.snapshot($0).refreshing }) {
                    ProgressView().controlSize(.mini)
                }
                Spacer()
                Button(action: { usage.refresh(visible, force: true) }) {
                    Label(copy.text("更新", "Refresh"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(visible.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

            if visible.isEmpty {
                ContentUnavailableView {
                    Text(copy.text("表示するサービスがありません", "No services to show"))
                } actions: {
                    Button(copy.text("AI設定を開く", "Open AI settings"), action: openSettings)
                }
            } else {
                ScrollView {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        VStack(spacing: 8) {
                            ForEach(visible) { service in
                                serviceCard(service, now: context.date)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 12)
                    }
                }
            }
        }
        .font(.system(size: textSize.scaled(12)))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: isActive, initial: true) { _, active in
            if active { usage.refresh(visible) }
        }
    }

    private var visible: [AiUsageService] {
        AiUsageService.allCases.filter { !settings.hiddenAiUsageServices.contains($0) }
    }

    private var copy: AiUsageCopy { .init(language: settings.appLanguage) }

    private func serviceCard(_ service: AiUsageService, now: Date) -> some View {
        let state = usage.snapshot(service)
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(service.title).fontWeight(.semibold)
                Spacer()
                if let plan = state.reading?.plan { Text(plan).foregroundStyle(.secondary) }
            }
            if let reading = state.reading {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(reading.windows.enumerated()), id: \.offset) { _, window in
                        windowRow(window, now: now)
                    }
                    ForEach(Array(reading.balances.enumerated()), id: \.offset) { _, balance in
                        balanceRow(balance, now: now)
                    }
                }
                .opacity(state.stale ? 0.60 : 1)
            }
            if case .failure(let error) = state.status {
                if state.stale, let instant = state.fetchedAt {
                    Text(copy.stale(instant))
                        .foregroundStyle(.yellow)
                }
                Text(copy.error(error)).foregroundStyle(.secondary)
            } else if state.status == .signedOut {
                HStack {
                    Text(copy.text("サインインしていません", "Signed out"))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(copy.text("設定でサインイン", "Sign in from Settings"), action: openSettings)
                        .buttonStyle(.borderless)
                }
            } else if state.reading == nil {
                Text(usage.isChangingAccount(service) ? copy.accountChanging : state.refreshing ? copy.checking : copy.unchecked)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private func windowRow(_ window: AiUsageWindow, now: Date) -> some View {
        let level = copy.level(window.percent)
        let tint: Color = switch level {
        case .critical: .red
        case .warning: .yellow
        case .normal: .blue
        }
        let elapsed = copy.elapsed(window, now: now)
        let reset = copy.reset(window.resetsAt, now: now)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(copy.windowLabel(window))
                Spacer()
                Text(copy.percent(window.percent)).monospacedDigit()
                    .foregroundStyle(level == .normal ? Color.primary : tint)
            }
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.13))
                    Capsule().fill(tint).frame(width: width * window.percent / 100)
                    if let elapsed {
                        Rectangle().fill(.white.opacity(0.95))
                            .frame(width: 2, height: 8)
                            .offset(x: max(0, (width - 2) * elapsed))
                            .help(copy.elapsedLabel(elapsed))
                    }
                }
            }
            .frame(height: 7)
            .accessibilityHidden(true)
            Text(window.kind == .weekly && elapsed != nil
                 ? reset + " · " + (elapsed.map(copy.elapsedLabel) ?? "") : reset)
                .font(.system(size: textSize.scaled(10)))
                .foregroundStyle(.secondary)
        }
    }

    private func balanceRow(_ balance: AiUsageBalance, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(copy.balanceLabel(balance))
                Spacer()
                Text(copy.balanceValue(balance)).monospacedDigit()
            }
            if let detail = copy.balanceDetail(balance, now: now) {
                Text(detail).font(.system(size: textSize.scaled(10))).foregroundStyle(.secondary)
            }
        }
    }
}

struct AiUsageSettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var usage: AiUsageStore
    @ObservedObject var codexAccount: CodexVoiceAccountLoginController
    @State private var signOutError: AiUsageService?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(copy.text("AI使用状況", "AI usage")).font(.headline)
            ForEach(AiUsageService.allCases) { service in
                if service != .codex { Divider() }
                row(service)
            }
        }
    }

    private var copy: AiUsageCopy { .init(language: settings.appLanguage) }

    private func row(_ service: AiUsageService) -> some View {
        let state = usage.snapshot(service)
        let changing = usage.isChangingAccount(service)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(service.title).fontWeight(.semibold)
                Text(heading(state: state, changing: changing))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Toggle(copy.text("\(service.title)を表示", "Show \(service.title)"), isOn: Binding(
                    get: { !settings.hiddenAiUsageServices.contains(service) },
                    set: { visible in
                        if visible {
                            settings.hiddenAiUsageServices.remove(service)
                            usage.refresh([service])
                        } else {
                            settings.hiddenAiUsageServices.insert(service)
                        }
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
            }
            if let error = errorMessage(service, state: state) {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if service == .codex {
                    codexActions(state)
                } else if service.hasWebSignIn {
                    let signedIn = Self.canSignOut(service, usage: usage)
                    Button(state.status == .ready ? copy.text("サインインし直す", "Sign in again") : copy.text("サインイン", "Sign in")) {
                        AiUsageSignInCoordinator.shared.show(service, language: settings.appLanguage, usage: usage)
                    }
                    .disabled(changing)
                    if signedIn {
                        Button(copy.text("サインアウト", "Sign out")) {
                            signOutError = nil
                            Task {
                                do { try await usage.signOut(service) { try await AiUsageWebProfiles.clear(service) } }
                                catch { signOutError = service }
                            }
                        }
                        .disabled(changing)
                    }
                }
                if let detail = detail(service) {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 3)
    }

    static func canSignOut(_ service: AiUsageService, usage: AiUsageStore) -> Bool {
        service.hasWebSignIn && service.sharedServices.contains {
            switch usage.snapshot($0).status {
            case .ready, .failure: true
            case .idle, .signedOut: false
            }
        }
    }

    private func heading(state: AiUsageSnapshot, changing: Bool) -> String {
        if changing { return copy.accountChanging }
        if state.refreshing { return copy.checking }
        switch state.status {
        case .ready:
            let status = copy.text("サインイン済み", "Signed in")
            return state.reading?.plan.map { status + " · " + $0 } ?? status
        case .signedOut: return copy.text("サインインしていません", "Signed out")
        case .failure: return copy.text("読み取りエラー", "Could not read usage")
        case .idle: return copy.unchecked
        }
    }

    private func errorMessage(_ service: AiUsageService, state: AiUsageSnapshot) -> String? {
        if signOutError == service { return copy.text("サインアウトを完了できませんでした。", "Sign-out could not be completed.") }
        if case .failure(let error) = state.status { return copy.error(error) }
        return nil
    }

    @ViewBuilder
    private func codexActions(_ state: AiUsageSnapshot) -> some View {
        switch codexAccount.state {
        case .signingIn:
            Button(copy.text("キャンセル", "Cancel")) { codexAccount.cancelLogin() }
            Text(copy.text("ブラウザでChatGPTへログインしてください。", "Complete ChatGPT sign-in in your browser."))
                .font(.caption).foregroundStyle(.secondary)
        case .checking:
            Text(copy.checking).font(.caption).foregroundStyle(.secondary)
        case .failed:
            Button(copy.text("再試行", "Try again")) { codexAccount.startLogin() }
            Text(copy.text("ChatGPTログインを完了できませんでした。", "ChatGPT sign-in could not be completed."))
                .font(.caption).foregroundStyle(.secondary)
        case .signedOut(false, _):
            Text(copy.text("CodexアプリでChatGPTにログインしてください。", "Sign in with ChatGPT in the Codex app."))
                .font(.caption).foregroundStyle(.secondary)
            Button(copy.text("再確認", "Check again")) {
                codexAccount.refresh()
                usage.refresh([.codex], force: true)
            }
        default:
            if state.reading == nil {
                Button(copy.text("ChatGPTでログイン", "Sign in with ChatGPT")) { codexAccount.startLogin() }
            }
        }
    }

    private func detail(_ service: AiUsageService) -> String? {
        switch service {
        case .codex: copy.text("チャット・音声と同じChatGPTログインを使います。", "Uses the ChatGPT sign-in shared with chat and voice.")
        case .claudeAPI: copy.text("Claude Consoleに個別にサインインします。", "Sign in to Claude Console separately.")
        case .colab: copy.text("Geminiと同じGoogleアカウントを使います。複数ある場合は最初のアカウントを表示します。",
                               "Uses the Gemini Google sign-in. If there are several accounts, shows the first one.")
        default: nil
        }
    }
}
