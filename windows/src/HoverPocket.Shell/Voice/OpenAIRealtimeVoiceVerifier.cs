using System.Net;
using System.Text;
using System.Text.Json;
using HoverPocket.Shell.Capabilities;
using HoverPocket.Shell.Services;

namespace HoverPocket.Shell.Voice;

internal sealed class OpenAIRealtimeVoiceVerifier
{
    private readonly List<string> _failures = [];

    public int Run()
    {
        Task.Run(RunAsync).GetAwaiter().GetResult();
        if (_failures.Count == 0)
        {
            Console.WriteLine("OK OpenAI Realtime BYOK voice verification");
            return 0;
        }
        foreach (var failure in _failures)
        {
            Console.Error.WriteLine($"FAIL OpenAI Realtime BYOK: {failure}");
        }
        return 1;
    }

    private async Task RunAsync()
    {
        await VerifyDefaultOffAndProviderReplacementAsync();
        await VerifyCredentialAndMissingKeyFailClosedAsync();
        await VerifyBoundedSdpResponseAsync();
        await VerifyExactToolSurfaceBrokerDenialAndReadbackAsync();
        await VerifyLeaseMalformedEventStopMuteRestartAsync();
    }

    private async Task VerifyDefaultOffAndProviderReplacementAsync()
    {
        var sequence = new List<string>();
        var codexFactoryCount = 0;
        var openAIFactoryCount = 0;
        using var providers = new VoiceProviderCoordinator(
            featureEnabled: false,
            providerId: VoiceProviderIds.Off,
            codexFactory: () =>
            {
                codexFactoryCount++;
                return new FakeProviderCoordinator(VoiceProviderIds.CodexAppServer, sequence);
            },
            openAIRealtimeFactory: () =>
            {
                openAIFactoryCount++;
                return new FakeProviderCoordinator(VoiceProviderIds.OpenAIRealtimeByok, sequence);
            });
        await providers.InitializeAsync();
        Require(codexFactoryCount == 0 && openAIFactoryCount == 0, "off_constructed_provider");
        await providers.SetProviderAsync(VoiceProviderIds.OpenAIRealtimeByok);
        Require(openAIFactoryCount == 0, "disabled_provider_selection_started_transport");
        await providers.SetFeatureEnabledAsync(true);
        Require(openAIFactoryCount == 1 && sequence.Contains("openai_realtime_byok:start"), "openai_provider_did_not_start");
        await providers.SetProviderAsync(VoiceProviderIds.CodexAppServer);
        var openAIStop = sequence.IndexOf("openai_realtime_byok:stop");
        var codexStart = sequence.IndexOf("codex_app_server:start");
        Require(openAIStop >= 0 && codexStart > openAIStop, "provider_switch_overlapped_transport");
        await providers.SetProviderAsync(VoiceProviderIds.Off);
        Require(providers.Snapshot == CodexVoiceSnapshot.Disabled, "provider_off_not_disabled");
    }

    private async Task VerifyCredentialAndMissingKeyFailClosedAsync()
    {
        using var sample = new OpenAIRealtimeApiKey(new string('x', 32));
        Require(sample.ToString() == "[redacted]", "credential_string_not_redacted");
        Require(
            VoiceTextSafety.SanitizeVisibleText($"api_key={new string('x', 32)}", 200) == "[redacted]",
            "credential_visible_text_not_redacted");

        var authority = new FakeCapabilityAuthority();
        var tools = NewToolRuntime(authority);
        var credentials = new FakeCredentialStore(hasCredential: false);
        var calls = new FakeCallsClient();
        using var coordinator = new OpenAIRealtimeVoiceCoordinator(true, credentials, calls, tools);
        coordinator.SetUiAttached(true);
        await coordinator.InitializeAsync();
        Require(coordinator.Snapshot.Availability == CodexVoiceAvailability.Unavailable, "missing_key_not_unavailable");
        Require(coordinator.Snapshot.LastErrorCode == "openai_realtime_key_missing", "missing_key_error_not_safe");
        Require(credentials.LoadCount == 0 && calls.ExchangeCount == 0, "missing_key_touched_secret_or_network");
    }

    private async Task VerifyBoundedSdpResponseAsync()
    {
        var oversized = new byte[OpenAIRealtimeContract.MaximumSdpBytes + 1];
        Encoding.UTF8.GetBytes("v=0").CopyTo(oversized, 0);
        var rejected = false;
        try
        {
            _ = await ExchangeSdpResponseAsync(new ByteArrayContent(oversized));
        }
        catch (OpenAIRealtimeProtocolException error)
        {
            rejected = error.Code == "openai_realtime_answer_too_large";
        }
        Require(rejected, "oversized_sdp_content_length_not_rejected");

        var valid = "v=0" + new string('a', OpenAIRealtimeContract.MaximumSdpBytes - 3);
        var answer = await ExchangeSdpResponseAsync(new StringContent(valid, Encoding.UTF8, "application/sdp"));
        Require(
            Encoding.UTF8.GetByteCount(answer) == OpenAIRealtimeContract.MaximumSdpBytes,
            "maximum_sdp_response_not_accepted");
    }

    private static async Task<string> ExchangeSdpResponseAsync(HttpContent content)
    {
        using var httpClient = new HttpClient(new StaticResponseHandler(content));
        using var calls = new OpenAIRealtimeCallsClient(httpClient);
        using var apiKey = new OpenAIRealtimeApiKey(new string('x', 32));
        return await calls.ExchangeSdpAsync(
            "v=0\r\no=verify-offer\r\n",
            JsonSerializer.SerializeToElement(new { type = "realtime", model = OpenAIRealtimeContract.ModelId }),
            apiKey,
            CancellationToken.None);
    }

    private async Task VerifyExactToolSurfaceBrokerDenialAndReadbackAsync()
    {
        var authority = new FakeCapabilityAuthority();
        var runtime = NewToolRuntime(authority);
        var names = OpenAIRealtimeSessionBuilder.ValidateTools(runtime.SessionTools).Order(StringComparer.Ordinal).ToArray();
        var expected = new[]
        {
            OpenAIRealtimeCapabilityRuntime.CalendarCreateTool,
            OpenAIRealtimeCapabilityRuntime.CalendarListTool,
            OpenAIRealtimeCapabilityRuntime.TimerStartTool
        }.Order(StringComparer.Ordinal).ToArray();
        Require(names.SequenceEqual(expected, StringComparer.Ordinal), "tool_surface_not_exact");
        Require(OpenAIRealtimeContract.ModelId == "gpt-realtime-2.1", "realtime_model_regressed");

        authority.DenyNextPrepare = true;
        var denied = await runtime.ExecuteAsync(
            "session-denied",
            "call-denied",
            OpenAIRealtimeCapabilityRuntime.CalendarListTool,
            "{}",
            CancellationToken.None);
        Require(denied.Output?.Contains("permission_denied", StringComparison.Ordinal) == true, "broker_denial_not_propagated_safely");
        Require(authority.ExecuteCount == 0, "broker_denial_reached_execution");

        var timer = await runtime.ExecuteAsync(
            "session-readback",
            "call-readback",
            OpenAIRealtimeCapabilityRuntime.TimerStartTool,
            "{\"durationSeconds\":60,\"title\":\"verify\"}",
            CancellationToken.None);
        Require(timer.Output?.Contains("\"readback\":\"verified\"", StringComparison.Ordinal) == true, "timer_readback_not_verified");
        Require(authority.ExecuteCount == 1, "timer_not_routed_once_through_authority");

        var firstOnce = await runtime.ExecuteAsync(
            "session-once",
            "call-once",
            OpenAIRealtimeCapabilityRuntime.TimerStartTool,
            "{\"durationSeconds\":45}",
            CancellationToken.None);
        var secondOnce = await runtime.ExecuteAsync(
            "session-once",
            "call-once",
            OpenAIRealtimeCapabilityRuntime.TimerStartTool,
            "{\"durationSeconds\":45}",
            CancellationToken.None);
        Require(firstOnce == secondOnce && authority.ExecuteCount == 2, "repeated_call_executed_more_than_once");

        var calendarCreate = await runtime.ExecuteAsync(
            "session-calendar-create",
            "call-calendar-create",
            OpenAIRealtimeCapabilityRuntime.CalendarCreateTool,
            "{\"title\":\"verify\",\"start\":\"2026-08-24T01:00:00Z\",\"end\":\"2026-08-24T02:00:00Z\",\"isAllDay\":false}",
            CancellationToken.None);
        Require(calendarCreate.Output?.Contains("\"readback\":\"verified\"", StringComparison.Ordinal) == true, "calendar_create_readback_not_verified");
        Require(authority.ExecuteCount == 3, "calendar_create_not_routed_once_through_authority");

        var revokedCalendarRuntime = NewToolRuntime(new FakeCapabilityAuthority(), calendarAccessGranted: false);
        var revokedNames = OpenAIRealtimeSessionBuilder.ValidateTools(revokedCalendarRuntime.SessionTools);
        Require(revokedNames.SequenceEqual([OpenAIRealtimeCapabilityRuntime.TimerStartTool], StringComparer.Ordinal),
            "calendar_tools_exposed_without_host_grant");
    }

    private async Task VerifyLeaseMalformedEventStopMuteRestartAsync()
    {
        var authority = new FakeCapabilityAuthority();
        var runtime = NewToolRuntime(authority);
        var credentials = new FakeCredentialStore(hasCredential: true);
        var calls = new FakeCallsClient();
        using var coordinator = new OpenAIRealtimeVoiceCoordinator(true, credentials, calls, runtime);
        coordinator.SetUiAttached(true);
        await coordinator.InitializeAsync();
        coordinator.BeginMicrophonePermissionRequest();
        var start = await coordinator.StartRealtimeAsync("v=0\r\no=verify-offer\r\n");
        var secondBlocked = false;
        try
        {
            _ = await coordinator.StartRealtimeAsync("v=0\r\no=second-offer\r\n");
        }
        catch (CodexAppServerProtocolException)
        {
            secondBlocked = true;
        }
        Require(secondBlocked && calls.ExchangeCount == 1, "one_active_lease_not_enforced");
        coordinator.ConfirmRealtimeConnected(start.Generation, start.ThreadId);
        coordinator.SetMuted(true);
        Require(coordinator.Snapshot.Muted, "mute_state_not_applied");
        coordinator.SetMuted(false);
        Require(!coordinator.Snapshot.Muted, "unmute_state_not_applied");

        var malformedBlocked = false;
        try
        {
            _ = await coordinator.HandleRealtimeFunctionEventAsync(
                start.Generation,
                start.ThreadId,
                JsonSerializer.SerializeToElement(new
                {
                    type = "response.function_call_arguments.done",
                    call_id = "invalid/call",
                    name = OpenAIRealtimeCapabilityRuntime.TimerStartTool,
                    arguments = "{}"
                }));
        }
        catch (CodexAppServerProtocolException)
        {
            malformedBlocked = true;
        }
        Require(malformedBlocked, "malformed_event_not_fail_closed");

        var valid = await coordinator.HandleRealtimeFunctionEventAsync(
            start.Generation,
            start.ThreadId,
            JsonSerializer.SerializeToElement(new
            {
                type = "response.function_call_arguments.done",
                call_id = "call-valid",
                name = OpenAIRealtimeCapabilityRuntime.TimerStartTool,
                arguments = "{\"durationSeconds\":30}"
            }));
        Require(valid.Output?.Contains("\"readback\":\"verified\"", StringComparison.Ordinal) == true, "function_result_readback_missing");

        await coordinator.StopRealtimeAsync();
        Require(!coordinator.Snapshot.RealtimeAttached && coordinator.Snapshot.Muted, "stop_did_not_teardown_lease");
        await coordinator.NotifySystemTransitionAsync();
        Require(coordinator.Snapshot.Availability == CodexVoiceAvailability.Ready, "restart_not_ready");
        var restarted = await coordinator.StartRealtimeAsync("v=0\r\no=restart-offer\r\n");
        Require(restarted.Generation != start.Generation && calls.ExchangeCount == 2, "restart_did_not_create_fresh_lease");
        await coordinator.StopRealtimeAsync();
    }

    private static OpenAIRealtimeCapabilityRuntime NewToolRuntime(
        FakeCapabilityAuthority authority,
        bool calendarAccessGranted = true) =>
        new(
            authority,
            (_, cancellationToken) =>
            {
                cancellationToken.ThrowIfCancellationRequested();
                return Task.FromResult(true);
            },
            (_, cancellationToken) =>
            {
                cancellationToken.ThrowIfCancellationRequested();
                return Task.FromResult(true);
            },
            () => calendarAccessGranted,
            () => "UTC",
            () => DateTimeOffset.Parse("2026-08-24T00:00:00Z"));

    private void Require(bool condition, string failure)
    {
        if (!condition)
        {
            _failures.Add(failure);
        }
    }

    private sealed class FakeCredentialStore(bool hasCredential) : IOpenAIRealtimeCredentialStore
    {
        private bool _hasCredential = hasCredential;
        public int HasCount { get; private set; }
        public int LoadCount { get; private set; }

        public bool HasCredential()
        {
            HasCount++;
            return _hasCredential;
        }

        public OpenAIRealtimeApiKey? Load()
        {
            LoadCount++;
            return _hasCredential ? new OpenAIRealtimeApiKey(new string('x', 32)) : null;
        }

        public void Save(OpenAIRealtimeApiKey apiKey)
        {
            _ = apiKey;
            _hasCredential = true;
        }

        public void Delete() => _hasCredential = false;
    }

    private sealed class FakeCallsClient : IOpenAIRealtimeCallsClient
    {
        public int ExchangeCount { get; private set; }
        public JsonElement? LastSession { get; private set; }

        public Task<string> ExchangeSdpAsync(
            string localSdp,
            JsonElement session,
            OpenAIRealtimeApiKey apiKey,
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            _ = localSdp;
            _ = apiKey;
            ExchangeCount++;
            LastSession = session.Clone();
            return Task.FromResult("v=0\r\no=verify-answer\r\n");
        }

        public void Dispose() { }
    }

    private sealed class StaticResponseHandler(HttpContent content) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            _ = request;
            cancellationToken.ThrowIfCancellationRequested();
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = content
            });
        }
    }

    private sealed class FakeCapabilityAuthority : IOpenAIRealtimeCapabilityAuthority
    {
        private static readonly string Digest = "sha256:" + new string('0', 64);
        public bool DenyNextPrepare { get; set; }
        public int ExecuteCount { get; private set; }

        public OpenAIRealtimeCapabilityDescriptor Resolve(PocketCapabilityKey key) => key switch
        {
            var value when value == CapabilityIds.CalendarList => new(
                key, CapabilityEffect.PrivateRead, Set("calendar.events.read"), CapabilityApprovalPolicy.PermissionGrant),
            var value when value == CapabilityIds.CalendarCreate => new(
                key, CapabilityEffect.ExternalWrite, Set("calendar.events.write"), CapabilityApprovalPolicy.PerCall),
            var value when value == CapabilityIds.TimerStart => new(
                key, CapabilityEffect.ReversibleLocalWrite, Set("timer.write"), CapabilityApprovalPolicy.BrokerPolicy),
            _ => throw new CapabilityBrokerException("CAPABILITY_UNKNOWN", key.Id)
        };

        public CapabilityBrokerPreparation Prepare(
            CapabilityExecutionPlan plan,
            CapabilityPermissionSet permissions,
            DateTimeOffset now)
        {
            _ = permissions;
            if (DenyNextPrepare)
            {
                DenyNextPrepare = false;
                throw new CapabilityBrokerException("CAPABILITY_PERMISSION_DENIED", "verify");
            }
            var capability = plan.Steps[0].Capability;
            var requiresApproval = capability == CapabilityIds.CalendarCreate
                || capability == CapabilityIds.TimerStart;
            var request = requiresApproval
                ? new CapabilityApprovalRequest(
                    "approval-verify",
                    plan.Id,
                    Digest,
                    plan.Principal,
                    null,
                    now,
                    now.AddMinutes(1),
                    "nonce-verify",
                    [],
                    plan.RequiredPermissions)
                : null;
            return new CapabilityBrokerPreparation(Digest, request, []);
        }

        public CapabilityApprovalGrant DecideApproval(
            string requestId,
            string planDigest,
            CapabilityApprovalDecision decision,
            DateTimeOffset now)
        {
            _ = requestId;
            _ = planDigest;
            _ = now;
            if (decision == CapabilityApprovalDecision.Reject)
            {
                throw new CapabilityBrokerException("CAPABILITY_APPROVAL_REJECTED", "verify");
            }
            return new CapabilityApprovalGrant("grant-verify");
        }

        public Task<CapabilityWorkflowReceipt> ExecuteAsync(
            CapabilityExecutionPlan plan,
            CapabilityPermissionSet permissions,
            CapabilityApprovalGrant? grant,
            DateTimeOffset now,
            CancellationToken cancellationToken)
        {
            _ = permissions;
            _ = grant;
            cancellationToken.ThrowIfCancellationRequested();
            ExecuteCount++;
            JsonElement output;
            CapabilityReadbackStrategy strategy;
            if (plan.Steps[0].Capability == CapabilityIds.CalendarList)
            {
                output = CapabilityJson.From(new
                {
                    events = Array.Empty<object>()
                });
                strategy = CapabilityReadbackStrategy.SameStoreSnapshot;
            }
            else if (plan.Steps[0].Capability == CapabilityIds.CalendarCreate)
            {
                output = CapabilityJson.From(new
                {
                    eventRef = "event-verify",
                    eventId = "event-id-verify",
                    start = "2026-08-24T01:00:00.0000000+00:00",
                    end = "2026-08-24T02:00:00.0000000+00:00",
                    safeTitle = "verify"
                });
                strategy = CapabilityReadbackStrategy.CapabilityQuery;
            }
            else
            {
                output = CapabilityJson.From(new
                {
                    timerId = "00000000-0000-0000-0000-000000000001",
                    state = "running",
                    endAt = "2026-08-24T00:01:00.0000000+00:00"
                });
                strategy = CapabilityReadbackStrategy.CapabilityQuery;
            }
            var readback = new CapabilityReadbackReceipt(
                CapabilityReadbackStatus.Verified,
                strategy,
                now,
                output,
                Digest);
            var step = new CapabilityReceipt(
                "invocation-verify",
                plan.Id,
                Digest,
                plan.Steps[0].Capability,
                CapabilityReceiptStatus.Succeeded,
                output,
                readback,
                false,
                null,
                "audit-verify",
                null,
                now,
                false);
            return Task.FromResult(new CapabilityWorkflowReceipt(
                plan.Id,
                Digest,
                CapabilityReceiptStatus.Succeeded,
                [step],
                now,
                false));
        }

        private static IReadOnlySet<string> Set(string value) =>
            new HashSet<string>([value], StringComparer.Ordinal);
    }

    private sealed class FakeProviderCoordinator(string providerId, List<string> sequence) : IVoiceRuntimeCoordinator
    {
        private bool _enabled;
        private CodexVoiceSnapshot _snapshot = CodexVoiceSnapshot.Disabled;

        public string ProviderId { get; } = providerId;
        public event EventHandler<CodexVoiceSnapshot>? SnapshotChanged;
        public event EventHandler<VoiceTransportSignal>? TransportSignal
        {
            add { }
            remove { }
        }
        public CodexVoiceSnapshot Snapshot => _snapshot;

        public Task InitializeAsync(CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return Task.CompletedTask;
        }

        public Task SetFeatureEnabledAsync(bool enabled, CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (_enabled == enabled)
            {
                return Task.CompletedTask;
            }
            _enabled = enabled;
            sequence.Add($"{ProviderId}:{(enabled ? "start" : "stop")}");
            _snapshot = enabled
                ? CodexVoiceSnapshot.Disabled with
                {
                    Availability = CodexVoiceAvailability.Ready,
                    TransportAttached = true
                }
                : CodexVoiceSnapshot.Disabled;
            SnapshotChanged?.Invoke(this, _snapshot);
            return Task.CompletedTask;
        }

        public void SetUiAttached(bool attached) { _ = attached; }
        public void SetMuted(bool muted) { _ = muted; }
        public void BeginMicrophonePermissionRequest() { }
        public Task<VoiceRealtimeStartResult> StartRealtimeAsync(string sdp, CancellationToken cancellationToken = default) =>
            Task.FromResult(new VoiceRealtimeStartResult(1, "fake-session"));
        public void ConfirmRealtimeConnected(int generation, string threadId) { _ = generation; _ = threadId; }
        public Task StopRealtimeAsync(CancellationToken cancellationToken = default) => Task.CompletedTask;
        public Task AbortRealtimeStartAsync(string reason, CancellationToken cancellationToken = default) => Task.CompletedTask;
        public Task<VoiceRealtimeFunctionResult> HandleRealtimeFunctionEventAsync(
            int generation,
            string threadId,
            JsonElement eventPayload,
            CancellationToken cancellationToken = default) => Task.FromResult(new VoiceRealtimeFunctionResult(false, null, null));
        public Task NotifySystemTransitionAsync(CancellationToken cancellationToken = default) => Task.CompletedTask;
        public void Dispose() { }
    }
}
