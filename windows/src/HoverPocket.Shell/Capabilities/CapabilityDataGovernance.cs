using HoverPocket.Shell.Configuration;

namespace HoverPocket.Shell.Capabilities;

internal enum CapabilityDataRetentionPeriod
{
    SevenDays,
    ThirtyDays,
    NinetyDays,
    Forever
}

internal sealed record CapabilityLedgerRetentionSnapshot(
    int StoredReceiptCount,
    int RedactedTombstoneCount,
    int PendingCount);

internal sealed record CapabilityAuditRetentionSnapshot(
    int FileCount,
    long ByteCount);

internal sealed record CapabilityDataGovernanceSnapshot(
    int AuditFileCount,
    long AuditByteCount,
    int StoredReceiptCount,
    int RedactedTombstoneCount,
    int PendingCount,
    DateTimeOffset? LastAppliedAt);

internal sealed class CapabilityDataGovernanceController(
    CapabilityBrokerLedger ledger,
    CapabilityBrokerAuditLog auditLog)
{
    private readonly object _sync = new();
    private DateTimeOffset? _lastAppliedAt;

    public CapabilityDataGovernanceSnapshot ApplyRetention(
        CapabilityDataRetentionPeriod period,
        DateTimeOffset? now = null)
    {
        lock (_sync)
        {
            var appliedAt = now ?? DateTimeOffset.UtcNow;
            var cutoff = Duration(period) is { } duration
                ? appliedAt.Subtract(duration)
                : (DateTimeOffset?)null;
            _ = ledger.RetentionSnapshot();
            _ = auditLog.RetentionSnapshot();
            auditLog.RemoveEntries(cutoff);
            ledger.RedactCompletedReceipts(cutoff);
            _lastAppliedAt = appliedAt;
            return SnapshotLocked();
        }
    }

    public CapabilityDataGovernanceSnapshot ClearHistory(DateTimeOffset? now = null)
    {
        lock (_sync)
        {
            _ = ledger.RetentionSnapshot();
            _ = auditLog.RetentionSnapshot();
            auditLog.RemoveAllEntries();
            ledger.RedactCompletedReceipts(null, redactAll: true);
            _lastAppliedAt = now ?? DateTimeOffset.UtcNow;
            return SnapshotLocked();
        }
    }

    public CapabilityDataGovernanceSnapshot Snapshot()
    {
        lock (_sync)
        {
            return SnapshotLocked();
        }
    }

    private CapabilityDataGovernanceSnapshot SnapshotLocked()
    {
        var ledgerSnapshot = ledger.RetentionSnapshot();
        var auditSnapshot = auditLog.RetentionSnapshot();
        return new CapabilityDataGovernanceSnapshot(
            auditSnapshot.FileCount,
            auditSnapshot.ByteCount,
            ledgerSnapshot.StoredReceiptCount,
            ledgerSnapshot.RedactedTombstoneCount,
            ledgerSnapshot.PendingCount,
            _lastAppliedAt);
    }

    private static TimeSpan? Duration(CapabilityDataRetentionPeriod period) => period switch
    {
        CapabilityDataRetentionPeriod.SevenDays => TimeSpan.FromDays(7),
        CapabilityDataRetentionPeriod.ThirtyDays => TimeSpan.FromDays(30),
        CapabilityDataRetentionPeriod.NinetyDays => TimeSpan.FromDays(90),
        CapabilityDataRetentionPeriod.Forever => null,
        _ => throw new ArgumentOutOfRangeException(nameof(period))
    };
}
