using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace HoverPocket.Shell.Capabilities;

internal enum CapabilityLedgerStartKind
{
    Execute,
    Replay,
    Unknown
}

internal sealed record CapabilityLedgerStart<T>(CapabilityLedgerStartKind Kind, T? Receipt = default);

internal sealed class CapabilityBrokerLedger
{
    private enum RecordState
    {
        Pending,
        Completed
    }

    private sealed record InvocationRecord(
        string PlanDigest,
        string ArgumentDigest,
        PocketCapabilityKey Capability,
        RecordState State,
        CapabilityReceipt? Receipt,
        DateTimeOffset? CompletedAt);

    private sealed record WorkflowRecord(
        string PlanDigest,
        RecordState State,
        CapabilityWorkflowReceipt? Receipt,
        DateTimeOffset? CompletedAt);

    private sealed class LedgerState
    {
        public int Version { get; set; } = 2;
        public Dictionary<string, InvocationRecord> Invocations { get; set; } = new(StringComparer.Ordinal);
        public Dictionary<string, WorkflowRecord> Workflows { get; set; } = new(StringComparer.Ordinal);
    }

    private static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = false
    };

    private readonly string _filePath;
    private readonly object _sync = new();

    private LedgerState _state;

    public CapabilityBrokerLedger(string rootDirectory)
    {
        try
        {
            Directory.CreateDirectory(rootDirectory);
            _filePath = Path.Combine(rootDirectory, "capability-broker-ledger.json");
            _state = File.Exists(_filePath)
                ? JsonSerializer.Deserialize<LedgerState>(File.ReadAllBytes(_filePath), Options)
                    ?? throw Unavailable()
                : new LedgerState();
            if (_state.Version is not 1 and not 2)
            {
                throw Unavailable();
            }
            if (_state.Version == 1)
            {
                foreach (var key in _state.Invocations.Keys.ToArray())
                {
                    var record = _state.Invocations[key];
                    _state.Invocations[key] = record with { CompletedAt = record.Receipt?.CompletedAt };
                }
                foreach (var key in _state.Workflows.Keys.ToArray())
                {
                    var record = _state.Workflows[key];
                    _state.Workflows[key] = record with { CompletedAt = record.Receipt?.CompletedAt };
                }
                _state.Version = 2;
                Persist();
            }
        }
        catch (CapabilityBrokerException)
        {
            throw;
        }
        catch
        {
            throw Unavailable();
        }
    }

    public CapabilityLedgerStart<CapabilityReceipt> BeginInvocation(
        string idempotencyKey,
        string planDigest,
        string argumentDigest,
        PocketCapabilityKey capability)
    {
        lock (_sync)
        {
            if (_state.Invocations.TryGetValue(idempotencyKey, out var existing))
            {
                if (existing.PlanDigest != planDigest
                    || existing.ArgumentDigest != argumentDigest
                    || existing.Capability != capability)
                {
                    throw new CapabilityBrokerException("CAPABILITY_IDEMPOTENCY_CONFLICT", idempotencyKey);
                }
                return existing.State == RecordState.Completed && existing.Receipt is not null
                    ? new CapabilityLedgerStart<CapabilityReceipt>(CapabilityLedgerStartKind.Replay, existing.Receipt.ReplayCopy())
                    : new CapabilityLedgerStart<CapabilityReceipt>(CapabilityLedgerStartKind.Unknown);
            }
            _state.Invocations[idempotencyKey] = new InvocationRecord(
                planDigest,
                argumentDigest,
                capability,
                RecordState.Pending,
                null,
                null);
            Persist();
            return new CapabilityLedgerStart<CapabilityReceipt>(CapabilityLedgerStartKind.Execute);
        }
    }

    public void CompleteInvocation(string idempotencyKey, CapabilityReceipt receipt)
    {
        lock (_sync)
        {
            if (!_state.Invocations.TryGetValue(idempotencyKey, out var existing)
                || existing.PlanDigest != receipt.PlanDigest
                || existing.Capability != receipt.Capability)
            {
                throw Unavailable();
            }
            _state.Invocations[idempotencyKey] = existing with
            {
                State = RecordState.Completed,
                Receipt = receipt.DurableCopy(),
                CompletedAt = receipt.CompletedAt
            };
            Persist();
        }
    }

    public CapabilityLedgerStart<CapabilityWorkflowReceipt> LookupWorkflow(string planId, string planDigest)
    {
        lock (_sync)
        {
            if (!_state.Workflows.TryGetValue(planId, out var existing))
            {
                return new CapabilityLedgerStart<CapabilityWorkflowReceipt>(CapabilityLedgerStartKind.Execute);
            }
            if (existing.PlanDigest != planDigest)
            {
                throw new CapabilityBrokerException("CAPABILITY_IDEMPOTENCY_CONFLICT", planId);
            }
            return existing.State == RecordState.Completed && existing.Receipt is not null
                ? new CapabilityLedgerStart<CapabilityWorkflowReceipt>(CapabilityLedgerStartKind.Replay, existing.Receipt.ReplayCopy())
                : new CapabilityLedgerStart<CapabilityWorkflowReceipt>(CapabilityLedgerStartKind.Unknown);
        }
    }

    public void StartWorkflow(string planId, string planDigest)
    {
        lock (_sync)
        {
            if (!_state.Workflows.TryAdd(planId, new WorkflowRecord(planDigest, RecordState.Pending, null, null)))
            {
                throw new CapabilityBrokerException("CAPABILITY_IDEMPOTENCY_CONFLICT", planId);
            }
            Persist();
        }
    }

    public void CompleteWorkflow(CapabilityWorkflowReceipt receipt)
    {
        lock (_sync)
        {
            if (!_state.Workflows.TryGetValue(receipt.PlanId, out var existing)
                || existing.PlanDigest != receipt.PlanDigest)
            {
                throw Unavailable();
            }
            _state.Workflows[receipt.PlanId] = existing with
            {
                State = RecordState.Completed,
                Receipt = receipt.DurableCopy(),
                CompletedAt = receipt.CompletedAt
            };
            Persist();
        }
    }

    public int RedactCompletedReceipts(DateTimeOffset? olderThan, bool redactAll = false)
    {
        lock (_sync)
        {
            var redacted = 0;
            foreach (var key in _state.Invocations.Keys.ToArray())
            {
                var record = _state.Invocations[key];
                if (record.State != RecordState.Completed
                    || record.Receipt is null
                    || (!redactAll && (olderThan is null || (record.CompletedAt ?? DateTimeOffset.MinValue) >= olderThan.Value)))
                {
                    continue;
                }
                _state.Invocations[key] = record with { Receipt = null, CompletedAt = null };
                redacted += 1;
            }
            foreach (var key in _state.Workflows.Keys.ToArray())
            {
                var record = _state.Workflows[key];
                if (record.State != RecordState.Completed
                    || record.Receipt is null
                    || (!redactAll && (olderThan is null || (record.CompletedAt ?? DateTimeOffset.MinValue) >= olderThan.Value)))
                {
                    continue;
                }
                _state.Workflows[key] = record with { Receipt = null, CompletedAt = null };
                redacted += 1;
            }
            if (redacted > 0)
            {
                Persist();
            }
            return redacted;
        }
    }

    public CapabilityLedgerRetentionSnapshot RetentionSnapshot()
    {
        lock (_sync)
        {
            var records = _state.Invocations.Values
                .Select(record => (record.State, HasReceipt: record.Receipt is not null))
                .Concat(_state.Workflows.Values.Select(record => (record.State, HasReceipt: record.Receipt is not null)))
                .ToArray();
            return new CapabilityLedgerRetentionSnapshot(
                records.Count(record => record.State == RecordState.Completed && record.HasReceipt),
                records.Count(record => record.State == RecordState.Completed && !record.HasReceipt),
                records.Count(record => record.State == RecordState.Pending));
        }
    }

    private void Persist()
    {
        try
        {
            var data = JsonSerializer.SerializeToUtf8Bytes(_state, Options);
            var temporary = _filePath + ".tmp";
            File.WriteAllBytes(temporary, data);
            File.Move(temporary, _filePath, overwrite: true);
        }
        catch
        {
            throw Unavailable();
        }
    }

    private static CapabilityBrokerException Unavailable() =>
        new("CAPABILITY_LEDGER_UNAVAILABLE", "ledger");
}

internal enum CapabilityApprovalDecision
{
    Approve,
    Reject
}

internal sealed class CapabilityApprovalStore(TimeSpan? timeToLive = null)
{
    private sealed record IssuedGrant(
        string PlanId,
        string PlanDigest,
        CapabilityPrincipal Principal,
        CapabilityAppContext? AppContext,
        IReadOnlySet<string> Permissions,
        DateTimeOffset ExpiresAt);

    private readonly TimeSpan _timeToLive = timeToLive ?? TimeSpan.FromMinutes(5);
    private readonly Dictionary<string, CapabilityApprovalRequest> _pending = new(StringComparer.Ordinal);
    private readonly Dictionary<string, IssuedGrant> _grants = new(StringComparer.Ordinal);
    private readonly HashSet<string> _consumedTokens = new(StringComparer.Ordinal);
    private readonly object _sync = new();

    public CapabilityApprovalRequest? PendingRequest(string requestId)
    {
        lock (_sync)
        {
            return _pending.GetValueOrDefault(requestId);
        }
    }

    public void DiscardPending(string requestId)
    {
        lock (_sync)
        {
            _pending.Remove(requestId);
        }
    }

    public CapabilityApprovalRequest? Request(
        CapabilityExecutionPlan plan,
        string digest,
        IReadOnlyList<PocketCapabilityDescriptor> descriptors,
        DateTimeOffset now)
    {
        lock (_sync)
        {
            var effects = plan.Steps.Zip(descriptors)
                .Where(pair => pair.Second.ApprovalPolicy.RequiresExecutionApproval())
                .Select(pair => new CapabilityApprovalEffect(
                    pair.First.Id,
                    pair.First.Capability,
                    pair.Second.Effect,
                    CapabilityCanonicalJson.ArgumentsDigest(pair.First.Arguments),
                    $"approval.{pair.First.Capability.Id}",
                    pair.Second.RollbackAvailable))
                .ToArray();
            if (effects.Length == 0)
            {
                return null;
            }
            var permissions = descriptors
                .Where(descriptor => descriptor.ApprovalPolicy.RequiresExecutionApproval())
                .SelectMany(descriptor => descriptor.Permissions)
                .ToHashSet(StringComparer.Ordinal);
            var request = new CapabilityApprovalRequest(
                $"approval:{Guid.NewGuid():D}",
                plan.Id,
                digest,
                plan.Principal,
                plan.AppContext,
                now,
                now.Add(_timeToLive),
                $"nonce:{Guid.NewGuid():D}",
                effects,
                permissions);
            _pending[request.Id] = request;
            return request;
        }
    }

    public CapabilityApprovalGrant Decide(
        string requestId,
        string presentedPlanDigest,
        CapabilityApprovalDecision decision,
        DateTimeOffset now)
    {
        lock (_sync)
        {
            if (!_pending.Remove(requestId, out var request))
            {
                throw new CapabilityBrokerException("CAPABILITY_APPROVAL_INVALID", requestId);
            }
            if (request.PlanDigest != presentedPlanDigest)
            {
                throw new CapabilityBrokerException("CAPABILITY_APPROVAL_INVALID", requestId);
            }
            if (now > request.ExpiresAt)
            {
                throw new CapabilityBrokerException("CAPABILITY_APPROVAL_EXPIRED", requestId);
            }
            if (decision != CapabilityApprovalDecision.Approve)
            {
                throw new CapabilityBrokerException("CAPABILITY_APPROVAL_REJECTED", requestId);
            }
            var token = $"grant:{Guid.NewGuid():D}";
            _grants[token] = new IssuedGrant(
                request.PlanId,
                request.PlanDigest,
                request.Principal,
                request.AppContext,
                request.RequiredPermissions,
                request.ExpiresAt);
            return new CapabilityApprovalGrant(token);
        }
    }

    public void Consume(
        CapabilityApprovalGrant grant,
        CapabilityExecutionPlan plan,
        string digest,
        IReadOnlySet<string> requiredPermissions,
        DateTimeOffset now)
    {
        lock (_sync)
        {
            if (_consumedTokens.Contains(grant.Token))
            {
                throw new CapabilityBrokerException("CAPABILITY_APPROVAL_REPLAYED", grant.Token);
            }
            if (!_grants.Remove(grant.Token, out var issued)
                || issued.PlanId != plan.Id
                || issued.PlanDigest != digest
                || issued.Principal != plan.Principal
                || issued.AppContext != plan.AppContext
                || !requiredPermissions.All(issued.Permissions.Contains))
            {
                throw new CapabilityBrokerException("CAPABILITY_APPROVAL_INVALID", grant.Token);
            }
            _consumedTokens.Add(grant.Token);
            if (_consumedTokens.Count > 1_024)
            {
                _consumedTokens.Clear();
                _consumedTokens.Add(grant.Token);
            }
            if (now > issued.ExpiresAt)
            {
                throw new CapabilityBrokerException("CAPABILITY_APPROVAL_EXPIRED", grant.Token);
            }
        }
    }
}

internal sealed record CapabilityAuditEntry(
    [property: JsonPropertyName("approvalDecision")] string ApprovalDecision,
    [property: JsonPropertyName("approvalPolicy")] string ApprovalPolicy,
    [property: JsonPropertyName("auditEntryId")] string AuditEntryId,
    [property: JsonPropertyName("capability")] CapabilityAuditCapability Capability,
    [property: JsonPropertyName("durationMs")] long DurationMilliseconds,
    [property: JsonPropertyName("idempotencyReplay")] bool IdempotencyReplay,
    [property: JsonPropertyName("inputDigest")] string InputDigest,
    [property: JsonPropertyName("invocationId")] string InvocationId,
    [property: JsonPropertyName("origin")] string Origin,
    [property: JsonPropertyName("permissionDecision")] string PermissionDecision,
    [property: JsonPropertyName("pocketApp")] CapabilityAuditPocketApp? PocketApp,
    [property: JsonPropertyName("principalPseudonym")] string PrincipalPseudonym,
    [property: JsonPropertyName("readback")] CapabilityAuditReadback Readback,
    [property: JsonPropertyName("retryCount")] int RetryCount,
    [property: JsonPropertyName("safeErrorCode")] string? SafeErrorCode,
    [property: JsonPropertyName("status")] string Status,
    [property: JsonPropertyName("timestamp")] DateTimeOffset Timestamp,
    [property: JsonPropertyName("traceId")] string TraceId);

internal sealed record CapabilityAuditCapability(string Id, int Version, string Effect);
internal sealed record CapabilityAuditPocketApp(string Id, string Version, string ManifestDigest);
internal sealed record CapabilityAuditReadback(string Status, string? EvidenceDigest);

internal sealed record CapabilityAuthorizationAuditEntry(
    [property: JsonPropertyName("decision")] string Decision,
    [property: JsonPropertyName("eventType")] string EventType,
    [property: JsonPropertyName("origin")] string Origin,
    [property: JsonPropertyName("planDigest")] string PlanDigest,
    [property: JsonPropertyName("planId")] string PlanId,
    [property: JsonPropertyName("pocketApp")] CapabilityAuditPocketApp? PocketApp,
    [property: JsonPropertyName("principalPseudonym")] string PrincipalPseudonym,
    [property: JsonPropertyName("safeErrorCode")] string? SafeErrorCode,
    [property: JsonPropertyName("timestamp")] DateTimeOffset Timestamp);

internal sealed class CapabilityBrokerAuditLog
{
    private sealed record AuditFile(string Path, DateOnly Day, long ByteCount);

    private static readonly Regex AuditFilePattern = new(
        "^capability-(?<day>[0-9]{8})\\.jsonl$",
        RegexOptions.CultureInvariant | RegexOptions.Compiled);
    private static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.Never
    };

    private readonly string _directory;
    private readonly object _sync = new();

    public CapabilityBrokerAuditLog(string rootDirectory)
    {
        try
        {
            _directory = Path.Combine(rootDirectory, "audit");
            Directory.CreateDirectory(_directory);
            if ((File.GetAttributes(_directory) & FileAttributes.ReparsePoint) != 0)
            {
                throw new CapabilityBrokerException("CAPABILITY_AUDIT_UNAVAILABLE", "audit");
            }
        }
        catch
        {
            throw new CapabilityBrokerException("CAPABILITY_AUDIT_UNAVAILABLE", "audit");
        }
    }

    public void Append(CapabilityAuditEntry entry)
    {
        AppendEntry(entry, entry.Timestamp);
    }

    public void AppendAuthorization(CapabilityAuthorizationAuditEntry entry)
    {
        AppendEntry(entry, entry.Timestamp);
    }

    private void AppendEntry<T>(T entry, DateTimeOffset timestamp)
    {
        lock (_sync)
        {
            try
            {
                var path = Path.Combine(_directory, $"capability-{timestamp.UtcDateTime:yyyyMMdd}.jsonl");
                try
                {
                    var attributes = File.GetAttributes(path);
                    if ((attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0)
                    {
                        throw new CapabilityBrokerException("CAPABILITY_AUDIT_UNAVAILABLE", "audit");
                    }
                }
                catch (FileNotFoundException)
                {
                }
                catch (DirectoryNotFoundException)
                {
                }
                var data = JsonSerializer.SerializeToUtf8Bytes(entry, Options);
                using var stream = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.Read);
                stream.Write(data);
                stream.WriteByte((byte)'\n');
                stream.Flush(flushToDisk: true);
            }
            catch
            {
                throw new CapabilityBrokerException("CAPABILITY_AUDIT_UNAVAILABLE", "audit");
            }
        }
    }

    public byte[] CombinedData()
    {
        lock (_sync)
        {
            using var result = new MemoryStream();
            foreach (var file in StrictAuditFiles())
            {
                var data = File.ReadAllBytes(file.Path);
                result.Write(data);
            }
            return result.ToArray();
        }
    }

    public int RemoveEntries(DateTimeOffset? olderThan)
    {
        if (olderThan is null)
        {
            return 0;
        }
        lock (_sync)
        {
            try
            {
                var cutoffDay = DateOnly.FromDateTime(olderThan.Value.UtcDateTime);
                var targets = StrictAuditFiles().Where(file => file.Day < cutoffDay).ToArray();
                foreach (var target in targets)
                {
                    File.Delete(target.Path);
                }
                return targets.Length;
            }
            catch (CapabilityBrokerException)
            {
                throw;
            }
            catch
            {
                throw new CapabilityBrokerException("CAPABILITY_AUDIT_UNAVAILABLE", "audit");
            }
        }
    }

    public int RemoveAllEntries()
    {
        lock (_sync)
        {
            try
            {
                var targets = StrictAuditFiles();
                foreach (var target in targets)
                {
                    File.Delete(target.Path);
                }
                return targets.Count;
            }
            catch (CapabilityBrokerException)
            {
                throw;
            }
            catch
            {
                throw new CapabilityBrokerException("CAPABILITY_AUDIT_UNAVAILABLE", "audit");
            }
        }
    }

    public CapabilityAuditRetentionSnapshot RetentionSnapshot()
    {
        lock (_sync)
        {
            var files = StrictAuditFiles();
            return new CapabilityAuditRetentionSnapshot(files.Count, files.Sum(file => file.ByteCount));
        }
    }

    public static string PrincipalPseudonym(CapabilityPrincipal principal)
    {
        var source = string.Join("\u001f", new[]
        {
            principal.UserId,
            principal.PocketAppId ?? string.Empty,
            principal.AgentSessionId ?? string.Empty
        });
        return "principal:sha256:" + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(source))).ToLowerInvariant();
    }

    private List<AuditFile> StrictAuditFiles()
    {
        try
        {
            var files = new List<AuditFile>();
            foreach (var path in Directory.EnumerateFileSystemEntries(_directory))
            {
                var name = Path.GetFileName(path);
                if (!name.StartsWith("capability-", StringComparison.Ordinal)
                    && !name.EndsWith(".jsonl", StringComparison.Ordinal))
                {
                    continue;
                }
                var match = AuditFilePattern.Match(name);
                if (!match.Success
                    || !DateOnly.TryParseExact(
                        match.Groups["day"].Value,
                        "yyyyMMdd",
                        System.Globalization.CultureInfo.InvariantCulture,
                        System.Globalization.DateTimeStyles.None,
                        out var day))
                {
                    throw new CapabilityBrokerException("CAPABILITY_AUDIT_UNAVAILABLE", "audit");
                }
                var attributes = File.GetAttributes(path);
                if ((attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0)
                {
                    throw new CapabilityBrokerException("CAPABILITY_AUDIT_UNAVAILABLE", "audit");
                }
                files.Add(new AuditFile(path, day, new FileInfo(path).Length));
            }
            return files.OrderBy(file => file.Path, StringComparer.Ordinal).ToList();
        }
        catch (CapabilityBrokerException)
        {
            throw;
        }
        catch
        {
            throw new CapabilityBrokerException("CAPABILITY_AUDIT_UNAVAILABLE", "audit");
        }
    }
}
