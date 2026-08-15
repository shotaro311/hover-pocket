import Foundation

enum PocketStableKey {
    static let maximumScalars = 96
    private static let namespacePattern = "^[a-z][a-z0-9-]{0,31}$"
    private static let keyPattern = "^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$"

    static func validate(_ value: String) throws -> String {
        guard value.unicodeScalars.count <= maximumScalars,
              value.unicodeScalars.allSatisfy({ $0.value < 0x80 }),
              value.firstIndex(of: ":") == value.lastIndex(of: ":"),
              let separator = value.firstIndex(of: ":") else {
            throw CapabilityBrokerError.invalidPlan("stable_key")
        }
        let namespace = String(value[..<separator])
        let key = String(value[value.index(after: separator)...])
        guard matches(namespace, namespacePattern), matches(key, keyPattern) else {
            throw CapabilityBrokerError.invalidPlan("stable_key")
        }
        return value
    }

    static func namespace(_ value: String) throws -> String {
        _ = try validate(value)
        return String(value[..<value.firstIndex(of: ":")!])
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}
