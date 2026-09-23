using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace HoverPocket.Shell.Capabilities;

internal sealed class PocketCapabilityDescriptor(
    PocketCapabilityKey key,
    string titleKey,
    CapabilityEffect effect,
    IEnumerable<string> permissions,
    CapabilityApprovalPolicy approvalPolicy,
    CapabilityIdempotencyPolicy idempotency,
    CapabilityLimits limits,
    CapabilityReadbackPolicy readback,
    bool rollbackAvailable,
    Action<JsonElement> inputValidator,
    Action<JsonElement> outputValidator)
{
    public PocketCapabilityKey Key { get; } = key;
    public string TitleKey { get; } = titleKey;
    public CapabilityEffect Effect { get; } = effect;
    public IReadOnlySet<string> Permissions { get; } = permissions.ToHashSet(StringComparer.Ordinal);
    public CapabilityApprovalPolicy ApprovalPolicy { get; } = approvalPolicy;
    public CapabilityIdempotencyPolicy Idempotency { get; } = idempotency;
    public CapabilityLimits Limits { get; } = limits;
    public CapabilityReadbackPolicy Readback { get; } = readback;
    public bool RollbackAvailable { get; } = rollbackAvailable;

    public void ValidateInput(JsonElement arguments)
    {
        inputValidator(arguments);
        if (CapabilityCanonicalJson.CanonicalBytes(arguments).Length > Limits.MaximumPayloadBytes)
        {
            throw new CapabilityBrokerException("CAPABILITY_ARGUMENT_INVALID", "payload");
        }
    }

    public void ValidateOutput(JsonElement output) => outputValidator(output);
}

internal sealed class CapabilityRegistry
{
    private readonly IReadOnlyDictionary<PocketCapabilityKey, PocketCapabilityDescriptor> _descriptors;
    private readonly PocketCapabilityHandlerSet _handlers;

    public CapabilityRegistry(
        PocketCapabilityHandlerSet handlers,
        IEnumerable<PocketCapabilityDescriptor>? descriptors = null)
    {
        var mapped = new Dictionary<PocketCapabilityKey, PocketCapabilityDescriptor>();
        foreach (var descriptor in descriptors ?? PocketCapabilityDescriptors.BuiltIn)
        {
            if (!mapped.TryAdd(descriptor.Key, descriptor))
            {
                throw new CapabilityBrokerException("CAPABILITY_DESCRIPTOR_DUPLICATE", descriptor.Key.Id);
            }
        }
        _descriptors = mapped;
        _handlers = handlers;
    }

    public IReadOnlyList<PocketCapabilityKey> DescriptorKeys => _descriptors.Keys.Order().ToArray();
    public IReadOnlyList<PocketCapabilityKey> AvailableHandlerKeys => _handlers.Keys;

    public PocketCapabilityDescriptor Resolve(PocketCapabilityKey key)
    {
        if (!_descriptors.TryGetValue(key, out var descriptor))
        {
            throw new CapabilityBrokerException("CAPABILITY_UNKNOWN", key.Id);
        }
        if (descriptor.ApprovalPolicy == CapabilityApprovalPolicy.RuntimeProhibited)
        {
            throw new CapabilityBrokerException("CAPABILITY_RUNTIME_PROHIBITED", key.Id);
        }
        if (!_handlers.Keys.Contains(key))
        {
            throw new CapabilityBrokerException("CAPABILITY_UNAVAILABLE", key.Id);
        }
        return descriptor;
    }

    public async Task<JsonElement> InvokeAsync(
        PocketCapabilityKey key,
        JsonElement arguments,
        CapabilityHandlerContext context,
        CancellationToken cancellationToken = default)
    {
        _ = Resolve(key);
        return await _handlers.InvokeAsync(key, arguments, context, cancellationToken);
    }
}

internal static class PocketCapabilityDescriptors
{
    private static readonly CapabilityLimits ReadLimits = new(3_000, 4_096, 120);
    private static readonly CapabilityLimits LocalWriteLimits = new(3_000, 4_096, 120);

    public static IReadOnlyList<PocketCapabilityDescriptor> BuiltIn { get; } = new[]
    {
        Descriptor(
            CapabilityIds.CalculatorEvaluate,
            CapabilityEffect.Pure,
            [],
            CapabilityApprovalPolicy.None,
            CapabilityIdempotencyPolicy.NotApplicable,
            new CapabilityLimits(1_000, 1_024, 600),
            new CapabilityReadbackPolicy(CapabilityReadbackStrategy.None, null, ["normalizedExpression", "result"]),
            false,
            CapabilitySchemaValidation.CalculatorInput,
            CapabilitySchemaValidation.CalculatorOutput),
        Descriptor(
            CapabilityIds.CalendarCreate,
            CapabilityEffect.ExternalWrite,
            ["calendar.events.write"],
            CapabilityApprovalPolicy.PerCall,
            CapabilityIdempotencyPolicy.Required,
            new CapabilityLimits(10_000, 16_384, 30),
            new CapabilityReadbackPolicy(CapabilityReadbackStrategy.CapabilityQuery, CapabilityIds.CalendarGet, ["eventRef", "eventId", "start", "end", "safeTitle"]),
            false,
            CapabilitySchemaValidation.CalendarCreateInput,
            CapabilitySchemaValidation.CalendarEventOutput),
        Descriptor(
            CapabilityIds.CalendarGet,
            CapabilityEffect.PrivateRead,
            ["calendar.events.read"],
            CapabilityApprovalPolicy.PermissionGrant,
            CapabilityIdempotencyPolicy.Optional,
            ReadLimits,
            new CapabilityReadbackPolicy(CapabilityReadbackStrategy.SameStoreSnapshot, null, ["eventRef", "eventId", "start", "end", "safeTitle"]),
            false,
            CapabilitySchemaValidation.CalendarGetInput,
            CapabilitySchemaValidation.CalendarEventOutput),
        Descriptor(
            CapabilityIds.CalendarList,
            CapabilityEffect.PrivateRead,
            ["calendar.events.read"],
            CapabilityApprovalPolicy.PermissionGrant,
            CapabilityIdempotencyPolicy.Optional,
            ReadLimits,
            new CapabilityReadbackPolicy(CapabilityReadbackStrategy.SameStoreSnapshot, null, ["events"]),
            false,
            CapabilitySchemaValidation.CalendarListInput,
            CapabilitySchemaValidation.CalendarListOutput),
        ControlsDescriptor(
            CapabilityIds.ControlsAvailability,
            CapabilityEffect.PrivateRead,
            CapabilityApprovalPolicy.PermissionGrant,
            CapabilityIdempotencyPolicy.Optional,
            CapabilitySchemaValidation.EmptyInput,
            CapabilitySchemaValidation.ControlsAvailabilityOutput,
            ["volumeAvailable", "brightnessAvailable", "mediaAvailable", "displayIds"]),
        ControlsDescriptor(
            CapabilityIds.ControlsBrightnessSet,
            CapabilityEffect.ReversibleLocalWrite,
            CapabilityApprovalPolicy.BrokerPolicy,
            CapabilityIdempotencyPolicy.Required,
            CapabilitySchemaValidation.ControlsBrightnessInput,
            CapabilitySchemaValidation.ControlsBrightnessOutput,
            ["displayId", "level", "controllable"]),
        ControlsDescriptor(
            CapabilityIds.ControlsMediaCommand,
            CapabilityEffect.ReversibleLocalWrite,
            CapabilityApprovalPolicy.BrokerPolicy,
            CapabilityIdempotencyPolicy.Required,
            CapabilitySchemaValidation.ControlsMediaInput,
            CapabilitySchemaValidation.ControlsMediaOutput,
            ["command", "available", "isPlaying", "safeTitle", "safeSource"]),
        ControlsDescriptor(
            CapabilityIds.ControlsMuteSet,
            CapabilityEffect.ReversibleLocalWrite,
            CapabilityApprovalPolicy.BrokerPolicy,
            CapabilityIdempotencyPolicy.Required,
            CapabilitySchemaValidation.ControlsMuteInput,
            CapabilitySchemaValidation.ControlsVolumeOutput,
            ["level", "muted"]),
        ControlsDescriptor(
            CapabilityIds.ControlsVolumeGet,
            CapabilityEffect.PrivateRead,
            CapabilityApprovalPolicy.PermissionGrant,
            CapabilityIdempotencyPolicy.Optional,
            CapabilitySchemaValidation.EmptyInput,
            CapabilitySchemaValidation.ControlsVolumeOutput,
            ["level", "muted"]),
        ControlsDescriptor(
            CapabilityIds.ControlsVolumeSet,
            CapabilityEffect.ReversibleLocalWrite,
            CapabilityApprovalPolicy.BrokerPolicy,
            CapabilityIdempotencyPolicy.Required,
            CapabilitySchemaValidation.ControlsVolumeInput,
            CapabilitySchemaValidation.ControlsVolumeOutput,
            ["level", "muted"]),
        Descriptor(
            CapabilityIds.StickyArchive,
            CapabilityEffect.ReversibleLocalWrite,
            ["sticky.write"],
            CapabilityApprovalPolicy.BrokerPolicy,
            CapabilityIdempotencyPolicy.Required,
            LocalWriteLimits,
            new CapabilityReadbackPolicy(CapabilityReadbackStrategy.CapabilityQuery, CapabilityIds.StickyStatus, ["noteId", "state", "updatedAt"]),
            false,
            CapabilitySchemaValidation.StickyIdInput,
            CapabilitySchemaValidation.StickyArchivedOutput),
        Descriptor(
            CapabilityIds.StickyDelete,
            CapabilityEffect.DestructiveSensitive,
            ["sticky.delete"],
            CapabilityApprovalPolicy.StrongPerCall,
            CapabilityIdempotencyPolicy.Required,
            LocalWriteLimits,
            new CapabilityReadbackPolicy(CapabilityReadbackStrategy.CapabilityQuery, CapabilityIds.StickyStatus, ["noteId", "state", "updatedAt"]),
            false,
            CapabilitySchemaValidation.StickyIdInput,
            CapabilitySchemaValidation.StickyDeletedOutput),
        Descriptor(
            CapabilityIds.StickyGet,
            CapabilityEffect.PrivateRead,
            ["sticky.read"],
            CapabilityApprovalPolicy.PermissionGrant,
            CapabilityIdempotencyPolicy.Optional,
            ReadLimits,
            new CapabilityReadbackPolicy(CapabilityReadbackStrategy.SameStoreSnapshot, null, ["noteId", "updatedAt"]),
            false,
            value => CapabilitySchemaValidation.IdentifierInput(value, "noteId", 128, false),
            CapabilitySchemaValidation.StickyOutput),
        Descriptor(
            CapabilityIds.StickyStatus,
            CapabilityEffect.PrivateRead,
            ["sticky.read"],
            CapabilityApprovalPolicy.PermissionGrant,
            CapabilityIdempotencyPolicy.Optional,
            ReadLimits,
            new CapabilityReadbackPolicy(CapabilityReadbackStrategy.SameStoreSnapshot, null, ["noteId", "state", "updatedAt"]),
            false,
            CapabilitySchemaValidation.StickyIdInput,
            CapabilitySchemaValidation.StickyStatusOutput),
        Descriptor(
            CapabilityIds.StickyUpsert,
            CapabilityEffect.ReversibleLocalWrite,
            ["sticky.write"],
            CapabilityApprovalPolicy.BrokerPolicy,
            CapabilityIdempotencyPolicy.Required,
            LocalWriteLimits,
            new CapabilityReadbackPolicy(CapabilityReadbackStrategy.CapabilityQuery, CapabilityIds.StickyGet, ["noteId", "title", "body", "updatedAt"]),
            false,
            CapabilitySchemaValidation.StickyUpsertInput,
            CapabilitySchemaValidation.StickyOutput),
        Descriptor(
            CapabilityIds.NativeAuthority,
            CapabilityEffect.NativeAuthority,
            ["system.native"],
            CapabilityApprovalPolicy.RuntimeProhibited,
            CapabilityIdempotencyPolicy.Required,
            new CapabilityLimits(3_000, 4_096, 1),
            new CapabilityReadbackPolicy(CapabilityReadbackStrategy.OsState, null, ["status"]),
            false,
            value => CapabilitySchemaValidation.ExactKeys(value, []),
            value =>
            {
                CapabilitySchemaValidation.ExactKeys(value, ["status"]);
                if (CapabilitySchemaValidation.String(value, "status", 0, 32) != "unavailable")
                {
                    throw new CapabilityBrokerException("CAPABILITY_READBACK_MISMATCH", "status");
                }
            }),
        TimerDescriptor(CapabilityIds.TimerGet, CapabilityEffect.PrivateRead, CapabilityApprovalPolicy.PermissionGrant, CapabilityIdempotencyPolicy.Optional, CapabilitySchemaValidation.TimerIdInput, false),
        TimerDescriptor(CapabilityIds.TimerPause, CapabilityEffect.ReversibleLocalWrite, CapabilityApprovalPolicy.BrokerPolicy, CapabilityIdempotencyPolicy.Required, CapabilitySchemaValidation.TimerIdInput, false),
        TimerDescriptor(CapabilityIds.TimerResume, CapabilityEffect.ReversibleLocalWrite, CapabilityApprovalPolicy.BrokerPolicy, CapabilityIdempotencyPolicy.Required, CapabilitySchemaValidation.TimerIdInput, false),
        TimerDescriptor(CapabilityIds.TimerStart, CapabilityEffect.ReversibleLocalWrite, CapabilityApprovalPolicy.BrokerPolicy, CapabilityIdempotencyPolicy.Required, CapabilitySchemaValidation.TimerStartInput, true),
        TimerDescriptor(CapabilityIds.TimerStop, CapabilityEffect.ReversibleLocalWrite, CapabilityApprovalPolicy.BrokerPolicy, CapabilityIdempotencyPolicy.Required, CapabilitySchemaValidation.TimerIdInput, false)
    }.OrderBy(descriptor => descriptor.Key).ToArray();

    private static PocketCapabilityDescriptor Descriptor(
        PocketCapabilityKey key,
        CapabilityEffect effect,
        IEnumerable<string> permissions,
        CapabilityApprovalPolicy approval,
        CapabilityIdempotencyPolicy idempotency,
        CapabilityLimits limits,
        CapabilityReadbackPolicy readback,
        bool rollback,
        Action<JsonElement> input,
        Action<JsonElement> output) =>
        new(
            key,
            $"capability.{key.Id}",
            effect,
            permissions,
            approval,
            idempotency,
            limits,
            readback,
            rollback,
            input,
            output);

    private static PocketCapabilityDescriptor TimerDescriptor(
        PocketCapabilityKey key,
        CapabilityEffect effect,
        CapabilityApprovalPolicy approval,
        CapabilityIdempotencyPolicy idempotency,
        Action<JsonElement> input,
        bool rollback) =>
        Descriptor(
            key,
            effect,
            effect == CapabilityEffect.PrivateRead ? new HashSet<string>(["timer.read"], StringComparer.Ordinal) : new HashSet<string>(["timer.write"], StringComparer.Ordinal),
            approval,
            idempotency,
            effect == CapabilityEffect.PrivateRead ? ReadLimits : LocalWriteLimits,
            new CapabilityReadbackPolicy(
                effect == CapabilityEffect.PrivateRead ? CapabilityReadbackStrategy.SameStoreSnapshot : CapabilityReadbackStrategy.CapabilityQuery,
                effect == CapabilityEffect.PrivateRead ? null : CapabilityIds.TimerGet,
                ["timerId", "state", "endAt"]),
            rollback,
            input,
            CapabilitySchemaValidation.TimerOutput);

    private static PocketCapabilityDescriptor ControlsDescriptor(
        PocketCapabilityKey key,
        CapabilityEffect effect,
        CapabilityApprovalPolicy approval,
        CapabilityIdempotencyPolicy idempotency,
        Action<JsonElement> input,
        Action<JsonElement> output,
        IReadOnlyList<string> matchFields) =>
        Descriptor(
            key,
            effect,
            effect == CapabilityEffect.PrivateRead
                ? new HashSet<string>(["controls.read"], StringComparer.Ordinal)
                : new HashSet<string>(["controls.write"], StringComparer.Ordinal),
            approval,
            idempotency,
            effect == CapabilityEffect.PrivateRead ? ReadLimits : LocalWriteLimits,
            new CapabilityReadbackPolicy(
                effect == CapabilityEffect.PrivateRead
                    ? CapabilityReadbackStrategy.SameStoreSnapshot
                    : CapabilityReadbackStrategy.OsState,
                null,
                matchFields),
            false,
            input,
            output);
}

internal static partial class CapabilitySchemaValidation
{
    private static readonly Regex CalculatorResultPattern = new(
        "^-?(?:0|[1-9][0-9]{0,17})(?:\\.[0-9]{1,12})?$",
        RegexOptions.CultureInvariant);
    private static readonly Regex TimeZonePattern = new(
        "^(?:UTC|Etc/UTC|[A-Za-z_]+(?:/[A-Za-z0-9._+-]+)+)$",
        RegexOptions.CultureInvariant);

    public static void ExactKeys(JsonElement value, IEnumerable<string> expected)
    {
        if (value.ValueKind != JsonValueKind.Object)
        {
            throw Invalid("object");
        }
        var properties = value.EnumerateObject().ToArray();
        var keys = properties.Select(property => property.Name).ToHashSet(StringComparer.Ordinal);
        var expectedKeys = expected.ToHashSet(StringComparer.Ordinal);
        if (keys.Count != properties.Length || !keys.SetEquals(expectedKeys))
        {
            throw Invalid("keys");
        }
    }

    public static string String(
        JsonElement value,
        string name,
        int minimum,
        int maximum,
        IReadOnlySet<string>? allowed = null)
    {
        if (!value.TryGetProperty(name, out var property) || property.ValueKind != JsonValueKind.String)
        {
            throw Invalid(name);
        }
        var text = property.GetString() ?? string.Empty;
        var length = text.EnumerateRunes().Count();
        if (length < minimum || length > maximum || (allowed is not null && !allowed.Contains(text)))
        {
            throw Invalid(name);
        }
        return text;
    }

    public static void NullableString(JsonElement value, string name, int maximum)
    {
        if (!value.TryGetProperty(name, out var property))
        {
            throw Invalid(name);
        }
        if (property.ValueKind == JsonValueKind.Null)
        {
            return;
        }
        if (property.ValueKind != JsonValueKind.String || (property.GetString() ?? string.Empty).EnumerateRunes().Count() > maximum)
        {
            throw Invalid(name);
        }
    }

    public static int Integer(JsonElement value, string name, int minimum, int maximum)
    {
        if (!value.TryGetProperty(name, out var property)
            || property.ValueKind != JsonValueKind.Number
            || !property.TryGetInt32(out var result)
            || result < minimum
            || result > maximum)
        {
            throw Invalid(name);
        }
        return result;
    }

    public static double Number(JsonElement value, string name, double minimum, double maximum)
    {
        if (!value.TryGetProperty(name, out var property)
            || property.ValueKind != JsonValueKind.Number
            || !property.TryGetDouble(out var result)
            || !double.IsFinite(result)
            || result < minimum
            || result > maximum)
        {
            throw Invalid(name);
        }
        return result;
    }

    public static bool Boolean(JsonElement value, string name)
    {
        if (!value.TryGetProperty(name, out var property)
            || property.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
        {
            throw Invalid(name);
        }
        return property.GetBoolean();
    }

    public static void IdentifierInput(JsonElement value, string name, int maximum, bool uuid)
    {
        ExactKeys(value, new HashSet<string>([name], StringComparer.Ordinal));
        var identifier = String(value, name, 1, maximum);
        if (uuid && !Guid.TryParse(identifier, out _))
        {
            throw Invalid(name);
        }
    }

    public static void CalendarListInput(JsonElement value)
    {
        ExactKeys(value, ["range", "timezone"]);
        _ = String(value, "range", 1, 16, new HashSet<string>(["today"], StringComparer.Ordinal));
        var timezone = String(value, "timezone", 1, 64);
        if (!TimeZonePattern.IsMatch(timezone))
        {
            throw Invalid("timezone");
        }
    }

    public static void EmptyInput(JsonElement value) => ExactKeys(value, []);

    public static void ControlsVolumeInput(JsonElement value)
    {
        ExactKeys(value, ["level"]);
        _ = Number(value, "level", 0, 1);
    }

    public static void ControlsMuteInput(JsonElement value)
    {
        ExactKeys(value, ["muted"]);
        _ = Boolean(value, "muted");
    }

    public static void ControlsBrightnessInput(JsonElement value)
    {
        ExactKeys(value, ["displayId", "level"]);
        _ = String(value, "displayId", 1, 128);
        _ = Number(value, "level", 0.05, 1);
    }

    public static void ControlsMediaInput(JsonElement value)
    {
        ExactKeys(value, ["command"]);
        _ = String(
            value,
            "command",
            1,
            16,
            new HashSet<string>(["play_pause", "next", "previous"], StringComparer.Ordinal));
    }

    public static void ControlsVolumeOutput(JsonElement value)
    {
        ExactKeys(value, ["level", "muted"]);
        _ = Number(value, "level", 0, 1);
        _ = Boolean(value, "muted");
    }

    public static void ControlsBrightnessOutput(JsonElement value)
    {
        ExactKeys(value, ["displayId", "level", "controllable"]);
        _ = String(value, "displayId", 1, 128);
        _ = Number(value, "level", 0, 1);
        if (!Boolean(value, "controllable"))
        {
            throw Invalid("controllable");
        }
    }

    public static void ControlsAvailabilityOutput(JsonElement value)
    {
        ExactKeys(value, ["volumeAvailable", "brightnessAvailable", "mediaAvailable", "displayIds"]);
        _ = Boolean(value, "volumeAvailable");
        _ = Boolean(value, "brightnessAvailable");
        _ = Boolean(value, "mediaAvailable");
        if (!value.TryGetProperty("displayIds", out var displayIds)
            || displayIds.ValueKind != JsonValueKind.Array
            || displayIds.GetArrayLength() > 16)
        {
            throw Invalid("displayIds");
        }
        foreach (var displayId in displayIds.EnumerateArray())
        {
            if (displayId.ValueKind != JsonValueKind.String)
            {
                throw Invalid("displayIds");
            }
            var raw = displayId.GetString() ?? string.Empty;
            if (raw.Length == 0 || raw.EnumerateRunes().Count() > 128)
            {
                throw Invalid("displayIds");
            }
        }
    }

    public static void ControlsMediaOutput(JsonElement value)
    {
        ExactKeys(value, ["command", "available", "isPlaying", "safeTitle", "safeSource"]);
        _ = String(
            value,
            "command",
            1,
            16,
            new HashSet<string>(["play_pause", "next", "previous"], StringComparer.Ordinal));
        if (!Boolean(value, "available"))
        {
            throw Invalid("available");
        }
        _ = Boolean(value, "isPlaying");
        _ = String(value, "safeTitle", 0, 160);
        _ = String(value, "safeSource", 0, 120);
    }

    public static void CalculatorInput(JsonElement value)
    {
        ExactKeys(value, ["expression"]);
        _ = String(value, "expression", 1, 256);
    }

    public static void CalculatorOutput(JsonElement value)
    {
        ExactKeys(value, ["normalizedExpression", "result"]);
        _ = String(value, "normalizedExpression", 1, 512);
        if (!CalculatorResultPattern.IsMatch(String(value, "result", 1, 32)))
        {
            throw Invalid("result");
        }
    }

    public static void CalendarGetInput(JsonElement value) => IdentifierInput(value, "eventRef", 256, false);

    public static void CalendarCreateInput(JsonElement value)
    {
        ExactKeys(value, ["calendarId", "title", "start", "end", "isAllDay", "location", "notes"]);
        NullableString(value, "calendarId", 256);
        _ = String(value, "title", 1, 160);
        var start = String(value, "start", 1, 64);
        var end = String(value, "end", 1, 64);
        _ = Boolean(value, "isAllDay");
        NullableString(value, "location", 500);
        NullableString(value, "notes", 10_000);
        if (!DateTimeOffset.TryParse(start, out var startDate)
            || !DateTimeOffset.TryParse(end, out var endDate)
            || endDate <= startDate)
        {
            throw Invalid("start_end");
        }
    }

    public static void CalendarEventOutput(JsonElement value)
    {
        ExactKeys(value, ["eventRef", "eventId", "start", "end", "safeTitle"]);
        _ = String(value, "eventRef", 1, 256);
        _ = String(value, "eventId", 1, 256);
        DateFields(value);
        _ = String(value, "safeTitle", 0, 160);
    }

    public static void CalendarListOutput(JsonElement value)
    {
        ExactKeys(value, ["events"]);
        if (!value.TryGetProperty("events", out var events) || events.ValueKind != JsonValueKind.Array || events.GetArrayLength() > 128)
        {
            throw Invalid("events");
        }
        foreach (var item in events.EnumerateArray())
        {
            ExactKeys(item, ["eventRef", "start", "end", "safeTitle"]);
            _ = String(item, "eventRef", 1, 256);
            DateFields(item);
            _ = String(item, "safeTitle", 0, 160);
        }
    }

    public static void TimerIdInput(JsonElement value) => IdentifierInput(value, "timerId", 36, true);

    public static void TimerStartInput(JsonElement value)
    {
        ExactKeys(value, ["durationSeconds", "title", "sourceRef"]);
        _ = Integer(value, "durationSeconds", 1, 86_400);
        _ = String(value, "title", 1, 80);
        NullableString(value, "sourceRef", 256);
    }

    public static void TimerOutput(JsonElement value)
    {
        ExactKeys(value, ["timerId", "state", "endAt"]);
        _ = String(value, "timerId", 1, 36);
        _ = String(value, "state", 1, 16, new HashSet<string>(["running", "paused", "stopped"], StringComparer.Ordinal));
        var endAt = value.GetProperty("endAt");
        if (endAt.ValueKind == JsonValueKind.Null)
        {
            return;
        }
        if (endAt.ValueKind != JsonValueKind.String || !DateTimeOffset.TryParse(endAt.GetString(), out _))
        {
            throw Invalid("endAt");
        }
    }

    public static void StickyUpsertInput(JsonElement value)
    {
        ExactKeys(value, ["stableKey", "title", "body", "color"]);
        _ = PocketStableKey.Validate(String(value, "stableKey", 1, PocketStableKey.MaximumScalars));
        _ = String(value, "title", 0, 120);
        _ = String(value, "body", 0, 10_000);
        _ = String(value, "color", 1, 16, new HashSet<string>(["yellow", "blue", "green", "pink", "gray"], StringComparer.Ordinal));
    }

    public static void StickyIdInput(JsonElement value) => IdentifierInput(value, "noteId", 128, true);

    public static void StickyStatusOutput(JsonElement value)
    {
        ExactKeys(value, ["noteId", "state", "updatedAt"]);
        _ = String(value, "noteId", 1, 128);
        var state = String(value, "state", 1, 16, new HashSet<string>(["active", "archived", "missing"], StringComparer.Ordinal));
        var updatedAt = value.GetProperty("updatedAt");
        if (state == "missing" && updatedAt.ValueKind == JsonValueKind.Null)
        {
            return;
        }
        if (state is "active" or "archived"
            && updatedAt.ValueKind == JsonValueKind.String
            && DateTimeOffset.TryParse(updatedAt.GetString(), out _))
        {
            return;
        }
        throw Invalid("updatedAt");
    }

    public static void StickyArchivedOutput(JsonElement value)
    {
        StickyStatusOutput(value);
        if (value.GetProperty("state").GetString() != "archived")
        {
            throw Invalid("state");
        }
    }

    public static void StickyDeletedOutput(JsonElement value)
    {
        StickyStatusOutput(value);
        if (value.GetProperty("state").GetString() != "missing")
        {
            throw Invalid("state");
        }
    }

    public static void StickyOutput(JsonElement value)
    {
        ExactKeys(value, ["noteId", "title", "body", "updatedAt"]);
        _ = String(value, "noteId", 1, 128);
        _ = String(value, "title", 0, 120);
        _ = String(value, "body", 0, 10_000);
        if (!DateTimeOffset.TryParse(String(value, "updatedAt", 1, 64), out _))
        {
            throw Invalid("updatedAt");
        }
    }

    private static void DateFields(JsonElement value)
    {
        if (!DateTimeOffset.TryParse(String(value, "start", 1, 64), out _)
            || !DateTimeOffset.TryParse(String(value, "end", 1, 64), out _))
        {
            throw Invalid("start_end");
        }
    }

    private static CapabilityBrokerException Invalid(string field) =>
        new("CAPABILITY_ARGUMENT_INVALID", field);
}
