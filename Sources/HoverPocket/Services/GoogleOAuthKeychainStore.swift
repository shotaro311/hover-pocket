import Foundation
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
    private let service = "local.codex.hover-pocket.google-oauth"
    private let legacyServices = [
        "local.codex.notch-pocket.google-oauth",
        "local.codex.hover-menu-preview.google-oauth"
    ]
    private let account = "default"

    func load() throws -> GoogleOAuthStoredCredential? {
        if let credential = try load(service: service) {
            return credential
        }

        for legacyService in legacyServices {
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

        var query = baseQuery(service: service)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw GoogleOAuthKeychainError.unhandledStatus(updateStatus)
        }

        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw GoogleOAuthKeychainError.unhandledStatus(addStatus)
        }
    }

    func delete() {
        SecItemDelete(baseQuery(service: service) as CFDictionary)
        for legacyService in legacyServices {
            SecItemDelete(baseQuery(service: legacyService) as CFDictionary)
        }
    }

    private func load(service: String) throws -> GoogleOAuthStoredCredential? {
        var query = baseQuery(service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
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

    private func baseQuery(service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
