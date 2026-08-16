using System.Collections;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace HoverPocket.Shell.PocketApps;

internal sealed class PocketSurfaceRuntimeException(string path) : Exception(path)
{
    public string Path { get; } = path;
}

internal sealed record PocketSurfaceRenderNode(
    string Type,
    IReadOnlyDictionary<string, object?> Properties,
    IReadOnlyList<PocketSurfaceRenderNode> Children);

internal sealed record PocketSurfaceDocument(
    string Id,
    PocketSurfaceRenderNode Root,
    int NodeCount,
    int MaximumDepth)
{
    public byte[] CanonicalRenderModelBytes()
    {
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream))
        {
            writer.WriteStartObject();
            writer.WriteString("hostRegion", "provider_host");
            writer.WritePropertyName("root");
            PocketSurfaceCanonicalJson.WriteNode(writer, Root);
            writer.WriteString("surfaceId", Id);
            writer.WriteNumber("surfaceVersion", 1);
            writer.WriteEndObject();
        }
        return stream.ToArray();
    }
}

internal sealed class PocketSurfaceRuntime(
    IReadOnlySet<string> knownQueries,
    IReadOnlySet<string> knownWorkflows)
{
    public const int MaximumDocumentBytes = 256 * 1024;
    public const int MaximumNodes = 256;
    public const int MaximumDepth = 8;

    private static readonly Regex IdentifierPattern = new(
        "^[A-Za-z][A-Za-z0-9_-]{0,63}$",
        RegexOptions.CultureInvariant);

    private static readonly Regex QueryPattern = new(
        "^[a-z][a-z0-9]*(?:\\.[a-z][a-z0-9_]*){2,}@[1-9][0-9]*$",
        RegexOptions.CultureInvariant);

    private static readonly Regex BindingNamePattern = new(
        "^[A-Za-z][A-Za-z0-9_]*$",
        RegexOptions.CultureInvariant);

    private static readonly Regex AssetComponentPattern = new(
        "^[A-Za-z0-9._-]+$",
        RegexOptions.CultureInvariant);

    private readonly IReadOnlySet<string> _knownQueries = knownQueries;
    private readonly IReadOnlySet<string> _knownWorkflows = knownWorkflows;

    public PocketSurfaceDocument Load(ReadOnlyMemory<byte> data)
    {
        Require(data.Length <= MaximumDocumentBytes, "$:document_size");

        JsonDocument document;
        try
        {
            document = JsonDocument.Parse(data, new JsonDocumentOptions
            {
                AllowTrailingCommas = false,
                CommentHandling = JsonCommentHandling.Disallow,
                MaxDepth = 16
            });
        }
        catch (JsonException)
        {
            throw new PocketSurfaceRuntimeException("$:json");
        }

        using (document)
        {
            var rootObject = RequireObject(document.RootElement, "$");
            ExactKeys(
                rootObject,
                ["$schema", "surfaceVersion", "id", "hostBoundary", "root"],
                [],
                "$");
            Require(GetString(rootObject.GetProperty("$schema"), "$.$schema") == "hoverpocket://schemas/pocket-surface/v1", "$.$schema");
            Require(GetInteger(rootObject.GetProperty("surfaceVersion"), "$.surfaceVersion") == 1, "$.surfaceVersion");
            var id = GetString(rootObject.GetProperty("id"), "$.id");
            Require(IdentifierPattern.IsMatch(id), "$.id");
            ValidateHostBoundary(rootObject.GetProperty("hostBoundary"));

            var nodeCount = 0;
            var maximumDepth = 0;
            var root = ValidateNode(
                rootObject.GetProperty("root"),
                "$.root",
                1,
                ref nodeCount,
                ref maximumDepth);
            return new PocketSurfaceDocument(id, root, nodeCount, maximumDepth);
        }
    }

    private static void ValidateHostBoundary(JsonElement value)
    {
        var boundary = RequireObject(value, "$.hostBoundary");
        ExactKeys(
            boundary,
            ["region", "mayRenderHeader", "mayRenderVoiceLane", "mayRenderApproval", "mayRenderReceipt"],
            [],
            "$.hostBoundary");
        Require(GetString(boundary.GetProperty("region"), "$.hostBoundary.region") == "provider_host", "$.hostBoundary.region");
        foreach (var key in new[] { "mayRenderHeader", "mayRenderVoiceLane", "mayRenderApproval", "mayRenderReceipt" })
        {
            Require(!GetBoolean(boundary.GetProperty(key), $"$.hostBoundary.{key}"), $"$.hostBoundary.{key}");
        }
    }

    private PocketSurfaceRenderNode ValidateNode(
        JsonElement value,
        string path,
        int depth,
        ref int nodeCount,
        ref int maximumDepth)
    {
        Require(depth <= MaximumDepth, $"{path}:depth");
        nodeCount++;
        Require(nodeCount <= MaximumNodes, $"{path}:node_count");
        maximumDepth = Math.Max(maximumDepth, depth);

        var node = RequireObject(value, path);
        if (!node.TryGetProperty("type", out var typeElement))
        {
            throw new PocketSurfaceRuntimeException($"{path}:missing_key");
        }
        var type = GetString(typeElement, $"{path}.type");

        return type switch
        {
            "stack" => ValidateStack(node, path, type, depth, ref nodeCount, ref maximumDepth),
            "grid" => ValidateGrid(node, path, type, depth, ref nodeCount, ref maximumDepth),
            "text" => ValidateText(node, path, type),
            "image" => ValidateImage(node, path, type),
            "button" => ValidateButton(node, path, type),
            "textField" => ValidateTextField(node, path, type),
            "toggle" => ValidateToggle(node, path, type),
            "picker" => ValidatePicker(node, path, type),
            "calendarEventPicker" => ValidateCalendarEventPicker(node, path, type),
            "durationPicker" => ValidateDurationPicker(node, path, type),
            "status" => ValidateStatus(node, path, type),
            _ => throw new PocketSurfaceRuntimeException($"{path}.type:unknown")
        };
    }

    private PocketSurfaceRenderNode ValidateStack(
        JsonElement node,
        string path,
        string type,
        int depth,
        ref int nodeCount,
        ref int maximumDepth)
    {
        ExactKeys(node, ["type", "axis", "children"], ["spacing"], path);
        var axis = GetString(node.GetProperty("axis"), $"{path}.axis");
        Require(axis is "vertical" or "horizontal", $"{path}.axis");
        var spacing = OptionalInteger(node, "spacing", 0, $"{path}.spacing");
        Require(spacing is >= 0 and <= 64, $"{path}.spacing");
        var children = ValidateChildren(node.GetProperty("children"), path, depth, ref nodeCount, ref maximumDepth);
        return RenderNode(type, new SortedDictionary<string, object?>
        {
            ["axis"] = axis,
            ["spacing"] = spacing
        }, children);
    }

    private PocketSurfaceRenderNode ValidateGrid(
        JsonElement node,
        string path,
        string type,
        int depth,
        ref int nodeCount,
        ref int maximumDepth)
    {
        ExactKeys(node, ["type", "columns", "children"], ["gap"], path);
        var columns = GetInteger(node.GetProperty("columns"), $"{path}.columns");
        var gap = OptionalInteger(node, "gap", 0, $"{path}.gap");
        Require(columns is >= 1 and <= 12, $"{path}.columns");
        Require(gap is >= 0 and <= 64, $"{path}.gap");
        var children = ValidateChildren(node.GetProperty("children"), path, depth, ref nodeCount, ref maximumDepth);
        return RenderNode(type, new SortedDictionary<string, object?>
        {
            ["columns"] = columns,
            ["gap"] = gap
        }, children);
    }

    private static PocketSurfaceRenderNode ValidateText(JsonElement node, string path, string type)
    {
        ExactKeys(node, ["type", "style", "value"], [], path);
        var style = GetString(node.GetProperty("style"), $"{path}.style");
        var value = BoundedString(node.GetProperty("value"), 0, 2_000, $"{path}.value");
        Require(style is "title" or "body" or "caption" or "monospace", $"{path}.style");
        return RenderNode(type, new SortedDictionary<string, object?>
        {
            ["style"] = style,
            ["value"] = value
        });
    }

    private static PocketSurfaceRenderNode ValidateImage(JsonElement node, string path, string type)
    {
        ExactKeys(node, ["type", "assetRef", "alt"], [], path);
        var assetRef = BoundedString(node.GetProperty("assetRef"), 1, 240, $"{path}.assetRef");
        var alt = BoundedString(node.GetProperty("alt"), 1, 240, $"{path}.alt");
        Require(ValidAssetReference(assetRef), $"{path}.assetRef");
        return RenderNode(type, new SortedDictionary<string, object?>
        {
            ["alt"] = alt,
            ["assetRef"] = assetRef
        });
    }

    private PocketSurfaceRenderNode ValidateButton(JsonElement node, string path, string type)
    {
        ExactKeys(node, ["type", "label", "workflow"], [], path);
        var label = BoundedString(node.GetProperty("label"), 1, 120, $"{path}.label");
        var workflow = GetString(node.GetProperty("workflow"), $"{path}.workflow");
        Require(IdentifierPattern.IsMatch(workflow), $"{path}.workflow");
        Require(_knownWorkflows.Contains(workflow), $"{path}.workflow:unknown");
        return RenderNode(type, new SortedDictionary<string, object?>
        {
            ["label"] = label,
            ["workflow"] = workflow
        });
    }

    private static PocketSurfaceRenderNode ValidateTextField(JsonElement node, string path, string type)
    {
        ExactKeys(node, ["type", "label", "value", "maxLength"], [], path);
        var label = BoundedString(node.GetProperty("label"), 1, 120, $"{path}.label");
        var binding = Binding(node.GetProperty("value"), inputAllowed: true, stateAllowed: true, $"{path}.value");
        var maxLength = GetInteger(node.GetProperty("maxLength"), $"{path}.maxLength");
        Require(maxLength is >= 1 and <= 10_000, $"{path}.maxLength");
        return RenderNode(type, new SortedDictionary<string, object?>
        {
            ["label"] = label,
            ["maxLength"] = maxLength,
            ["value"] = binding
        });
    }

    private static PocketSurfaceRenderNode ValidateToggle(JsonElement node, string path, string type)
    {
        ExactKeys(node, ["type", "label", "value"], [], path);
        var label = BoundedString(node.GetProperty("label"), 1, 120, $"{path}.label");
        var binding = Binding(node.GetProperty("value"), inputAllowed: true, stateAllowed: true, $"{path}.value");
        return RenderNode(type, new SortedDictionary<string, object?>
        {
            ["label"] = label,
            ["value"] = binding
        });
    }

    private static PocketSurfaceRenderNode ValidatePicker(JsonElement node, string path, string type)
    {
        ExactKeys(node, ["type", "label", "options", "value"], [], path);
        var label = BoundedString(node.GetProperty("label"), 1, 120, $"{path}.label");
        var binding = Binding(node.GetProperty("value"), inputAllowed: true, stateAllowed: true, $"{path}.value");
        var optionsElement = node.GetProperty("options");
        Require(optionsElement.ValueKind == JsonValueKind.Array, $"{path}.options");
        var optionElements = optionsElement.EnumerateArray().ToArray();
        Require(optionElements.Length is >= 1 and <= 64, $"{path}.options");
        var options = new List<IReadOnlyDictionary<string, object?>>(optionElements.Length);
        for (var index = 0; index < optionElements.Length; index++)
        {
            var optionPath = $"{path}.options[{index}]";
            var option = RequireObject(optionElements[index], optionPath);
            ExactKeys(option, ["label", "value"], [], optionPath);
            options.Add(new SortedDictionary<string, object?>
            {
                ["label"] = BoundedString(option.GetProperty("label"), 1, 120, $"{optionPath}.label"),
                ["value"] = BoundedString(option.GetProperty("value"), 0, 120, $"{optionPath}.value")
            });
        }
        return RenderNode(type, new SortedDictionary<string, object?>
        {
            ["label"] = label,
            ["options"] = options,
            ["value"] = binding
        });
    }

    private PocketSurfaceRenderNode ValidateCalendarEventPicker(JsonElement node, string path, string type)
    {
        ExactKeys(node, ["type", "items", "selection"], ["titleTarget"], path);
        var items = QueryBinding(node.GetProperty("items"), $"{path}.items");
        var selection = Binding(node.GetProperty("selection"), inputAllowed: false, stateAllowed: true, $"{path}.selection");
        var properties = new SortedDictionary<string, object?>
        {
            ["items"] = items,
            ["selection"] = selection
        };
        if (node.TryGetProperty("titleTarget", out var titleTarget))
        {
            properties["titleTarget"] = Binding(titleTarget, inputAllowed: true, stateAllowed: false, $"{path}.titleTarget");
        }
        return RenderNode(type, properties);
    }

    private static PocketSurfaceRenderNode ValidateDurationPicker(JsonElement node, string path, string type)
    {
        ExactKeys(node, ["type", "value", "min", "max"], ["default"], path);
        var binding = Binding(node.GetProperty("value"), inputAllowed: true, stateAllowed: false, $"{path}.value");
        var minimum = GetInteger(node.GetProperty("min"), $"{path}.min");
        var maximum = GetInteger(node.GetProperty("max"), $"{path}.max");
        var defaultValue = node.TryGetProperty("default", out var defaultElement)
            ? GetInteger(defaultElement, $"{path}.default")
            : minimum;
        Require(
            minimum is >= 1 and <= 86_400
                && maximum is >= 1 and <= 86_400
                && minimum <= defaultValue
                && defaultValue <= maximum,
            $"{path}:duration_range");
        return RenderNode(type, new SortedDictionary<string, object?>
        {
            ["default"] = defaultValue,
            ["max"] = maximum,
            ["min"] = minimum,
            ["value"] = binding
        });
    }

    private static PocketSurfaceRenderNode ValidateStatus(JsonElement node, string path, string type)
    {
        ExactKeys(node, ["type", "value", "tone"], [], path);
        var value = BoundedString(node.GetProperty("value"), 0, 1_000, $"{path}.value");
        var tone = GetString(node.GetProperty("tone"), $"{path}.tone");
        Require(tone is "neutral" or "warning" or "error", $"{path}.tone");
        return RenderNode(type, new SortedDictionary<string, object?>
        {
            ["tone"] = tone,
            ["value"] = value
        });
    }

    private IReadOnlyDictionary<string, object?> QueryBinding(JsonElement value, string path)
    {
        var binding = RequireObject(value, path);
        ExactKeys(binding, ["query", "arguments"], [], path);
        var query = BoundedString(binding.GetProperty("query"), 1, 160, $"{path}.query");
        Require(QueryPattern.IsMatch(query), $"{path}.query");
        Require(_knownQueries.Contains(query), $"{path}.query:unknown");
        var arguments = RequireObject(binding.GetProperty("arguments"), $"{path}.arguments");
        var argumentProperties = arguments.EnumerateObject().ToArray();
        Require(
            argumentProperties.Length <= 64
                && argumentProperties.All(property => property.Name.EnumerateRunes().Count() <= 64)
                && argumentProperties.Select(property => property.Name).Distinct(StringComparer.Ordinal).Count() == argumentProperties.Length,
            $"{path}.arguments");
        ValidateJsonValue(arguments, $"{path}.arguments", 0);
        return new SortedDictionary<string, object?>
        {
            ["arguments"] = arguments.Clone(),
            ["query"] = query
        };
    }

    private List<PocketSurfaceRenderNode> ValidateChildren(
        JsonElement value,
        string path,
        int depth,
        ref int nodeCount,
        ref int maximumDepth)
    {
        Require(value.ValueKind == JsonValueKind.Array, $"{path}.children");
        var childElements = value.EnumerateArray().ToArray();
        Require(childElements.Length <= 64, $"{path}.children");
        var children = new List<PocketSurfaceRenderNode>(childElements.Length);
        for (var index = 0; index < childElements.Length; index++)
        {
            children.Add(ValidateNode(
                childElements[index],
                $"{path}.children[{index}]",
                depth + 1,
                ref nodeCount,
                ref maximumDepth));
        }
        return children;
    }

    private static PocketSurfaceRenderNode RenderNode(
        string type,
        IReadOnlyDictionary<string, object?> properties,
        IReadOnlyList<PocketSurfaceRenderNode>? children = null) =>
        new(type, properties, children ?? []);

    private static JsonElement RequireObject(JsonElement value, string path)
    {
        Require(value.ValueKind == JsonValueKind.Object, $"{path}:object");
        return value;
    }

    private static string GetString(JsonElement value, string path)
    {
        Require(value.ValueKind == JsonValueKind.String, $"{path}:string");
        return value.GetString()!;
    }

    private static string BoundedString(JsonElement value, int minimum, int maximum, string path)
    {
        var text = GetString(value, path);
        var scalarCount = text.EnumerateRunes().Count();
        Require(scalarCount >= minimum && scalarCount <= maximum, path);
        return text;
    }

    private static bool GetBoolean(JsonElement value, string path)
    {
        Require(value.ValueKind is JsonValueKind.True or JsonValueKind.False, $"{path}:boolean");
        return value.GetBoolean();
    }

    private static int GetInteger(JsonElement value, string path)
    {
        Require(value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out _), $"{path}:integer");
        return value.GetInt32();
    }

    private static int OptionalInteger(JsonElement value, string name, int defaultValue, string path) =>
        value.TryGetProperty(name, out var element) ? GetInteger(element, path) : defaultValue;

    private static string Binding(JsonElement value, bool inputAllowed, bool stateAllowed, string path)
    {
        var binding = BoundedString(value, 1, 128, path);
        var prefix = binding.StartsWith("$input.", StringComparison.Ordinal)
            ? "$input."
            : binding.StartsWith("$state.", StringComparison.Ordinal)
                ? "$state."
                : string.Empty;
        var allowedPrefix = (prefix == "$input." && inputAllowed) || (prefix == "$state." && stateAllowed);
        var name = prefix.Length == 0 ? string.Empty : binding[prefix.Length..];
        Require(allowedPrefix && BindingNamePattern.IsMatch(name), path);
        return binding;
    }

    private static void ExactKeys(
        JsonElement value,
        IEnumerable<string> required,
        IEnumerable<string> optional,
        string path)
    {
        var properties = value.EnumerateObject().ToArray();
        var keys = properties.Select(property => property.Name).ToHashSet(StringComparer.Ordinal);
        var requiredKeys = required.ToHashSet(StringComparer.Ordinal);
        var optionalKeys = optional.ToHashSet(StringComparer.Ordinal);
        Require(keys.Count == properties.Length, $"{path}:duplicate_key");
        Require(requiredKeys.All(keys.Contains), $"{path}:missing_key");
        Require(keys.All(key => requiredKeys.Contains(key) || optionalKeys.Contains(key)), $"{path}:unknown_key");
    }

    private static bool ValidAssetReference(string value)
    {
        const string prefix = "asset://";
        if (!value.StartsWith(prefix, StringComparison.Ordinal))
        {
            return false;
        }
        var relativePath = value[prefix.Length..];
        var components = relativePath.Split('/', StringSplitOptions.None);
        return components.Length > 0
            && components.All(component =>
                component.Length > 0
                && component is not "." and not ".."
                && AssetComponentPattern.IsMatch(component));
    }

    private static void ValidateJsonValue(JsonElement value, string path, int depth)
    {
        Require(depth <= 16, $"{path}:json_depth");
        switch (value.ValueKind)
        {
            case JsonValueKind.Object:
            {
                var properties = value.EnumerateObject().ToArray();
                Require(properties.Length <= 128, $"{path}:object_size");
                Require(
                    properties.Select(property => property.Name).Distinct(StringComparer.Ordinal).Count() == properties.Length,
                    $"{path}:duplicate_key");
                foreach (var property in properties)
                {
                    Require(property.Name.EnumerateRunes().Count() <= 128, $"{path}:object_key");
                    ValidateJsonValue(property.Value, $"{path}.{property.Name}", depth + 1);
                }
                break;
            }
            case JsonValueKind.Array:
            {
                var items = value.EnumerateArray().ToArray();
                Require(items.Length <= 256, $"{path}:array_size");
                for (var index = 0; index < items.Length; index++)
                {
                    ValidateJsonValue(items[index], $"{path}[{index}]", depth + 1);
                }
                break;
            }
            case JsonValueKind.Number:
                Require(value.TryGetDouble(out var number) && double.IsFinite(number), $"{path}:number");
                break;
            case JsonValueKind.String:
            case JsonValueKind.True:
            case JsonValueKind.False:
            case JsonValueKind.Null:
                break;
            default:
                throw new PocketSurfaceRuntimeException($"{path}:json_type");
        }
    }

    private static void Require(bool condition, string path)
    {
        if (!condition)
        {
            throw new PocketSurfaceRuntimeException(path);
        }
    }
}

internal static class PocketSurfaceCanonicalJson
{
    public static void WriteNode(Utf8JsonWriter writer, PocketSurfaceRenderNode node)
    {
        writer.WriteStartObject();
        var values = new SortedDictionary<string, object?>(StringComparer.Ordinal);
        foreach (var (key, value) in node.Properties)
        {
            values[key] = value;
        }
        values["type"] = node.Type;
        if (node.Children.Count > 0)
        {
            values["children"] = node.Children;
        }
        foreach (var (key, value) in values)
        {
            writer.WritePropertyName(key);
            WriteValue(writer, value);
        }
        writer.WriteEndObject();
    }

    private static void WriteValue(Utf8JsonWriter writer, object? value)
    {
        switch (value)
        {
            case null:
                writer.WriteNullValue();
                break;
            case string text:
                writer.WriteStringValue(text);
                break;
            case bool boolean:
                writer.WriteBooleanValue(boolean);
                break;
            case int integer:
                writer.WriteNumberValue(integer);
                break;
            case double number:
                writer.WriteNumberValue(number);
                break;
            case PocketSurfaceRenderNode node:
                WriteNode(writer, node);
                break;
            case JsonElement element:
                WriteElement(writer, element);
                break;
            case IReadOnlyDictionary<string, object?> dictionary:
                WriteDictionary(writer, dictionary);
                break;
            case IEnumerable sequence:
                writer.WriteStartArray();
                foreach (var item in sequence)
                {
                    WriteValue(writer, item);
                }
                writer.WriteEndArray();
                break;
            default:
                throw new InvalidOperationException($"Unsupported canonical value: {value.GetType().Name}");
        }
    }

    private static void WriteDictionary(Utf8JsonWriter writer, IReadOnlyDictionary<string, object?> dictionary)
    {
        writer.WriteStartObject();
        foreach (var (key, value) in dictionary.OrderBy(pair => pair.Key, StringComparer.Ordinal))
        {
            writer.WritePropertyName(key);
            WriteValue(writer, value);
        }
        writer.WriteEndObject();
    }

    private static void WriteElement(Utf8JsonWriter writer, JsonElement element)
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
                throw new InvalidOperationException($"Unsupported JSON value: {element.ValueKind}");
        }
    }
}
