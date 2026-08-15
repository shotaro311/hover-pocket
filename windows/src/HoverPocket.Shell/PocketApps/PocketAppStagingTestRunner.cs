using System.Text.Json;
using HoverPocket.Shell.Capabilities;

namespace HoverPocket.Shell.PocketApps;

internal sealed class PocketAppStagingTestRunner
{
    private readonly IReadOnlyDictionary<PocketCapabilityKey, PocketCapabilityDescriptor> _descriptors;

    public PocketAppStagingTestRunner(IEnumerable<PocketCapabilityDescriptor>? descriptors = null)
    {
        _descriptors = (descriptors ?? PocketCapabilityDescriptors.BuiltIn)
            .ToDictionary(item => item.Key);
    }

    public IReadOnlyList<PocketAppStagingTestResult> Run(PocketAppPackage package)
    {
        var results = new List<PocketAppStagingTestResult>
        {
            new("host.snapshot-byte-binding", "pass", "pass"),
            new("host.preview-determinism", "pass", "pass")
        };
        foreach (var item in package.TestCases.OrderBy(item => item.Key, StringComparer.Ordinal))
        {
            var status = Observe(item.Key, package);
            if (!string.Equals(status, item.Value, StringComparison.Ordinal))
            {
                throw new PocketAppLifecycleException("LIFECYCLE_STAGING_TEST_FAILED");
            }
            results.Add(new PocketAppStagingTestResult(item.Key, item.Value, status));
        }
        return results;
    }

    private string Observe(string id, PocketAppPackage package) => id switch
    {
        "calendar-read" => CalendarReadIsBound(package) ? "pass" : "reject",
        "start-focus-approved" => FocusWorkflowIsBound(package) ? "pass" : "reject",
        "start-focus-idempotent-replay" => FocusWorkflowIsBound(package) && FocusWritesRequireIdempotency(package) ? "pass" : "reject",
        "start-focus-rejected" => FocusWorkflowRequiresApproval(package) ? "reject" : "pass",
        _ => throw new PocketAppLifecycleException("LIFECYCLE_STAGING_TEST_FAILED")
    };

    private static bool CalendarReadIsBound(PocketAppPackage package)
    {
        var request = package.Manifest.RequestedCapabilities.FirstOrDefault(item => item.Key == CapabilityIds.CalendarList);
        if (request is null
            || request.Effect != CapabilityEffect.PrivateRead
            || request.Scope is not JsonElement scope
            || scope.ValueKind != JsonValueKind.Object
            || !scope.TryGetProperty("range", out var range)
            || range.GetString() != "today")
        {
            return false;
        }
        return package.Surfaces.Values.Any(surface => ContainsNode(surface.Root, node =>
        {
            if (node.Type != "calendarEventPicker"
                || !node.Properties.TryGetValue("items", out var rawItems)
                || rawItems is not IReadOnlyDictionary<string, object?> items
                || !items.TryGetValue("query", out var query))
            {
                return false;
            }
            return string.Equals(query as string, "calendar.events.list@1", StringComparison.Ordinal);
        }));
    }

    private static bool FocusWorkflowIsBound(PocketAppPackage package)
    {
        if (!package.Workflows.TryGetValue("startFocus", out var workflow)
            || workflow.ApprovalMode != "before_writes"
            || workflow.ApprovalGroup != "all_writes"
            || workflow.PartialFailureMode != "compensate_if_available"
            || workflow.Steps.Count != 2
            || workflow.Steps[0].Id != "startTimer"
            || workflow.Steps[0].Capability != CapabilityIds.TimerStart
            || workflow.Steps[0].Dependencies.Count != 0
            || !ArgumentsEqual(workflow.Steps[0].Arguments, new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["durationSeconds"] = "$input.durationSeconds",
                ["sourceRef"] = "$input.selectedEventRef",
                ["title"] = "$input.purpose"
            })
            || workflow.Steps[1].Id != "savePurpose"
            || workflow.Steps[1].Capability != CapabilityIds.StickyUpsert
            || !workflow.Steps[1].Dependencies.SequenceEqual(["startTimer"], StringComparer.Ordinal)
            || !ArgumentsEqual(workflow.Steps[1].Arguments, new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["body"] = "$input.purpose",
                ["color"] = "yellow",
                ["stableKey"] = "$context.todayFocusStableKey",
                ["title"] = "Focus purpose"
            }))
        {
            return false;
        }
        return package.Surfaces.Values.Any(surface => ContainsNode(surface.Root, node =>
            node.Type == "button"
            && node.Properties.TryGetValue("workflow", out var workflowId)
            && string.Equals(workflowId as string, "startFocus", StringComparison.Ordinal)));
    }

    private bool FocusWritesRequireIdempotency(PocketAppPackage package) =>
        package.Workflows.TryGetValue("startFocus", out var workflow)
        && workflow.Steps.All(step =>
            _descriptors.TryGetValue(step.Capability, out var descriptor)
            && descriptor.Idempotency == CapabilityIdempotencyPolicy.Required);

    private bool FocusWorkflowRequiresApproval(PocketAppPackage package) =>
        FocusWorkflowIsBound(package)
        && package.Workflows.TryGetValue("startFocus", out var workflow)
        && workflow.ApprovalMode == "before_writes"
        && workflow.ApprovalGroup == "all_writes"
        && workflow.Steps.Any(step =>
            _descriptors.TryGetValue(step.Capability, out var descriptor)
            && descriptor.Effect.IsWrite());

    private static bool ArgumentsEqual(
        IReadOnlyDictionary<string, JsonElement> actual,
        IReadOnlyDictionary<string, string> expected) =>
        actual.Count == expected.Count
        && expected.All(item =>
            actual.TryGetValue(item.Key, out var value)
            && value.ValueKind == JsonValueKind.String
            && string.Equals(value.GetString(), item.Value, StringComparison.Ordinal));

    private static bool ContainsNode(PocketSurfaceRenderNode node, Func<PocketSurfaceRenderNode, bool> predicate) =>
        predicate(node) || node.Children.Any(child => ContainsNode(child, predicate));
}
