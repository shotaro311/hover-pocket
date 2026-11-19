import SwiftUI

struct AiUsageSettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var usage: AiUsageStore
    @ObservedObject var codexAccount: CodexVoiceAccountLoginController
    @State private var signOutError: AiUsageService?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(copy.text("AI使用状況", "AI usage")).font(.headline)
            ForEach(settings.aiUsageServiceOrder) { service in
                if service != settings.aiUsageServiceOrder.first { Divider() }
                row(service)
            }
        }
    }

    private var copy: AiUsageCopy { .init(language: settings.appLanguage) }

    private func row(_ service: AiUsageService) -> some View {
        let state = usage.snapshot(service)
        let changing = usage.isChangingAccount(service)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top) {
                Text(service.title).fontWeight(.semibold)
                Text(heading(state: state, changing: changing))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                orderButton(service, offset: -1)
                orderButton(service, offset: 1)
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

    private func orderButton(_ service: AiUsageService, offset: Int) -> some View {
        let label = offset < 0 ? copy.text("上へ", "Move up") : copy.text("下へ", "Move down")
        let allowed = settings.canStepAiUsageService(service, by: offset)
        return Button {
            settings.stepAiUsageService(service, by: offset)
        } label: {
            Image(systemName: offset < 0 ? "arrow.up" : "arrow.down")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!allowed)
        .opacity(allowed ? 1 : 0.45)
        .help(label)
        .accessibilityLabel(label)
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
