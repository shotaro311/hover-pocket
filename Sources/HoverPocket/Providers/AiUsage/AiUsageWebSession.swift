import WebKit

struct AiUsageWebResponse: Decodable, Sendable {
    let status: Int
    let type: String
    let body: String
    let truncated: Bool
    let bytes: Int
}

@MainActor
enum AiUsageWebProfiles {
    private static let identifiers: [AiUsageService: UUID] = [
        .claude: UUID(uuidString: "389143E0-FA9B-41A9-93EE-8A4D10222A5B")!,
        .claudeAPI: UUID(uuidString: "99905BD6-6298-4EC1-9294-7D9D85DA447E")!,
        .gemini: UUID(uuidString: "9986F90E-C2D4-4496-AD28-7C5160A21480")!,
        .muse: UUID(uuidString: "96C256F9-2B4D-4D60-8D26-1582171D8E47")!
    ]
    private static var stores: [AiUsageService: WKWebsiteDataStore] = [:]

    static func identifier(for service: AiUsageService) -> UUID? {
        identifiers[service.accountOwner]
    }

    static func store(for service: AiUsageService) -> WKWebsiteDataStore {
        let owner = service.accountOwner
        if let store = stores[owner] { return store }
        guard let identifier = identifier(for: owner) else {
            preconditionFailure("A web data store is only available for web services")
        }
        let store = WKWebsiteDataStore(forIdentifier: identifier)
        stores[owner] = store
        return store
    }

    static func clear(_ service: AiUsageService) async throws {
        try Task.checkCancellation()
        await store(for: service).removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        try Task.checkCancellation()
    }
}

@MainActor
final class AiUsageWebSession: NSObject, WKNavigationDelegate {
    enum Observation {
        case document(status: Int, mimeType: String)
        case fetch(status: Int, type: String, html: Bool, truncated: Bool)
        case navigationFailure(domain: String, code: Int)
        case redirect, preventedWrite
    }

    private let webView: WKWebView
    private let robots: URL
    private let readOnly: Bool
    var observe: ((Observation) -> Void)?
    private var navigation: CheckedContinuation<Void, Error>?
    private var evaluation: CheckedContinuation<String, Error>?
    private var timeout: Task<Void, Never>?
    private var ready = false

    init(robots: URL, store: WKWebsiteDataStore, readOnly: Bool = false) {
        self.robots = robots
        self.readOnly = readOnly
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    func open() async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                navigation = continuation
                armTimeout()
                webView.load(URLRequest(url: robots, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25))
            }
        } onCancel: {
            Task { @MainActor in self.fail(CancellationError()) }
        }
    }

    private func armTimeout() {
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(25)) }
            catch { return }
            self?.fail(AiUsageFailure.timeout)
        }
    }

    private func fail(_ error: Error) {
        ready = false
        finishNavigation(.failure(error))
        finishEvaluation(.failure(error))
        webView.stopLoading()
    }

    private func finishNavigation(_ result: Result<Void, Error>) {
        guard let pending = navigation else { return }
        navigation = nil
        timeout?.cancel()
        pending.resume(with: result)
    }

    private func finishEvaluation(_ result: Result<String, Error>) {
        guard let pending = evaluation else { return }
        evaluation = nil
        timeout?.cancel()
        pending.resume(with: result)
    }

    nonisolated static func permitsRobotsNavigation(_ url: URL?, targetIsMainFrame: Bool, robots: URL) -> Bool {
        targetIsMainFrame && url == robots
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let mainFrame = action.targetFrame?.isMainFrame == true
        let allowed = navigation != nil && Self.permitsRobotsNavigation(
            action.request.url, targetIsMainFrame: mainFrame, robots: robots
        )
        decisionHandler(allowed ? .allow : .cancel)
        if !allowed, mainFrame, navigation != nil { fail(AiUsageFailure.blocked) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        // Some sites return an HTML error for robots.txt. The exact main document still
        // establishes the origin for isolated-world fetches. Page JavaScript remains disabled.
        let allowed = navigation != nil && Self.permitsRobotsNavigation(
            response.response.url, targetIsMainFrame: response.isForMainFrame, robots: robots
        )
        decisionHandler(allowed ? .allow : .cancel)
        if allowed, let http = response.response as? HTTPURLResponse {
            observe?(.document(status: http.statusCode, mimeType: http.mimeType ?? "unknown"))
        } else if !allowed, response.isForMainFrame, navigation != nil {
            fail(AiUsageFailure.blocked)
        }
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        observe?(.redirect)
        fail(AiUsageFailure.blocked)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView.url == robots, self.navigation != nil else { return }
        ready = true
        finishNavigation(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failNavigation(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failNavigation(error)
    }

    private func failNavigation(_ error: Error) {
        guard navigation != nil else { return }
        let error = error as NSError
        observe?(.navigationFailure(domain: error.domain, code: error.code))
        fail(AiUsageFailure.network)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        fail(AiUsageFailure.unavailable)
    }

    func fetch(
        _ path: String, method: String = "GET", headers: [String: String] = ["Accept": "application/json"],
        body: String = "", cap: Int = 1_048_576
    ) async throws -> AiUsageWebResponse {
        guard let first = try await fetch([path], method: method, headers: headers, body: body, cap: cap).first else {
            throw AiUsageFailure.network
        }
        return first
    }

    func fetch(
        _ paths: [String], method: String = "GET", headers: [String: String] = [:], body: String = "", cap: Int
    ) async throws -> [AiUsageWebResponse] {
        if readOnly && method != "GET" {
            observe?(.preventedWrite)
            throw AiUsageFailure.blocked
        }
        guard ready, webView.url == robots, var components = URLComponents(url: robots, resolvingAgainstBaseURL: false),
              paths.allSatisfy(Self.validPath) else { throw AiUsageFailure.blocked }
        components.path = ""
        components.query = nil
        components.fragment = nil
        guard let origin = components.string else { throw AiUsageFailure.blocked }
        let result = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                evaluation = continuation
                armTimeout()
                webView.callAsyncJavaScript(Self.fetchScript, arguments: [
                    "origin": origin, "paths": paths, "method": method, "headers": headers, "payload": body, "cap": cap
                ], in: nil, in: .world(name: "HoverPocket.AiUsage")) { [weak self] result in
                    switch result {
                    case .success(let text as String):
                        self?.finishEvaluation(.success(text))
                    default:
                        self?.fail(AiUsageFailure.network)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in self.fail(CancellationError()) }
        }
        guard let responses = try? JSONDecoder().decode([AiUsageWebResponse].self, from: Data(result.utf8)),
              responses.count == paths.count else { throw AiUsageFailure.changed }
        if let observe {
            for response in responses {
                observe(.fetch(
                    status: response.status, type: response.type,
                    html: response.body.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<"),
                    truncated: response.truncated
                ))
            }
        }
        return responses
    }

    nonisolated static func validPath(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.hasPrefix("//") && !path.contains("\\")
            && path.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    // Each call gets its own helper declarations and parameters in an isolated world.
    static let fetchScript = #"""
    if (location.origin !== origin) throw new Error("wrong origin");
    async function readCapped(response) {
        const reader = response.body?.getReader();
        const decoder = new TextDecoder();
        let body = "", bytes = 0, truncated = false;
        if (reader) {
            while (true) {
                const { value, done } = await reader.read();
                if (done) break;
                const kept = value.subarray(0, cap - bytes);
                bytes += kept.byteLength;
                body += decoder.decode(kept, { stream: true });
                if (kept.byteLength < value.byteLength) {
                    truncated = true;
                    void reader.cancel().catch(() => {});
                    break;
                }
            }
            body += decoder.decode();
        }
        return { status: response.status, type: response.type, body, truncated, bytes };
    }
    const results = await Promise.all(paths.map(async path => {
        const url = new URL(path, origin);
        if (url.origin !== origin) throw new Error("wrong origin");
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), 24000);
        try {
            return await readCapped(await fetch(url, {
                method, headers, body: method === "POST" ? payload : undefined,
                credentials: "include", mode: "same-origin", redirect: "manual",
                cache: "no-store", signal: controller.signal
            }));
        } catch {
            return { status: 0, type: controller.signal.aborted ? "timeout" : "error",
                     body: "", truncated: false, bytes: 0 };
        } finally {
            clearTimeout(timer);
        }
    }));
    return JSON.stringify(results);
    """#
}
