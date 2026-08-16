using System.Text.Json;
using System.Text;
using HoverPocket.Shell.Bridge;
using HoverPocket.Shell.Capabilities;
using HoverPocket.Shell.Configuration;

namespace HoverPocket.Shell.PocketApps;

internal sealed class PocketAppHostController
{
    private readonly PocketAppExecutionRuntime _runtime;
    private readonly Func<UserSettings> _settings;
    private readonly object _eventRefSync = new();
    private readonly HashSet<string> _allowedEventRefs = new(StringComparer.Ordinal);

    public PocketAppHostController(
        PocketAppExecutionRuntime runtime,
        Func<UserSettings> settings)
    {
        _runtime = runtime;
        _settings = settings;
    }

    internal bool IsActivationActive => _runtime.IsActivationActive;

    internal string AppId => _runtime.Package.Manifest.Id;

    internal string AppName => _runtime.Package.Manifest.Name;

    public object BuildSurfaceState(string surfaceId = "main")
    {
        EnsureAiNativeEnabled();
        _runtime.EnsureActivationActive();
        if (!_runtime.Package.Surfaces.TryGetValue(surfaceId, out var surface))
        {
            throw new CapabilityBrokerException("CAPABILITY_PLAN_INVALID", "pocket_surface");
        }
        using var document = JsonDocument.Parse(surface.CanonicalRenderModelBytes());
        return new
        {
            appId = _runtime.Package.Manifest.Id,
            appName = _runtime.Package.Manifest.Name,
            version = _runtime.Package.Manifest.Version,
            manifestDigest = _runtime.Package.ManifestDigest,
            surfaceId,
            renderModel = document.RootElement.Clone(),
            initialState = _runtime.UserStateStore?.Snapshot()
                ?? new Dictionary<string, string>(StringComparer.Ordinal)
        };
    }

    public object BuildManagerState()
    {
        EnsureAiNativeEnabled();
        _runtime.EnsureActivationActive();
        var package = _runtime.Package;
        return new
        {
            appId = package.Manifest.Id,
            name = package.Manifest.Name,
            version = package.Manifest.Version,
            manifestDigest = package.ManifestDigest,
            intent = BoundedVisibleText(package.Intent, 500),
            capabilities = package.Manifest.RequestedCapabilities
                .Select(item => item.Key.Id)
                .OrderBy(id => id, StringComparer.Ordinal)
                .ToArray(),
            workflows = package.Workflows.Keys.OrderBy(id => id, StringComparer.Ordinal).ToArray(),
            testsCount = package.TestCases.Count,
            stateStore = package.Manifest.StateStore,
            storageBoundary = "separate_definition_data_receipts",
            status = "active"
        };
    }

    public void Attach(BridgeDispatcher dispatcher)
    {
        dispatcher.Register("pocketApp.load", LoadAsync);
        dispatcher.Register("pocketApp.invokeWorkflow", InvokeWorkflowAsync);
        dispatcher.Register("pocketApp.updateState", UpdateStateAsync);
    }

    internal async Task<object?> LoadAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        EnsureAiNativeEnabled();
        EnsureApp(parameters);
        var surfaceId = RequiredString(parameters, "surfaceId", 64);
        if (!_runtime.Package.Surfaces.TryGetValue(surfaceId, out var surface))
        {
            throw new CapabilityBrokerException("CAPABILITY_PLAN_INVALID", "pocket_surface");
        }

        var queryResults = new List<object>();
        var allowedEventRefs = new HashSet<string>(StringComparer.Ordinal);
        foreach (var query in QueryBindings(surface.Root))
        {
            var output = await _runtime.QueryAsync(
                query.Reference,
                query.Arguments,
                DateTimeOffset.Now,
                cancellationToken);
            queryResults.Add(new
            {
                query = query.Reference,
                output = SafeQueryOutput(output, allowedEventRefs)
            });
        }
        lock (_eventRefSync)
        {
            _allowedEventRefs.Clear();
            _allowedEventRefs.UnionWith(allowedEventRefs);
        }
        return new
        {
            surface = BuildSurfaceState(surfaceId),
            queryResults
        };
    }

    internal async Task<object?> InvokeWorkflowAsync(
        JsonElement? parameters,
        CancellationToken cancellationToken)
    {
        EnsureAiNativeEnabled();
        EnsureApp(parameters);
        var workflowId = RequiredString(parameters, "workflowId", 64);
        if (parameters is null
            || !parameters.Value.TryGetProperty("inputs", out var inputsValue)
            || inputsValue.ValueKind != JsonValueKind.Object)
        {
            throw new CapabilityBrokerException("CAPABILITY_PLAN_INVALID", "pocket_inputs");
        }
        var inputs = inputsValue.EnumerateObject().ToDictionary(
            property => property.Name,
            property => property.Value.Clone(),
            StringComparer.Ordinal);
        if (inputs.TryGetValue("selectedEventRef", out var selectedEventRef))
        {
            var eventRef = selectedEventRef.ValueKind == JsonValueKind.String
                ? selectedEventRef.GetString() ?? string.Empty
                : string.Empty;
            lock (_eventRefSync)
            {
                if (!_allowedEventRefs.Contains(eventRef))
                {
                    throw new CapabilityBrokerException("CAPABILITY_PLAN_INVALID", "selected_event_ref");
                }
            }
        }
        if (inputs.TryGetValue("purpose", out var purpose))
        {
            if (purpose.ValueKind != JsonValueKind.String)
            {
                throw new CapabilityBrokerException("CAPABILITY_PLAN_INVALID", "purpose");
            }
            inputs["purpose"] = CapabilityJson.From(TodayFocusApprovalText.Sanitize(purpose.GetString() ?? string.Empty));
        }

        var draft = _runtime.Prepare(workflowId, inputs, DateTimeOffset.Now);
        if (draft.Preparation.ApprovalRequest is null)
        {
            throw new CapabilityBrokerException("CAPABILITY_APPROVAL_REQUIRED", draft.Plan.Id);
        }
        var english = _settings().Language == AppLanguage.English;
        var approvalText = ApprovalSummary(draft, english);
        var result = System.Windows.MessageBox.Show(
            approvalText,
            english ? "Approve Pocket App" : "Pocket Appを承認",
            System.Windows.MessageBoxButton.YesNo,
            System.Windows.MessageBoxImage.Question,
            System.Windows.MessageBoxResult.No);
        cancellationToken.ThrowIfCancellationRequested();
        if (result != System.Windows.MessageBoxResult.Yes)
        {
            _runtime.Reject(draft);
            return new { status = "rejected" };
        }

        var receipt = await _runtime.ApproveAndExecuteAsync(
            draft,
            DateTimeOffset.Now,
            cancellationToken);
        var readbackVerified = receipt.Steps.All(step => step.Readback.Status == CapabilityReadbackStatus.Verified);
        return new
        {
            status = receipt.Status.WireValue(),
            replayed = receipt.Replayed,
            readbackVerified,
            capabilities = receipt.Steps.Select(step => step.Capability.Id).ToArray(),
            summary = receipt.Status == CapabilityReceiptStatus.Succeeded && readbackVerified
                ? ReceiptSummary(receipt, english)
                : null
        };
    }

    internal Task<object?> UpdateStateAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        EnsureAiNativeEnabled();
        _runtime.EnsureActivationActive();
        EnsureApp(parameters);
        var key = RequiredString(parameters, "key", 128);
        if (parameters is null
            || !parameters.Value.TryGetProperty("value", out var rawValue)
            || rawValue.ValueKind is not (JsonValueKind.String or JsonValueKind.Null))
        {
            throw new CapabilityBrokerException("CAPABILITY_PLAN_INVALID", "state_value");
        }
        var value = rawValue.ValueKind == JsonValueKind.Null ? null : rawValue.GetString();
        if (key == "selectedEventRef" && value is not null)
        {
            lock (_eventRefSync)
            {
                if (!_allowedEventRefs.Contains(value))
                {
                    throw new CapabilityBrokerException("CAPABILITY_PLAN_INVALID", "selected_event_ref");
                }
            }
        }
        var store = _runtime.UserStateStore
            ?? throw new CapabilityBrokerException("CAPABILITY_UNAVAILABLE", "pocket_state");
        try
        {
            store.SetString(key, value);
        }
        catch (PocketAppUserStateStoreException)
        {
            throw new CapabilityBrokerException("CAPABILITY_UNAVAILABLE", "pocket_state");
        }
        return Task.FromResult<object?>(new { saved = true });
    }

    private void EnsureAiNativeEnabled()
    {
        if (!_settings().AiNativeEnabled)
        {
            throw new CapabilityBrokerException("CAPABILITY_UNAVAILABLE", "ai_native_disabled");
        }
    }

    private void EnsureApp(JsonElement? parameters)
    {
        var appId = RequiredString(parameters, "appId", 160);
        if (appId != _runtime.Package.Manifest.Id)
        {
            throw new CapabilityBrokerException("CAPABILITY_PLAN_INVALID", "pocket_app");
        }
    }

    private static object SafeQueryOutput(JsonElement output, ISet<string> allowedEventRefs)
    {
        if (!output.TryGetProperty("events", out var events) || events.ValueKind != JsonValueKind.Array)
        {
            throw new CapabilityBrokerException("CAPABILITY_READBACK_MISMATCH", "calendar_events");
        }
        var safeEvents = new List<object>();
        foreach (var item in events.EnumerateArray())
        {
            if (!item.TryGetProperty("eventRef", out var eventRefElement)
                || eventRefElement.ValueKind != JsonValueKind.String)
            {
                continue;
            }
            var eventRef = eventRefElement.GetString() ?? string.Empty;
            if (string.IsNullOrEmpty(eventRef) || eventRef.EnumerateRunes().Count() > 256)
            {
                continue;
            }
            allowedEventRefs.Add(eventRef);
            safeEvents.Add(new
            {
                eventRef,
                safeTitle = TodayFocusApprovalText.Sanitize(
                    item.TryGetProperty("safeTitle", out var title) ? title.GetString() ?? string.Empty : string.Empty),
                start = item.TryGetProperty("start", out var start) ? start.GetString() : null,
                end = item.TryGetProperty("end", out var end) ? end.GetString() : null
            });
        }
        return new { events = safeEvents };
    }

    internal static string ApprovalSummary(PocketAppWorkflowDraft draft, bool english)
    {
        var lines = new List<string>();
        foreach (var step in draft.Plan.Steps)
        {
            if (step.Capability == CapabilityIds.TimerStart)
            {
                var title = step.Arguments.TryGetProperty("title", out var titleElement)
                    ? titleElement.GetString() ?? "Focus"
                    : "Focus";
                var seconds = step.Arguments.TryGetProperty("durationSeconds", out var duration)
                    && duration.TryGetInt32(out var parsed) ? parsed : 0;
                lines.Add(english
                    ? $"Start a {Math.Max(1, seconds / 60)}-minute timer for \"{title}\""
                    : $"「{title}」のタイマーを{Math.Max(1, seconds / 60)}分で開始");
            }
            else if (step.Capability == CapabilityIds.StickyUpsert)
            {
                var title = step.Arguments.TryGetProperty("title", out var titleElement)
                    ? titleElement.GetString() ?? "Focus"
                    : "Focus";
                var body = step.Arguments.TryGetProperty("body", out var bodyElement)
                    ? bodyElement.GetString() ?? "Focus"
                    : "Focus";
                var stableKey = step.Arguments.TryGetProperty("stableKey", out var stableKeyElement)
                    ? PocketStableKey.Validate(stableKeyElement.GetString() ?? string.Empty)
                    : "unknown";
                lines.Add(english
                    ? $"Save \"{body}\" to Sticky Notes \"{title}\" ({stableKey})"
                    : $"Sticky Notes「{title}」（{stableKey}）へ「{body}」を保存");
            }
            else
            {
                lines.Add(step.Capability.Id);
            }
        }
        return string.Join(Environment.NewLine, lines);
    }

    internal static string ReceiptSummary(CapabilityWorkflowReceipt receipt, bool english)
    {
        var labels = new List<string>();
        foreach (var step in receipt.Steps)
        {
            var label = step.Capability == CapabilityIds.TimerStart
                ? "Timer"
                : step.Capability == CapabilityIds.StickyUpsert
                    ? "Sticky Notes"
                    : english ? "Changes" : "変更";
            if (!labels.Contains(label, StringComparer.Ordinal))
            {
                labels.Add(label);
            }
        }
        return english
            ? $"Applied to {string.Join(" and ", labels)} ({receipt.Steps.Count} verified)"
            : $"{string.Join("、", labels)}へ反映しました（{receipt.Steps.Count}件確認済み）";
    }

    private static IEnumerable<QueryBinding> QueryBindings(PocketSurfaceRenderNode node)
    {
        if (node.Type == "calendarEventPicker"
            && node.Properties.TryGetValue("items", out var rawItems)
            && rawItems is IReadOnlyDictionary<string, object?> items
            && items.TryGetValue("query", out var rawQuery)
            && rawQuery is string reference
            && items.TryGetValue("arguments", out var rawArguments)
            && rawArguments is JsonElement arguments)
        {
            yield return new QueryBinding(reference, arguments);
        }
        foreach (var child in node.Children)
        {
            foreach (var query in QueryBindings(child))
            {
                yield return query;
            }
        }
    }

    private static string RequiredString(JsonElement? parameters, string name, int maximumLength)
    {
        if (parameters is null
            || !parameters.Value.TryGetProperty(name, out var value)
            || value.ValueKind != JsonValueKind.String)
        {
            throw new CapabilityBrokerException("CAPABILITY_PLAN_INVALID", name);
        }
        var text = value.GetString() ?? string.Empty;
        if (string.IsNullOrEmpty(text) || text.EnumerateRunes().Count() > maximumLength)
        {
            throw new CapabilityBrokerException("CAPABILITY_PLAN_INVALID", name);
        }
        return text;
    }

    private static string BoundedVisibleText(string value, int maximumLength)
    {
        var builder = new StringBuilder();
        var pendingSpace = false;
        var scalarCount = 0;
        foreach (var rune in value.EnumerateRunes())
        {
            var disallowed = Rune.GetUnicodeCategory(rune) is System.Globalization.UnicodeCategory.Control
                or System.Globalization.UnicodeCategory.Format
                or System.Globalization.UnicodeCategory.LineSeparator
                or System.Globalization.UnicodeCategory.ParagraphSeparator;
            if (disallowed || Rune.IsWhiteSpace(rune))
            {
                pendingSpace = builder.Length > 0;
                continue;
            }
            if (pendingSpace && scalarCount < maximumLength)
            {
                builder.Append(' ');
                scalarCount += 1;
                pendingSpace = false;
            }
            if (scalarCount >= maximumLength)
            {
                break;
            }
            builder.Append(rune.ToString());
            scalarCount += 1;
        }
        return builder.ToString().Trim();
    }

    private sealed record QueryBinding(string Reference, JsonElement Arguments);
}
