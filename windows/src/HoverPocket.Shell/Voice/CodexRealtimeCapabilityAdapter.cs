using System.Text.Json;
using System.Text.Json.Nodes;

namespace HoverPocket.Shell.Voice;

// Both transports execute the same validated plans, approvals, and readback.
internal sealed class CodexRealtimeCapabilityAdapter(IOpenAIRealtimeCapabilityRuntime runtime) : ICodexVoiceDynamicToolRuntime
{
    public JsonElement Definitions => JsonSerializer.SerializeToElement(runtime.SessionTools.EnumerateArray().Select(tool => new
    {
        type = "function",
        name = tool.GetProperty("name").GetString(),
        description = tool.GetProperty("description").GetString(),
        inputSchema = ModelSchema(tool.GetProperty("parameters"))
    }).ToArray());

    internal static JsonElement ModelSchema(JsonElement schema)
    {
        // App-server's model schema omits these bounds. The native broker still
        // validates the full schema before any operation; the route proof stays exact.
        var result = JsonNode.Parse(schema.GetRawText())!.AsObject();
        Normalize(result);
        return JsonSerializer.SerializeToElement(result);

        static void Normalize(JsonObject node)
        {
            foreach (var key in new[] { "minimum", "maximum", "minLength", "maxLength", "format" }) node.Remove(key);
            if (node["properties"] is JsonObject properties)
                foreach (var property in properties)
                    if (property.Value is JsonObject child) Normalize(child);
            if (node["items"] is JsonObject items) Normalize(items);
        }
    }

    public async Task<CodexVoiceDynamicToolResponse> ExecuteAsync(JsonElement? parameters, string expectedThreadId, CancellationToken cancellationToken)
    {
        if (parameters is not { ValueKind: JsonValueKind.Object } value
            || !value.TryGetProperty("threadId", out var thread) || thread.ValueKind != JsonValueKind.String || thread.GetString() != expectedThreadId
            || !value.TryGetProperty("callId", out var call) || call.ValueKind != JsonValueKind.String
            || !value.TryGetProperty("tool", out var tool) || tool.ValueKind != JsonValueKind.String
            || !value.TryGetProperty("arguments", out var arguments) || arguments.ValueKind != JsonValueKind.Object
            || (value.TryGetProperty("namespace", out var ns) && ns.ValueKind != JsonValueKind.Null))
            return new(false, "{\"status\":\"failed\",\"error\":\"invalid_request\"}");
        var result = await runtime.ExecuteAsync(expectedThreadId, call.GetString()!, tool.GetString()!, arguments.GetRawText(), cancellationToken);
        var output = result.Output ?? "{\"status\":\"failed\",\"error\":\"unavailable\"}";
        using var parsed = JsonDocument.Parse(output);
        var success = parsed.RootElement.TryGetProperty("status", out var status) && status.GetString() == "succeeded";
        return new(success, output);
    }
}
