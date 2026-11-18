import Foundation
import WebKit

enum AiUsageCodexReader {
    static func read() async -> AiUsageResult {
        do {
            let executable = try CodexExecutableResolver.resolve(nil)
            let profile = try CodexVoiceAppServerProfile.prepare(executableURL: executable)
            try Task.checkCancellation()
            let client = try await CodexAppServerClient.start(options: .init(
                executableURL: executable, launchArguments: ["app-server", "--stdio"],
                processEnvironment: profile.processEnvironment, workingDirectoryURL: profile.codexHomeURL,
                requestTimeout: 20, clientName: "hover_pocket_usage", clientTitle: "HoverPocket AI Usage",
                clientVersion: "1", experimentalAPI: true
            ))
            let result: AiUsageResult
            do {
                result = try await read(client)
            } catch {
                await client.close()
                throw error
            }
            await client.close()
            return result
        } catch let failure as AiUsageFailure {
            return .failure(failure)
        } catch CodexAppServerClientError.executableNotFound, CodexAppServerClientError.executableNotRunnable {
            return .failure(.codexMissing)
        } catch CodexAppServerClientError.requestTimedOut {
            return .failure(.timeout)
        } catch {
            return .failure(.unavailable)
        }
    }

    static func read(_ client: CodexAppServerClient) async throws -> AiUsageResult {
        let response = try await client.sendRequest("account/read", params: .object(["refreshToken": .bool(false)]))
        guard let account = try AiUsageParsers.codexAccount(response) else { return .signedOut }
        let limits = try await client.sendRequest(
            "account/rateLimits/read", params: .object(["excludeResetCreditDetails": .bool(true)])
        )
        return .success(try AiUsageParsers.codex(limits, account: account))
    }
}

@MainActor
final class AiUsageWebReader {
    static let shared = AiUsageWebReader()
    private var museAction: String?

    static func robots(_ service: AiUsageService) -> URL? {
        let host = switch service {
        case .claude: "claude.ai"
        case .claudeAPI: "platform.claude.com"
        case .gemini: "gemini.google.com"
        case .colab: "colab.research.google.com"
        case .muse: "muse.ai"
        case .codex: ""
        }
        return host.isEmpty ? nil : URL(string: "https://\(host)/robots.txt")
    }

    static func signInURL(_ service: AiUsageService) -> URL? {
        switch service {
        case .claude: URL(string: "https://claude.ai/login")
        case .claudeAPI: URL(string: "https://platform.claude.com/login")
        case .gemini: URL(string: "https://accounts.google.com/ServiceLogin?continue=https%3A%2F%2Fgemini.google.com%2Fusage")
        case .muse: URL(string: "https://muse.ai/")
        case .codex, .colab: nil
        }
    }

    static func expectedHost(_ host: String, for service: AiUsageService) -> Bool {
        let host = host.lowercased()
        if ["accounts.google.com", "appleid.apple.com", "login.microsoftonline.com", "login.live.com"].contains(host) {
            return true
        }
        let expected: [String] = switch service {
        case .claude, .claudeAPI: ["claude.ai", "anthropic.com", "claude.com"]
        case .gemini: ["google.com"]
        case .muse: ["muse.ai"]
        default: []
        }
        return expected.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    func read(_ service: AiUsageService) async -> AiUsageResult {
        guard let robots = Self.robots(service) else { return .failure(.unavailable) }
        let session = AiUsageWebSession(robots: robots, store: AiUsageWebProfiles.store(for: service))
        return await read(service, session: session)
    }

    #if DEBUG
    func readAnonymously(_ service: AiUsageService, observe: @escaping (AiUsageWebSession.Observation) -> Void) async -> AiUsageResult {
        guard let robots = Self.robots(service) else { return .failure(.unavailable) }
        let session = AiUsageWebSession(robots: robots, store: .nonPersistent(), readOnly: true)
        session.observe = observe
        return await read(service, session: session)
    }
    #endif

    private func read(_ service: AiUsageService, session: AiUsageWebSession) async -> AiUsageResult {
        do {
            try await session.open()
            switch service {
            case .claude, .claudeAPI:
                return try await readClaude(session, console: service == .claudeAPI)
            case .gemini:
                let response = try await session.fetch(Self.geminiPath)
                if let error = Self.classify(response) { return error }
                return try AiUsageParsers.gemini(response.body).map(AiUsageResult.success) ?? .signedOut
            case .colab:
                let response = try await session.fetch("/tun/m/ccu-info?authuser=0")
                if let error = Self.classify(response, colab: true) { return error }
                return .success(try AiUsageParsers.colab(response.body))
            case .muse:
                return try await readMuse(session)
            case .codex:
                return .failure(.unavailable)
            }
        } catch let failure as AiUsageFailure {
            return .failure(failure)
        } catch {
            return .failure(.network)
        }
    }

    private func readClaude(_ session: AiUsageWebSession, console: Bool) async throws -> AiUsageResult {
        let organizations = try await session.fetch("/api/organizations")
        if let result = Self.classify(organizations) { return result }
        let selected = try AiUsageParsers.claudeOrganization(AiUsageParsers.json(organizations.body), console: console)
        let path = "/api/organizations/\(selected.id)" + (console ? "/prepaid/credits" : "/usage")
        let response = try await session.fetch(path)
        if let result = Self.classify(response, billing: console) { return result }
        let json = try AiUsageParsers.json(response.body)
        return .success(try console ? AiUsageParsers.claudeCredits(json) : AiUsageParsers.claude(json, plan: selected.plan))
    }

    static func classify(
        _ response: AiUsageWebResponse, colab: Bool = false, billing: Bool = false, allowsHTML: Bool = false
    ) -> AiUsageResult? {
        if response.truncated { return .failure(.changed) }
        switch response.type {
        case "opaqueredirect": return .failure(.blocked)
        case "error": return .failure(.network)
        case "timeout": return .failure(.timeout)
        default: break
        }
        switch response.status {
        case 401, 403:
            if billing { return .failure(.noAccess) }
            if colab && response.status == 401 { return .signedOut }
            let json = (try? AiUsageParsers.json(response.body)) as? AiUsageParsers.Object
            if json?["error"] is String || json?["error"] is AiUsageParsers.Object { return .signedOut }
            return .failure(.blocked)
        case 300..<400:
            return .failure(.blocked)
        case 200:
            return !allowsHTML && response.body.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<")
                ? .failure(.blocked) : nil
        default:
            return .failure(.unavailable)
        }
    }

    private static let geminiPath: String = {
        // UsagePageQuery signature from CodexBar (MIT).
        let signature = "2/dWbCvkVB0X16r9NPnxifeOAAqdCqMf0xeWvau9yPy7g="
        let variables = #"{"g1Request":{"entrypoints":["GEMINI_USAGE_SETTINGS_UPGRADE_BANNER"]},"workspaceRequest":{"recommendationsForSurfaceRequests":[]}}"#
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let query = signature.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
        let params = variables.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
        return "/_/BardChatUi/graphql/schemas/GEMINI_WEB_GRAPHQL/executeQuery?query_signature=\(query)&variables=\(params)"
    }()

    private func readMuse(_ session: AiUsageWebSession) async throws -> AiUsageResult {
        let gate = try await session.fetch("/settings", headers: ["Accept": "text/html"], cap: 1_048_576)
        if let result = Self.classify(gate, allowsHTML: true) { return result }
        if let cached = museAction {
            let response = try await postMuse(session, action: cached)
            if ![400, 404, 409].contains(response.status) { return try Self.museResult(response) }
            if museAction == cached { museAction = nil }
        }
        let page = try await session.fetch("/", headers: ["Accept": "text/html"], cap: 4 * 1_048_576)
        if let result = Self.classify(page, allowsHTML: true) { return result }
        let action = try await discoverMuseAction(in: page.body, session: session)
        let response = try await postMuse(session, action: action)
        let result = try Self.museResult(response)
        try Task.checkCancellation()
        if case .success = result { museAction = action }
        return result
    }

    private static func museResult(_ response: AiUsageWebResponse) throws -> AiUsageResult {
        if let result = classify(response) { return result }
        return .success(try AiUsageParsers.muse(response.body))
    }

    private func postMuse(_ session: AiUsageWebSession, action: String) async throws -> AiUsageWebResponse {
        try await session.fetch(
            "/", method: "POST",
            headers: ["Accept": "text/x-component", "Next-Action": action, "Content-Type": "text/plain;charset=UTF-8"],
            body: #"[{"includeAgreement":true}]"#
        )
    }

    // Adapted from CodexBar's museai provider (MIT). The UI chunk preloads a settings module.
    // The loader for that module lists separate chunks containing the subscription action ID.
    private func discoverMuseAction(in html: String, session: AiUsageWebSession) async throws -> String {
        let deadline = ContinuousClock.now + .seconds(60)
        var budget = 16 * 1_048_576
        func chunks(_ paths: ArraySlice<String>) async throws -> [String] {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw AiUsageFailure.timeout }
            let cap = min(4 * 1_048_576, budget / paths.count)
            guard cap >= 1024 else { throw AiUsageFailure.changed }
            let results = try await session.fetch(Array(paths), cap: cap)
            budget -= results.reduce(0) { $0 + $1.bytes }
            if results.contains(where: { $0.type == "timeout" }) { throw AiUsageFailure.timeout }
            return results.filter { $0.status == 200 && !$0.truncated }.map(\.body)
        }
        let paths = Self.museChunkPaths(html, limit: 160)
        var scanned: [String] = []
        var module: String?
        for offset in stride(from: 0, to: paths.count, by: 4) {
            let batch = try await chunks(paths[offset..<min(offset + 4, paths.count)])
            scanned += batch
            if module == nil {
                module = batch.lazy.compactMap(Self.museSettingsModule).first
                guard module != nil else { continue }
            } else {
                scanned = batch
            }
            guard let module else { continue }
            let nested = scanned.lazy.map { Self.museLoaderPaths($0, module: module) }.first { !$0.isEmpty }
            guard let nested else { continue }
            for index in stride(from: 0, to: nested.count, by: 4) {
                let candidates = try await chunks(nested[index..<min(index + 4, nested.count)])
                if let action = candidates.lazy.compactMap(Self.museActionID).first { return action }
            }
        }
        throw AiUsageFailure.changed
    }

    static func museChunkPaths(_ body: String, limit: Int) -> [String] {
        let regex = #/static\/(?:immutable\/)?chunks\/[a-zA-Z0-9_~.-]+\.js/#
        var seen = Set<String>()
        var paths: [String] = []
        for match in body.matches(of: regex) {
            let path = "/_next/" + match.output
            if seen.insert(path).inserted { paths.append(path) }
            if paths.count == limit { break }
        }
        return paths
    }

    static func museSettingsModule(_ body: String) -> String? {
        body.firstMatch(of: #/\.A\(([0-9]+)\)\.then\(\(\{[^}]{0,512}Settings/#).map { String($0.1) }
    }

    static func museLoaderPaths(_ body: String, module: String) -> [String] {
        let pattern = #"[,{\[]"# + NSRegularExpression.escapedPattern(for: module) + #",\w+=>\{\w+\.v\(\w+=>Promise\.all\(\[([^\]]*)"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let match = re.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
              let payload = Range(match.range(at: 1), in: body) else { return [] }
        return museChunkPaths(String(body[payload]), limit: 32)
    }

    static func museActionID(_ body: String) -> String? {
        body.firstMatch(of: #/"([0-9a-f]{40,128})",[^"]{0,200}"fetchSubscriptionAction"/#).map { String($0.1) }
    }
}
