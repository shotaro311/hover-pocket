using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using HoverPocket.Shell.Capabilities;

namespace HoverPocket.Shell.Providers.CodexVoice;

internal sealed record CodexVoiceCapabilityApprovalField(string Key, string Value);

internal sealed record CodexVoiceCapabilityApproval(
    string ToolName,
    IReadOnlyList<CodexVoiceCapabilityApprovalField> Fields);

internal interface ICodexVoiceCapabilityToolAdapter
{
    IReadOnlyList<object> DynamicTools { get; }

    Task<CodexAppServerReply> HandleAsync(
        CodexAppServerRequest request,
        string? expectedRootThreadId,
        CancellationToken cancellationToken);
}

internal sealed class CodexVoiceCapabilityToolAdapter : ICodexVoiceCapabilityToolAdapter
{
    internal const string CalendarTodayTool = "hoverpocket_calendar_today";
    internal const string TimerStartTool = "hoverpocket_timer_start";
    internal const string CalendarCreateTool = "hoverpocket_calendar_create";
    internal const string TodayFocusTool = "hoverpocket_today_focus";

    private static readonly Regex IdentifierPattern = new(
        "^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$",
        RegexOptions.CultureInvariant);
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase
    };
    private static readonly IReadOnlyList<object> ToolSpecs = BuildToolSpecs();

    private readonly CapabilityBroker _broker;
    private readonly TodayFocusTextAdapter _todayFocus;
    private readonly Func<CodexVoiceCapabilityApproval, CancellationToken, Task<bool>> _requestApproval;
    private readonly SemaphoreSlim _callGate = new(1, 1);
    private readonly Dictionary<string, CachedToolReply> _completedCalls = new(StringComparer.Ordinal);
    private readonly Queue<string> _completedCallOrder = new();

    public CodexVoiceCapabilityToolAdapter(
        CapabilityBroker broker,
        TodayFocusTextAdapter todayFocus,
        Func<CodexVoiceCapabilityApproval, CancellationToken, Task<bool>> requestApproval)
    {
        _broker = broker;
        _todayFocus = todayFocus;
        _requestApproval = requestApproval;
    }

    public IReadOnlyList<object> DynamicTools => ToolSpecs;

    public async Task<CodexAppServerReply> HandleAsync(
        CodexAppServerRequest request,
        string? expectedRootThreadId,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!string.Equals(request.Method, "item/tool/call", StringComparison.Ordinal))
        {
            return CodexAppServerReply.Failure(
                -32601,
                $"HoverPocket has no handler for app-server request: {request.Method}");
        }

        DynamicToolCall call;
        try
        {
            call = ParseCall(request.Params, expectedRootThreadId);
        }
        catch (CodexVoiceToolException exception)
        {
            return ToolReply(false, new { status = "rejected", code = exception.Code });
        }

        await _callGate.WaitAsync(cancellationToken);
        try
        {
            var callToken = CallToken(call);
            var argumentDigest = CapabilityCanonicalJson.ArgumentsDigest(call.Arguments);
            if (_completedCalls.TryGetValue(callToken, out var cached))
            {
                return string.Equals(cached.ArgumentDigest, argumentDigest, StringComparison.Ordinal)
                    ? cached.Reply
                    : ToolReply(false, new { status = "rejected", code = "CAPABILITY_IDEMPOTENCY_CONFLICT" });
            }

            CodexAppServerReply reply;
            try
            {
                reply = call.Tool switch
                {
                    CalendarTodayTool => await ListTodayAsync(call, cancellationToken),
                    TimerStartTool => await StartTimerAsync(call, cancellationToken),
                    CalendarCreateTool => await CreateCalendarEventAsync(call, cancellationToken),
                    TodayFocusTool => await StartTodayFocusAsync(call, cancellationToken),
                    _ => ToolReply(false, new { status = "rejected", code = "CAPABILITY_UNKNOWN" })
                };
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                throw;
            }
            catch (CodexVoiceToolException exception)
            {
                reply = ToolReply(false, new { status = "rejected", code = exception.Code });
            }
            catch (CapabilityBrokerException exception)
            {
                reply = ToolReply(false, new { status = "failed", code = exception.Code });
            }
            catch (Exception)
            {
                reply = ToolReply(false, new { status = "failed", code = "CAPABILITY_FAILED" });
            }

            CacheReply(callToken, argumentDigest, reply);
            return reply;
        }
        finally
        {
            _callGate.Release();
        }
    }

    private void CacheReply(string callToken, string argumentDigest, CodexAppServerReply reply)
    {
        _completedCalls[callToken] = new CachedToolReply(argumentDigest, reply);
        _completedCallOrder.Enqueue(callToken);
        while (_completedCallOrder.Count > 128)
        {
            var expired = _completedCallOrder.Dequeue();
            _completedCalls.Remove(expired);
        }
    }

    private async Task<CodexAppServerReply> ListTodayAsync(
        DynamicToolCall call,
        CancellationToken cancellationToken)
    {
        RequireOnlyKeys(call.Arguments, []);
        var now = DateTimeOffset.Now;
        var principal = Principal(call.ThreadId);
        var permissions = Permissions(principal, "calendar.events.read");
        var events = await _todayFocus.ListTodayAsync(
            CapabilityTimeZoneId(),
            principal,
            permissions,
            now,
            cancellationToken,
            CapabilityOrigin.Voice);
        return ToolReply(true, new
        {
            status = "succeeded",
            events = events.Take(64).Select(item => new
            {
                eventRef = item.EventRef,
                safeTitle = item.SafeTitle,
                start = item.Start.ToString("O", CultureInfo.InvariantCulture),
                end = item.End.ToString("O", CultureInfo.InvariantCulture)
            }).ToArray()
        });
    }

    private async Task<CodexAppServerReply> StartTimerAsync(
        DynamicToolCall call,
        CancellationToken cancellationToken)
    {
        RequireOnlyKeys(call.Arguments, ["durationSeconds", "title"]);
        var duration = CapabilityJson.RequiredInt(call.Arguments, "durationSeconds", 1, 86_400);
        var rawTitle = CapabilityJson.OptionalString(call.Arguments, "title", 80);
        var title = TodayFocusApprovalText.Sanitize(
            string.IsNullOrWhiteSpace(rawTitle) ? "タイマー" : rawTitle);
        var now = DateTimeOffset.Now;
        var principal = Principal(call.ThreadId);
        var permissions = Permissions(principal, "timer.write");
        var token = CallToken(call);
        var plan = new CapabilityExecutionPlan(
            $"voice-timer:{token}",
            now,
            CapabilityOrigin.Voice,
            principal,
            null,
            [
                new CapabilityPlanStep(
                    "startTimer",
                    CapabilityIds.TimerStart,
                    CapabilityJson.From(new
                    {
                        durationSeconds = duration,
                        title,
                        sourceRef = $"voice:{call.ThreadId}"
                    }),
                    $"voice-timer.{token}",
                    [])
            ],
            new HashSet<string>(["timer.write"], StringComparer.Ordinal));
        var receipt = await ApproveAndExecuteAsync(
            plan,
            permissions,
            new CodexVoiceCapabilityApproval(
                TimerStartTool,
                [
                    new CodexVoiceCapabilityApprovalField("title", title),
                    new CodexVoiceCapabilityApprovalField("durationSeconds", duration.ToString(CultureInfo.InvariantCulture))
                ]),
            cancellationToken);
        return ReceiptReply(receipt);
    }

    private async Task<CodexAppServerReply> CreateCalendarEventAsync(
        DynamicToolCall call,
        CancellationToken cancellationToken)
    {
        RequireOnlyKeys(call.Arguments, ["title", "start", "end", "isAllDay"]);
        var title = TodayFocusApprovalText.Sanitize(
            CapabilityJson.RequiredString(call.Arguments, "title", 80));
        var start = RequiredDateTime(call.Arguments, "start");
        var end = RequiredDateTime(call.Arguments, "end");
        var isAllDay = CapabilityJson.RequiredBool(call.Arguments, "isAllDay");
        var canonicalStart = start.ToString("O", CultureInfo.InvariantCulture);
        var canonicalEnd = end.ToString("O", CultureInfo.InvariantCulture);
        var now = DateTimeOffset.Now;
        var principal = Principal(call.ThreadId);
        var permissions = Permissions(principal, "calendar.events.write");
        var token = CallToken(call);
        var plan = new CapabilityExecutionPlan(
            $"voice-calendar-create:{token}",
            now,
            CapabilityOrigin.Voice,
            principal,
            null,
            [
                new CapabilityPlanStep(
                    "createCalendar",
                    CapabilityIds.CalendarCreate,
                    CapabilityJson.From(new
                    {
                        calendarId = (string?)null,
                        title,
                        start = canonicalStart,
                        end = canonicalEnd,
                        isAllDay,
                        location = (string?)null,
                        notes = (string?)null
                    }),
                    $"voice-calendar.{token}",
                    [])
            ],
            new HashSet<string>(["calendar.events.write"], StringComparer.Ordinal));
        var receipt = await ApproveAndExecuteAsync(
            plan,
            permissions,
            new CodexVoiceCapabilityApproval(
                CalendarCreateTool,
                [
                    new CodexVoiceCapabilityApprovalField("title", title),
                    new CodexVoiceCapabilityApprovalField("start", canonicalStart),
                    new CodexVoiceCapabilityApprovalField("end", canonicalEnd),
                    new CodexVoiceCapabilityApprovalField("isAllDay", isAllDay ? "true" : "false")
                ]),
            cancellationToken);
        return ReceiptReply(receipt);
    }

    private async Task<CodexAppServerReply> StartTodayFocusAsync(
        DynamicToolCall call,
        CancellationToken cancellationToken)
    {
        RequireOnlyKeys(call.Arguments, ["eventRef", "durationSeconds", "purpose"]);
        var eventRef = CapabilityJson.RequiredString(call.Arguments, "eventRef", 256);
        var duration = call.Arguments.TryGetProperty("durationSeconds", out _)
            ? CapabilityJson.RequiredInt(call.Arguments, "durationSeconds", 1, 86_400)
            : 1_500;
        var rawPurpose = CapabilityJson.OptionalString(call.Arguments, "purpose", 10_000);
        var now = DateTimeOffset.Now;
        var principal = Principal(call.ThreadId);
        var readPermissions = Permissions(principal, "calendar.events.read");
        var events = await _todayFocus.ListTodayAsync(
            CapabilityTimeZoneId(),
            principal,
            readPermissions,
            now,
            cancellationToken,
            CapabilityOrigin.Voice);
        var selected = events.FirstOrDefault(item => item.EventRef == eventRef)
            ?? throw new CodexVoiceToolException("CAPABILITY_UNAVAILABLE");
        var purpose = string.IsNullOrWhiteSpace(rawPurpose)
            ? (string.IsNullOrWhiteSpace(selected.SafeTitle) ? "今日の予定" : selected.SafeTitle)
            : rawPurpose;
        var writePermissions = Permissions(principal, "sticky.write", "timer.write");
        var draft = _todayFocus.PrepareFocus(
            selected,
            duration,
            purpose,
            principal,
            writePermissions,
            now,
            TimeZoneInfo.Local,
            CapabilityOrigin.Voice,
            CallToken(call));
        var receipt = await ApproveAndExecuteAsync(
            draft.Plan,
            writePermissions,
            new CodexVoiceCapabilityApproval(
                TodayFocusTool,
                [
                    new CodexVoiceCapabilityApprovalField("event", TodayFocusApprovalText.Sanitize(selected.SafeTitle)),
                    new CodexVoiceCapabilityApprovalField("purpose", draft.ApprovalText),
                    new CodexVoiceCapabilityApprovalField("durationSeconds", duration.ToString(CultureInfo.InvariantCulture))
                ]),
            cancellationToken,
            draft.Preparation);
        return ReceiptReply(receipt);
    }

    private async Task<CapabilityWorkflowReceipt> ApproveAndExecuteAsync(
        CapabilityExecutionPlan plan,
        CapabilityPermissionSet permissions,
        CodexVoiceCapabilityApproval approval,
        CancellationToken cancellationToken,
        CapabilityBrokerPreparation? prepared = null)
    {
        var preparation = prepared ?? _broker.Prepare(plan, permissions, DateTimeOffset.Now);
        var request = preparation.ApprovalRequest
            ?? throw new CodexVoiceToolException("CAPABILITY_APPROVAL_REQUIRED");
        var approved = await _requestApproval(approval, cancellationToken);
        cancellationToken.ThrowIfCancellationRequested();
        if (!approved)
        {
            try
            {
                _ = _broker.DecideApproval(
                    request.Id,
                    preparation.PlanDigest,
                    CapabilityApprovalDecision.Reject,
                    DateTimeOffset.Now);
            }
            catch (CapabilityBrokerException exception) when (exception.Code == "CAPABILITY_APPROVAL_REJECTED")
            {
            }
            throw new CodexVoiceToolException("CAPABILITY_APPROVAL_REJECTED");
        }

        var grant = _broker.DecideApproval(
            request.Id,
            preparation.PlanDigest,
            CapabilityApprovalDecision.Approve,
            DateTimeOffset.Now);
        return await _broker.ExecuteAsync(
            plan,
            permissions,
            grant,
            DateTimeOffset.Now,
            cancellationToken);
    }

    private static CodexAppServerReply ReceiptReply(CapabilityWorkflowReceipt receipt)
    {
        var succeeded = receipt.Status == CapabilityReceiptStatus.Succeeded
            && receipt.Steps.All(step => step.Readback.Status == CapabilityReadbackStatus.Verified);
        return ToolReply(succeeded, new
        {
            status = receipt.Status.WireValue(),
            replayed = receipt.Replayed,
            readbackVerified = receipt.Steps.All(step => step.Readback.Status == CapabilityReadbackStatus.Verified),
            steps = receipt.Steps.Select(step => new
            {
                capability = step.Capability.Id,
                status = step.Status.WireValue(),
                output = step.Output,
                errorCode = step.SafeError?.Code
            }).ToArray()
        });
    }

    private static CodexAppServerReply ToolReply(bool success, object payload)
    {
        var text = JsonSerializer.Serialize(payload, JsonOptions);
        return CodexAppServerReply.Success(new
        {
            success,
            contentItems = new[]
            {
                new { type = "inputText", text }
            }
        });
    }

    private static DynamicToolCall ParseCall(
        JsonElement? parameters,
        string? expectedRootThreadId)
    {
        if (parameters is not { ValueKind: JsonValueKind.Object } value
            || string.IsNullOrWhiteSpace(expectedRootThreadId)
            || !IdentifierPattern.IsMatch(expectedRootThreadId))
        {
            throw new CodexVoiceToolException("CAPABILITY_REQUEST_INVALID");
        }
        RequireOnlyKeys(value, ["arguments", "callId", "namespace", "threadId", "tool", "turnId"]);
        var callId = Identifier(value, "callId");
        var threadId = Identifier(value, "threadId");
        var tool = Identifier(value, "tool");
        var turnId = Identifier(value, "turnId");
        if (!string.Equals(threadId, expectedRootThreadId, StringComparison.Ordinal)
            || (value.TryGetProperty("namespace", out var namespaceValue)
                && namespaceValue.ValueKind != JsonValueKind.Null))
        {
            throw new CodexVoiceToolException("CAPABILITY_REQUEST_DENIED");
        }
        if (!value.TryGetProperty("arguments", out var arguments)
            || arguments.ValueKind != JsonValueKind.Object)
        {
            throw new CodexVoiceToolException("CAPABILITY_ARGUMENT_INVALID");
        }
        return new DynamicToolCall(
            callId,
            threadId,
            tool,
            turnId,
            arguments.Clone());
    }

    private static string Identifier(JsonElement value, string name)
    {
        if (!value.TryGetProperty(name, out var property)
            || property.ValueKind != JsonValueKind.String
            || property.GetString() is not { } text
            || !IdentifierPattern.IsMatch(text))
        {
            throw new CodexVoiceToolException("CAPABILITY_REQUEST_INVALID");
        }
        return text;
    }

    private static void RequireOnlyKeys(JsonElement value, IEnumerable<string> allowed)
    {
        if (value.ValueKind != JsonValueKind.Object)
        {
            throw new CodexVoiceToolException("CAPABILITY_ARGUMENT_INVALID");
        }
        var allowedSet = allowed.ToHashSet(StringComparer.Ordinal);
        var properties = value.EnumerateObject().ToArray();
        if (properties.Select(property => property.Name).Distinct(StringComparer.Ordinal).Count() != properties.Length
            || properties.Any(property => !allowedSet.Contains(property.Name)))
        {
            throw new CodexVoiceToolException("CAPABILITY_ARGUMENT_INVALID");
        }
    }

    private static DateTimeOffset RequiredDateTime(JsonElement arguments, string name)
    {
        var value = CapabilityJson.RequiredString(arguments, name, 64);
        if (!DateTimeOffset.TryParse(
                value,
                CultureInfo.InvariantCulture,
                DateTimeStyles.RoundtripKind,
                out var parsed))
        {
            throw new CodexVoiceToolException("CAPABILITY_ARGUMENT_INVALID");
        }
        return parsed;
    }

    private static CapabilityPrincipal Principal(string threadId)
    {
        return new CapabilityPrincipal("local-user", AgentSessionId: threadId);
    }

    private static CapabilityPermissionSet Permissions(
        CapabilityPrincipal principal,
        params string[] permissions)
    {
        return new CapabilityPermissionSet(
            principal,
            permissions.ToHashSet(StringComparer.Ordinal));
    }

    private static string CallToken(DynamicToolCall call)
    {
        var bytes = Encoding.UTF8.GetBytes($"{call.ThreadId}\n{call.TurnId}\n{call.CallId}\n{call.Tool}");
        return Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
    }

    private static string CapabilityTimeZoneId()
    {
        var identifier = TimeZoneInfo.Local.Id;
        if (identifier == "UTC" || identifier.Contains('/'))
        {
            return identifier;
        }
        if (TimeZoneInfo.TryConvertWindowsIdToIanaId(identifier, out var converted)
            && !string.IsNullOrEmpty(converted))
        {
            return converted;
        }
        throw new CodexVoiceToolException("CAPABILITY_UNAVAILABLE");
    }

    private static IReadOnlyList<object> BuildToolSpecs()
    {
        return
        [
            FunctionTool(
                CalendarTodayTool,
                "Read today's Calendar events through HoverPocket. Use the returned eventRef for Today Focus.",
                Schema([], new Dictionary<string, object>(StringComparer.Ordinal))),
            FunctionTool(
                TimerStartTool,
                "Start a HoverPocket countdown Timer after the user approves the exact duration and title.",
                Schema(
                    ["durationSeconds"],
                    new Dictionary<string, object>(StringComparer.Ordinal)
                    {
                        ["durationSeconds"] = new { type = "integer", minimum = 1, maximum = 86_400 },
                        ["title"] = new { type = "string", maxLength = 80 }
                    })),
            FunctionTool(
                CalendarCreateTool,
                "Create a Calendar event after the user approves the exact title and time range.",
                Schema(
                    ["title", "start", "end", "isAllDay"],
                    new Dictionary<string, object>(StringComparer.Ordinal)
                    {
                        ["title"] = new { type = "string", minLength = 1, maxLength = 80 },
                        ["start"] = new { type = "string", format = "date-time", maxLength = 64 },
                        ["end"] = new { type = "string", format = "date-time", maxLength = 64 },
                        ["isAllDay"] = new { type = "boolean" }
                    })),
            FunctionTool(
                TodayFocusTool,
                "Start Today Focus for a Calendar event: start a Timer and save today's purpose to Sticky Notes after one approval.",
                Schema(
                    ["eventRef"],
                    new Dictionary<string, object>(StringComparer.Ordinal)
                    {
                        ["eventRef"] = new { type = "string", minLength = 1, maxLength = 256 },
                        ["durationSeconds"] = new { type = "integer", minimum = 1, maximum = 86_400 },
                        ["purpose"] = new { type = "string", maxLength = 10_000 }
                    }))
        ];
    }

    private static object FunctionTool(string name, string description, JsonElement inputSchema)
    {
        return new
        {
            type = "function",
            name,
            description,
            inputSchema,
            deferLoading = false
        };
    }

    private static JsonElement Schema(
        string[] required,
        IReadOnlyDictionary<string, object> properties)
    {
        return JsonSerializer.SerializeToElement(new
        {
            type = "object",
            properties,
            required,
            additionalProperties = false
        }, JsonOptions);
    }

    private sealed record DynamicToolCall(
        string CallId,
        string ThreadId,
        string Tool,
        string TurnId,
        JsonElement Arguments);

    private sealed record CachedToolReply(
        string ArgumentDigest,
        CodexAppServerReply Reply);

    private sealed class CodexVoiceToolException(string code) : Exception(code)
    {
        public string Code { get; } = code;
    }
}
