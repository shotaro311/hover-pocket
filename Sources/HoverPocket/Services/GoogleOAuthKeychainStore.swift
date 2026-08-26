import Foundation
import LocalAuthentication
import Security

struct GoogleOAuthStoredCredential: Codable, Equatable, Sendable {
    let refreshToken: String
    let grantedScopes: [String]
}

enum GoogleOAuthKeychainError: Error {
    case encodeFailed
    case decodeFailed
    case unhandledStatus(OSStatus)
}

final class GoogleOAuthKeychainStore: @unchecked Sendable {
    private static let serviceBase = "local.codex.hover-pocket.google-oauth"
    private static let serviceSuffixInfoKey = "HoverPocketKeychainServiceSuffix"
    private static let fallbackServiceSuffix = "release"

    private let service: String
    private let legacyFileKeychainServices: [String] = []
    private let account = "default"

    init() {
        let configuredSuffix = Bundle.main.object(forInfoDictionaryKey: Self.serviceSuffixInfoKey) as? String
        let suffix = configuredSuffix?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        let serviceSuffix = suffix?.isEmpty == false ? suffix! : Self.fallbackServiceSuffix
        service = "\(Self.serviceBase).\(serviceSuffix)"
    }

    func load() throws -> GoogleOAuthStoredCredential? {
        if let credential = try load(service: service) {
            return credential
        }

        for legacyService in legacyFileKeychainServices {
            if let credential = try load(service: legacyService) {
                try? save(credential)
                return credential
            }
        }

        return nil
    }

    func save(_ credential: GoogleOAuthStoredCredential) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(credential)
        } catch {
            throw GoogleOAuthKeychainError.encodeFailed
        }

        let query = baseQuery(service: service, allowsAuthenticationUI: false)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if Self.isNonInteractiveAccessFailure(updateStatus) || updateStatus == errSecDuplicateItem {
            try replaceExistingItem(with: data)
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw GoogleOAuthKeychainError.unhandledStatus(updateStatus)
        }

        try add(data)
    }

    func delete() {
        SecItemDelete(baseQuery(service: service, allowsAuthenticationUI: false) as CFDictionary)
    }

    private func load(service: String) throws -> GoogleOAuthStoredCredential? {
        var query = baseQuery(service: service, allowsAuthenticationUI: false)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        if Self.isNonInteractiveAccessFailure(status) {
            return nil
        }
        guard status == errSecSuccess else {
            throw GoogleOAuthKeychainError.unhandledStatus(status)
        }
        guard let data = item as? Data else {
            throw GoogleOAuthKeychainError.decodeFailed
        }
        do {
            return try JSONDecoder().decode(GoogleOAuthStoredCredential.self, from: data)
        } catch {
            throw GoogleOAuthKeychainError.decodeFailed
        }
    }

    private func add(_ data: Data) throws {
        var query = baseQuery(service: service, allowsAuthenticationUI: false)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(query as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return
        }
        if addStatus == errSecDuplicateItem || Self.isNonInteractiveAccessFailure(addStatus) {
            try replaceExistingItem(with: data)
            return
        }
        throw GoogleOAuthKeychainError.unhandledStatus(addStatus)
    }

    private func replaceExistingItem(with data: Data) throws {
        SecItemDelete(baseQuery(service: service, allowsAuthenticationUI: false) as CFDictionary)

        var query = baseQuery(service: service, allowsAuthenticationUI: false)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw GoogleOAuthKeychainError.unhandledStatus(addStatus)
        }
    }

    private func baseQuery(service: String, allowsAuthenticationUI: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if !allowsAuthenticationUI {
            query[kSecUseAuthenticationContext as String] = Self.nonInteractiveAuthenticationContext()
        }
        return query
    }

    private static func nonInteractiveAuthenticationContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }

    private static func isNonInteractiveAccessFailure(_ status: OSStatus) -> Bool {
        status == errSecInteractionNotAllowed ||
            status == errSecAuthFailed ||
            status == errSecUserCanceled ||
            status == errSecMissingEntitlement
    }
}

final class OpenAIRealtimeAPIKey: @unchecked Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    private var bytes: Data

    init(_ value: String) throws {
        let scalarCount = value.unicodeScalars.count
        guard (20...512).contains(scalarCount),
              !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) else {
            throw OpenAIRealtimeKeychainError.invalidKey
        }
        bytes = Data(value.utf8)
    }

    func withUTF8Bytes<T>(_ body: (Data) throws -> T) rethrows -> T {
        try body(bytes)
    }

    var description: String { "[redacted]" }
    var debugDescription: String { "[redacted]" }

    deinit {
        bytes.resetBytes(in: 0..<bytes.count)
    }
}

enum OpenAIRealtimeKeychainError: Error {
    case invalidKey
    case decodeFailed
    case deletionNotConfirmed
    case unhandledStatus(OSStatus)
}

final class OpenAIRealtimeKeychainStore: OpenAIRealtimeCredentialStoring, @unchecked Sendable {
    private static let serviceBase = "local.codex.hover-pocket.openai-realtime"
    private static let serviceSuffixInfoKey = "HoverPocketKeychainServiceSuffix"
    private static let fallbackServiceSuffix = "release"
    private let service: String
    private let account = "default"

    init() {
        let configuredSuffix = Bundle.main.object(forInfoDictionaryKey: Self.serviceSuffixInfoKey) as? String
        let suffix = configuredSuffix?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        let serviceSuffix = suffix?.isEmpty == false ? suffix! : Self.fallbackServiceSuffix
        service = "\(Self.serviceBase).\(serviceSuffix)"
    }

    func hasCredential() throws -> Bool {
        var query = baseQuery()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return false
        }
        guard status == errSecSuccess else {
            throw OpenAIRealtimeKeychainError.unhandledStatus(status)
        }
        return true
    }

    func load() throws -> OpenAIRealtimeAPIKey? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound || Self.isNonInteractiveAccessFailure(status) {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data, data.count <= 2_048,
              let value = String(data: data, encoding: .utf8) else {
            throw status == errSecSuccess
                ? OpenAIRealtimeKeychainError.decodeFailed
                : OpenAIRealtimeKeychainError.unhandledStatus(status)
        }
        return try OpenAIRealtimeAPIKey(value)
    }

    func save(_ apiKey: OpenAIRealtimeAPIKey) throws {
        try apiKey.withUTF8Bytes { data in
            let query = baseQuery()
            let attributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ]
            let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if update == errSecSuccess { return }
            guard update == errSecItemNotFound else {
                throw OpenAIRealtimeKeychainError.unhandledStatus(update)
            }
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else {
                throw OpenAIRealtimeKeychainError.unhandledStatus(status)
            }
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw OpenAIRealtimeKeychainError.unhandledStatus(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseAuthenticationContext as String: Self.nonInteractiveAuthenticationContext()
        ]
    }

    private static func nonInteractiveAuthenticationContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }

    private static func isNonInteractiveAccessFailure(_ status: OSStatus) -> Bool {
        status == errSecInteractionNotAllowed ||
            status == errSecAuthFailed ||
            status == errSecUserCanceled ||
            status == errSecMissingEntitlement
    }
}
