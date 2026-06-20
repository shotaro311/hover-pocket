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
