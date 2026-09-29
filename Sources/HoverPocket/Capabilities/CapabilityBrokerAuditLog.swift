import CryptoKit
import Darwin
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
    private let lock = NSLock()

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
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw CapabilityBrokerError.ledgerUnavailable
            }
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
        try synchronized {
            let fileURL = fileURL(for: timestamp)
            do {
                var data = try encoder.encode(entry)
                data.append(0x0A)
                let descriptor = open(fileURL.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0o600)
                guard descriptor >= 0 else {
                    throw CapabilityBrokerError.ledgerUnavailable
                }
                var status = stat()
                guard fstat(descriptor, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else {
                    close(descriptor)
                    throw CapabilityBrokerError.ledgerUnavailable
                }
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                defer { try? handle.close() }
                try handle.write(contentsOf: data)
                try handle.synchronize()
            } catch let error as CapabilityBrokerError {
                throw error
            } catch {
                throw CapabilityBrokerError.ledgerUnavailable
            }
        }
    }

    func combinedData() throws -> Data {
        try synchronized {
            var result = Data()
            for file in try auditFilesLocked().map(\.url) {
                result.append(try Data(contentsOf: file))
            }
            return result
        }
    }

    @discardableResult
    func removeEntries(olderThan cutoff: Date?) throws -> Int {
        guard let cutoff else { return 0 }
        return try synchronized {
            let cutoffDay = calendar.startOfDay(for: cutoff)
            let targets = try auditFilesLocked().filter { $0.day < cutoffDay }
            for target in targets {
                try FileManager.default.removeItem(at: target.url)
            }
            return targets.count
        }
    }

    @discardableResult
    func removeAllEntries() throws -> Int {
        try synchronized {
            let targets = try auditFilesLocked()
            for target in targets {
                try FileManager.default.removeItem(at: target.url)
            }
            return targets.count
        }
    }

    func retentionSnapshot() throws -> CapabilityAuditRetentionSnapshot {
        try synchronized {
            let files = try auditFilesLocked()
            return CapabilityAuditRetentionSnapshot(
                fileCount: files.count,
                byteCount: files.reduce(into: 0) { result, file in
                    result += file.byteCount
                }
            )
        }
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

    private func auditFilesLocked() throws -> [(url: URL, day: Date, byteCount: Int64)] {
        do {
            let candidates = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                options: []
            )
            var files: [(URL, Date, Int64)] = []
            for candidate in candidates {
                let name = candidate.lastPathComponent
                guard name.hasPrefix("capability-") || candidate.pathExtension == "jsonl" else {
                    continue
                }
                guard let day = dayFromStrictFilename(name) else {
                    throw CapabilityBrokerError.ledgerUnavailable
                }
                try validateRegularFile(candidate)
                let values = try candidate.resourceValues(forKeys: [.fileSizeKey])
                files.append((candidate, day, Int64(values.fileSize ?? 0)))
            }
            return files.sorted { $0.0.lastPathComponent < $1.0.lastPathComponent }
        } catch let error as CapabilityBrokerError {
            throw error
        } catch {
            throw CapabilityBrokerError.ledgerUnavailable
        }
    }

    private func dayFromStrictFilename(_ name: String) -> Date? {
        let prefix = "capability-"
        let suffix = ".jsonl"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        let start = name.index(name.startIndex, offsetBy: prefix.count)
        let end = name.index(name.endIndex, offsetBy: -suffix.count)
        let digits = name[start..<end]
        guard digits.count == 8, digits.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let year = Int(digits.prefix(4)),
              let month = Int(digits.dropFirst(4).prefix(2)),
              let day = Int(digits.suffix(2)),
              let date = calendar.date(from: DateComponents(
                  calendar: calendar,
                  timeZone: calendar.timeZone,
                  year: year,
                  month: month,
                  day: day
              )) else {
            return nil
        }
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard components.year == year, components.month == month, components.day == day else {
            return nil
        }
        return date
    }

    private func validateRegularFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw CapabilityBrokerError.ledgerUnavailable
        }
    }

    private func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
