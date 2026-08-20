using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using HoverPocket.Shell.Capabilities;

namespace HoverPocket.Shell.PocketApps;

internal sealed class PocketAppPackageRuntimeException(string path) : Exception(path)
{
    public string Path { get; } = path;
}

internal sealed record PocketAppRequestedCapability(
    PocketCapabilityKey Key,
    JsonElement? Scope,
    CapabilityEffect Effect,
    IReadOnlySet<string> Permissions);

internal sealed record PocketAppManifestDocument(
    string Id,
    string Name,
    string Version,
    string MinimumHostVersion,
    string IntentPath,
    string StateSchemaPath,
    string StateStore,
    IReadOnlyDictionary<string, string> Surfaces,
    IReadOnlyList<PocketAppRequestedCapability> RequestedCapabilities,
    IReadOnlyDictionary<string, string> Workflows,
    IReadOnlyList<string> Tests);

internal sealed record PocketAppWorkflowStep(
    string Id,
    PocketCapabilityKey Capability,
    IReadOnlyDictionary<string, JsonElement> Arguments,
    IReadOnlyList<string> Dependencies);

internal sealed record PocketAppWorkflowDocument(
    string Id,
    IReadOnlyDictionary<string, string> Inputs,
    string ApprovalMode,
    string ApprovalGroup,
    IReadOnlyList<PocketAppWorkflowStep> Steps,
    string PartialFailureMode,
    int TimeoutSeconds,
    IReadOnlySet<string> RequiredPermissions);

internal sealed record PocketAppStatePropertySchema(
    IReadOnlySet<string> Types,
    bool IsRequired,
    string? Format,
    int? MaximumLength);

internal sealed record PocketAppPackage(
    string RootDirectory,
    PocketAppManifestDocument Manifest,
    string ManifestDigest,
    string Intent,
    string StateSchemaDigest,
    IReadOnlySet<string> StatePropertyNames,
    IReadOnlyDictionary<string, IReadOnlySet<string>> StatePropertyTypes,
    IReadOnlyDictionary<string, PocketAppStatePropertySchema> StateProperties,
    IReadOnlyDictionary<string, PocketSurfaceDocument> Surfaces,
    IReadOnlyDictionary<string, PocketAppWorkflowDocument> Workflows,
    IReadOnlyDictionary<string, string> TestCases);

internal sealed class PocketAppPackageRuntime
{
    public const int MaximumFiles = 128;
    public const int MaximumFileBytes = 1 * 1024 * 1024;
    public const int MaximumPackageBytes = 8 * 1024 * 1024;

    private static readonly Regex PackageIdPattern = new(
        "^[a-z][a-z0-9]*(?:\\.[a-z0-9][a-z0-9-]*){2,}$",
        RegexOptions.CultureInvariant);
    private static readonly Regex IdentifierPattern = new(
        "^[A-Za-z][A-Za-z0-9_-]{0,63}$",
        RegexOptions.CultureInvariant);
    private static readonly Regex CapabilityIdPattern = new(
        "^[a-z][a-z0-9]*(?:\\.[a-z][a-z0-9_]*){2,}$",
        RegexOptions.CultureInvariant);
    private static readonly Regex ArgumentNamePattern = new(
        "^[A-Za-z][A-Za-z0-9_]{0,63}$",
        RegexOptions.CultureInvariant);
    private static readonly Regex SemanticVersionPattern = new(
        "^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z.-]+)?$",
        RegexOptions.CultureInvariant);
    private static readonly Regex PathComponentPattern = new(
        "^[A-Za-z0-9._-]+$",
        RegexOptions.CultureInvariant);

    private readonly IReadOnlyDictionary<PocketCapabilityKey, PocketCapabilityDescriptor> _descriptors;

    public PocketAppPackageRuntime(IEnumerable<PocketCapabilityDescriptor>? descriptors = null)
    {
        _descriptors = (descriptors ?? PocketCapabilityDescriptors.BuiltIn)
            .ToDictionary(descriptor => descriptor.Key);
    }

    public PocketAppPackage Load(string directory)
    {
        return Load(PocketAppFileSnapshot.Capture(directory));
    }

    public PocketAppPackage Load(PocketAppFileSnapshot snapshot)
    {
        var root = snapshot.RootDirectory;
        var packageFiles = snapshot.Files;
        if (!packageFiles.TryGetValue("manifest.json", out var manifestData))
        {
            throw new PocketAppPackageRuntimeException("$:package_files");
        }
        var manifestElement = ReadObject(manifestData, "$.manifest");
        var manifest = ParseManifest(manifestElement);

        var expectedFiles = new HashSet<string>(StringComparer.Ordinal)
        {
            "manifest.json",
            manifest.IntentPath,
            manifest.StateSchemaPath
        };
        expectedFiles.UnionWith(manifest.Surfaces.Values);
        expectedFiles.UnionWith(manifest.Workflows.Values);
        expectedFiles.UnionWith(manifest.Tests);
        Require(expectedFiles.SetEquals(packageFiles.Keys), "$:package_files");
        var manifestDigest = PackageDigest(packageFiles);

        var intent = Encoding.UTF8.GetString(packageFiles[manifest.IntentPath]);
        Require(!string.IsNullOrWhiteSpace(intent) && intent.EnumerateRunes().Count() <= 20_000, "$.intent");
        var stateSchemaDigest = "sha256:" + Convert.ToHexString(SHA256.HashData(packageFiles[manifest.StateSchemaPath])).ToLowerInvariant();
        var stateProperties = ValidateStateSchema(ReadObject(packageFiles[manifest.StateSchemaPath], "$.state.schema"));
        var statePropertyTypes = stateProperties.ToDictionary(
            item => item.Key,
            item => item.Value.Types,
            StringComparer.Ordinal);
        var statePropertyNames = statePropertyTypes.Keys.ToHashSet(StringComparer.Ordinal);

        var requestedScopes = manifest.RequestedCapabilities.ToDictionary(item => item.Key, item => item.Scope);
        var readableQueries = manifest.RequestedCapabilities
            .Where(item => _descriptors[item.Key].Effect == CapabilityEffect.PrivateRead)
            .Select(item => $"{item.Key.Id}@{item.Key.Version}")
            .ToHashSet(StringComparer.Ordinal);
        var surfaceRuntime = new PocketSurfaceRuntime(readableQueries, manifest.Workflows.Keys.ToHashSet(StringComparer.Ordinal));
        var surfaces = new Dictionary<string, PocketSurfaceDocument>(StringComparer.Ordinal);
        foreach (var item in manifest.Surfaces.OrderBy(item => item.Key, StringComparer.Ordinal))
        {
            var surface = surfaceRuntime.Load(packageFiles[item.Value]);
            Require(surface.Id == item.Key, $"$.surfaces.{item.Key}:id");
            surfaces.Add(item.Key, surface);
        }

        var workflows = new Dictionary<string, PocketAppWorkflowDocument>(StringComparer.Ordinal);
        foreach (var item in manifest.Workflows.OrderBy(item => item.Key, StringComparer.Ordinal))
        {
            var workflow = ParseWorkflow(ReadObject(packageFiles[item.Value], $"$.workflows.{item.Key}"), requestedScopes);
            Require(workflow.Id == item.Key, $"$.workflows.{item.Key}:id");
            for (var index = 0; index < workflow.Steps.Count; index++)
            {
                Require(
                    PocketAppExecutionRuntime.SupportsWorkflowPresentation(workflow.Steps[index].Capability),
                    $"$.workflows.{item.Key}.steps[{index}]:presentation");
            }
            workflows.Add(item.Key, workflow);
        }

        var workflowInputTypes = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var workflow in workflows.Values)
        {
            foreach (var input in workflow.Inputs)
            {
                if (workflowInputTypes.TryGetValue(input.Key, out var existingType))
                {
                    Require(existingType == input.Value, "$.workflows:input_type_conflict");
                }
                else
                {
                    workflowInputTypes[input.Key] = input.Value;
                }
            }
        }
        foreach (var surface in surfaces.Values)
        {
            var boundNames = new HashSet<string>(StringComparer.Ordinal);
            ValidateBindings(surface.Root, workflowInputTypes, statePropertyTypes, boundNames, $"$.surfaces.{surface.Id}.root");
            ValidateSurfaceScopes(surface.Root, requestedScopes, $"$.surfaces.{surface.Id}.root");
            foreach (var workflowId in ReferencedWorkflows(surface.Root))
            {
                if (!workflows.TryGetValue(workflowId, out var workflow))
                {
                    throw new PocketAppPackageRuntimeException($"$.surfaces.{surface.Id}:workflow");
                }
                Require(
                    workflow.Inputs.Keys.ToHashSet(StringComparer.Ordinal).IsSubsetOf(boundNames),
                    $"$.surfaces.{surface.Id}:unbound_workflow_input");
            }
        }

        var testCases = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var testPath in manifest.Tests)
        {
            var test = ReadObject(packageFiles[testPath], "$.tests");
            ExactKeys(test, ["case", "expected"], [], "$.tests");
            var name = BoundedString(test.GetProperty("case"), 1, 120, "$.tests.case");
            var expected = BoundedString(test.GetProperty("expected"), 1, 32, "$.tests.expected");
            Require(PocketAppStagingTestRunner.SupportedCaseIds.Contains(name), "$.tests.case:unsupported");
            Require(expected is "pass" or "reject", "$.tests.expected");
            Require(testCases.TryAdd(name, expected), "$.tests.case:duplicate");
        }

        return new PocketAppPackage(
            root,
            manifest,
            manifestDigest,
            intent,
            stateSchemaDigest,
            statePropertyNames,
            statePropertyTypes,
            stateProperties,
            surfaces,
            workflows,
            testCases);
    }

    private PocketAppManifestDocument ParseManifest(JsonElement value)
    {
        ExactKeys(
            value,
            ["$schema", "apiVersion", "id", "name", "version", "minHostVersion", "intent", "state", "surfaces", "requestedCapabilities", "workflows", "tests", "workspace"],
            [],
            "$.manifest");
        Require(GetString(value.GetProperty("$schema"), "$.manifest.$schema") == "hoverpocket://schemas/pocket-app/v1", "$.manifest.$schema");
        Require(GetString(value.GetProperty("apiVersion"), "$.manifest.apiVersion") == "hoverpocket.app/v1", "$.manifest.apiVersion");
        var id = BoundedString(value.GetProperty("id"), 1, 160, "$.manifest.id");
        Require(PackageIdPattern.IsMatch(id), "$.manifest.id");
        var name = BoundedString(value.GetProperty("name"), 1, 120, "$.manifest.name");
        var version = SemanticVersion(value.GetProperty("version"), "$.manifest.version");
        var minimumHostVersion = SemanticVersion(value.GetProperty("minHostVersion"), "$.manifest.minHostVersion");
        var intentPath = SafePath(value.GetProperty("intent"), "$.manifest.intent");

        var state = RequireObject(value.GetProperty("state"), "$.manifest.state");
        ExactKeys(state, ["schema", "store"], [], "$.manifest.state");
        var stateSchemaPath = SafePath(state.GetProperty("schema"), "$.manifest.state.schema");
        var stateStore = BoundedString(state.GetProperty("store"), 1, 240, "$.manifest.state.store");
        Require(stateStore == $"user-data://{id}", "$.manifest.state.store");

        var surfaceItems = RequireArray(value.GetProperty("surfaces"), 1, 16, "$.manifest.surfaces");
        var surfaces = new Dictionary<string, string>(StringComparer.Ordinal);
        for (var index = 0; index < surfaceItems.Count; index++)
        {
            var surface = RequireObject(surfaceItems[index], $"$.manifest.surfaces[{index}]");
            ExactKeys(surface, ["id", "kind", "source"], [], $"$.manifest.surfaces[{index}]");
            var surfaceId = Identifier(surface.GetProperty("id"), $"$.manifest.surfaces[{index}].id");
            Require(GetString(surface.GetProperty("kind"), $"$.manifest.surfaces[{index}].kind") == "declarative", $"$.manifest.surfaces[{index}].kind");
            var source = SafePath(surface.GetProperty("source"), $"$.manifest.surfaces[{index}].source");
            Require(surfaces.TryAdd(surfaceId, source), "$.manifest.surfaces:duplicate");
        }

        var capabilityItems = RequireArray(value.GetProperty("requestedCapabilities"), 0, 64, "$.manifest.requestedCapabilities");
        var requestedCapabilities = new List<PocketAppRequestedCapability>();
        var capabilityKeys = new HashSet<PocketCapabilityKey>();
        for (var index = 0; index < capabilityItems.Count; index++)
        {
            var request = RequireObject(capabilityItems[index], $"$.manifest.requestedCapabilities[{index}]");
            ExactKeys(request, ["id", "version"], ["scope"], $"$.manifest.requestedCapabilities[{index}]");
            var capabilityId = BoundedString(request.GetProperty("id"), 1, 128, $"$.manifest.requestedCapabilities[{index}].id");
            var capabilityVersion = GetInteger(request.GetProperty("version"), $"$.manifest.requestedCapabilities[{index}].version");
            var key = new PocketCapabilityKey(capabilityId, capabilityVersion);
            if (!_descriptors.TryGetValue(key, out var descriptor) || descriptor.ApprovalPolicy == CapabilityApprovalPolicy.RuntimeProhibited)
            {
                throw new PocketAppPackageRuntimeException($"$.manifest.requestedCapabilities[{index}]:unknown");
            }
            Require(capabilityKeys.Add(key), "$.manifest.requestedCapabilities:duplicate");
            JsonElement? scope = request.TryGetProperty("scope", out var rawScope) ? rawScope.Clone() : null;
            ValidateScope(scope, key, $"$.manifest.requestedCapabilities[{index}].scope");
            requestedCapabilities.Add(new PocketAppRequestedCapability(
                key,
                scope,
                descriptor.Effect,
                descriptor.Permissions));
        }

        var workflowObject = RequireObject(value.GetProperty("workflows"), "$.manifest.workflows");
        Require(workflowObject.EnumerateObject().Count() <= 32, "$.manifest.workflows");
        var workflows = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var property in workflowObject.EnumerateObject().OrderBy(item => item.Name, StringComparer.Ordinal))
        {
            var workflowId = Identifier(property.Name, "$.manifest.workflows");
            Require(workflows.TryAdd(workflowId, SafePath(property.Value, $"$.manifest.workflows.{property.Name}")), "$.manifest.workflows:duplicate");
        }

        var testItems = RequireArray(value.GetProperty("tests"), 0, 128, "$.manifest.tests");
        var tests = testItems.Select((item, index) => SafePath(item, $"$.manifest.tests[{index}]")).ToArray();
        Require(tests.Distinct(StringComparer.Ordinal).Count() == tests.Length, "$.manifest.tests:duplicate");

        var workspace = RequireObject(value.GetProperty("workspace"), "$.manifest.workspace");
        ExactKeys(workspace, ["ownership", "definitionRoot", "dataRoot", "secrets", "exportable", "deletable", "rollback"], [], "$.manifest.workspace");
        Require(GetString(workspace.GetProperty("ownership"), "$.manifest.workspace.ownership") == "user", "$.manifest.workspace.ownership");
        Require(GetString(workspace.GetProperty("definitionRoot"), "$.manifest.workspace.definitionRoot") == "app_definition", "$.manifest.workspace.definitionRoot");
        Require(GetString(workspace.GetProperty("dataRoot"), "$.manifest.workspace.dataRoot") == "separate_user_data", "$.manifest.workspace.dataRoot");
        Require(GetString(workspace.GetProperty("secrets"), "$.manifest.workspace.secrets") == "credential_store_only", "$.manifest.workspace.secrets");
        Require(GetBoolean(workspace.GetProperty("exportable"), "$.manifest.workspace.exportable"), "$.manifest.workspace.exportable");
        Require(GetBoolean(workspace.GetProperty("deletable"), "$.manifest.workspace.deletable"), "$.manifest.workspace.deletable");
        Require(GetString(workspace.GetProperty("rollback"), "$.manifest.workspace.rollback") == "versioned_snapshot", "$.manifest.workspace.rollback");

        return new PocketAppManifestDocument(
            id,
            name,
            version,
            minimumHostVersion,
            intentPath,
            stateSchemaPath,
            stateStore,
            surfaces,
            requestedCapabilities,
            workflows,
            tests);
    }

    private PocketAppWorkflowDocument ParseWorkflow(
        JsonElement value,
        IReadOnlyDictionary<PocketCapabilityKey, JsonElement?> requestedScopes)
    {
        ExactKeys(value, ["$schema", "workflowVersion", "id", "inputs", "approval", "steps", "onPartialFailure", "limits"], [], "$.workflow");
        Require(GetString(value.GetProperty("$schema"), "$.workflow.$schema") == "hoverpocket://schemas/pocket-workflow/v1", "$.workflow.$schema");
        Require(GetInteger(value.GetProperty("workflowVersion"), "$.workflow.workflowVersion") == 1, "$.workflow.workflowVersion");
        var id = Identifier(value.GetProperty("id"), "$.workflow.id");
        var inputObject = RequireObject(value.GetProperty("inputs"), "$.workflow.inputs");
        Require(inputObject.EnumerateObject().Count() <= 64, "$.workflow.inputs");
        var inputs = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var property in inputObject.EnumerateObject().OrderBy(item => item.Name, StringComparer.Ordinal))
        {
            var name = Identifier(property.Name, "$.workflow.inputs");
            var type = GetString(property.Value, $"$.workflow.inputs.{property.Name}");
            Require(type is "string" or "integer" or "number" or "boolean" or "date-time" or "entity-ref", $"$.workflow.inputs.{property.Name}");
            Require(inputs.TryAdd(name, type), "$.workflow.inputs:duplicate");
        }

        var approval = RequireObject(value.GetProperty("approval"), "$.workflow.approval");
        ExactKeys(approval, ["mode", "group"], [], "$.workflow.approval");
        var approvalMode = GetString(approval.GetProperty("mode"), "$.workflow.approval.mode");
        var approvalGroup = GetString(approval.GetProperty("group"), "$.workflow.approval.group");
        Require(approvalMode is "none" or "before_writes" or "per_step", "$.workflow.approval.mode");
        Require(approvalGroup is "none" or "all_writes" or "step", "$.workflow.approval.group");
        Require((approvalMode == "none") == (approvalGroup == "none"), "$.workflow.approval");

        var limits = RequireObject(value.GetProperty("limits"), "$.workflow.limits");
        ExactKeys(limits, ["maxSteps", "maxDepth", "timeoutSeconds"], [], "$.workflow.limits");
        var maximumSteps = GetInteger(limits.GetProperty("maxSteps"), "$.workflow.limits.maxSteps");
        var maximumDepth = GetInteger(limits.GetProperty("maxDepth"), "$.workflow.limits.maxDepth");
        var timeoutSeconds = GetInteger(limits.GetProperty("timeoutSeconds"), "$.workflow.limits.timeoutSeconds");
        Require(maximumSteps is >= 1 and <= 32 && maximumDepth is >= 1 and <= 8 && timeoutSeconds is >= 1 and <= 300, "$.workflow.limits");

        var stepItems = RequireArray(value.GetProperty("steps"), 1, maximumSteps, "$.workflow.steps");
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var steps = new List<PocketAppWorkflowStep>();
        var requiredPermissions = new HashSet<string>(StringComparer.Ordinal);
        var hasWrite = false;
        for (var index = 0; index < stepItems.Count; index++)
        {
            var step = RequireObject(stepItems[index], $"$.workflow.steps[{index}]");
            ExactKeys(step, ["id", "use", "with", "dependsOn"], [], $"$.workflow.steps[{index}]");
            var stepId = Identifier(step.GetProperty("id"), $"$.workflow.steps[{index}].id");
            Require(seen.Add(stepId), "$.workflow.steps:duplicate");
            var capability = CapabilityKey(BoundedString(step.GetProperty("use"), 3, 160, $"$.workflow.steps[{index}].use"), $"$.workflow.steps[{index}].use");
            Require(requestedScopes.ContainsKey(capability), $"$.workflow.steps[{index}].use:undeclared");
            if (!_descriptors.TryGetValue(capability, out var descriptor) || descriptor.ApprovalPolicy == CapabilityApprovalPolicy.RuntimeProhibited)
            {
                throw new PocketAppPackageRuntimeException($"$.workflow.steps[{index}].use:unknown");
            }
            hasWrite |= descriptor.Effect.IsWrite();
            requiredPermissions.UnionWith(descriptor.Permissions);

            var argumentObject = RequireObject(step.GetProperty("with"), $"$.workflow.steps[{index}].with");
            Require(argumentObject.EnumerateObject().Count() <= 64, $"$.workflow.steps[{index}].with");
            var arguments = new Dictionary<string, JsonElement>(StringComparer.Ordinal);
            foreach (var property in argumentObject.EnumerateObject().OrderBy(item => item.Name, StringComparer.Ordinal))
            {
                Require(ArgumentNamePattern.IsMatch(property.Name), $"$.workflow.steps[{index}].with");
                ValidateWorkflowBinding(property.Value, inputs.Keys.ToHashSet(StringComparer.Ordinal), $"$.workflow.steps[{index}].with.{property.Name}");
                arguments.Add(property.Name, property.Value.Clone());
            }
            ValidateCapabilityScope(
                arguments,
                requestedScopes[capability],
                capability,
                $"$.workflow.steps[{index}].with");

            var dependencies = RequireArray(step.GetProperty("dependsOn"), 0, 32, $"$.workflow.steps[{index}].dependsOn")
                .Select((item, dependencyIndex) => Identifier(item, $"$.workflow.steps[{index}].dependsOn[{dependencyIndex}]")).ToArray();
            Require(dependencies.Distinct(StringComparer.Ordinal).Count() == dependencies.Length
                && dependencies.All(seen.Contains)
                && !dependencies.Contains(stepId, StringComparer.Ordinal), $"$.workflow.steps[{index}].dependsOn");
            steps.Add(new PocketAppWorkflowStep(stepId, capability, arguments, dependencies));
        }
        Require(!hasWrite || approvalMode != "none", "$.workflow.approval:writes");
        Require(!(steps.Count > 1 && steps.Any(step => _descriptors[step.Capability].ApprovalPolicy == CapabilityApprovalPolicy.StrongPerCall)), "$.workflow.steps:strong_per_call");

        var partial = RequireObject(value.GetProperty("onPartialFailure"), "$.workflow.onPartialFailure");
        ExactKeys(partial, ["mode", "presentReceipt"], [], "$.workflow.onPartialFailure");
        var partialMode = GetString(partial.GetProperty("mode"), "$.workflow.onPartialFailure.mode");
        Require(partialMode is "stop" or "continue" or "compensate_if_available", "$.workflow.onPartialFailure.mode");
        Require(GetBoolean(partial.GetProperty("presentReceipt"), "$.workflow.onPartialFailure.presentReceipt"), "$.workflow.onPartialFailure.presentReceipt");

        return new PocketAppWorkflowDocument(id, inputs, approvalMode, approvalGroup, steps, partialMode, timeoutSeconds, requiredPermissions);
    }

    private static IReadOnlyDictionary<string, PocketAppStatePropertySchema> ValidateStateSchema(JsonElement value)
    {
        ExactKeys(value, ["type", "properties", "additionalProperties"], ["$schema", "required"], "$.state.schema");
        if (value.TryGetProperty("$schema", out var schema))
        {
            Require(GetString(schema, "$.state.schema.$schema") == "https://json-schema.org/draft/2020-12/schema", "$.state.schema.$schema");
        }
        Require(GetString(value.GetProperty("type"), "$.state.schema.type") == "object", "$.state.schema.type");
        Require(!GetBoolean(value.GetProperty("additionalProperties"), "$.state.schema.additionalProperties"), "$.state.schema.additionalProperties");
        var properties = RequireObject(value.GetProperty("properties"), "$.state.schema.properties");
        Require(properties.EnumerateObject().Count() <= 128, "$.state.schema.properties");
        var required = value.TryGetProperty("required", out var requiredValue)
            ? RequireArray(requiredValue, 0, 128, "$.state.schema.required")
                .Select(item => GetString(item, "$.state.schema.required")).ToArray()
            : Array.Empty<string>();
        Require(
            required.Distinct(StringComparer.Ordinal).Count() == required.Length
            && required.All(name => properties.TryGetProperty(name, out _)),
            "$.state.schema.required");
        var requiredNames = required.ToHashSet(StringComparer.Ordinal);
        var stateProperties = new Dictionary<string, PocketAppStatePropertySchema>(StringComparer.Ordinal);
        foreach (var propertyItem in properties.EnumerateObject())
        {
            Require(ArgumentNamePattern.IsMatch(propertyItem.Name), "$.state.schema.properties");
            Require(!stateProperties.ContainsKey(propertyItem.Name), "$.state.schema.properties:duplicate");
            var property = RequireObject(propertyItem.Value, $"$.state.schema.properties.{propertyItem.Name}");
            ExactKeys(property, ["type"], ["format", "maxLength"], $"$.state.schema.properties.{propertyItem.Name}");
            string[] types = property.GetProperty("type").ValueKind == JsonValueKind.String
                ? [GetString(property.GetProperty("type"), $"$.state.schema.properties.{propertyItem.Name}.type")]
                : RequireArray(property.GetProperty("type"), 1, 8, $"$.state.schema.properties.{propertyItem.Name}.type")
                    .Select(item => GetString(item, $"$.state.schema.properties.{propertyItem.Name}.type")).ToArray();
            Require(types.Distinct(StringComparer.Ordinal).Count() == types.Length
                && types.All(type => type is "string" or "integer" or "number" or "boolean" or "null"), $"$.state.schema.properties.{propertyItem.Name}.type");
            string? parsedFormat = null;
            if (property.TryGetProperty("format", out var format))
            {
                parsedFormat = GetString(format, $"$.state.schema.properties.{propertyItem.Name}.format");
                Require(parsedFormat == "date", $"$.state.schema.properties.{propertyItem.Name}.format");
            }
            int? maximumLength = null;
            if (property.TryGetProperty("maxLength", out var maximum))
            {
                maximumLength = GetInteger(maximum, $"$.state.schema.properties.{propertyItem.Name}.maxLength");
                Require(maximumLength is >= 1 and <= 10_000, $"$.state.schema.properties.{propertyItem.Name}.maxLength");
            }
            stateProperties[propertyItem.Name] = new PocketAppStatePropertySchema(
                types.ToHashSet(StringComparer.Ordinal),
                requiredNames.Contains(propertyItem.Name),
                parsedFormat,
                maximumLength);
        }
        return stateProperties;
    }

    private static void ValidateBindings(
        PocketSurfaceRenderNode node,
        IReadOnlyDictionary<string, string> inputTypes,
        IReadOnlyDictionary<string, IReadOnlySet<string>> stateTypes,
        ISet<string> boundNames,
        string path)
    {
        foreach (var property in node.Properties)
        {
            if (property.Value is not string binding)
            {
                continue;
            }
            var acceptedInputTypes = AcceptedWorkflowInputTypes(node.Type, property.Key);
            var acceptedStateTypes = AcceptedStateTypes(node.Type, property.Key);
            if (acceptedInputTypes is null && acceptedStateTypes is null)
            {
                continue;
            }
            if (!binding.StartsWith('$'))
            {
                continue;
            }
            if (binding.StartsWith("$input.", StringComparison.Ordinal))
            {
                var name = binding["$input.".Length..];
                if (!inputTypes.TryGetValue(name, out var declaredType) || acceptedInputTypes is null)
                {
                    throw new PocketAppPackageRuntimeException($"{path}.{property.Key}:binding");
                }
                Require(acceptedInputTypes.Contains(declaredType), $"{path}.{property.Key}:binding_type");
                boundNames.Add(name);
            }
            else if (binding.StartsWith("$state.", StringComparison.Ordinal))
            {
                var name = binding["$state.".Length..];
                if (!stateTypes.TryGetValue(name, out var declaredStateTypes))
                {
                    throw new PocketAppPackageRuntimeException($"{path}.{property.Key}:binding");
                }
                if (acceptedStateTypes is null)
                {
                    throw new PocketAppPackageRuntimeException($"{path}.{property.Key}:binding_type");
                }
                var nonNullStateTypes = declaredStateTypes.Where(type => type != "null").ToArray();
                Require(
                    nonNullStateTypes.Length > 0 && nonNullStateTypes.All(acceptedStateTypes.Contains),
                    $"{path}.{property.Key}:binding_type");
                if (inputTypes.TryGetValue(name, out var fallbackInputType))
                {
                    Require(
                        acceptedInputTypes is not null && acceptedInputTypes.Contains(fallbackInputType),
                        $"{path}.{property.Key}:workflow_fallback_type");
                }
                boundNames.Add(name);
            }
            else
            {
                throw new PocketAppPackageRuntimeException($"{path}.{property.Key}:binding");
            }
        }
        for (var index = 0; index < node.Children.Count; index++)
        {
            ValidateBindings(node.Children[index], inputTypes, stateTypes, boundNames, $"{path}.children[{index}]");
        }
    }

    private static IReadOnlySet<string>? AcceptedWorkflowInputTypes(string nodeType, string propertyName)
    {
        return (nodeType, propertyName) switch
        {
            ("textField", "value") => new HashSet<string>(["string"], StringComparer.Ordinal),
            ("toggle", "value") => new HashSet<string>(["boolean"], StringComparer.Ordinal),
            ("picker", "value") => new HashSet<string>(["string"], StringComparer.Ordinal),
            ("calendarEventPicker", "selection") => new HashSet<string>(["entity-ref"], StringComparer.Ordinal),
            ("calendarEventPicker", "titleTarget") => new HashSet<string>(["string"], StringComparer.Ordinal),
            ("durationPicker", "value") => new HashSet<string>(["integer", "number"], StringComparer.Ordinal),
            _ => null
        };
    }

    private static IReadOnlySet<string> ReferencedWorkflows(PocketSurfaceRenderNode node)
    {
        var workflows = new HashSet<string>(StringComparer.Ordinal);
        if (node.Type == "button"
            && node.Properties.TryGetValue("workflow", out var workflowValue)
            && workflowValue is string workflowId)
        {
            workflows.Add(workflowId);
        }
        foreach (var child in node.Children)
        {
            workflows.UnionWith(ReferencedWorkflows(child));
        }
        return workflows;
    }

    private static IReadOnlySet<string>? AcceptedStateTypes(string nodeType, string propertyName)
    {
        return (nodeType, propertyName) switch
        {
            ("textField", "value") => new HashSet<string>(["string"], StringComparer.Ordinal),
            ("toggle", "value") => new HashSet<string>(["boolean"], StringComparer.Ordinal),
            ("picker", "value") => new HashSet<string>(["string"], StringComparer.Ordinal),
            ("calendarEventPicker", "selection") => new HashSet<string>(["string"], StringComparer.Ordinal),
            ("calendarEventPicker", "titleTarget") => new HashSet<string>(["string"], StringComparer.Ordinal),
            ("durationPicker", "value") => new HashSet<string>(["integer", "number"], StringComparer.Ordinal),
            _ => null
        };
    }

    private static void ValidateWorkflowBinding(JsonElement value, IReadOnlySet<string> inputs, string path)
    {
        switch (value.ValueKind)
        {
            case JsonValueKind.String:
                var text = value.GetString() ?? string.Empty;
                if (text.StartsWith('$'))
                {
                    var inputBinding = text.StartsWith("$input.", StringComparison.Ordinal)
                        && inputs.Contains(text["$input.".Length..]);
                    var contextBinding = text == "$context.todayFocusStableKey";
                    Require(inputBinding || contextBinding, $"{path}:binding");
                }
                break;
            case JsonValueKind.Array:
                var index = 0;
                foreach (var child in value.EnumerateArray())
                {
                    ValidateWorkflowBinding(child, inputs, $"{path}[{index++}]");
                }
                break;
            case JsonValueKind.Object:
                foreach (var property in value.EnumerateObject())
                {
                    ValidateWorkflowBinding(property.Value, inputs, $"{path}.{property.Name}");
                }
                break;
        }
    }

    private static void ValidateSurfaceScopes(
        PocketSurfaceRenderNode node,
        IReadOnlyDictionary<PocketCapabilityKey, JsonElement?> requestedScopes,
        string path)
    {
        if (node.Type == "calendarEventPicker"
            && node.Properties.TryGetValue("items", out var rawItems)
            && rawItems is IReadOnlyDictionary<string, object?> items
            && items.TryGetValue("query", out var rawQuery)
            && rawQuery is string query
            && items.TryGetValue("arguments", out var rawArguments)
            && rawArguments is JsonElement arguments)
        {
            var key = CapabilityKey(query, $"{path}.items.query");
            Require(key == CapabilityIds.CalendarList, $"{path}.items.query:unsupported_shape");
            Require(requestedScopes.ContainsKey(key), $"{path}.items.query:undeclared");
            ValidateCapabilityScope(arguments, requestedScopes[key], key, $"{path}.items.arguments");
        }
        for (var index = 0; index < node.Children.Count; index++)
        {
            ValidateSurfaceScopes(node.Children[index], requestedScopes, $"{path}.children[{index}]");
        }
    }

    private static void ValidateCapabilityScope(
        IReadOnlyDictionary<string, JsonElement> arguments,
        JsonElement? scope,
        PocketCapabilityKey key,
        string path)
    {
        if (scope is not { } rawScope)
        {
            return;
        }
        var scopeObject = RequireObject(rawScope, path);
        if (scopeObject.TryGetProperty("range", out var range))
        {
            Require(arguments.TryGetValue("range", out var value)
                && value.ValueKind == JsonValueKind.String
                && value.GetString() == range.GetString(), $"{path}.range:scope");
        }
        if (scopeObject.TryGetProperty("namespace", out var namespaceValue))
        {
            var expectedNamespace = namespaceValue.GetString() ?? string.Empty;
            Require(arguments.TryGetValue("stableKey", out var value) && value.ValueKind == JsonValueKind.String, $"{path}.stableKey:scope");
            var stableKey = value.GetString() ?? string.Empty;
            var contextBinding = expectedNamespace == "today-focus" && stableKey == "$context.todayFocusStableKey";
            var literalBinding = false;
            if (!stableKey.StartsWith('$'))
            {
                try
                {
                    literalBinding = PocketStableKey.Namespace(stableKey) == expectedNamespace;
                }
                catch (CapabilityBrokerException)
                {
                    literalBinding = false;
                }
            }
            Require(literalBinding || contextBinding, $"{path}.stableKey:scope");
        }
        _ = key;
    }

    private static void ValidateCapabilityScope(
        JsonElement arguments,
        JsonElement? scope,
        PocketCapabilityKey key,
        string path)
    {
        if (scope is not { } rawScope)
        {
            return;
        }
        var scopeObject = RequireObject(rawScope, path);
        if (scopeObject.TryGetProperty("range", out var range))
        {
            Require(arguments.ValueKind == JsonValueKind.Object
                && arguments.TryGetProperty("range", out var value)
                && value.ValueKind == JsonValueKind.String
                && value.GetString() == range.GetString(), $"{path}.range:scope");
        }
        if (scopeObject.TryGetProperty("namespace", out _))
        {
            throw new PocketAppPackageRuntimeException($"{path}.stableKey:scope");
        }
        _ = key;
    }

    private static void ValidateScope(JsonElement? scope, PocketCapabilityKey key, string path)
    {
        if (key.Id == "calendar.events.list" && scope is { } calendarScope)
        {
            var objectValue = RequireObject(calendarScope, path);
            ExactKeys(objectValue, ["range"], [], path);
            Require(GetString(objectValue.GetProperty("range"), path) == "today", path);
        }
        else if ((key.Id == "sticky.note.get" || key.Id == "sticky.note.upsert") && scope is { } stickyScope)
        {
            var objectValue = RequireObject(stickyScope, path);
            ExactKeys(objectValue, ["namespace"], [], path);
            Require(GetString(objectValue.GetProperty("namespace"), path) == "today-focus", path);
        }
        else if (scope is not null)
        {
            throw new PocketAppPackageRuntimeException(path);
        }
    }

    private static Dictionary<string, long> Inventory(string root)
    {
        var result = new Dictionary<string, long>(StringComparer.Ordinal);
        long total = 0;
        var pendingDirectories = new Stack<string>();
        pendingDirectories.Push(root);
        while (pendingDirectories.Count > 0)
        {
            var current = pendingDirectories.Pop();
            foreach (var path in Directory.EnumerateFileSystemEntries(current, "*", SearchOption.TopDirectoryOnly))
            {
                var attributes = File.GetAttributes(path);
                Require(!attributes.HasFlag(FileAttributes.ReparsePoint), "$:package_symlink");
                if (attributes.HasFlag(FileAttributes.Directory))
                {
                    pendingDirectories.Push(path);
                    continue;
                }
                var relative = Path.GetRelativePath(root, path).Replace(Path.DirectorySeparatorChar, '/');
                Require(IsSafeRelativePath(relative), "$:package_path");
                var size = new FileInfo(path).Length;
                Require(size <= MaximumFileBytes, "$:package_file_size");
                Require(result.TryAdd(relative, size), "$:package_duplicate");
                total += size;
                Require(result.Count <= MaximumFiles && total <= MaximumPackageBytes, "$:package_size");
            }
        }
        return result;
    }

    private static byte[] Read(string relativePath, string root, IReadOnlyDictionary<string, long> inventory)
    {
        Require(inventory.ContainsKey(relativePath) && IsSafeRelativePath(relativePath), "$:package_reference");
        var path = Path.GetFullPath(Path.Combine(root, relativePath.Replace('/', Path.DirectorySeparatorChar)));
        Require(path.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase), "$:package_reference");
        return File.ReadAllBytes(path);
    }

    private static string PackageDigest(IReadOnlyDictionary<string, byte[]> files)
    {
        using var hasher = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        hasher.AppendData(Encoding.UTF8.GetBytes("hoverpocket.package/v1\0"));
        foreach (var path in files.Keys.OrderBy(path => path, StringComparer.Ordinal))
        {
            hasher.AppendData(Encoding.UTF8.GetBytes(path));
            hasher.AppendData(new byte[] { 0 });
            hasher.AppendData(SHA256.HashData(files[path]));
        }
        return "sha256:" + Convert.ToHexString(hasher.GetHashAndReset()).ToLowerInvariant();
    }

    private static JsonElement ReadObject(ReadOnlyMemory<byte> data, string path)
    {
        Require(data.Length <= MaximumFileBytes, $"{path}:size");
        try
        {
            using var document = JsonDocument.Parse(data, new JsonDocumentOptions
            {
                AllowTrailingCommas = false,
                CommentHandling = JsonCommentHandling.Disallow,
                MaxDepth = 16
            });
            return RequireObject(document.RootElement, path).Clone();
        }
        catch (PocketAppPackageRuntimeException)
        {
            throw;
        }
        catch (JsonException)
        {
            throw new PocketAppPackageRuntimeException($"{path}:json");
        }
    }

    private static PocketCapabilityKey CapabilityKey(string value, string path)
    {
        var marker = value.LastIndexOf('@');
        if (marker <= 0 || !int.TryParse(value[(marker + 1)..], out var version) || version < 1)
        {
            throw new PocketAppPackageRuntimeException(path);
        }
        var id = value[..marker];
        Require(CapabilityIdPattern.IsMatch(id), path);
        return new PocketCapabilityKey(id, version);
    }

    private static string SafePath(JsonElement value, string path)
    {
        var result = BoundedString(value, 1, 240, path);
        Require(IsSafeRelativePath(result), path);
        return result;
    }

    private static bool IsSafeRelativePath(string value)
    {
        if (string.IsNullOrEmpty(value) || Path.IsPathRooted(value) || value.Contains('\\') || value.Contains('\0'))
        {
            return false;
        }
        return value.Split('/', StringSplitOptions.None)
            .All(component => !string.IsNullOrEmpty(component)
                && component is not "." and not ".."
                && PathComponentPattern.IsMatch(component));
    }

    private static string SemanticVersion(JsonElement value, string path)
    {
        var result = BoundedString(value, 1, 64, path);
        Require(SemanticVersionPattern.IsMatch(result), path);
        return result;
    }

    private static string Identifier(JsonElement value, string path) => Identifier(GetString(value, path), path);

    private static string Identifier(string value, string path)
    {
        Require(IdentifierPattern.IsMatch(value), path);
        return value;
    }

    private static void ExactKeys(JsonElement value, IEnumerable<string> required, IEnumerable<string> optional, string path)
    {
        var properties = RequireObject(value, path).EnumerateObject().ToArray();
        var keys = properties.Select(property => property.Name).ToHashSet(StringComparer.Ordinal);
        var requiredSet = required.ToHashSet(StringComparer.Ordinal);
        var allowed = requiredSet.Concat(optional).ToHashSet(StringComparer.Ordinal);
        Require(keys.Count == properties.Length && requiredSet.IsSubsetOf(keys) && keys.IsSubsetOf(allowed), $"{path}:keys");
    }

    private static JsonElement RequireObject(JsonElement value, string path)
    {
        Require(value.ValueKind == JsonValueKind.Object && value.EnumerateObject().Count() <= 128, $"{path}:object");
        return value;
    }

    private static IReadOnlyList<JsonElement> RequireArray(JsonElement value, int minimum, int maximum, string path)
    {
        Require(value.ValueKind == JsonValueKind.Array, $"{path}:array");
        var result = value.EnumerateArray().Select(item => item.Clone()).ToArray();
        Require(result.Length >= minimum && result.Length <= maximum, $"{path}:array");
        return result;
    }

    private static string GetString(JsonElement value, string path)
    {
        Require(value.ValueKind == JsonValueKind.String, $"{path}:string");
        return value.GetString() ?? string.Empty;
    }

    private static string BoundedString(JsonElement value, int minimum, int maximum, string path)
    {
        var result = GetString(value, path);
        var length = result.EnumerateRunes().Count();
        Require(length >= minimum && length <= maximum, path);
        return result;
    }

    private static int GetInteger(JsonElement value, string path)
    {
        if (value.ValueKind != JsonValueKind.Number || !value.TryGetInt32(out var result))
        {
            throw new PocketAppPackageRuntimeException($"{path}:integer");
        }
        return result;
    }

    private static bool GetBoolean(JsonElement value, string path)
    {
        Require(value.ValueKind is JsonValueKind.True or JsonValueKind.False, $"{path}:boolean");
        return value.GetBoolean();
    }

    private static void Require(bool condition, string path)
    {
        if (!condition)
        {
            throw new PocketAppPackageRuntimeException(path);
        }
    }
}
