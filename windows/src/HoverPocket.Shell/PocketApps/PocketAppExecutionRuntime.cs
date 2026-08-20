using System.Globalization;
using System.Text.Json;
using HoverPocket.Shell.Capabilities;

namespace HoverPocket.Shell.PocketApps;

internal sealed record PocketAppWorkflowDraft(
    string PackageId,
    string WorkflowId,
    CapabilityExecutionPlan Plan,
    CapabilityBrokerPreparation Preparation);

internal sealed class PocketAppExecutionRuntime : IDisposable
{
    private static readonly HashSet<PocketCapabilityKey> PresentableWorkflowCapabilities =
    [
        CapabilityIds.TimerStart,
        CapabilityIds.StickyUpsert
    ];

    private readonly CapabilityBroker _broker;
    private readonly CapabilityPrincipal _principal;
    private readonly IReadOnlySet<string> _permissions;
    private readonly TimeZoneInfo _timeZone;
    private readonly PocketAppActivationLease? _activationLease;
    private bool _disposed;

    public PocketAppExecutionRuntime(
        PocketAppPackage package,
        CapabilityBroker broker,
        string userId,
        IReadOnlySet<string> grantedPermissions,
        TimeZoneInfo? timeZone = null,
        PocketAppUserStateStore? userStateStore = null,
        PocketAppActivationLease? activationLease = null)
    {
        Package = package;
        _broker = broker;
        _principal = new CapabilityPrincipal(userId, package.Manifest.Id);
        _timeZone = timeZone ?? TimeZoneInfo.Local;
        var requested = package.Manifest.RequestedCapabilities
            .SelectMany(item => item.Permissions)
            .ToHashSet(StringComparer.Ordinal);
        _permissions = grantedPermissions.Where(requested.Contains).ToHashSet(StringComparer.Ordinal);
        UserStateStore = userStateStore;
        _activationLease = activationLease;
    }

    public PocketAppPackage Package { get; }

    public PocketAppUserStateStore? UserStateStore { get; }

    internal bool IsActivationActive => _activationLease?.IsActive ?? true;

    internal void EnsureActivationActive() => _activationLease?.RequireActive();

    public void Dispose()
    {
        if (_disposed) { return; }
        _disposed = true;
        UserStateStore?.Dispose();
    }

    public async Task<JsonElement> QueryAsync(
        string reference,
        JsonElement arguments,
        DateTimeOffset? now = null,
        CancellationToken cancellationToken = default)
    {
        EnsureActivationActive();
        var key = CapabilityKey(reference);
        var request = RequestedCapability(key);
        if (request.Effect is not (CapabilityEffect.Pure or CapabilityEffect.PrivateRead))
        {
            throw new CapabilityBrokerException("CAPABILITY_PLAN_INVALID", "query_effect");
        }
        var current = now ?? DateTimeOffset.Now;
        var resolved = ResolveObject(arguments, new Dictionary<string, JsonElement>(StringComparer.Ordinal), current);
        ValidateScope(resolved, request);
        var nonce = Guid.NewGuid().ToString("D");
        var plan = new CapabilityExecutionPlan(
            $"pocket-query:{nonce}",
            current,
            CapabilityOrigin.PocketSurface,
            _principal,
            AppContext,
            [new CapabilityPlanStep("query", key, resolved, $"pocket-query.{nonce}", [])],
            request.Permissions);
        var permissions = PermissionSet;
        var preparation = _broker.Prepare(plan, permissions, current);
        if (preparation.ApprovalRequest is not null)
        {
            throw new CapabilityBrokerException("CAPABILITY_PLAN_INVALID", "query_approval");
        }
        using var linkedCancellation = LinkedActivationCancellation(cancellationToken);
        var effectiveCancellation = linkedCancellation?.Token ?? cancellationToken;
        effectiveCancellation.ThrowIfCancellationRequested();
        var receipt = await _broker.ExecuteAsync(plan, permissions, null, current, effectiveCancellation);
        EnsureActivationActive();
        return receipt.Status == CapabilityReceiptStatus.Succeeded
            && receipt.Steps.FirstOrDefault()?.Output is { } output
            ? output
            : throw new CapabilityBrokerException("CAPABILITY_UNAVAILABLE", key.Id);
    }

    public PocketAppWorkflowDraft Prepare(
        string workflowId,
        IReadOnlyDictionary<string, JsonElement> inputs,
        DateTimeOffset? now = null)
    {
        EnsureActivationActive();
        if (!Package.Workflows.TryGetValue(workflowId, out var workflow))
        {
            throw new CapabilityBrokerException("CAPABILITY_PLAN_INVALID", "pocket_workflow");
        }
        ValidateInputs(inputs, workflow);
        var current = now ?? DateTimeOffset.Now;
        var nonce = Guid.NewGuid().ToString("D");
        var steps = workflow.Steps.Select(step =>
        {
            if (!SupportsWorkflowPresentation(step.Capability))
            {
                throw new CapabilityBrokerException("CAPABILITY_PLAN_INVALID", "pocket_workflow_presentation");
            }
            var resolvedArguments = ResolveObject(
                CapabilityJson.From(step.Arguments.ToDictionary(item => item.Key, item => item.Value)),
                inputs,
                current);
            var arguments = CanonicalWorkflowArguments(resolvedArguments, step.Capability);
            var request = RequestedCapability(step.Capability);
            ValidateScope(arguments, request);
            return new CapabilityPlanStep(
                step.Id,
                step.Capability,
                arguments,
                $"pocket-workflow.{nonce}.{step.Id}",
                step.Dependencies);
        }).ToArray();
        var plan = new CapabilityExecutionPlan(
            $"pocket-workflow:{nonce}",
            current,
            CapabilityOrigin.PocketSurface,
            _principal,
            AppContext,
            steps,
            workflow.RequiredPermissions);
        return new PocketAppWorkflowDraft(
            Package.Manifest.Id,
            workflowId,
            plan,
            _broker.Prepare(plan, PermissionSet, current));
    }

    public async Task<CapabilityWorkflowReceipt> ApproveAndExecuteAsync(
        PocketAppWorkflowDraft draft,
        DateTimeOffset? now = null,
        CancellationToken cancellationToken = default)
    {
        EnsureActivationActive();
        ValidateDraft(draft);
        var request = draft.Preparation.ApprovalRequest
            ?? throw new CapabilityBrokerException("CAPABILITY_APPROVAL_REQUIRED", draft.Plan.Id);
        var current = now ?? DateTimeOffset.Now;
        var grant = _broker.DecideApproval(
            request.Id,
            draft.Preparation.PlanDigest,
            CapabilityApprovalDecision.Approve,
            current);
        using var linkedCancellation = LinkedActivationCancellation(cancellationToken);
        var effectiveCancellation = linkedCancellation?.Token ?? cancellationToken;
        effectiveCancellation.ThrowIfCancellationRequested();
        var receipt = await _broker.ExecuteAsync(draft.Plan, PermissionSet, grant, current, effectiveCancellation);
        EnsureActivationActive();
        return receipt;
    }

    public void Reject(PocketAppWorkflowDraft draft, DateTimeOffset? now = null)
    {
        if (!IsActivationActive) { return; }
        ValidateDraft(draft);
        if (draft.Preparation.ApprovalRequest is not { } request)
        {
            return;
        }
        try
        {
            _ = _broker.DecideApproval(
                request.Id,
                draft.Preparation.PlanDigest,
                CapabilityApprovalDecision.Reject,
                now ?? DateTimeOffset.Now);
        }
        catch (CapabilityBrokerException ex) when (ex.Code == "CAPABILITY_APPROVAL_REJECTED")
        {
        }
    }

    private CapabilityAppContext AppContext => new(
        Package.Manifest.Id,
        Package.Manifest.Version,
        Package.ManifestDigest);

    private CapabilityPermissionSet PermissionSet => new(_principal, _permissions);

    private CancellationTokenSource? LinkedActivationCancellation(CancellationToken cancellationToken) =>
        _activationLease is null
            ? null
            : CancellationTokenSource.CreateLinkedTokenSource(
                cancellationToken,
                _activationLease.CancellationToken);

    private PocketAppRequestedCapability RequestedCapability(PocketCapabilityKey key) =>
        Package.Manifest.RequestedCapabilities.FirstOrDefault(item => item.Key == key)
        ?? throw new CapabilityBrokerException("CAPABILITY_UNKNOWN", key.Id);

    private void ValidateDraft(PocketAppWorkflowDraft draft)
    {
        if (draft.PackageId != Package.Manifest.Id
            || !Package.Workflows.ContainsKey(draft.WorkflowId)
            || draft.Plan.Principal != _principal
            || draft.Plan.AppContext != AppContext
            || draft.Plan.Origin != CapabilityOrigin.PocketSurface)
        {
            throw new CapabilityBrokerException("CAPABILITY_PLAN_INVALID", "pocket_draft");
        }
    }

    private static void ValidateInputs(
        IReadOnlyDictionary<string, JsonElement> inputs,
        PocketAppWorkflowDocument workflow)
    {
        if (!inputs.Keys.ToHashSet(StringComparer.Ordinal).SetEquals(workflow.Inputs.Keys))
        {
            throw new CapabilityBrokerException("CAPABILITY_PLAN_INVALID", "pocket_inputs");
        }
        foreach (var input in workflow.Inputs)
        {
            if (!inputs.TryGetValue(input.Key, out var value) || !Accepts(value, input.Value))
            {
                throw new CapabilityBrokerException("CAPABILITY_PLAN_INVALID", $"pocket_input_{input.Key}");
            }
        }
    }

    private static bool Accepts(JsonElement value, string type) => type switch
    {
        "string" or "entity-ref" => value.ValueKind == JsonValueKind.String,
        "integer" => value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out _),
        "number" => value.ValueKind == JsonValueKind.Number,
        "boolean" => value.ValueKind is JsonValueKind.True or JsonValueKind.False,
        "date-time" => value.ValueKind == JsonValueKind.String
            && DateTimeOffset.TryParse(value.GetString(), CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out _),
        _ => false
    };

    private JsonElement ResolveObject(
        JsonElement value,
        IReadOnlyDictionary<string, JsonElement> inputs,
        DateTimeOffset now)
    {
        if (value.ValueKind != JsonValueKind.Object)
        {
            throw new CapabilityBrokerException("CAPABILITY_PLAN_INVALID", "pocket_arguments");
        }
        return CapabilityJson.From(value.EnumerateObject().ToDictionary(
            property => property.Name,
            property => Resolve(property.Value, inputs, now),
            StringComparer.Ordinal));
    }

    private object? Resolve(
        JsonElement value,
        IReadOnlyDictionary<string, JsonElement> inputs,
        DateTimeOffset now)
    {
        return value.ValueKind switch
        {
            JsonValueKind.Null => null,
            JsonValueKind.True => true,
            JsonValueKind.False => false,
            JsonValueKind.Number when value.TryGetInt32(out var integer) => integer,
            JsonValueKind.Number => value.GetDouble(),
            JsonValueKind.String => ResolveString(value.GetString() ?? string.Empty, inputs, now),
            JsonValueKind.Array => value.EnumerateArray().Select(item => Resolve(item, inputs, now)).ToArray(),
            JsonValueKind.Object => value.EnumerateObject().ToDictionary(
                property => property.Name,
                property => Resolve(property.Value, inputs, now),
                StringComparer.Ordinal),
            _ => throw new CapabilityBrokerException("CAPABILITY_PLAN_INVALID", "pocket_json")
        };
    }

    private object? ResolveString(
        string value,
        IReadOnlyDictionary<string, JsonElement> inputs,
        DateTimeOffset now)
    {
        if (value.StartsWith("$input.", StringComparison.Ordinal))
        {
            var name = value["$input.".Length..];
            return inputs.TryGetValue(name, out var input)
                ? Resolve(input, inputs, now)
                : throw new CapabilityBrokerException("CAPABILITY_PLAN_INVALID", "pocket_binding");
        }
        if (value == "$context.timezone")
        {
            return _timeZone.Id;
        }
        if (value == "$context.todayFocusStableKey")
        {
            return $"today-focus:{TimeZoneInfo.ConvertTime(now, _timeZone):yyyy-MM-dd}";
        }
        if (value.StartsWith('$'))
        {
            throw new CapabilityBrokerException("CAPABILITY_PLAN_INVALID", "pocket_context");
        }
        return value;
    }

    private static void ValidateScope(JsonElement arguments, PocketAppRequestedCapability request)
    {
        if (request.Scope is not { ValueKind: JsonValueKind.Object } scope)
        {
            return;
        }
        if (scope.TryGetProperty("range", out var range)
            && (!arguments.TryGetProperty("range", out var actualRange)
                || actualRange.GetString() != range.GetString()))
        {
            throw new CapabilityBrokerException("CAPABILITY_PLAN_INVALID", "pocket_scope_range");
        }
        if (scope.TryGetProperty("namespace", out var namespaceElement))
        {
            var expected = namespaceElement.GetString() ?? string.Empty;
            if (!arguments.TryGetProperty("stableKey", out var stableKey)
                || stableKey.ValueKind != JsonValueKind.String
                || PocketStableKey.Namespace(stableKey.GetString() ?? string.Empty) != expected)
            {
                throw new CapabilityBrokerException("CAPABILITY_PLAN_INVALID", "pocket_scope_namespace");
            }
        }
    }

    private static PocketCapabilityKey CapabilityKey(string reference)
    {
        var marker = reference.LastIndexOf('@');
        if (marker <= 0
            || !int.TryParse(reference[(marker + 1)..], NumberStyles.None, CultureInfo.InvariantCulture, out var version)
            || version < 1)
        {
            throw new CapabilityBrokerException("CAPABILITY_PLAN_INVALID", "pocket_capability");
        }
        return new PocketCapabilityKey(reference[..marker], version);
    }

    private static JsonElement CanonicalWorkflowArguments(
        JsonElement arguments,
        PocketCapabilityKey capability)
    {
        var values = arguments.EnumerateObject().ToDictionary(
            property => property.Name,
            property => property.Value.Clone(),
            StringComparer.Ordinal);
        if (capability == CapabilityIds.TimerStart)
        {
            CanonicalizeVisibleString(values, "title");
        }
        else if (capability == CapabilityIds.StickyUpsert)
        {
            CanonicalizeVisibleString(values, "title");
            CanonicalizeVisibleString(values, "body");
        }
        else
        {
            throw new CapabilityBrokerException("CAPABILITY_PLAN_INVALID", "pocket_workflow_presentation");
        }
        return CapabilityJson.From(values);
    }

    private static void CanonicalizeVisibleString(
        IDictionary<string, JsonElement> values,
        string field)
    {
        if (!values.TryGetValue(field, out var value) || value.ValueKind != JsonValueKind.String)
        {
            throw new CapabilityBrokerException("CAPABILITY_PLAN_INVALID", "pocket_workflow_presentation");
        }
        values[field] = CapabilityJson.From(TodayFocusApprovalText.Sanitize(value.GetString() ?? string.Empty));
    }

    internal static bool SupportsWorkflowPresentation(PocketCapabilityKey capability) =>
        PresentableWorkflowCapabilities.Contains(capability);
}
