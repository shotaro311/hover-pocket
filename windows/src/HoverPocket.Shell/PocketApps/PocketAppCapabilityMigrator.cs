using System.Text.Json;
using System.Text.Json.Nodes;
using HoverPocket.Shell.Capabilities;

namespace HoverPocket.Shell.PocketApps;

internal sealed record PocketAppCapabilityMigrationReceipt(
    string PackageId,
    string SourceVersion,
    string TargetVersion,
    string SourcePackageDigest,
    string TargetPackageDigest,
    IReadOnlyList<string> MigrationIds,
    IReadOnlyDictionary<string, int> ReplacementCounts,
    string StateSchemaDigest,
    string UserDataStore);

internal sealed class PocketAppCapabilityMigrationException(string code) : Exception(code)
{
    internal string Code { get; } = code;
}

internal sealed class PocketAppCapabilityMigrator
{
    private readonly PocketAppPackageRuntime _runtime;
    private readonly PocketCapabilityCompatibilityCatalog _catalog;

    internal PocketAppCapabilityMigrator(
        IEnumerable<PocketCapabilityDescriptor>? descriptors = null,
        PocketCapabilityCompatibilityCatalog? catalog = null)
    {
        _catalog = catalog ?? PocketCapabilityCompatibilityCatalog.BuiltIn;
        _runtime = new PocketAppPackageRuntime(descriptors, _catalog);
    }

    internal PocketAppCapabilityMigrationReceipt Migrate(
        string sourceDirectory,
        string destinationDirectory,
        string targetVersion)
    {
        if (Path.GetFullPath(sourceDirectory).Equals(
                Path.GetFullPath(destinationDirectory),
                StringComparison.OrdinalIgnoreCase))
        {
            throw Failure("destination");
        }
        var sourceSnapshot = PocketAppFileSnapshot.Capture(sourceDirectory);
        var sourcePackage = _runtime.LoadMigrationSource(sourceSnapshot);
        if (sourcePackage.CompatibilityIssues.Count == 0
            || !ValidVersion(targetVersion)
            || CompareVersions(sourcePackage.Manifest.Version, targetVersion) >= 0)
        {
            throw Failure("version");
        }

        var migrations = sourcePackage.CompatibilityIssues
            .Select(issue => _catalog.Migration(issue.Key))
            .ToArray();
        var rewritten = Rewrite(
            sourceSnapshot,
            sourcePackage,
            targetVersion,
            migrations,
            destinationDirectory);
        var validatedTarget = _runtime.Load(rewritten.Snapshot);
        if (validatedTarget.Manifest.Id != sourcePackage.Manifest.Id
            || validatedTarget.Manifest.Version != targetVersion
            || validatedTarget.Manifest.StateStore != sourcePackage.Manifest.StateStore
            || validatedTarget.StateSchemaDigest != sourcePackage.StateSchemaDigest
            || validatedTarget.CompatibilityIssues.Count != 0)
        {
            throw Failure("target_readback");
        }

        rewritten.Snapshot.Materialize(destinationDirectory);
        var materialized = _runtime.Load(destinationDirectory);
        if (materialized.ManifestDigest != validatedTarget.ManifestDigest
            || materialized.StateSchemaDigest != sourcePackage.StateSchemaDigest
            || materialized.Manifest.StateStore != sourcePackage.Manifest.StateStore)
        {
            throw Failure("materialized_readback");
        }

        return new PocketAppCapabilityMigrationReceipt(
            sourcePackage.Manifest.Id,
            sourcePackage.Manifest.Version,
            targetVersion,
            sourcePackage.ManifestDigest,
            materialized.ManifestDigest,
            migrations.Select(item => item.Id).Order(StringComparer.Ordinal).ToArray(),
            rewritten.Counts,
            materialized.StateSchemaDigest,
            materialized.Manifest.StateStore);
    }

    internal (PocketAppFileSnapshot Snapshot, IReadOnlyDictionary<string, int> Counts) RewriteForVerification(
        PocketAppFileSnapshot snapshot,
        PocketAppPackage package,
        string targetVersion,
        IReadOnlyList<PocketCapabilityReferenceMigration> migrations,
        string destinationDirectory) =>
        Rewrite(snapshot, package, targetVersion, migrations, destinationDirectory);

    private static (PocketAppFileSnapshot Snapshot, IReadOnlyDictionary<string, int> Counts) Rewrite(
        PocketAppFileSnapshot snapshot,
        PocketAppPackage package,
        string targetVersion,
        IReadOnlyList<PocketCapabilityReferenceMigration> migrations,
        string destinationDirectory)
    {
        var files = snapshot.Files.ToDictionary(
            item => item.Key,
            item => item.Value.ToArray(),
            StringComparer.Ordinal);
        var counts = migrations.ToDictionary(item => item.Id, _ => 0, StringComparer.Ordinal);
        var bySource = migrations.ToDictionary(item => item.Source);
        var referenceMap = migrations.ToDictionary(
            item => Reference(item.Source),
            item => Reference(item.Target),
            StringComparer.Ordinal);

        var manifest = Object(files["manifest.json"], "manifest");
        manifest["version"] = targetVersion;
        var requested = manifest["requestedCapabilities"]?.AsArray() ?? throw Failure("manifest_capability");
        foreach (var item in requested)
        {
            var request = item?.AsObject() ?? throw Failure("manifest_capability");
            var id = request["id"]?.GetValue<string>() ?? throw Failure("manifest_capability");
            var version = request["version"]?.GetValue<int>() ?? throw Failure("manifest_capability");
            var key = new PocketCapabilityKey(id, version);
            if (!bySource.TryGetValue(key, out var migration)) { continue; }
            request["id"] = migration.Target.Id;
            request["version"] = migration.Target.Version;
            counts[migration.Id]++;
        }
        files["manifest.json"] = CanonicalJson(manifest);

        foreach (var path in package.Manifest.Workflows.Values.Order(StringComparer.Ordinal))
        {
            var workflow = Object(files[path], "workflow");
            var steps = workflow["steps"]?.AsArray() ?? throw Failure("workflow");
            foreach (var item in steps)
            {
                var step = item?.AsObject() ?? throw Failure("workflow_reference");
                var reference = step["use"]?.GetValue<string>() ?? throw Failure("workflow_reference");
                if (!referenceMap.TryGetValue(reference, out var target)) { continue; }
                var migration = migrations.Single(value => Reference(value.Source) == reference);
                step["use"] = target;
                counts[migration.Id]++;
            }
            files[path] = CanonicalJson(workflow);
        }

        foreach (var path in package.Manifest.Surfaces.Values.Order(StringComparer.Ordinal))
        {
            var surface = Object(files[path], "surface");
            RewriteQueries(surface, referenceMap, migrations, counts);
            files[path] = CanonicalJson(surface);
        }

        if (counts.Values.Any(value => value == 0)
            || !files[package.Manifest.StateSchemaPath].AsSpan().SequenceEqual(snapshot.Files[package.Manifest.StateSchemaPath]))
        {
            throw Failure("migration_coverage");
        }
        return (
            new PocketAppFileSnapshot(
                Path.GetFullPath(destinationDirectory),
                files,
                new Dictionary<string, PocketAppFileIdentity>(StringComparer.Ordinal)),
            counts);
    }

    private static void RewriteQueries(
        JsonNode? node,
        IReadOnlyDictionary<string, string> referenceMap,
        IReadOnlyList<PocketCapabilityReferenceMigration> migrations,
        IDictionary<string, int> counts)
    {
        if (node is JsonObject obj)
        {
            foreach (var property in obj.ToArray())
            {
                if (property.Key == "query"
                    && property.Value is JsonValue value
                    && value.TryGetValue<string>(out var reference)
                    && referenceMap.TryGetValue(reference, out var target))
                {
                    var migration = migrations.Single(item => Reference(item.Source) == reference);
                    obj[property.Key] = target;
                    counts[migration.Id]++;
                }
                else
                {
                    RewriteQueries(property.Value, referenceMap, migrations, counts);
                }
            }
        }
        else if (node is JsonArray array)
        {
            foreach (var item in array)
            {
                RewriteQueries(item, referenceMap, migrations, counts);
            }
        }
    }

    private static JsonObject Object(byte[] data, string code)
    {
        try
        {
            return JsonNode.Parse(data, new JsonNodeOptions { PropertyNameCaseInsensitive = false }, new JsonDocumentOptions
            {
                AllowTrailingCommas = false,
                CommentHandling = JsonCommentHandling.Disallow,
                MaxDepth = 16
            })?.AsObject() ?? throw Failure(code);
        }
        catch (PocketAppCapabilityMigrationException)
        {
            throw;
        }
        catch (Exception error) when (error is JsonException or InvalidOperationException)
        {
            throw Failure(code);
        }
    }

    private static byte[] CanonicalJson(JsonObject value)
    {
        var element = JsonSerializer.SerializeToElement(value);
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream))
        {
            CapabilityCanonicalJson.WriteElement(writer, element);
        }
        stream.WriteByte((byte)'\n');
        return stream.ToArray();
    }

    private static string Reference(PocketCapabilityKey key) => $"{key.Id}@{key.Version}";

    private static bool ValidVersion(string value) =>
        System.Text.RegularExpressions.Regex.IsMatch(
            value,
            "^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z.-]+)?$",
            System.Text.RegularExpressions.RegexOptions.CultureInvariant);

    private static int CompareVersions(string left, string right)
    {
        var leftCore = Version.Parse(left.Split('-', 2)[0]);
        var rightCore = Version.Parse(right.Split('-', 2)[0]);
        var core = leftCore.CompareTo(rightCore);
        if (core != 0) { return core; }
        if (left == right) { return 0; }
        return left.Contains('-') && !right.Contains('-') ? -1 : 1;
    }

    private static PocketAppCapabilityMigrationException Failure(string code) => new(code);
}
