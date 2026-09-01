using System.Security.Cryptography;
using System.Text.Json.Nodes;

namespace HoverPocket.Shell.PocketApps;

internal static class CodexPocketAppGenerationModelCatalog
{
    public const string ModelId = "gpt-5.6-sol";
    public const string ReasoningEffort = "medium";
    public const string ExpectedDigest = "bc11d3320055b4e235ecefe823fd78017e1a526b893541cc936fa0708d0d515c";
    public const string FileName = "codex-model-catalog.v1.json";
    public const int MaximumBytes = 64 * 1024;

    public static byte[] Load()
    {
        var hostRoot = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "PocketApps", "_Host"));
        var path = Path.GetFullPath(Path.Combine(hostRoot, FileName));
        if (!string.Equals(Path.GetDirectoryName(path), hostRoot, StringComparison.OrdinalIgnoreCase)
            || !File.Exists(path)
            || File.GetAttributes(path).HasFlag(FileAttributes.ReparsePoint))
        {
            throw Failure();
        }
        var length = new FileInfo(path).Length;
        if (length is <= 0 or > MaximumBytes) { throw Failure(); }
        var data = File.ReadAllBytes(path);
        Validate(data);
        return data;
    }

    public static void Validate(byte[] data)
    {
        if (data.Length is <= 0 or > MaximumBytes
            || !string.Equals(
                Convert.ToHexString(SHA256.HashData(data)).ToLowerInvariant(),
                ExpectedDigest,
                StringComparison.Ordinal))
        {
            throw Failure();
        }
        try
        {
            var root = JsonNode.Parse(data)?.AsObject() ?? throw Failure();
            if (root.Count != 1
                || root["models"] is not JsonArray { Count: 1 } models
                || models[0] is not JsonObject model
                || model["slug"]?.GetValue<string>() != ModelId
                || model["default_reasoning_level"]?.GetValue<string>() != ReasoningEffort
                || model["supported_in_api"]?.GetValue<bool>() != true
                || model["supports_parallel_tool_calls"]?.GetValue<bool>() != false
                || model["supports_search_tool"]?.GetValue<bool>() != false
                || !model.ContainsKey("tool_mode")
                || model["tool_mode"] is not null
                || !model.ContainsKey("multi_agent_version")
                || model["multi_agent_version"] is not null
                || model["base_instructions"]?.GetValue<string>()
                    != "Generate only the requested HoverPocket Pocket App DSL document. Do not call tools. Return only one JSON object that satisfies the supplied output schema.")
            {
                throw Failure();
            }
        }
        catch (Exception exception) when (exception is not PocketAppGenerationException)
        {
            throw Failure();
        }
    }

    private static PocketAppGenerationException Failure() => new("GENERATOR_UNAVAILABLE");
}
