using System.Text.Json;
using System.Text.Json.Serialization;

namespace HoverPocket.Shell.PocketApps;

internal enum PocketAppHealthStatus
{
    Healthy,
    Attention,
    Unused,
    Disabled
}

internal sealed record PocketAppHealthSnapshot(
    string PackageId,
    PocketAppHealthStatus Status,
    string ReasonCode,
    DateTimeOffset? LastUsedAt,
    DateTimeOffset? LastSuccessfulActivationAt,
    int ConsecutiveActivationFailures,
    bool DisableSuggested);

internal sealed class PocketAppHealthException(string code) : Exception(code)
{
    internal string Code { get; } = code;
}

internal sealed class PocketAppHealthStore
{
    private sealed record HealthRecord(
        int RecordVersion,
        string PackageId,
        DateTimeOffset? FirstActivatedAt,
        DateTimeOffset? LastSuccessfulActivationAt,
        DateTimeOffset? LastUsedAt,
        DateTimeOffset? LastFailureAt,
        int ConsecutiveActivationFailures,
        DateTimeOffset UpdatedAt);

    internal static readonly TimeSpan UnusedInterval = TimeSpan.FromDays(30);
    private static readonly TimeSpan UsageWriteInterval = TimeSpan.FromMinutes(5);
    private const int MaximumRecordBytes = 16 * 1024;
    private readonly string _rootDirectory;
    private readonly JsonSerializerOptions _jsonOptions = new()
    {
        PropertyNameCaseInsensitive = false,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
        MaxDepth = 8,
        WriteIndented = false
    };

    internal PocketAppHealthStore(string rootDirectory)
    {
        _rootDirectory = Path.GetFullPath(rootDirectory);
        try
        {
            Directory.CreateDirectory(_rootDirectory);
            RequireSafeRoot();
        }
        catch (PocketAppHealthException)
        {
            throw;
        }
        catch
        {
            throw Failure("HEALTH_STORAGE_FAILED");
        }
    }

    internal void RecordActivationSuccess(string packageId, DateTimeOffset? now = null)
    {
        var timestamp = now ?? DateTimeOffset.UtcNow;
        Update(packageId, timestamp, record => record with
        {
            FirstActivatedAt = record.FirstActivatedAt ?? timestamp,
            LastSuccessfulActivationAt = timestamp,
            ConsecutiveActivationFailures = 0
        });
    }

    internal void RecordActivationFailure(string packageId, DateTimeOffset? now = null)
    {
        var timestamp = now ?? DateTimeOffset.UtcNow;
        Update(packageId, timestamp, record => record with
        {
            LastFailureAt = timestamp,
            ConsecutiveActivationFailures = Math.Min(record.ConsecutiveActivationFailures + 1, 1_000)
        });
    }

    internal void RecordUse(string packageId, DateTimeOffset? now = null)
    {
        var timestamp = now ?? DateTimeOffset.UtcNow;
        if (!ValidPackageId(packageId)) { throw Failure("HEALTH_INVALID"); }
        var current = Read(packageId);
        if (current?.LastUsedAt is { } lastUsed
            && timestamp >= lastUsed
            && timestamp - lastUsed < UsageWriteInterval)
        {
            return;
        }
        Update(packageId, timestamp, record => record with
        {
            FirstActivatedAt = record.FirstActivatedAt ?? timestamp,
            LastUsedAt = timestamp
        });
    }

    internal IReadOnlyList<PocketAppHealthSnapshot> Snapshots(
        IReadOnlyList<PocketAppManagedPackage> packages,
        IReadOnlyList<PocketAppManagementIssue> issues,
        DateTimeOffset? now = null)
    {
        var timestamp = now ?? DateTimeOffset.UtcNow;
        var result = new List<PocketAppHealthSnapshot>();
        foreach (var package in packages.Where(item => item.State != PocketAppLifecycleState.Removed))
        {
            try
            {
                result.Add(Snapshot(package, Read(package.PackageId), timestamp));
            }
            catch
            {
                result.Add(new PocketAppHealthSnapshot(
                    package.PackageId,
                    PocketAppHealthStatus.Attention,
                    "HEALTH_METADATA_CORRUPT",
                    null,
                    null,
                    0,
                    false));
            }
        }
        foreach (var issue in issues)
        {
            HealthRecord? record = null;
            try { record = Read(issue.PackageId); } catch { }
            result.Add(new PocketAppHealthSnapshot(
                issue.PackageId,
                PocketAppHealthStatus.Attention,
                issue.ErrorCode,
                record?.LastUsedAt,
                record?.LastSuccessfulActivationAt,
                record?.ConsecutiveActivationFailures ?? 0,
                false));
        }
        return result.OrderBy(item => item.PackageId, StringComparer.Ordinal).ToArray();
    }

    private void Update(
        string packageId,
        DateTimeOffset now,
        Func<HealthRecord, HealthRecord> mutate)
    {
        if (!ValidPackageId(packageId)) { throw Failure("HEALTH_INVALID"); }
        var record = Read(packageId) ?? new HealthRecord(
            1,
            packageId,
            null,
            null,
            null,
            null,
            0,
            now);
        record = mutate(record) with { UpdatedAt = now };
        if (!Valid(record)) { throw Failure("HEALTH_INVALID"); }
        Write(record);
    }

    private HealthRecord? Read(string packageId)
    {
        if (!ValidPackageId(packageId)) { throw Failure("HEALTH_INVALID"); }
        RequireSafeRoot();
        var path = RecordPath(packageId);
        if (!File.Exists(path)) { return null; }
        try
        {
            var data = PocketAppFileSnapshot.ReadFileNoFollow(
                _rootDirectory,
                $"{packageId}.json",
                MaximumRecordBytes);
            var record = JsonSerializer.Deserialize<HealthRecord>(data, _jsonOptions)
                ?? throw Failure("HEALTH_INVALID");
            if (!Valid(record) || record.PackageId != packageId)
            {
                throw Failure("HEALTH_INVALID");
            }
            return record;
        }
        catch (PocketAppHealthException)
        {
            throw;
        }
        catch
        {
            throw Failure("HEALTH_INVALID");
        }
    }

    private void Write(HealthRecord record)
    {
        RequireSafeRoot();
        var data = JsonSerializer.SerializeToUtf8Bytes(record, _jsonOptions);
        if (data.Length > MaximumRecordBytes) { throw Failure("HEALTH_INVALID"); }
        var temporary = Path.Combine(_rootDirectory, $".health-{Guid.NewGuid():N}.tmp");
        var destination = RecordPath(record.PackageId);
        try
        {
            using (var stream = new FileStream(
                temporary,
                FileMode.CreateNew,
                FileAccess.Write,
                FileShare.None,
                4_096,
                FileOptions.WriteThrough))
            {
                stream.Write(data);
                stream.Flush(flushToDisk: true);
            }
            if (File.Exists(destination))
            {
                var attributes = File.GetAttributes(destination);
                if (attributes.HasFlag(FileAttributes.ReparsePoint)
                    || attributes.HasFlag(FileAttributes.Directory))
                {
                    throw Failure("HEALTH_STORAGE_FAILED");
                }
            }
            File.Move(temporary, destination, overwrite: true);
            var observed = PocketAppFileSnapshot.ReadFileNoFollow(
                _rootDirectory,
                $"{record.PackageId}.json",
                MaximumRecordBytes);
            if (!observed.AsSpan().SequenceEqual(data))
            {
                throw Failure("HEALTH_READBACK_FAILED");
            }
        }
        catch (PocketAppHealthException)
        {
            try { if (File.Exists(temporary)) { File.Delete(temporary); } } catch { }
            throw;
        }
        catch
        {
            try { if (File.Exists(temporary)) { File.Delete(temporary); } } catch { }
            throw Failure("HEALTH_STORAGE_FAILED");
        }
    }

    private void RequireSafeRoot()
    {
        var attributes = File.GetAttributes(_rootDirectory);
        if (!attributes.HasFlag(FileAttributes.Directory)
            || attributes.HasFlag(FileAttributes.ReparsePoint))
        {
            throw Failure("HEALTH_STORAGE_FAILED");
        }
    }

    private string RecordPath(string packageId) => Path.Combine(_rootDirectory, $"{packageId}.json");

    private static PocketAppHealthSnapshot Snapshot(
        PocketAppManagedPackage package,
        HealthRecord? record,
        DateTimeOffset now)
    {
        if (package.State == PocketAppLifecycleState.Disabled)
        {
            return new PocketAppHealthSnapshot(
                package.PackageId,
                PocketAppHealthStatus.Disabled,
                "APP_DISABLED",
                record?.LastUsedAt,
                record?.LastSuccessfulActivationAt,
                record?.ConsecutiveActivationFailures ?? 0,
                false);
        }
        if (record is { ConsecutiveActivationFailures: >= 3 } failed)
        {
            return new PocketAppHealthSnapshot(
                package.PackageId,
                PocketAppHealthStatus.Attention,
                "ACTIVATION_FAILURES",
                failed.LastUsedAt,
                failed.LastSuccessfulActivationAt,
                failed.ConsecutiveActivationFailures,
                false);
        }
        var inactivityReference = record?.LastUsedAt ?? record?.FirstActivatedAt;
        var unused = inactivityReference is { } reference && now - reference >= UnusedInterval;
        return new PocketAppHealthSnapshot(
            package.PackageId,
            unused ? PocketAppHealthStatus.Unused : PocketAppHealthStatus.Healthy,
            unused ? "UNUSED_30_DAYS" : "HEALTHY",
            record?.LastUsedAt,
            record?.LastSuccessfulActivationAt,
            record?.ConsecutiveActivationFailures ?? 0,
            unused);
    }

    private static bool Valid(HealthRecord record)
    {
        var dates = new[]
        {
            record.FirstActivatedAt,
            record.LastSuccessfulActivationAt,
            record.LastUsedAt,
            record.LastFailureAt
        }.Where(value => value is not null).Select(value => value!.Value);
        return record.RecordVersion == 1
            && ValidPackageId(record.PackageId)
            && record.ConsecutiveActivationFailures is >= 0 and <= 1_000
            && dates.All(value => value <= record.UpdatedAt)
            && !(record.FirstActivatedAt is { } first
                && record.LastSuccessfulActivationAt is { } success
                && success < first);
    }

    private static bool ValidPackageId(string value) =>
        value.Length <= 160
        && System.Text.RegularExpressions.Regex.IsMatch(
            value,
            "^[a-z][a-z0-9]*(?:\\.[a-z0-9][a-z0-9-]*){2,}$",
            System.Text.RegularExpressions.RegexOptions.CultureInvariant);

    private static PocketAppHealthException Failure(string code) => new(code);
}
