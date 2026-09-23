using System.Globalization;
using System.Text;
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

    public string RequireIdempotencyKey()
    {
        if (string.IsNullOrEmpty(IdempotencyKey)
            || IdempotencyKey.Length is < 16 or > 128
            || !char.IsAsciiLetterOrDigit(IdempotencyKey[0])
            || IdempotencyKey.Any(character => !char.IsAsciiLetterOrDigit(character)
                && character is not ('-' or '.' or ':' or '_')))
        {
            throw CapabilityJson.Invalid("idempotencyKey");
        }
        return IdempotencyKey;
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
        if (ExceedsMaxLength(value, maxLength) || (!allowEmpty && value.Length == 0))
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
        if (ExceedsMaxLength(value, maxLength))
        {
            throw Invalid(name);
        }
        return value;
    }

    private static bool ExceedsMaxLength(string value, int maxLength)
    {
        var count = 0;
        foreach (var _ in value.EnumerateRunes())
        {
            count += 1;
            if (count > maxLength)
            {
                return true;
            }
        }
        return false;
    }

    public static string TruncateString(string value, int maxLength)
    {
        var builder = new StringBuilder();
        var count = 0;
        foreach (var rune in value.EnumerateRunes())
        {
            if (count == maxLength)
            {
                break;
            }
            builder.Append(rune.ToString());
            count += 1;
        }
        return builder.ToString();
    }

    public static string SanitizeVisibleText(string value, int maxLength)
    {
        var builder = new StringBuilder();
        var count = 0;
        var pendingSpace = false;
        foreach (var rune in value.EnumerateRunes())
        {
            var category = Rune.GetUnicodeCategory(rune);
            if (Rune.IsWhiteSpace(rune)
                || category is UnicodeCategory.Control
                    or UnicodeCategory.Format
                    or UnicodeCategory.LineSeparator
                    or UnicodeCategory.ParagraphSeparator)
            {
                pendingSpace = builder.Length > 0;
                continue;
            }
            if (pendingSpace && count < maxLength)
            {
                builder.Append(' ');
                count++;
                pendingSpace = false;
            }
            if (count >= maxLength)
            {
                break;
            }
            builder.Append(rune.ToString());
            count++;
        }
        return builder.ToString().Trim();
    }

    public static string OutputString(
        string value,
        int maxLength,
        string field,
        bool allowEmpty = false)
    {
        if (ExceedsMaxLength(value, maxLength) || (!allowEmpty && value.Length == 0))
        {
            throw new CapabilityHandlerException("CAPABILITY_READBACK_MISMATCH", field);
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

    public static double RequiredNumber(JsonElement arguments, string name, double minimum, double maximum)
    {
        if (arguments.ValueKind != JsonValueKind.Object
            || !arguments.TryGetProperty(name, out var property)
            || property.ValueKind != JsonValueKind.Number
            || !property.TryGetDouble(out var value)
            || !double.IsFinite(value)
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
