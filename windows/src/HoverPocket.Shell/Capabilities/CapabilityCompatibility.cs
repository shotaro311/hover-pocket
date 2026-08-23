using System.Text.RegularExpressions;

namespace HoverPocket.Shell.Capabilities;

internal enum PocketCapabilityLifecycleStatus
{
    Active,
    Deprecated,
    Removed
}

internal sealed record PocketCapabilityLifecycleRecord(
    PocketCapabilityKey Key,
    PocketCapabilityLifecycleStatus Status,
    string IntroducedInHostVersion,
    string? DeprecatedInHostVersion,
    string? RemovalNotBeforeHostVersion,
    PocketCapabilityKey? Replacement,
    string? MigrationId,
    string NoticeKey);

internal sealed record PocketCapabilityReferenceMigration(
    string Id,
    PocketCapabilityKey Source,
    PocketCapabilityKey Target);

internal sealed record PocketCapabilityCompatibilityIssue(
    PocketCapabilityKey Key,
    PocketCapabilityLifecycleStatus Status,
    PocketCapabilityKey Replacement,
    string MigrationId,
    string RemovalNotBeforeHostVersion,
    string NoticeKey);

internal sealed class PocketCapabilityCompatibilityException(string code) : Exception(code)
{
    public string Code { get; } = code;
}

internal sealed class PocketCapabilityCompatibilityCatalog
{
    internal const string CurrentHostVersion = "1.0.0";

    private static readonly Regex CapabilityIdPattern = new(
        "^[a-z][a-z0-9]*(?:\\.[a-z][a-z0-9_]*){2,}$",
        RegexOptions.CultureInvariant | RegexOptions.NonBacktracking);
    private static readonly Regex MigrationIdPattern = new(
        "^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)+$",
        RegexOptions.CultureInvariant | RegexOptions.NonBacktracking);
    private static readonly Regex NoticeKeyPattern = new(
        "^[a-z][a-z0-9]*(?:\\.[a-z0-9_-]+)+$",
        RegexOptions.CultureInvariant | RegexOptions.NonBacktracking);

    private readonly IReadOnlyDictionary<PocketCapabilityKey, PocketCapabilityLifecycleRecord> _records;
    private readonly IReadOnlyDictionary<PocketCapabilityKey, PocketCapabilityReferenceMigration> _migrations;

    internal static PocketCapabilityCompatibilityCatalog BuiltIn { get; } = new(
        CurrentHostVersion,
        [],
        []);

    internal PocketCapabilityCompatibilityCatalog(
        string hostVersion,
        IEnumerable<PocketCapabilityLifecycleRecord> records,
        IEnumerable<PocketCapabilityReferenceMigration> migrations)
    {
        if (SemanticVersion(hostVersion) is null)
        {
            throw Failure("host_version");
        }

        var recordMap = new Dictionary<PocketCapabilityKey, PocketCapabilityLifecycleRecord>();
        foreach (var record in records)
        {
            if (!ValidKey(record.Key)
                || SemanticVersion(record.IntroducedInHostVersion) is null
                || !recordMap.TryAdd(record.Key, record))
            {
                throw Failure("record");
            }
            Validate(record, hostVersion);
        }

        var migrationMap = new Dictionary<PocketCapabilityKey, PocketCapabilityReferenceMigration>();
        var migrationIds = new HashSet<string>(StringComparer.Ordinal);
        foreach (var migration in migrations)
        {
            if (!ValidMigrationId(migration.Id)
                || !ValidKey(migration.Source)
                || !ValidKey(migration.Target)
                || migration.Source == migration.Target
                || !migrationMap.TryAdd(migration.Source, migration)
                || !migrationIds.Add(migration.Id))
            {
                throw Failure("migration");
            }
            if (!recordMap.TryGetValue(migration.Source, out var record)
                || record.Status == PocketCapabilityLifecycleStatus.Active
                || record.Replacement != migration.Target
                || record.MigrationId != migration.Id)
            {
                throw Failure("migration_binding");
            }
        }

        foreach (var record in recordMap.Values.Where(item => item.Status != PocketCapabilityLifecycleStatus.Active))
        {
            if (!migrationMap.ContainsKey(record.Key))
            {
                throw Failure("migration_missing");
            }
            if (record.Replacement is not { } replacement
                || (recordMap.TryGetValue(replacement, out var target)
                    && target.Status == PocketCapabilityLifecycleStatus.Removed))
            {
                throw Failure("replacement_removed");
            }
        }

        foreach (var source in migrationMap.Keys)
        {
            var visited = new HashSet<PocketCapabilityKey> { source };
            var current = migrationMap[source].Target;
            while (migrationMap.TryGetValue(current, out var next))
            {
                if (!visited.Add(current))
                {
                    throw Failure("migration_cycle");
                }
                current = next.Target;
            }
        }

        HostVersion = hostVersion;
        _records = recordMap;
        _migrations = migrationMap;
    }

    internal string HostVersion { get; }

    internal PocketCapabilityLifecycleStatus Status(PocketCapabilityKey key) =>
        _records.TryGetValue(key, out var record) ? record.Status : PocketCapabilityLifecycleStatus.Active;

    internal PocketCapabilityCompatibilityIssue? Issue(PocketCapabilityKey key)
    {
        if (!_records.TryGetValue(key, out var record)
            || record.Status == PocketCapabilityLifecycleStatus.Active
            || record.Replacement is not { } replacement
            || record.MigrationId is not { } migrationId
            || record.RemovalNotBeforeHostVersion is not { } removalNotBefore)
        {
            return null;
        }
        return new PocketCapabilityCompatibilityIssue(
            key,
            record.Status,
            replacement,
            migrationId,
            removalNotBefore,
            record.NoticeKey);
    }

    internal PocketCapabilityReferenceMigration Migration(PocketCapabilityKey key) =>
        _migrations.TryGetValue(key, out var migration)
            ? migration
            : throw Failure("migration_unavailable");

    internal void RequireRuntimeExecutable(PocketCapabilityKey key)
    {
        if (_records.TryGetValue(key, out var record)
            && record.Status == PocketCapabilityLifecycleStatus.Removed)
        {
            var field = record.Replacement is { } replacement
                ? $"{key.Id}@{key.Version}->{replacement.Id}@{replacement.Version}"
                : $"{key.Id}@{key.Version}";
            throw new CapabilityBrokerException("CAPABILITY_REMOVED", field);
        }
    }

    private static void Validate(PocketCapabilityLifecycleRecord record, string hostVersion)
    {
        var introduced = SemanticVersion(record.IntroducedInHostVersion);
        var host = SemanticVersion(hostVersion);
        if (!ValidNoticeKey(record.NoticeKey)
            || introduced is null
            || host is null
            || introduced > host)
        {
            throw Failure("record_version");
        }

        if (record.Status == PocketCapabilityLifecycleStatus.Active)
        {
            if (record.DeprecatedInHostVersion is not null
                || record.RemovalNotBeforeHostVersion is not null
                || record.Replacement is not null
                || record.MigrationId is not null)
            {
                throw Failure("active_fields");
            }
            return;
        }

        var deprecated = SemanticVersion(record.DeprecatedInHostVersion);
        var removal = SemanticVersion(record.RemovalNotBeforeHostVersion);
        if (deprecated is null
            || removal is null
            || record.Replacement is not { } replacement
            || !ValidKey(replacement)
            || replacement == record.Key
            || record.MigrationId is not { } migrationId
            || !ValidMigrationId(migrationId)
            || introduced > deprecated
            || deprecated > host
            || deprecated >= removal)
        {
            throw Failure("deprecation_window");
        }
        if (record.Status == PocketCapabilityLifecycleStatus.Removed && host < removal)
        {
            throw Failure("removed_too_early");
        }
    }

    private static bool ValidKey(PocketCapabilityKey key) =>
        key.Version >= 1 && CapabilityIdPattern.IsMatch(key.Id);

    private static bool ValidMigrationId(string value) =>
        value.Length <= 128 && MigrationIdPattern.IsMatch(value);

    private static bool ValidNoticeKey(string value) =>
        value.Length <= 160 && NoticeKeyPattern.IsMatch(value);

    private static Version? SemanticVersion(string? value) =>
        value is not null
        && Regex.IsMatch(value, "^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$", RegexOptions.CultureInvariant)
        && Version.TryParse(value, out var version)
            ? version
            : null;

    private static PocketCapabilityCompatibilityException Failure(string code) => new(code);
}
