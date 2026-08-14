using System.Text.Json;

namespace HoverPocket.Shell.Capabilities;

internal readonly record struct PocketCapabilityKey(string Id, int Version) : IComparable<PocketCapabilityKey>
{
    public int CompareTo(PocketCapabilityKey other)
    {
        var idComparison = string.Compare(Id, other.Id, StringComparison.Ordinal);
        return idComparison != 0 ? idComparison : Version.CompareTo(other.Version);
    }
}

internal sealed record CapabilityHandlerContext(string? IdempotencyKey, DateTimeOffset Now)
{
    public static CapabilityHandlerContext Create(string? idempotencyKey = null)
    {
        return new CapabilityHandlerContext(idempotencyKey, DateTimeOffset.UtcNow);
    }
}

internal sealed class CapabilityHandlerException : Exception
{
    public CapabilityHandlerException(string code, string field)
        : base($"{code}: {field}")
    {
        Code = code;
        Field = field;
    }

    public string Code { get; }

    public string Field { get; }
}

internal interface IPocketCapabilityHandler
{
    PocketCapabilityKey Key { get; }

    Task<JsonElement> HandleAsync(
        JsonElement arguments,
        CapabilityHandlerContext context,
        CancellationToken cancellationToken = default);
}

internal sealed class PocketCapabilityHandlerSet
{
    private readonly Dictionary<PocketCapabilityKey, IPocketCapabilityHandler> _handlers = [];

    public PocketCapabilityHandlerSet(IEnumerable<IPocketCapabilityHandler>? handlers = null)
    {
        foreach (var handler in handlers ?? [])
        {
            Register(handler);
        }
    }

    public IReadOnlyList<PocketCapabilityKey> Keys => _handlers.Keys.Order().ToArray();

    public void Register(IPocketCapabilityHandler handler)
    {
        if (!_handlers.TryAdd(handler.Key, handler))
        {
            throw new CapabilityHandlerException("CAPABILITY_HANDLER_DUPLICATE", handler.Key.Id);
        }
    }

    public async Task<JsonElement> InvokeAsync(
        PocketCapabilityKey key,
        JsonElement arguments,
        CapabilityHandlerContext? context = null,
        CancellationToken cancellationToken = default)
    {
        if (!_handlers.TryGetValue(key, out var handler))
        {
            throw new CapabilityHandlerException("CAPABILITY_UNKNOWN", key.Id);
        }

        return await handler.HandleAsync(
            arguments,
            context ?? CapabilityHandlerContext.Create(),
            cancellationToken);
    }
}

internal static class CapabilityJson
{
    private static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase
    };

    public static JsonElement From<T>(T value)
    {
        return JsonSerializer.SerializeToElement(value, Options);
    }

    public static string RequiredString(JsonElement arguments, string name, int maxLength, bool allowEmpty = false)
    {
        if (arguments.ValueKind != JsonValueKind.Object
            || !arguments.TryGetProperty(name, out var property)
            || property.ValueKind != JsonValueKind.String)
        {
            throw Invalid(name);
        }

        var value = property.GetString() ?? string.Empty;
        if (value.Length > maxLength || (!allowEmpty && value.Length == 0))
        {
            throw Invalid(name);
        }
        return value;
    }

    public static string? OptionalString(JsonElement arguments, string name, int maxLength)
    {
        if (arguments.ValueKind != JsonValueKind.Object)
        {
            throw Invalid(name);
        }
        if (!arguments.TryGetProperty(name, out var property) || property.ValueKind == JsonValueKind.Null)
        {
            return null;
        }
        if (property.ValueKind != JsonValueKind.String)
        {
            throw Invalid(name);
        }
        var value = property.GetString() ?? string.Empty;
        if (value.Length > maxLength)
        {
            throw Invalid(name);
        }
        return value;
    }

    public static int RequiredInt(JsonElement arguments, string name, int minimum, int maximum)
    {
        if (arguments.ValueKind != JsonValueKind.Object
            || !arguments.TryGetProperty(name, out var property)
            || property.ValueKind != JsonValueKind.Number
            || !property.TryGetInt32(out var value)
            || value < minimum
            || value > maximum)
        {
            throw Invalid(name);
        }
        return value;
    }

    public static bool RequiredBool(JsonElement arguments, string name)
    {
        if (arguments.ValueKind != JsonValueKind.Object
            || !arguments.TryGetProperty(name, out var property)
            || property.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
        {
            throw Invalid(name);
        }
        return property.GetBoolean();
    }

    public static CapabilityHandlerException Invalid(string field)
    {
        return new CapabilityHandlerException("CAPABILITY_ARGUMENT_INVALID", field);
    }
}
