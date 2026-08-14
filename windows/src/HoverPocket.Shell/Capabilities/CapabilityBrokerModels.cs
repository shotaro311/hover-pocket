using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace HoverPocket.Shell.Capabilities;

internal enum CapabilityOrigin
{
    NativeUi,
    Voice,
    Text,
    PocketSurface,
    Mcp,
    Connector
}

internal static class CapabilityOriginExtensions
{
    public static string WireValue(this CapabilityOrigin origin) => origin switch
    {
        CapabilityOrigin.NativeUi => "native_ui",
        CapabilityOrigin.Voice => "voice",
        CapabilityOrigin.Text => "text",
        CapabilityOrigin.PocketSurface => "pocket_surface",
        CapabilityOrigin.Mcp => "mcp",
        CapabilityOrigin.Connector => "connector",
        _ => throw new ArgumentOutOfRangeException(nameof(origin))
    };
}

internal sealed record CapabilityPrincipal(
    string UserId,
    string? PocketAppId = null,
    string? AgentSessionId = null);

internal sealed record CapabilityAppContext(
    string Id,
    string Version,
    string ManifestDigest);

internal enum CapabilityEffect
{
    Pure,
    PrivateRead,
    ReversibleLocalWrite,
    ExternalWrite,
    DestructiveSensitive,
    NativeAuthority
}

internal static class CapabilityEffectExtensions
{
    public static bool IsWrite(this CapabilityEffect effect) => effect is not (CapabilityEffect.Pure or CapabilityEffect.PrivateRead);

    public static string WireValue(this CapabilityEffect effect) => effect switch
    {
        CapabilityEffect.Pure => "pure",
        CapabilityEffect.PrivateRead => "private_read",
        CapabilityEffect.ReversibleLocalWrite => "reversible_local_write",
        CapabilityEffect.ExternalWrite => "external_write",
        CapabilityEffect.DestructiveSensitive => "destructive_sensitive",
        CapabilityEffect.NativeAuthority => "native_authority",
        _ => throw new ArgumentOutOfRangeException(nameof(effect))
    };
}

internal enum CapabilityApprovalPolicy
{
    None,
    PermissionGrant,
    BrokerPolicy,
    PerCall,
    StrongPerCall,
    RuntimeProhibited
}

internal static class CapabilityApprovalPolicyExtensions
{
    public static bool RequiresExecutionApproval(this CapabilityApprovalPolicy policy) =>
        policy is CapabilityApprovalPolicy.BrokerPolicy or CapabilityApprovalPolicy.PerCall or CapabilityApprovalPolicy.StrongPerCall;

    public static string WireValue(this CapabilityApprovalPolicy policy) => policy switch
    {
        CapabilityApprovalPolicy.None => "none",
        CapabilityApprovalPolicy.PermissionGrant => "permission_grant",
        CapabilityApprovalPolicy.BrokerPolicy => "broker_policy",
        CapabilityApprovalPolicy.PerCall => "per_call",
        CapabilityApprovalPolicy.StrongPerCall => "strong_per_call",
        CapabilityApprovalPolicy.RuntimeProhibited => "runtime_prohibited",
        _ => throw new ArgumentOutOfRangeException(nameof(policy))
    };
}

internal enum CapabilityIdempotencyPolicy
{
    NotApplicable,
    Optional,
    Required
}

internal enum CapabilityReadbackStrategy
{
    None,
    EntityGetById,
    CapabilityQuery,
    SameStoreSnapshot,
    OsState,
    ContentDigest
}

internal static class CapabilityReadbackStrategyExtensions
{
    public static string WireValue(this CapabilityReadbackStrategy strategy) => strategy switch
    {
        CapabilityReadbackStrategy.None => "none",
        CapabilityReadbackStrategy.EntityGetById => "entity_get_by_id",
        CapabilityReadbackStrategy.CapabilityQuery => "capability_query",
        CapabilityReadbackStrategy.SameStoreSnapshot => "same_store_snapshot",
        CapabilityReadbackStrategy.OsState => "os_state",
        CapabilityReadbackStrategy.ContentDigest => "content_digest",
        _ => throw new ArgumentOutOfRangeException(nameof(strategy))
    };
}

internal sealed record CapabilityLimits(
    int TimeoutMilliseconds,
    int MaximumPayloadBytes,
    int MaximumCallsPerMinute);

internal sealed record CapabilityReadbackPolicy(
    CapabilityReadbackStrategy Strategy,
    PocketCapabilityKey? Query,
    IReadOnlyList<string> MatchFields);

internal sealed record CapabilityPlanStep(
    string Id,
    PocketCapabilityKey Capability,
    JsonElement Arguments,
    string IdempotencyKey,
    IReadOnlyList<string> Dependencies);

internal sealed record CapabilityExecutionPlan(
    string Id,
    DateTimeOffset CreatedAt,
    CapabilityOrigin Origin,
    CapabilityPrincipal Principal,
    CapabilityAppContext? AppContext,
    IReadOnlyList<CapabilityPlanStep> Steps,
    IReadOnlySet<string> RequiredPermissions);

internal sealed record CapabilityPermissionSet(
    CapabilityPrincipal Principal,
    IReadOnlySet<string> Permissions)
{
    public bool Contains(IReadOnlySet<string> required) => required.All(Permissions.Contains);
}

internal sealed record CapabilityApprovalEffect(
    string StepId,
    PocketCapabilityKey Capability,
    CapabilityEffect Effect,
    string ArgumentDigest,
    string SummaryKey,
    bool RollbackAvailable);

internal sealed record CapabilityApprovalRequest(
    string Id,
    string PlanId,
    string PlanDigest,
    CapabilityPrincipal Principal,
    CapabilityAppContext? AppContext,
    DateTimeOffset CreatedAt,
    DateTimeOffset ExpiresAt,
    string Nonce,
    IReadOnlyList<CapabilityApprovalEffect> Effects,
    IReadOnlySet<string> RequiredPermissions);

internal readonly record struct CapabilityApprovalGrant(string Token);

internal sealed record CapabilityBrokerPreparation(
    string PlanDigest,
    CapabilityApprovalRequest? ApprovalRequest);

internal enum CapabilityReceiptStatus
{
    Succeeded,
    Rejected,
    Failed,
    Partial,
    Unknown
}

internal static class CapabilityReceiptStatusExtensions
{
    public static string WireValue(this CapabilityReceiptStatus status) => status.ToString().ToLowerInvariant();
}

internal enum CapabilityReadbackStatus
{
    Verified,
    Mismatch,
    Unavailable
}

internal static class CapabilityReadbackStatusExtensions
{
    public static string WireValue(this CapabilityReadbackStatus status) => status.ToString().ToLowerInvariant();
}

internal sealed record CapabilityReadbackReceipt(
    CapabilityReadbackStatus Status,
    CapabilityReadbackStrategy Strategy,
    DateTimeOffset? ObservedAt,
    JsonElement? Observed,
    string? EvidenceDigest);

internal sealed record CapabilitySafeError(
    string Code,
    bool Retryable,
    string MessageKey);

internal sealed record CapabilityReceipt(
    string InvocationId,
    string PlanId,
    string PlanDigest,
    PocketCapabilityKey Capability,
    CapabilityReceiptStatus Status,
    JsonElement? Output,
    CapabilityReadbackReceipt Readback,
    bool RollbackAvailable,
    string? RollbackStatus,
    string AuditEntryId,
    CapabilitySafeError? SafeError,
    DateTimeOffset CompletedAt,
    bool Replayed)
{
    public CapabilityReceipt ReplayCopy() => this with { Replayed = true };
}

internal sealed record CapabilityWorkflowReceipt(
    string PlanId,
    string PlanDigest,
    CapabilityReceiptStatus Status,
    IReadOnlyList<CapabilityReceipt> Steps,
    DateTimeOffset CompletedAt,
    bool Replayed)
{
    public CapabilityWorkflowReceipt ReplayCopy() => this with
    {
        Steps = Steps.Select(receipt => receipt.ReplayCopy()).ToArray(),
        Replayed = true
    };
}

internal sealed class CapabilityBrokerException(string code, string field) : Exception($"{code}: {field}")
{
    public string Code { get; } = code;
    public string Field { get; } = field;
}

internal static class CapabilityCanonicalJson
{
    public static string ArgumentsDigest(JsonElement arguments) => Digest(CanonicalBytes(arguments));

    public static string PlanDigest(CapabilityExecutionPlan plan)
    {
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream))
        {
            writer.WriteStartObject();
            if (plan.AppContext is not null)
            {
                writer.WritePropertyName("appContext");
                WriteAppContext(writer, plan.AppContext);
            }
            writer.WriteString("createdAt", Date(plan.CreatedAt));
            writer.WriteString("origin", plan.Origin.WireValue());
            writer.WriteString("planId", plan.Id);
            writer.WriteNumber("planVersion", 1);
            writer.WritePropertyName("principal");
            WritePrincipal(writer, plan.Principal);
            writer.WritePropertyName("requiredPermissions");
            writer.WriteStartArray();
            foreach (var permission in plan.RequiredPermissions.Order(StringComparer.Ordinal))
            {
                writer.WriteStringValue(permission);
            }
            writer.WriteEndArray();
            writer.WritePropertyName("steps");
            writer.WriteStartArray();
            foreach (var step in plan.Steps)
            {
                writer.WriteStartObject();
                writer.WritePropertyName("arguments");
                WriteElement(writer, step.Arguments);
                writer.WriteString("capabilityId", step.Capability.Id);
                writer.WriteNumber("capabilityVersion", step.Capability.Version);
                writer.WritePropertyName("dependsOn");
                writer.WriteStartArray();
                foreach (var dependency in step.Dependencies.Order(StringComparer.Ordinal))
                {
                    writer.WriteStringValue(dependency);
                }
                writer.WriteEndArray();
                writer.WriteString("idempotencyKey", step.IdempotencyKey);
                writer.WriteString("stepId", step.Id);
                writer.WriteEndObject();
            }
            writer.WriteEndArray();
            writer.WriteEndObject();
        }
        return Digest(stream.ToArray());
    }

    public static byte[] CanonicalBytes(JsonElement element)
    {
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream))
        {
            WriteElement(writer, element);
        }
        return stream.ToArray();
    }

    public static string Date(DateTimeOffset date) =>
        date.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture);

    private static string Digest(byte[] bytes) =>
        "sha256:" + Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();

    private static void WritePrincipal(Utf8JsonWriter writer, CapabilityPrincipal principal)
    {
        writer.WriteStartObject();
        if (principal.AgentSessionId is not null)
        {
            writer.WriteString("agentSessionId", principal.AgentSessionId);
        }
        if (principal.PocketAppId is not null)
        {
            writer.WriteString("pocketAppId", principal.PocketAppId);
        }
        writer.WriteString("userId", principal.UserId);
        writer.WriteEndObject();
    }

    private static void WriteAppContext(Utf8JsonWriter writer, CapabilityAppContext app)
    {
        writer.WriteStartObject();
        writer.WriteString("id", app.Id);
        writer.WriteString("manifestDigest", app.ManifestDigest);
        writer.WriteString("version", app.Version);
        writer.WriteEndObject();
    }

    public static void WriteElement(Utf8JsonWriter writer, JsonElement element)
    {
        switch (element.ValueKind)
        {
            case JsonValueKind.Object:
                writer.WriteStartObject();
                foreach (var property in element.EnumerateObject().OrderBy(property => property.Name, StringComparer.Ordinal))
                {
                    writer.WritePropertyName(property.Name);
                    WriteElement(writer, property.Value);
                }
                writer.WriteEndObject();
                break;
            case JsonValueKind.Array:
                writer.WriteStartArray();
                foreach (var item in element.EnumerateArray())
                {
                    WriteElement(writer, item);
                }
                writer.WriteEndArray();
                break;
            case JsonValueKind.String:
                writer.WriteStringValue(element.GetString());
                break;
            case JsonValueKind.Number:
                element.WriteTo(writer);
                break;
            case JsonValueKind.True:
            case JsonValueKind.False:
                writer.WriteBooleanValue(element.GetBoolean());
                break;
            case JsonValueKind.Null:
                writer.WriteNullValue();
                break;
            default:
                throw new CapabilityBrokerException("CAPABILITY_ARGUMENT_INVALID", "json");
        }
    }
}
