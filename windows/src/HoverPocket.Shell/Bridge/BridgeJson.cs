using System.Text.Json;
using System.Text.Json.Serialization;

namespace HoverPocket.Shell.Bridge;

internal static class BridgeJson
{
    public static JsonSerializerOptions Options { get; } = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) }
    };
}
