import AppKit
import AuthenticationServices
import CryptoKit
import Foundation
import Security

struct GoogleOAuthConfiguration: Equatable, Sendable {
    let googleSignInClientID: String?
    let legacyClientID: String?
    let legacyClientSecret: String?
    let chromeProfileDirectory: String?
    let chromeUserDataDirectory: String?
    let chromeRemoteDebuggingPort: String?

    static var current: GoogleOAuthConfiguration? {
        let googleSignInClientID = Self.trimmedInfoValue("GIDClientID")
        let legacyClientID = Self.trimmedInfoValue("GoogleOAuthClientID")
        guard googleSignInClientID != nil || legacyClientID != nil else {
            return nil
        }

        return GoogleOAuthConfiguration(
            googleSignInClientID: googleSignInClientID,
            legacyClientID: legacyClientID,
            legacyClientSecret: Self.trimmedInfoValue("GoogleOAuthClientSecret"),
            chromeProfileDirectory: Self.trimmedInfoValue("GoogleOAuthChromeProfileDirectory"),
            chromeUserDataDirectory: Self.trimmedInfoValue("GoogleOAuthChromeUserDataDirectory"),
            chromeRemoteDebuggingPort: Self.trimmedInfoValue("GoogleOAuthChromeRemoteDebuggingPort")
        )
    }

    var shouldOpenWithChrome: Bool {
        chromeProfileDirectory != nil || chromeUserDataDirectory != nil || chromeRemoteDebuggingPort != nil
    }

    var oauthClientID: String? {
        googleSignInClientID ?? legacyClientID
    }

    var usesNativeAppOAuth: Bool {
        googleSignInClientID != nil
    }

    var nativeCallbackScheme: String? {
        guard let googleSignInClientID else { return nil }
        return Self.reversedClientID(googleSignInClientID)
    }

    var nativeRedirectURI: String? {
        guard let nativeCallbackScheme else { return nil }
        return "\(nativeCallbackScheme):/oauth2redirect/google"
    }

    private static func trimmedInfoValue(_ key: String) -> String? {
        let rawValue = Bundle.main.object(forInfoDictionaryKey: key) as? String
        let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    private static func reversedClientID(_ clientID: String) -> String {
        clientID
            .split(separator: ".")
            .reversed()
            .joined(separator: ".")
    }
}

struct GoogleOAuthToken: Codable, Equatable, Sendable {
    let accessToken: String
    let expiresAt: Date
    let grantedScopes: [String]

    var isFresh: Bool {
        expiresAt.timeIntervalSinceNow > 60
    }
}

enum GoogleOAuthStoredCredentialStatus: Equatable {
    case missing
    case needsReconnect
    case ready
}

enum GoogleOAuthError: LocalizedError {
    case missingConfiguration
    case browserOpenFailed
    case missingAuthorizationCode
    case stateMismatch
    case userDenied(String)
    case missingRefreshToken
    case insufficientScopes
    case tokenEndpointFailed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "Google OAuth client ID is not configured."
        case .browserOpenFailed:
            return "Could not open the Google sign-in page."
        case .missingAuthorizationCode:
            return "Google did not return an authorization code."
        case .stateMismatch:
            return "Google sign-in state validation failed."
        case .userDenied(let message):
            return message
        case .missingRefreshToken:
            return "Google did not return a refresh token."
        case .insufficientScopes:
            return "Reconnect Google Calendar to allow event editing."
        case .tokenEndpointFailed(let message):
            return message
        case .timedOut:
            return "Google sign-in timed out."
        }
    }
}

final class GoogleOAuthService: @unchecked Sendable {
    static let calendarScopes = [
        "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
        "https://www.googleapis.com/auth/calendar.events"
    ]

    private let keychain = GoogleOAuthKeychainStore()
    private let tokenLock = NSLock()
    private var currentToken: GoogleOAuthToken?
    private var nativeOAuthSession: ASWebAuthenticationSession?
    private var nativeOAuthPresentationProvider: NativeOAuthPresentationProvider?

    var isConfigured: Bool {
        GoogleOAuthConfiguration.current != nil
    }

    func hasStoredCredential() -> Bool {
        storedCredentialStatus() != .missing
    }

    func hasRequiredCalendarCredential() -> Bool {
        storedCredentialStatus() == .ready
    }

    func storedCredentialStatus() -> GoogleOAuthStoredCredentialStatus {
        guard let credential = try? keychain.load() else {
            return .missing
        }
        return Self.hasRequiredCalendarScopes(credential.grantedScopes) ? .ready : .needsReconnect
    }

    func signIn() async throws {
        guard let configuration = GoogleOAuthConfiguration.current else {
            throw GoogleOAuthError.missingConfiguration
        }

        if configuration.usesNativeAppOAuth {
            try await signInWithNativeAppOAuth(configuration: configuration)
            return
        }

        try await signInWithLegacyOAuth(configuration: configuration)
    }

    func signOut() {
        let refreshToken = try? keychain.load()?.refreshToken
        setCurrentToken(nil)
        keychain.delete()
        if let refreshToken {
            Task.detached(priority: .utility) {
                try? await Self.revokeToken(refreshToken)
            }
        }
    }

    func accessToken() async throws -> String {
        guard GoogleOAuthConfiguration.current != nil else {
            throw GoogleOAuthError.missingConfiguration
        }
        return try await legacyAccessToken()
    }

    private func signInWithLegacyOAuth(configuration: GoogleOAuthConfiguration) async throws {
        guard configuration.legacyClientID != nil else {
            throw GoogleOAuthError.missingConfiguration
        }

        let receiver = try LoopbackOAuthReceiver()
        let state = try randomBase64URL(byteCount: 32)
        let verifier = try randomBase64URL(byteCount: 64)
        let challenge = codeChallenge(for: verifier)
        let authURL = try authorizationURL(
            configuration: configuration,
            redirectURI: receiver.redirectURI,
            state: state,
            codeChallenge: challenge
        )

        let opened = await openAuthorizationURL(authURL, configuration: configuration)
        guard opened else {
            receiver.cancel()
            throw GoogleOAuthError.browserOpenFailed
        }

        let callback = try await waitForCallback(receiver)
        if let error = callback.error {
            throw GoogleOAuthError.userDenied(error)
        }
        guard callback.state == state else {
            throw GoogleOAuthError.stateMismatch
        }
        guard let code = callback.code, !code.isEmpty else {
            throw GoogleOAuthError.missingAuthorizationCode
        }

        let response = try await exchangeAuthorizationCode(
            code,
            verifier: verifier,
            redirectURI: receiver.redirectURI,
            configuration: configuration
        )
        guard let refreshToken = response.refreshToken, !refreshToken.isEmpty else {
            throw GoogleOAuthError.missingRefreshToken
        }

        let scopes = response.scope?.split(separator: " ").map(String.init) ?? Self.calendarScopes
        try keychain.save(
            GoogleOAuthStoredCredential(refreshToken: refreshToken, grantedScopes: scopes)
        )
        setCurrentToken(GoogleOAuthToken(
            accessToken: response.accessToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(response.expiresIn)),
            grantedScopes: scopes
        ))
    }

    private func legacyAccessToken() async throws -> String {
        if let currentToken = readCurrentToken(), currentToken.isFresh {
            guard Self.hasRequiredCalendarScopes(currentToken.grantedScopes) else {
                throw GoogleOAuthError.insufficientScopes
            }
            return currentToken.accessToken
        }

        guard let credential = try keychain.load() else {
            throw GoogleOAuthError.missingRefreshToken
        }
        guard Self.hasRequiredCalendarScopes(credential.grantedScopes) else {
            throw GoogleOAuthError.insufficientScopes
        }
        let refreshed = try await refreshAccessToken(refreshToken: credential.refreshToken)
        let scopes = refreshed.scope?.split(separator: " ").map(String.init) ?? credential.grantedScopes
        guard Self.hasRequiredCalendarScopes(scopes) else {
            throw GoogleOAuthError.insufficientScopes
        }
        let token = GoogleOAuthToken(
            accessToken: refreshed.accessToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(refreshed.expiresIn)),
            grantedScopes: scopes
        )
        setCurrentToken(token)
        return token.accessToken
    }

    private func readCurrentToken() -> GoogleOAuthToken? {
        tokenLock.lock()
        defer { tokenLock.unlock() }
        return currentToken
    }

    private func setCurrentToken(_ token: GoogleOAuthToken?) {
        tokenLock.lock()
        currentToken = token
        tokenLock.unlock()
    }

    private func waitForCallback(_ receiver: LoopbackOAuthReceiver) async throws -> OAuthCallback {
        try await withThrowingTaskGroup(of: OAuthCallback.self) { group in
            group.addTask {
                try await receiver.waitForCallback()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(180))
                receiver.cancel()
                throw GoogleOAuthError.timedOut
            }

            guard let result = try await group.next() else {
                throw GoogleOAuthError.timedOut
            }
            group.cancelAll()
            return result
        }
    }

    private func authorizationURL(
        configuration: GoogleOAuthConfiguration,
        redirectURI: String,
        state: String,
        codeChallenge: String
    ) throws -> URL {
        guard let clientID = configuration.oauthClientID else {
            throw GoogleOAuthError.missingConfiguration
        }

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.calendarScopes.joined(separator: " ")),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "include_granted_scopes", value: "true"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        return components.url!
    }

    @MainActor
    private func openAuthorizationURL(_ url: URL, configuration: GoogleOAuthConfiguration) async -> Bool {
        guard configuration.shouldOpenWithChrome else {
            return NSWorkspace.shared.open(url)
        }

        guard let chromeURL = chromeApplicationURL() else {
            return NSWorkspace.shared.open(url)
        }

        var arguments: [String] = []
        if let userDataDirectory = configuration.chromeUserDataDirectory {
            arguments.append("--user-data-dir=\(userDataDirectory)")
        }
        if let profileDirectory = configuration.chromeProfileDirectory {
            arguments.append("--profile-directory=\(profileDirectory)")
        }
        if let remoteDebuggingPort = configuration.chromeRemoteDebuggingPort {
            arguments.append("--remote-debugging-port=\(remoteDebuggingPort)")
        }
        arguments.append(url.absoluteString)

        do {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-na", chromeURL.path, "--args"] + arguments
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    @MainActor
    private func chromeApplicationURL() -> URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") {
            return url
        }

        let fallbackURL = URL(fileURLWithPath: "/Applications/Google Chrome.app")
        return FileManager.default.fileExists(atPath: fallbackURL.path) ? fallbackURL : nil
    }

    private func signInWithNativeAppOAuth(configuration: GoogleOAuthConfiguration) async throws {
        guard
            let redirectURI = configuration.nativeRedirectURI,
            let callbackScheme = configuration.nativeCallbackScheme
        else {
            throw GoogleOAuthError.missingConfiguration
        }

        let state = try randomBase64URL(byteCount: 32)
        let verifier = try randomBase64URL(byteCount: 64)
        let challenge = codeChallenge(for: verifier)
        let authURL = try authorizationURL(
            configuration: configuration,
            redirectURI: redirectURI,
            state: state,
            codeChallenge: challenge
        )

        let callback = try await runNativeOAuthSession(
            url: authURL,
            callbackScheme: callbackScheme
        )
        if let error = callback.error {
            throw GoogleOAuthError.userDenied(error)
        }
        guard callback.state == state else {
            throw GoogleOAuthError.stateMismatch
        }
        guard let code = callback.code, !code.isEmpty else {
            throw GoogleOAuthError.missingAuthorizationCode
        }

        let response = try await exchangeAuthorizationCode(
            code,
            verifier: verifier,
            redirectURI: redirectURI,
            configuration: configuration
        )
        guard let refreshToken = response.refreshToken, !refreshToken.isEmpty else {
            throw GoogleOAuthError.missingRefreshToken
        }

        let scopes = response.scope?.split(separator: " ").map(String.init) ?? Self.calendarScopes
        try keychain.save(
            GoogleOAuthStoredCredential(refreshToken: refreshToken, grantedScopes: scopes)
        )
        setCurrentToken(GoogleOAuthToken(
            accessToken: response.accessToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(response.expiresIn)),
            grantedScopes: scopes
        ))
    }

    private func runNativeOAuthSession(url: URL, callbackScheme: String) async throws -> OAuthCallback {
        let window = await presentationWindowForNativeOAuth()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<OAuthCallback, Error>) in
            let completion: (URL?, Error?) -> Void = { [weak self] callbackURL, error in
                DispatchQueue.main.async {
                    self?.nativeOAuthSession = nil
                    self?.nativeOAuthPresentationProvider = nil
                }

                if let error {
                    continuation.resume(throwing: GoogleOAuthError.userDenied(error.localizedDescription))
                    return
                }
                guard let callbackURL, let callback = Self.oauthCallback(from: callbackURL) else {
                    continuation.resume(throwing: GoogleOAuthError.missingAuthorizationCode)
                    return
                }
                continuation.resume(returning: callback)
            }

            Task { @MainActor in
                let provider = NativeOAuthPresentationProvider(window: window)
                let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme, completionHandler: completion)
                session.presentationContextProvider = provider
                session.prefersEphemeralWebBrowserSession = false
                nativeOAuthPresentationProvider = provider
                nativeOAuthSession = session
                guard session.start() else {
                    nativeOAuthSession = nil
                    nativeOAuthPresentationProvider = nil
                    continuation.resume(throwing: GoogleOAuthError.browserOpenFailed)
                    return
                }
            }
        }
    }

    private static func oauthCallback(from url: URL) -> OAuthCallback? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let items = components.queryItems ?? []
        return OAuthCallback(
            code: items.first { $0.name == "code" }?.value,
            state: items.first { $0.name == "state" }?.value,
            error: items.first { $0.name == "error" }?.value
        )
    }

    @MainActor
    private func presentationWindowForNativeOAuth() -> NSWindow {
        let app = NSApplication.shared
        if let keyWindow = app.keyWindow {
            return keyWindow
        }
        if let mainWindow = app.mainWindow {
            return mainWindow
        }
        if let visibleWindow = app.windows.first(where: { $0.isVisible }) {
            return visibleWindow
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 120),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "HoverPocket Google Sign-In"
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        return window
    }

    private func exchangeAuthorizationCode(
        _ code: String,
        verifier: String,
        redirectURI: String,
        configuration: GoogleOAuthConfiguration
    ) async throws -> GoogleOAuthTokenResponse {
        guard let clientID = configuration.oauthClientID else {
            throw GoogleOAuthError.missingConfiguration
        }

        var form = [
            "client_id": clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI
        ]
        if !configuration.usesNativeAppOAuth, let clientSecret = configuration.legacyClientSecret {
            form["client_secret"] = clientSecret
        }
        return try await postTokenRequest(form: form)
    }

    private func refreshAccessToken(refreshToken: String) async throws -> GoogleOAuthTokenResponse {
        guard let configuration = GoogleOAuthConfiguration.current,
              let clientID = configuration.oauthClientID else {
            throw GoogleOAuthError.missingConfiguration
        }
        var form = [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken
        ]
        if !configuration.usesNativeAppOAuth, let clientSecret = configuration.legacyClientSecret {
            form["client_secret"] = clientSecret
        }
        return try await postTokenRequest(form: form)
    }

    private static func revokeToken(_ token: String) async throws {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "token=\(formEscape(token))".data(using: .utf8)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return
        }
    }

    private func postTokenRequest(form: [String: String]) async throws -> GoogleOAuthTokenResponse {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = percentEncodedForm(form).data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let error = (try? JSONDecoder().decode(GoogleOAuthErrorResponse.self, from: data))?.safeDescription
            throw GoogleOAuthError.tokenEndpointFailed(error ?? "Google token request failed.")
        }

        do {
            return try JSONDecoder().decode(GoogleOAuthTokenResponse.self, from: data)
        } catch {
            throw GoogleOAuthError.tokenEndpointFailed("Google token response could not be read.")
        }
    }

    private func randomBase64URL(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw GoogleOAuthKeychainError.unhandledStatus(status)
        }
        return Data(bytes).base64URLEncodedString()
    }

    private func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }

    private func percentEncodedForm(_ values: [String: String]) -> String {
        values
            .sorted { $0.key < $1.key }
            .map { "\(formEscape($0.key))=\(formEscape($0.value))" }
            .joined(separator: "&")
    }

    private func formEscape(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":#[]@!$&'()*+,;=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func formEscape(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":#[]@!$&'()*+,;=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func hasRequiredCalendarScopes(_ scopes: [String]) -> Bool {
        let granted = Set(scopes)
        return calendarScopes.allSatisfy { granted.contains($0) }
    }
}

private final class NativeOAuthPresentationProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let window: NSWindow

    init(window: NSWindow) {
        self.window = window
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        window
    }
}

private struct GoogleOAuthTokenResponse: Decodable {
    let accessToken: String
    let expiresIn: Int
    let refreshToken: String?
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case scope
    }
}

private struct GoogleOAuthErrorResponse: Decodable {
    let error: String?
    let errorDescription: String?

    var safeDescription: String {
        errorDescription ?? error ?? "Google authorization failed."
    }

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
