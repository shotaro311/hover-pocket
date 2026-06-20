import Foundation

enum AuditLogEvent: String, Codable, Sendable {
    case planned
    case candidateSelected
    case approvalRequested
    case approved
    case rejected
    case executed
    case failed
}

struct AuditLogEntry: Codable, Sendable {
    let id: UUID
    let event: AuditLogEvent
    let action: PocketAction?
    let result: ToolResult?
    let message: String?
    let createdAt: Date
}

@MainActor
final class AuditLog {
    static let shared = AuditLog()

    private let fileURL: URL

    init(fileManager: FileManager = .default) {
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
        let directory = baseURL
            .appendingPathComponent("HoverPocket", isDirectory: true)
            .appendingPathComponent("AuditLog", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("audit-log.jsonl")
    }

    func record(
        _ event: AuditLogEvent,
        action: PocketAction? = nil,
        result: ToolResult? = nil,
        message: String? = nil
    ) {
        let entry = AuditLogEntry(
            id: UUID(),
            event: event,
            action: action,
            result: result,
            message: message,
            createdAt: Date()
        )

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var data = try encoder.encode(entry)
            data.append(0x0a)
            try append(data)
        } catch {
            NSLog("HoverPocket audit log write failed: \(error.localizedDescription)")
        }
    }

    private func append(_ data: Data) throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } else {
            try data.write(to: fileURL, options: .atomic)
        }
    }
}
