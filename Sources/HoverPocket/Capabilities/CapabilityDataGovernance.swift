import Foundation

enum CapabilityDataRetentionPeriod: String, CaseIterable, Codable, Identifiable, Sendable {
    case sevenDays
    case thirtyDays
    case ninetyDays
    case forever

    var id: String { rawValue }

    fileprivate var duration: TimeInterval? {
        switch self {
        case .sevenDays:
            return 7 * 24 * 60 * 60
        case .thirtyDays:
            return 30 * 24 * 60 * 60
        case .ninetyDays:
            return 90 * 24 * 60 * 60
        case .forever:
            return nil
        }
    }

    func title(language: AppLanguage) -> String {
        switch (self, language) {
        case (.sevenDays, .japanese): "7日"
        case (.sevenDays, .english): "7 days"
        case (.thirtyDays, .japanese): "30日"
        case (.thirtyDays, .english): "30 days"
        case (.ninetyDays, .japanese): "90日"
        case (.ninetyDays, .english): "90 days"
        case (.forever, .japanese): "無期限"
        case (.forever, .english): "Forever"
        }
    }
}

struct CapabilityLedgerRetentionSnapshot: Equatable, Sendable {
    let storedReceiptCount: Int
    let redactedTombstoneCount: Int
    let pendingCount: Int
}

struct CapabilityAuditRetentionSnapshot: Equatable, Sendable {
    let fileCount: Int
    let byteCount: Int64
}

struct CapabilityDataGovernanceSnapshot: Equatable, Sendable {
    let auditFileCount: Int
    let auditByteCount: Int64
    let storedReceiptCount: Int
    let redactedTombstoneCount: Int
    let pendingCount: Int
    let lastAppliedAt: Date?
}

final class CapabilityDataGovernanceController {
    private let ledger: CapabilityBrokerLedger
    private let auditLog: CapabilityBrokerAuditLog
    private let lock = NSLock()
    private var lastAppliedAt: Date?

    init(ledger: CapabilityBrokerLedger, auditLog: CapabilityBrokerAuditLog) {
        self.ledger = ledger
        self.auditLog = auditLog
    }

    @discardableResult
    func applyRetention(
        _ period: CapabilityDataRetentionPeriod,
        now: Date = Date()
    ) throws -> CapabilityDataGovernanceSnapshot {
        try synchronized {
            let cutoff = period.duration.map { now.addingTimeInterval(-$0) }
            _ = ledger.retentionSnapshot()
            _ = try auditLog.retentionSnapshot()
            try auditLog.removeEntries(olderThan: cutoff)
            try ledger.redactCompletedReceipts(olderThan: cutoff)
            lastAppliedAt = now
            return try snapshotLocked()
        }
    }

    @discardableResult
    func clearHistory(now: Date = Date()) throws -> CapabilityDataGovernanceSnapshot {
        try synchronized {
            _ = ledger.retentionSnapshot()
            _ = try auditLog.retentionSnapshot()
            try auditLog.removeAllEntries()
            try ledger.redactCompletedReceipts(olderThan: nil, redactAll: true)
            lastAppliedAt = now
            return try snapshotLocked()
        }
    }

    func snapshot() throws -> CapabilityDataGovernanceSnapshot {
        try synchronized {
            try snapshotLocked()
        }
    }

    private func snapshotLocked() throws -> CapabilityDataGovernanceSnapshot {
        let ledgerSnapshot = ledger.retentionSnapshot()
        let auditSnapshot = try auditLog.retentionSnapshot()
        return CapabilityDataGovernanceSnapshot(
            auditFileCount: auditSnapshot.fileCount,
            auditByteCount: auditSnapshot.byteCount,
            storedReceiptCount: ledgerSnapshot.storedReceiptCount,
            redactedTombstoneCount: ledgerSnapshot.redactedTombstoneCount,
            pendingCount: ledgerSnapshot.pendingCount,
            lastAppliedAt: lastAppliedAt
        )
    }

    private func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
