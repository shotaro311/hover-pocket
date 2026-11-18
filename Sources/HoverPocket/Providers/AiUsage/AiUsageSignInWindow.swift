import AppKit
import WebKit

@MainActor
final class AiUsageSignInCoordinator {
    static let shared = AiUsageSignInCoordinator()
    private var windows: [AiUsageService: AiUsageSignInWindow] = [:]

    func show(_ service: AiUsageService, language: AppLanguage, usage: AiUsageStore) {
        guard let url = AiUsageWebReader.signInURL(service),
              HoverPocketRuntimeEnvironment.shared.externalIntegrationsEnabled else { return }
        if let existing = windows[service] {
            existing.showWindow(nil)
            return
        }
        guard !usage.isChangingAccount(service) else { return }
        usage.beginAccountChange(service)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = AiUsageWebProfiles.store(for: service)
        let controller = AiUsageSignInWindow(service: service, language: language, configuration: configuration) { [weak self] in
            self?.windows[service] = nil
            usage.endAccountChange(service)
        }
        windows[service] = controller
        controller.showWindow(nil)
        controller.load(url)
    }
}

enum AiUsageSignInNavigation {
    static func allows(_ url: URL?, isMainFrame: Bool) -> Bool {
        guard isMainFrame else { return true }
        return url?.scheme?.lowercased() == "https" && url?.host != nil && url?.user == nil && url?.password == nil
    }
}

@MainActor
private final class AiUsageSignInWindow: NSWindowController, NSWindowDelegate, WKUIDelegate, WKNavigationDelegate {
    private let service: AiUsageService
    private let language: AppLanguage
    private let webView: WKWebView
    private let address = NSTextField(labelWithString: "")
    private var children: [ObjectIdentifier: AiUsageSignInWindow] = [:]
    private var didClose: (() -> Void)?

    init(
        service: AiUsageService, language: AppLanguage, configuration: WKWebViewConfiguration,
        didClose: @escaping () -> Void
    ) {
        self.service = service
        self.language = language
        self.didClose = didClose
        webView = WKWebView(frame: .zero, configuration: configuration)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 650),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        super.init(window: window)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.title = service.title + (language == .japanese ? "のサインイン" : " sign-in")
        window.contentMinSize = NSSize(width: 420, height: 380)

        let content = NSView()
        let footer = NSButton(
            title: language == .japanese ? "完了" : "Done",
            target: self, action: #selector(closeFromButton)
        )
        footer.bezelStyle = .rounded
        address.maximumNumberOfLines = 0
        address.lineBreakMode = .byCharWrapping
        address.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        address.isSelectable = true
        for view in [address, webView, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            address.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            address.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            address.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            webView.topAnchor.constraint(equalTo: address.bottomAnchor, constant: 12),
            webView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14)
        ])
        window.contentView = content
        window.center()
        webView.uiDelegate = self
        webView.navigationDelegate = self
        updateAddress(nil)

    }

    required init?(coder: NSCoder) { nil }

    func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }

    @objc private func closeFromButton() {
        window?.performClose(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let onClose = didClose else { return }
        didClose = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        let popups = Array(children.values)
        children.removeAll()
        for popup in popups { popup.close() }
        onClose()
    }

    private func updateAddress(_ url: URL?) {
        guard let url, let host = url.host else {
            address.stringValue = language == .japanese ? "接続先を確認中…" : "Waiting for the site…"
            address.textColor = .secondaryLabelColor
            return
        }
        let port = url.port ?? 443
        let expected = port == 443 && AiUsageWebReader.expectedHost(host, for: service)
        let warning = language == .japanese ? "通常と異なる接続先" : "Unexpected sign-in site"
        address.stringValue = expected ? "\(host):\(port)" : "⚠ \(host):\(port)  \(warning)"
        address.textColor = expected ? .labelColor : .systemYellow
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        // A nil target frame requests a new top-level window.
        let allowed = AiUsageSignInNavigation.allows(action.request.url, isMainFrame: action.targetFrame?.isMainFrame != false)
        decisionHandler(allowed ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        let allowed = AiUsageSignInNavigation.allows(response.response.url, isMainFrame: response.isForMainFrame)
        decisionHandler(allowed ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        updateAddress(webView.url)
    }

    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard navigationAction.targetFrame == nil,
              AiUsageSignInNavigation.allows(navigationAction.request.url, isMainFrame: true) else { return nil }
        configuration.websiteDataStore = webView.configuration.websiteDataStore
        let child = AiUsageSignInWindow(service: service, language: language, configuration: configuration) { [weak self] in
            self?.children = self?.children.filter { $0.value.didClose != nil } ?? [:]
        }
        children[ObjectIdentifier(child.webView)] = child
        child.showWindow(nil)
        return child.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        close()
    }
}
