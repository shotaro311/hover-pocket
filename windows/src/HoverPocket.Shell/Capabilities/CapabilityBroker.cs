using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace HoverPocket.Shell.Capabilities;

internal sealed class CapabilityBroker
{
    private static readonly Regex IdentifierPattern = new(
        "^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$",
        RegexOptions.CultureInvariant);
    private static readonly Regex StepPattern = new(
        "^[A-Za-z][A-Za-z0-9_-]{0,63}$",
        RegexOptions.CultureInvariant);
    private static readonly Regex PocketAppPattern = new(
        "^[a-z][a-z0-9]*(?:\\.[a-z0-9][a-z0-9-]*){2,}$",
        RegexOptions.CultureInvariant);
    private static readonly Regex VersionPattern = new(
        "^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z.-]+)?$",
        RegexOptions.CultureInvariant);
    private static readonly Regex DigestPattern = new(
        "^sha256:[a-f0-9]{64}$",
        RegexOptions.CultureInvariant);
    private static readonly Regex CapabilityPattern = new(
        "^[a-z][a-z0-9]*(?:\\.[a-z][a-z0-9_]*){2,}$",
        RegexOptions.CultureInvariant);
    private static readonly Regex PermissionPattern = new(
        "^[a-z][a-z0-9]*(?:\\.[a-z][a-z0-9_]*)+$",
        RegexOptions.CultureInvariant);

    private readonly CapabilityRegistry _registry;
    private readonly CapabilityBrokerLedger _ledger;
    private readonly CapabilityApprovalStore _approvalStore;
    private readonly CapabilityBrokerAuditLog _auditLog;
    private readonly SemaphoreSlim _executionGate = new(1, 1);
    private readonly Dictionary<string, List<DateTimeOffset>> _callHistory = new(StringComparer.Ordinal);

    public CapabilityBroker(
        CapabilityRegistry registry,
        CapabilityBrokerLedger ledger,
        CapabilityBrokerAuditLog auditLog,
        CapabilityApprovalStore? approvalStore = null)
    {
        _registry = registry;
        _ledger = ledger;
        _auditLog = auditLog;
        _approvalStore = approvalStore ?? new CapabilityApprovalStore();
    }

    public CapabilityBrokerPreparation Prepare(
        CapabilityExecutionPlan plan,
        CapabilityPermissionSet permissions,
        DateTimeOffset now)
    {
        var digest = "unavailable";
        try
        {
            var descriptors = Validate(plan, permissions);
            digest = CapabilityCanonicalJson.PlanDigest(plan);
            return new CapabilityBrokerPreparation(
                digest,
                _approvalStore.Request(plan, digest, descriptors, now));
        }
        catch (Exception ex)
        {
            AppendAuthorizationAudit(plan, digest, "denied", ex, now);
            throw;
        }
    }

    public CapabilityApprovalGrant DecideApproval(
        string requestId,
        string planDigest,
        CapabilityApprovalDecision decision,
        DateTimeOffset now)
    {
        var request = _approvalStore.PendingRequest(requestId);
        try
        {
            var grant = _approvalStore.Decide(requestId, planDigest, decision, now);
            AppendApprovalDecisionAudit(request, planDigest, "approved", null, now);
            return grant;
        }
        catch (Exception ex)
        {
            AppendApprovalDecisionAudit(request, planDigest, "denied", ex, now);
            throw;
        }
    }

    public async Task<CapabilityWorkflowReceipt> ExecuteAsync(
        CapabilityExecutionPlan plan,
        CapabilityPermissionSet permissions,
        CapabilityApprovalGrant? approvalGrant,
        DateTimeOffset now,
        CancellationToken cancellationToken = default)
    {
        await _executionGate.WaitAsync(cancellationToken);
        try
        {
            var digest = "unavailable";
            IReadOnlyList<PocketCapabilityDescriptor> descriptors;
            try
            {
                descriptors = Validate(plan, permissions);
                digest = CapabilityCanonicalJson.PlanDigest(plan);
            }
            catch (Exception ex)
            {
                AppendAuthorizationAudit(plan, digest, "denied", ex, now);
                throw;
            }
            var durableExecution = descriptors.Any(descriptor => descriptor.Effect.IsWrite());
            if (durableExecution)
            {
                var workflowState = _ledger.LookupWorkflow(plan.Id, digest);
                if (workflowState.Kind == CapabilityLedgerStartKind.Replay && workflowState.Receipt is not null)
                {
                    foreach (var item in plan.Steps.Zip(descriptors).Zip(workflowState.Receipt.Steps))
                    {
                        AppendAudit(
                            item.Second,
                            item.First.Second,
                            plan,
                            CapabilityCanonicalJson.ArgumentsDigest(item.First.First.Arguments),
                            0,
                            true,
                            now);
                    }
                    return workflowState.Receipt;
                }
                if (workflowState.Kind == CapabilityLedgerStartKind.Unknown)
                {
                    throw new CapabilityBrokerException("CAPABILITY_EXECUTION_UNKNOWN", plan.Id);
                }
            }

            var approvalPermissions = descriptors
                .Where(descriptor => descriptor.ApprovalPolicy.RequiresExecutionApproval())
                .SelectMany(descriptor => descriptor.Permissions)
                .ToHashSet(StringComparer.Ordinal);
            if (approvalPermissions.Count > 0)
            {
                if (approvalGrant is null)
                {
                    AppendAuthorizationAudit(
                        plan,
                        digest,
                        "denied",
                        new CapabilityBrokerException("CAPABILITY_APPROVAL_REQUIRED", plan.Id),
                        now);
                    throw new CapabilityBrokerException("CAPABILITY_APPROVAL_REQUIRED", plan.Id);
                }
                try
                {
                    _approvalStore.Consume(approvalGrant.Value, plan, digest, approvalPermissions, now);
                }
                catch (Exception ex)
                {
                    AppendAuthorizationAudit(plan, digest, "denied", ex, now);
                    throw;
                }
            }

            if (durableExecution)
            {
                _ledger.StartWorkflow(plan.Id, digest);
            }
            var receipts = new List<CapabilityReceipt>();
            var successful = new List<(CapabilityPlanStep Step, PocketCapabilityDescriptor Descriptor, int ReceiptIndex)>();
            var workflowStatus = CapabilityReceiptStatus.Succeeded;
            for (var index = 0; index < plan.Steps.Count; index++)
            {
                var receipt = await ExecuteStepAsync(
                    plan.Steps[index],
                    descriptors[index],
                    plan,
                    digest,
                    durableExecution,
                    now,
                    cancellationToken);
                receipts.Add(receipt);
                if (receipt.Status == CapabilityReceiptStatus.Succeeded)
                {
                    successful.Add((plan.Steps[index], descriptors[index], receipts.Count - 1));
                    continue;
                }

                workflowStatus = receipt.Status == CapabilityReceiptStatus.Unknown
                    ? CapabilityReceiptStatus.Unknown
                    : successful.Count == 0
                        ? CapabilityReceiptStatus.Failed
                        : CapabilityReceiptStatus.Partial;
                var rollbackCandidates = successful.ToList();
                if (descriptors[index].RollbackAvailable && receipt.Output is not null)
                {
                    rollbackCandidates.Add((plan.Steps[index], descriptors[index], receipts.Count - 1));
                }
                if (rollbackCandidates.Count > 0)
                {
                    var rolledBack = await RollbackAsync(rollbackCandidates, receipts, plan, digest, now);
                    if (rolledBack && receipt.Status != CapabilityReceiptStatus.Unknown)
                    {
                        workflowStatus = CapabilityReceiptStatus.Failed;
                    }
                }
                break;
            }

            var workflow = new CapabilityWorkflowReceipt(
                plan.Id,
                digest,
                workflowStatus,
                receipts,
                now,
                false);
            if (durableExecution)
            {
                _ledger.CompleteWorkflow(workflow);
            }
            return workflow;
        }
        finally
        {
            _executionGate.Release();
        }
    }

    private IReadOnlyList<PocketCapabilityDescriptor> Validate(
        CapabilityExecutionPlan plan,
        CapabilityPermissionSet permissions)
    {
        if (!IdentifierPattern.IsMatch(plan.Id)
            || plan.Steps.Count is < 1 or > 32
            || plan.RequiredPermissions.Count > 64
            || !plan.RequiredPermissions.All(permission => permission.Length <= 128 && PermissionPattern.IsMatch(permission))
            || !Enum.IsDefined(typeof(CapabilityOrigin), plan.Origin)
            || permissions.Principal != plan.Principal
            || !IdentifierPattern.IsMatch(plan.Principal.UserId)
            || (plan.Principal.AgentSessionId is not null && !IdentifierPattern.IsMatch(plan.Principal.AgentSessionId)))
        {
            throw InvalidPlan("identity");
        }
        if (plan.Principal.PocketAppId is not null
            && (!PocketAppPattern.IsMatch(plan.Principal.PocketAppId) || plan.Principal.PocketAppId.EnumerateRunes().Count() > 160))
        {
            throw InvalidPlan("identity");
        }
        if (plan.AppContext is not null)
        {
            if (!PocketAppPattern.IsMatch(plan.AppContext.Id)
                || !VersionPattern.IsMatch(plan.AppContext.Version)
                || !DigestPattern.IsMatch(plan.AppContext.ManifestDigest)
                || plan.AppContext.Id != plan.Principal.PocketAppId)
            {
                throw InvalidPlan("app_context");
            }
        }
        else if (plan.Principal.PocketAppId is not null)
        {
            throw InvalidPlan("app_context");
        }

        var stepIds = new HashSet<string>(StringComparer.Ordinal);
        var idempotencyKeys = new HashSet<string>(StringComparer.Ordinal);
        var descriptors = new List<PocketCapabilityDescriptor>(plan.Steps.Count);
        var requiredPermissions = new HashSet<string>(StringComparer.Ordinal);
        foreach (var step in plan.Steps)
        {
            if (!StepPattern.IsMatch(step.Id)
                || !stepIds.Add(step.Id)
                || step.Capability.Id.Length > 128
                || !CapabilityPattern.IsMatch(step.Capability.Id)
                || step.Capability.Version < 1
                || !ValidIdempotencyKey(step.IdempotencyKey)
                || !idempotencyKeys.Add(step.IdempotencyKey)
                || step.Dependencies.Count > 32
                || step.Dependencies.Distinct(StringComparer.Ordinal).Count() != step.Dependencies.Count
                || !step.Dependencies.All(stepIds.Contains)
                || step.Dependencies.Contains(step.Id, StringComparer.Ordinal))
            {
                throw InvalidPlan("steps");
            }
            var descriptor = _registry.Resolve(step.Capability);
            descriptor.ValidateInput(step.Arguments);
            descriptors.Add(descriptor);
            requiredPermissions.UnionWith(descriptor.Permissions);
        }
        if (!requiredPermissions.SetEquals(plan.RequiredPermissions))
        {
            throw InvalidPlan("permissions");
        }
        if (!permissions.Contains(requiredPermissions))
        {
            var missing = requiredPermissions.Except(permissions.Permissions).Order(StringComparer.Ordinal).FirstOrDefault() ?? "unknown";
            throw new CapabilityBrokerException("CAPABILITY_PERMISSION_DENIED", missing);
        }
        return descriptors;
    }

    private async Task<CapabilityReceipt> ExecuteStepAsync(
        CapabilityPlanStep step,
        PocketCapabilityDescriptor descriptor,
        CapabilityExecutionPlan plan,
        string planDigest,
        bool durableExecution,
        DateTimeOffset now,
        CancellationToken cancellationToken)
    {
        var argumentDigest = CapabilityCanonicalJson.ArgumentsDigest(step.Arguments);
        if (durableExecution)
        {
            var invocationState = _ledger.BeginInvocation(step.IdempotencyKey, planDigest, argumentDigest, step.Capability);
            if (invocationState.Kind == CapabilityLedgerStartKind.Replay && invocationState.Receipt is not null)
            {
                AppendAudit(invocationState.Receipt, descriptor, plan, argumentDigest, 0, true, now);
                return invocationState.Receipt;
            }
            if (invocationState.Kind == CapabilityLedgerStartKind.Unknown)
            {
                throw new CapabilityBrokerException("CAPABILITY_EXECUTION_UNKNOWN", step.IdempotencyKey);
            }
        }

        EnforceRateLimit(descriptor, plan.Principal, now);
        var invocationId = InvocationId(planDigest, step.Id);
        var auditEntryId = $"audit:{Guid.NewGuid():D}";
        var traceId = $"trace:{DigestPrefix(planDigest, 32)}";
        _auditLog.Append(new CapabilityAuditEntry(
            descriptor.ApprovalPolicy.RequiresExecutionApproval() ? "approved" : "not_required",
            descriptor.ApprovalPolicy.WireValue(),
            auditEntryId,
            new CapabilityAuditCapability(descriptor.Key.Id, descriptor.Key.Version, descriptor.Effect.WireValue()),
            0,
            false,
            argumentDigest,
            invocationId,
            plan.Origin.WireValue(),
            "granted",
            plan.AppContext is null ? null : new CapabilityAuditPocketApp(plan.AppContext.Id, plan.AppContext.Version, plan.AppContext.ManifestDigest),
            CapabilityBrokerAuditLog.PrincipalPseudonym(plan.Principal),
            new CapabilityAuditReadback("unavailable", null),
            0,
            null,
            "unknown",
            now,
            traceId));

        var stopwatch = Stopwatch.StartNew();
        CapabilityReceipt receipt;
        JsonElement? possibleOutput = null;
        try
        {
            var output = await InvokeWithTimeoutAsync(
                descriptor.Key,
                step.Arguments,
                new CapabilityHandlerContext(step.IdempotencyKey, now),
                descriptor.Limits.TimeoutMilliseconds,
                cancellationToken);
            possibleOutput = output.Clone();
            descriptor.ValidateOutput(output);
            var readback = await ReadbackAsync(descriptor, output, now, cancellationToken);
            var status = readback.Status == CapabilityReadbackStatus.Verified
                ? CapabilityReceiptStatus.Succeeded
                : descriptor.Effect.IsWrite()
                    ? CapabilityReceiptStatus.Partial
                    : CapabilityReceiptStatus.Failed;
            receipt = new CapabilityReceipt(
                invocationId,
                plan.Id,
                planDigest,
                descriptor.Key,
                status,
                output.Clone(),
                readback,
                descriptor.RollbackAvailable,
                descriptor.RollbackAvailable ? "not_requested" : null,
                auditEntryId,
                status == CapabilityReceiptStatus.Succeeded
                    ? null
                    : new CapabilitySafeError("CAPABILITY_READBACK_MISMATCH", false, "error.capability.readback_mismatch"),
                now,
                false);
        }
        catch (Exception ex)
        {
            receipt = FailureReceipt(ex, invocationId, auditEntryId, descriptor, plan, planDigest, possibleOutput, now);
        }
        stopwatch.Stop();
        AppendAudit(receipt, descriptor, plan, argumentDigest, stopwatch.ElapsedMilliseconds, false, now);
        if (durableExecution)
        {
            _ledger.CompleteInvocation(step.IdempotencyKey, receipt);
        }
        return receipt;
    }

    private async Task<CapabilityReadbackReceipt> ReadbackAsync(
        PocketCapabilityDescriptor descriptor,
        JsonElement output,
        DateTimeOffset now,
        CancellationToken cancellationToken)
    {
        JsonElement observed;
        switch (descriptor.Readback.Strategy)
        {
            case CapabilityReadbackStrategy.SameStoreSnapshot:
            case CapabilityReadbackStrategy.OsState:
            case CapabilityReadbackStrategy.ContentDigest:
                observed = output.Clone();
                break;
            case CapabilityReadbackStrategy.CapabilityQuery:
            case CapabilityReadbackStrategy.EntityGetById:
                if (descriptor.Readback.Query is not { } query)
                {
                    throw InvalidPlan("readback_query");
                }
                var arguments = ReadbackArguments(query, output);
                var queryDescriptor = _registry.Resolve(query);
                queryDescriptor.ValidateInput(arguments);
                observed = await InvokeWithTimeoutAsync(
                    query,
                    arguments,
                    CapabilityHandlerContext.Create(),
                    queryDescriptor.Limits.TimeoutMilliseconds,
                    cancellationToken);
                queryDescriptor.ValidateOutput(observed);
                observed = observed.Clone();
                break;
            case CapabilityReadbackStrategy.None:
                if (descriptor.Effect.IsWrite())
                {
                    throw InvalidPlan("write_without_readback");
                }
                observed = output.Clone();
                break;
            default:
                throw InvalidPlan("readback_strategy");
        }

        var matched = descriptor.Readback.MatchFields.All(field =>
            output.TryGetProperty(field, out var expected)
            && observed.TryGetProperty(field, out var actual)
            && CapabilityCanonicalJson.CanonicalBytes(expected).AsSpan().SequenceEqual(CapabilityCanonicalJson.CanonicalBytes(actual)));
        return new CapabilityReadbackReceipt(
            matched ? CapabilityReadbackStatus.Verified : CapabilityReadbackStatus.Mismatch,
            descriptor.Readback.Strategy,
            now,
            observed,
            CapabilityCanonicalJson.ArgumentsDigest(observed));
    }

    private static JsonElement ReadbackArguments(PocketCapabilityKey query, JsonElement output)
    {
        string field = query == CapabilityIds.CalendarGet
            ? "eventRef"
            : query == CapabilityIds.TimerGet
                ? "timerId"
                : query == CapabilityIds.StickyGet
                    ? "noteId"
                    : throw InvalidPlan("readback_query");
        if (!output.TryGetProperty(field, out var value))
        {
            throw InvalidPlan("readback_identifier");
        }
        return CapabilityJson.From(new Dictionary<string, JsonElement>
        {
            [field] = value.Clone()
        });
    }

    private async Task<bool> RollbackAsync(
        IReadOnlyList<(CapabilityPlanStep Step, PocketCapabilityDescriptor Descriptor, int ReceiptIndex)> successful,
        List<CapabilityReceipt> receipts,
        CapabilityExecutionPlan plan,
        string planDigest,
        DateTimeOffset now)
    {
        var allSucceeded = true;
        foreach (var item in successful.Reverse())
        {
            if (!item.Descriptor.RollbackAvailable)
            {
                allSucceeded = false;
                continue;
            }
            var output = receipts[item.ReceiptIndex].Output;
            if (item.Step.Capability != CapabilityIds.TimerStart
                || output is null
                || !output.Value.TryGetProperty("timerId", out var timerId))
            {
                allSucceeded = false;
                continue;
            }
            var rollbackStep = new CapabilityPlanStep(
                $"rollback_{item.Step.Id}",
                CapabilityIds.TimerStop,
                CapabilityJson.From(new { timerId = timerId.GetString() }),
                $"rollback.{DigestPrefix(planDigest, 24)}.{item.Step.Id}",
                []);
            var rollbackReceipt = await ExecuteStepAsync(
                rollbackStep,
                _registry.Resolve(rollbackStep.Capability),
                plan,
                planDigest,
                true,
                now,
                CancellationToken.None);
            var succeeded = rollbackReceipt.Status == CapabilityReceiptStatus.Succeeded;
            receipts[item.ReceiptIndex] = receipts[item.ReceiptIndex] with
            {
                RollbackStatus = succeeded ? "succeeded" : "failed"
            };
            allSucceeded &= succeeded;
        }
        return allSucceeded;
    }

    private async Task<JsonElement> InvokeWithTimeoutAsync(
        PocketCapabilityKey key,
        JsonElement arguments,
        CapabilityHandlerContext context,
        int timeoutMilliseconds,
        CancellationToken cancellationToken)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(timeoutMilliseconds);
        try
        {
            return await _registry.InvokeAsync(key, arguments, context, timeout.Token);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new CapabilityBrokerException("CAPABILITY_TIMEOUT", key.Id);
        }
    }

    private void EnforceRateLimit(
        PocketCapabilityDescriptor descriptor,
        CapabilityPrincipal principal,
        DateTimeOffset now)
    {
        var key = CapabilityBrokerAuditLog.PrincipalPseudonym(principal) + ":" + descriptor.Key.Id;
        var cutoff = now.AddMinutes(-1);
        var history = _callHistory.TryGetValue(key, out var existing)
            ? existing.Where(date => date >= cutoff).ToList()
            : [];
        if (history.Count >= descriptor.Limits.MaximumCallsPerMinute)
        {
            throw new CapabilityBrokerException("CAPABILITY_RATE_LIMITED", descriptor.Key.Id);
        }
        history.Add(now);
        _callHistory[key] = history;
    }

    private CapabilityReceipt FailureReceipt(
        Exception error,
        string invocationId,
        string auditEntryId,
        PocketCapabilityDescriptor descriptor,
        CapabilityExecutionPlan plan,
        string planDigest,
        JsonElement? possibleOutput,
        DateTimeOffset now)
    {
        var safe = SafeError(error);
        var unknown = error is OperationCanceledException
            || (error is CapabilityBrokerException broker && broker.Code == "CAPABILITY_TIMEOUT");
        return new CapabilityReceipt(
            invocationId,
            plan.Id,
            planDigest,
            descriptor.Key,
            unknown ? CapabilityReceiptStatus.Unknown : descriptor.Effect.IsWrite() ? CapabilityReceiptStatus.Partial : CapabilityReceiptStatus.Failed,
            possibleOutput,
            new CapabilityReadbackReceipt(CapabilityReadbackStatus.Unavailable, descriptor.Readback.Strategy, null, null, null),
            descriptor.RollbackAvailable,
            descriptor.RollbackAvailable ? "not_requested" : null,
            auditEntryId,
            safe,
            now,
            false);
    }

    private void AppendApprovalDecisionAudit(
        CapabilityApprovalRequest? request,
        string planDigest,
        string decision,
        Exception? error,
        DateTimeOffset now)
    {
        _auditLog.AppendAuthorization(new CapabilityAuthorizationAuditEntry(
            decision,
            "authorization_decision",
            "approval",
            planDigest,
            request?.PlanId ?? "unknown",
            request?.AppContext is null
                ? null
                : new CapabilityAuditPocketApp(request.AppContext.Id, request.AppContext.Version, request.AppContext.ManifestDigest),
            request is null ? "principal:unknown" : CapabilityBrokerAuditLog.PrincipalPseudonym(request.Principal),
            error is null ? null : AuthorizationErrorCode(error),
            now));
    }

    private void AppendAuthorizationAudit(
        CapabilityExecutionPlan plan,
        string planDigest,
        string decision,
        Exception? error,
        DateTimeOffset now)
    {
        _auditLog.AppendAuthorization(new CapabilityAuthorizationAuditEntry(
            decision,
            "authorization_decision",
            Enum.IsDefined(typeof(CapabilityOrigin), plan.Origin) ? plan.Origin.WireValue() : "unknown",
            DigestPattern.IsMatch(planDigest) ? planDigest : "unavailable",
            IdentifierPattern.IsMatch(plan.Id) ? plan.Id : "invalid",
            SafeAuditPocketApp(plan.AppContext),
            CapabilityBrokerAuditLog.PrincipalPseudonym(SafeAuditPrincipal(plan.Principal)),
            error is null ? null : AuthorizationErrorCode(error),
            now));
    }

    private void AppendAudit(
        CapabilityReceipt receipt,
        PocketCapabilityDescriptor descriptor,
        CapabilityExecutionPlan plan,
        string argumentDigest,
        long durationMilliseconds,
        bool replayed,
        DateTimeOffset now)
    {
        _auditLog.Append(new CapabilityAuditEntry(
            descriptor.ApprovalPolicy.RequiresExecutionApproval() ? "approved" : "not_required",
            descriptor.ApprovalPolicy.WireValue(),
            receipt.AuditEntryId,
            new CapabilityAuditCapability(descriptor.Key.Id, descriptor.Key.Version, descriptor.Effect.WireValue()),
            durationMilliseconds,
            replayed,
            argumentDigest,
            receipt.InvocationId,
            plan.Origin.WireValue(),
            "granted",
            plan.AppContext is null ? null : new CapabilityAuditPocketApp(plan.AppContext.Id, plan.AppContext.Version, plan.AppContext.ManifestDigest),
            CapabilityBrokerAuditLog.PrincipalPseudonym(plan.Principal),
            new CapabilityAuditReadback(receipt.Readback.Status.WireValue(), receipt.Readback.EvidenceDigest),
            0,
            receipt.SafeError?.Code,
            receipt.Status.WireValue(),
            now,
            $"trace:{DigestPrefix(receipt.PlanDigest, 32)}"));
    }

    private static CapabilitySafeError SafeError(Exception error)
    {
        if (error is CapabilityHandlerException handler)
        {
            return new CapabilitySafeError(handler.Code, false, "error.capability.handler");
        }
        if (error is CapabilityBrokerException broker)
        {
            return broker.Code switch
            {
                "CAPABILITY_TIMEOUT" => new CapabilitySafeError(broker.Code, false, "error.capability.timeout"),
                "CAPABILITY_RATE_LIMITED" => new CapabilitySafeError(broker.Code, true, "error.capability.rate_limited"),
                _ => new CapabilitySafeError("CAPABILITY_EXECUTION_FAILED", false, "error.capability.execution_failed")
            };
        }
        if (error is OperationCanceledException)
        {
            return new CapabilitySafeError("CAPABILITY_CANCELLED", false, "error.capability.cancelled");
        }
        return new CapabilitySafeError("CAPABILITY_EXECUTION_FAILED", false, "error.capability.execution_failed");
    }

    private static string AuthorizationErrorCode(Exception error) =>
        error is CapabilityBrokerException broker ? broker.Code : SafeError(error).Code;

    private static bool ValidIdempotencyKey(string value)
    {
        try
        {
            _ = new CapabilityHandlerContext(value, DateTimeOffset.UtcNow).RequireIdempotencyKey();
            return true;
        }
        catch (CapabilityHandlerException)
        {
            return false;
        }
    }

    private static string InvocationId(string planDigest, string stepId) =>
        $"invocation:{DigestPrefix(planDigest, 32)}:{stepId}";

    private static CapabilityPrincipal SafeAuditPrincipal(CapabilityPrincipal principal) =>
        new(
            TruncateForAudit(principal.UserId, 128),
            principal.PocketAppId is null ? null : TruncateForAudit(principal.PocketAppId, 160),
            principal.AgentSessionId is null ? null : TruncateForAudit(principal.AgentSessionId, 128));

    private static CapabilityAuditPocketApp? SafeAuditPocketApp(CapabilityAppContext? app)
    {
        if (app is null
            || app.Id.Length > 160
            || !PocketAppPattern.IsMatch(app.Id)
            || !VersionPattern.IsMatch(app.Version)
            || !DigestPattern.IsMatch(app.ManifestDigest))
        {
            return null;
        }
        return new CapabilityAuditPocketApp(app.Id, app.Version, app.ManifestDigest);
    }

    private static string TruncateForAudit(string value, int maximum) =>
        value.Length <= maximum ? value : value[..maximum];

    private static string DigestPrefix(string digest, int length)
    {
        const string prefix = "sha256:";
        if (!digest.StartsWith(prefix, StringComparison.Ordinal)
            || digest.Length < prefix.Length + length)
        {
            throw InvalidPlan("digest");
        }
        return digest.Substring(prefix.Length, length);
    }

    private static CapabilityBrokerException InvalidPlan(string field) =>
        new("CAPABILITY_PLAN_INVALID", field);
}
