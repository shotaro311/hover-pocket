using System.Text;
using System.Text.Json.Nodes;

namespace HoverPocket.Shell.PocketApps;

internal sealed class PocketAppPackageVerifier
{
    private readonly List<string> _failures = [];

    public int Run()
    {
        PocketAppPackage? referencePackage = null;
        WithPackage(root =>
        {
            var package = new PocketAppPackageRuntime().Load(root);
            referencePackage = package;
            Require(package.Manifest.Id == "local.example.today-focus", "package_id");
            Require(package.Manifest.Version == "1.0.0", "package_version");
            Require(package.ManifestDigest.StartsWith("sha256:", StringComparison.Ordinal) && package.ManifestDigest.Length == 71, "manifest_digest");
            Require(package.Surfaces["main"].NodeCount == 6, "package_surface");
            Require(package.Workflows["startFocus"].Steps.Count == 2, "package_workflow");
            Require(package.Workflows["startFocus"].RequiredPermissions.SetEquals(["sticky.write", "timer.write"]), "package_permissions");
            Require(package.StatePropertyNames.SetEquals(["selectedEventRef"]), "package_state_schema");
            Require(
                package.TestCases.Count == 4
                && package.TestCases["calendar-read"] == "pass"
                && package.TestCases["start-focus-approved"] == "pass"
                && package.TestCases["start-focus-idempotent-replay"] == "pass"
                && package.TestCases["start-focus-rejected"] == "reject",
                "package_tests");
            Console.WriteLine($"pocket_app_manifest_digest={package.ManifestDigest}");
        }, "valid_package");

        try
        {
            if (referencePackage is null)
            {
                throw new InvalidOperationException("reference_package");
            }
            var bundledRoot = Path.Combine(AppContext.BaseDirectory, "PocketApps", "local.example.today-focus");
            var bundled = new PocketAppPackageRuntime().Load(bundledRoot);
            Require(bundled.ManifestDigest == referencePackage.ManifestDigest, "bundled_manifest");
            Require(bundled.Surfaces["main"].CanonicalRenderModelBytes().AsSpan().SequenceEqual(
                referencePackage.Surfaces["main"].CanonicalRenderModelBytes()), "bundled_surfaces");
            Require(bundled.Workflows["startFocus"].Id == referencePackage.Workflows["startFocus"].Id
                && bundled.Workflows["startFocus"].Steps.Count == referencePackage.Workflows["startFocus"].Steps.Count
                && bundled.Workflows["startFocus"].RequiredPermissions.SetEquals(referencePackage.Workflows["startFocus"].RequiredPermissions), "bundled_workflows");
            Require(bundled.TestCases.OrderBy(item => item.Key).SequenceEqual(
                referencePackage.TestCases.OrderBy(item => item.Key)), "bundled_tests");
        }
        catch (Exception ex)
        {
            _failures.Add($"bundled_package:{ex.GetType().Name}:{ex.Message}");
        }

        RejectPackage("unlisted_file", root => File.WriteAllText(Path.Combine(root, "unexpected.txt"), "unexpected", Encoding.UTF8));
        RejectPackage("hidden_unlisted_file", root => File.WriteAllText(Path.Combine(root, ".unexpected"), "unexpected", Encoding.UTF8));
        RejectPackage("missing_file", root => File.Delete(Path.Combine(root, "intent.md")));
        RejectPackage("oversized_file", root => File.WriteAllBytes(Path.Combine(root, "intent.md"), new byte[PocketAppPackageRuntime.MaximumFileBytes + 1]));
        RejectPackage("unknown_capability", root => MutateJson(Path.Combine(root, "manifest.json"), manifest =>
        {
            manifest["requestedCapabilities"]![0]!["id"] = "calendar.events.delete";
        }));
        RejectPackage("path_traversal", root => MutateJson(Path.Combine(root, "manifest.json"), manifest =>
        {
            manifest["intent"] = "../intent.md";
        }));
        RejectPackage("cyclic_or_forward_dependency", root => MutateJson(Path.Combine(root, "workflows", "start-focus.workflow.json"), workflow =>
        {
            workflow["steps"]![0]!["dependsOn"] = new JsonArray("savePurpose");
        }));
        RejectPackage("unbounded_workflow", root => MutateJson(Path.Combine(root, "workflows", "start-focus.workflow.json"), workflow =>
        {
            workflow["limits"]!["maxSteps"] = 33;
        }));
        RejectPackage("unbound_surface_input", root => MutateJson(Path.Combine(root, "surfaces", "main.surface.json"), surface =>
        {
            surface["root"]!["children"]![2]!["value"] = "$input.missing";
        }));

        if (_failures.Count > 0)
        {
            Console.Error.WriteLine("pocket_app_package_verify=failed");
            foreach (var failure in _failures)
            {
                Console.Error.WriteLine($"failure={failure}");
            }
            return 1;
        }

        Console.WriteLine("pocket_app_package_verify=ok");
        Console.WriteLine("pocket_app_package_valid_files=9");
        Console.WriteLine("pocket_app_package_bundled=ok");
        Console.WriteLine("pocket_app_package_negative_cases=9");
        return 0;
    }

    private void RejectPackage(string label, Action<string> mutation)
    {
        WithPackage(root =>
        {
            mutation(root);
            try
            {
                _ = new PocketAppPackageRuntime().Load(root);
                _failures.Add($"accepted:{label}");
            }
            catch (PocketAppPackageRuntimeException)
            {
            }
            catch (PocketSurfaceRuntimeException)
            {
            }
        }, label);
    }

    private void WithPackage(Action<string> body, string label)
    {
        var root = Path.Combine(Path.GetTempPath(), $"hover-pocket-package-{Guid.NewGuid():N}");
        try
        {
            AssemblePackage(root);
            body(root);
        }
        catch (Exception ex)
        {
            _failures.Add($"{label}:fixture:{ex.GetType().Name}:{ex.Message}");
        }
        finally
        {
            try
            {
                if (Directory.Exists(root))
                {
                    Directory.Delete(root, recursive: true);
                }
            }
            catch
            {
            }
        }
    }

    private static void AssemblePackage(string root)
    {
        Directory.CreateDirectory(Path.Combine(root, "surfaces"));
        Directory.CreateDirectory(Path.Combine(root, "workflows"));
        Directory.CreateDirectory(Path.Combine(root, "tests"));

        var files = new (string Destination, string Fixture)[]
        {
            ("manifest.json", "valid/pocket-app.today-focus.json"),
            ("intent.md", "package/intent.md"),
            ("data.schema.json", "package/data.schema.json"),
            ("surfaces/main.surface.json", "valid/pocket-surface.today-focus.json"),
            ("workflows/start-focus.workflow.json", "valid/pocket-workflow.today-focus.json"),
            ("tests/calendar-read.json", "package/test.calendar-read.json"),
            ("tests/start-focus-approved.json", "package/test.start-focus-approved.json"),
            ("tests/start-focus-idempotent-replay.json", "package/test.start-focus-idempotent-replay.json"),
            ("tests/start-focus-rejected.json", "package/test.start-focus-rejected.json")
        };
        foreach (var file in files)
        {
            File.WriteAllBytes(
                Path.Combine(root, file.Destination.Replace('/', Path.DirectorySeparatorChar)),
                FixtureData(file.Fixture));
        }
    }

    private static void MutateJson(string path, Action<JsonNode> mutation)
    {
        var root = JsonNode.Parse(File.ReadAllBytes(path))
            ?? throw new InvalidOperationException("fixture_parse");
        mutation(root);
        File.WriteAllBytes(path, Encoding.UTF8.GetBytes(root.ToJsonString()));
    }

    private static byte[] FixtureData(string relativePath)
    {
        var current = new DirectoryInfo(Environment.CurrentDirectory);
        while (current is not null)
        {
            var candidate = Path.Combine(current.FullName, "contracts", "pocket", "v1", "fixtures", relativePath.Replace('/', Path.DirectorySeparatorChar));
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
