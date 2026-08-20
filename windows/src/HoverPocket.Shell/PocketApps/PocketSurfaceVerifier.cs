using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace HoverPocket.Shell.PocketApps;

internal sealed class PocketSurfaceVerifier
{
    private const string GoldenRenderDigest = "sha256:6e3ac77b36cc0aeb3f93e1cf6350b0ef134bc2757f7888ee3687e0aa1058dba1";
    private readonly List<string> _failures = [];

    public int Run()
    {
        var runtime = new PocketSurfaceRuntime(
            new HashSet<string>(["calendar.events.list@1", "sticky.note.get@1"], StringComparer.Ordinal),
            new HashSet<string>(["startFocus"], StringComparer.Ordinal));
        var renderDigest = "unavailable";

        try
        {
            var valid = FixtureData("valid/pocket-surface.today-focus.json");
            var document = runtime.Load(valid);
            Require(document.Id == "main", "surface_id");
            Require(document.NodeCount == 6, "node_count");
            Require(document.MaximumDepth == 2, "maximum_depth");
            var rendered = document.CanonicalRenderModelBytes();
            renderDigest = "sha256:" + Convert.ToHexString(SHA256.HashData(rendered)).ToLowerInvariant();
            var renderedAgain = runtime.Load(valid).CanonicalRenderModelBytes();
            Require(rendered.AsSpan().SequenceEqual(renderedAgain), "render_determinism");
            Require(renderDigest == GoldenRenderDigest, "render_golden_digest");
            Require(Encoding.UTF8.GetString(rendered).Contains("calendar.events.list@1", StringComparison.Ordinal), "render_query");
            Require(document.Root.Children[1].Properties["titleTarget"] as string == "$input.purpose", "selection_title_target");
            Require(Convert.ToInt32(document.Root.Children[2].Properties["default"]) == 1_500, "duration_default");
        }
        catch (Exception ex)
        {
            _failures.Add($"valid_fixture:{ex.Message}");
        }
        VerifyOmittedDurationDefault(runtime);

        RejectData(FixtureData("invalid/pocket-surface.asset-traversal.json"), "asset_traversal", runtime);
        RejectData(FixtureData("invalid/pocket-surface.receipt-component.json"), "receipt_component", runtime);
        RejectMutation(root => root["root"]!["children"]![0]!["unexpected"] = true, "unknown_key", runtime);
        RejectMutation(root => root["root"]!["children"]![0]!["type"] = "webView", "unknown_component", runtime);
        RejectMutation(root => root["root"]!["children"]![1]!["items"]!["query"] = "calendar.events.delete@1", "unknown_query", runtime);
        RejectMutation(root => root["root"]!["children"]![1]!["items"]!["query"] = "sticky.note.get@1", "unsupported_query_shape", runtime);
        RejectMutation(root => root["root"]!["children"]![4]!["workflow"] = "missing", "unknown_workflow", runtime);
        RejectMutation(root =>
        {
            root["root"]!["children"]![2]!["min"] = 500;
            root["root"]!["children"]![2]!["max"] = 60;
        }, "duration_range", runtime);
        RejectMutation(root => root["root"]!["children"]![2]!["default"] = 14_401, "duration_default", runtime);
        RejectMutation(root => root["root"]!["children"]![1]!["titleTarget"] = "$state.purpose", "selection_title_target", runtime);
        RejectData(new byte[PocketSurfaceRuntime.MaximumDocumentBytes + 1], "document_size", runtime);
        RejectData(DeepSurfaceData(), "depth", runtime);
        RejectData(WideSurfaceData(), "node_count", runtime);
        RejectMutation(root => root["root"]!["children"]![4]!["label"] = new string('界', 121), "unicode_scalar_limit", runtime);
        RejectData(SurfaceData(new JsonObject
        {
            ["type"] = "status",
            ["value"] = "saved",
            ["tone"] = "success"
        }), "host_receipt_spoof", runtime);

        if (_failures.Count > 0)
        {
            Console.Error.WriteLine("pocket_surface_verify=failed");
            foreach (var failure in _failures)
            {
                Console.Error.WriteLine($"failure={failure}");
            }
            return 1;
        }

        Console.WriteLine("pocket_surface_verify=ok");
        Console.WriteLine("pocket_surface_valid_nodes=6");
        Console.WriteLine("pocket_surface_negative_cases=15");
        Console.WriteLine($"pocket_surface_render_digest={renderDigest}");
        return 0;
    }

    private void RejectMutation(Action<JsonNode> mutation, string label, PocketSurfaceRuntime runtime)
    {
        try
        {
            var root = JsonNode.Parse(FixtureData("valid/pocket-surface.today-focus.json"))
                ?? throw new InvalidOperationException("fixture_parse");
            mutation(root);
            RejectData(Encoding.UTF8.GetBytes(root.ToJsonString()), label, runtime);
        }
        catch (Exception ex)
        {
            _failures.Add($"{label}:fixture:{ex.Message}");
        }
    }

    private void VerifyOmittedDurationDefault(PocketSurfaceRuntime runtime)
    {
        try
        {
            var root = JsonNode.Parse(FixtureData("valid/pocket-surface.today-focus.json"))
                ?? throw new InvalidOperationException("fixture_parse");
            root["root"]!["children"]![2]!.AsObject().Remove("default");
            var document = runtime.Load(Encoding.UTF8.GetBytes(root.ToJsonString()));
            Require(
                Convert.ToInt32(document.Root.Children[2].Properties["default"]) == 60,
                "duration_default_omitted");
        }
        catch (Exception ex)
        {
            _failures.Add($"duration_default_omitted:{ex.Message}");
        }
    }

    private void RejectData(byte[] data, string label, PocketSurfaceRuntime runtime)
    {
        try
        {
            _ = runtime.Load(data);
            _failures.Add($"accepted:{label}");
        }
        catch (PocketSurfaceRuntimeException)
        {
        }
    }

    private static byte[] DeepSurfaceData()
    {
        JsonNode root = new JsonObject
        {
            ["type"] = "status",
            ["value"] = "deep",
            ["tone"] = "neutral"
        };
        for (var index = 0; index < PocketSurfaceRuntime.MaximumDepth; index++)
        {
            root = new JsonObject
            {
                ["type"] = "stack",
                ["axis"] = "vertical",
                ["children"] = new JsonArray(root)
            };
        }
        return SurfaceData(root);
    }

    private static byte[] WideSurfaceData()
    {
        var groups = new JsonArray();
        for (var groupIndex = 0; groupIndex < 4; groupIndex++)
        {
            var children = new JsonArray();
            for (var childIndex = 0; childIndex < 64; childIndex++)
            {
                children.Add(new JsonObject
                {
                    ["type"] = "text",
                    ["style"] = "caption",
                    ["value"] = $"{groupIndex}:{childIndex}"
                });
            }
            groups.Add(new JsonObject
            {
                ["type"] = "stack",
                ["axis"] = "vertical",
                ["children"] = children
            });
        }
        return SurfaceData(new JsonObject
        {
            ["type"] = "stack",
            ["axis"] = "vertical",
            ["children"] = groups
        });
    }

    private static byte[] SurfaceData(JsonNode root)
    {
        var document = new JsonObject
        {
            ["$schema"] = "hoverpocket://schemas/pocket-surface/v1",
            ["surfaceVersion"] = 1,
            ["id"] = "verification",
            ["hostBoundary"] = new JsonObject
            {
                ["region"] = "provider_host",
                ["mayRenderHeader"] = false,
                ["mayRenderVoiceLane"] = false,
                ["mayRenderApproval"] = false,
                ["mayRenderReceipt"] = false
            },
            ["root"] = root
        };
        return Encoding.UTF8.GetBytes(document.ToJsonString());
    }

    private static byte[] FixtureData(string relativePath)
    {
        var current = new DirectoryInfo(Environment.CurrentDirectory);
        while (current is not null)
        {
            var candidate = Path.Combine(current.FullName, "contracts", "pocket", "v1", "fixtures", relativePath);
            if (File.Exists(candidate))
            {
                return File.ReadAllBytes(candidate);
            }
            current = current.Parent;
        }
        throw new FileNotFoundException(relativePath);
    }

    private void Require(bool condition, string label)
    {
        if (!condition)
        {
            _failures.Add(label);
        }
    }
}
