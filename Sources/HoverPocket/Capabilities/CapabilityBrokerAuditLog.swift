import CryptoKit
import Foundation

struct CapabilityAuditEntry: Codable, Sendable {
    struct CapabilitySummary: Codable, Sendable {
        let id: String
        let version: Int
        let effect: String
    }

    struct PocketAppSummary: Codable, Sendable {
        let id: String
        let version: String
        let manifestDigest: String
    }

    struct ReadbackSummary: Codable, Sendable {
        let status: String
        let evidenceDigest: String?
    }

    let approvalDecision: String
    let approvalPolicy: String
    let auditEntryID: String
    let capability: CapabilitySummary
    let durationMilliseconds: Int
    let idempotencyReplay: Bool
    let inputDigest: String
    let invocationID: String
    let origin: String
    let permissionDecision: String
    let pocketApp: PocketAppSummary?
    let principalPseudonym: String
    let readback: ReadbackSummary
    let retryCount: Int
    let safeErrorCode: String?
    let status: String
    let timestamp: Date
    let traceID: String

    private enum CodingKeys: String, CodingKey {
        case approvalDecision
        case approvalPolicy
        case auditEntryID = "auditEntryId"
        case capability
        case durationMilliseconds = "durationMs"
        case idempotencyReplay
        case inputDigest
        case invocationID = "invocationId"
        case origin
        case permissionDecision
        case pocketApp
        case principalPseudonym
        case readback
        case retryCount
        case safeErrorCode
        case status
        case timestamp
        case traceID = "traceId"
    }
}

struct CapabilityAuthorizationAuditEntry: Codable, Sendable {
    let decision: String
    var eventType = "authorization_decision"
    let origin: String
    let planDigest: String
    let planID: String
    let pocketApp: CapabilityAuditEntry.PocketAppSummary?
    let principalPseudonym: String
    let safeErrorCode: String?
    let timestamp: Date
}

final class CapabilityBrokerAuditLog {
    private let directory: URL
    private let encoder: JSONEncoder
    private let calendar: Calendar

    init(rootDirectory: URL) throws {
        self.directory = rootDirectory.appendingPathComponent("audit", isDirectory: true)
        self.encoder = JSONEncoder()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        self.calendar = calendar
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw CapabilityBrokerError.ledgerUnavailable
        }
    }

    func append(_ entry: CapabilityAuditEntry) throws {
        try appendEncoded(entry, timestamp: entry.timestamp)
    }

    func appendAuthorization(_ entry: CapabilityAuthorizationAuditEntry) throws {
        try appendEncoded(entry, timestamp: entry.timestamp)
    }

    private func appendEncoded<T: Encodable>(_ entry: T, timestamp: Date) throws {
        let fileURL = fileURL(for: timestamp)
        do {
            var data = try encoder.encode(entry)
            data.append(0x0A)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                guard FileManager.default.createFile(
                    atPath: fileURL.path,
                    contents: nil,
                    attributes: [.posixPermissions: 0o600]
                ) else {
                    throw CapabilityBrokerError.ledgerUnavailable
                }
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch let error as CapabilityBrokerError {
            throw error
        } catch {
            throw CapabilityBrokerError.ledgerUnavailable
        }
    }

    func combinedData() throws -> Data {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("capability-") && $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var result = Data()
        for file in files {
            result.append(try Data(contentsOf: file))
        }
        return result
    }

    static func principalPseudonym(_ principal: CapabilityPrincipal) -> String {
        let source = [principal.userID, principal.pocketAppID ?? "", principal.agentSessionID ?? ""].joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
        return "principal:sha256:\(digest)"
    }

    private func fileURL(for date: Date) -> URL {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let name = String(
            format: "capability-%04d%02d%02d.jsonl",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
        return directory.appendingPathComponent(name, isDirectory: false)
    }
}
