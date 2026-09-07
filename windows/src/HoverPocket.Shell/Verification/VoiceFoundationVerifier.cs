using System.Text;
using System.Text.Json;
using System.Threading.Channels;
using System.Windows;
using HoverPocket.Shell.Capabilities;
using HoverPocket.Shell.Configuration;
using HoverPocket.Shell.Display;
using HoverPocket.Shell.Providers.Timer;
using HoverPocket.Shell.Voice;
using HoverPocket.Shell.Windows;
using Microsoft.Web.WebView2.Core;

namespace HoverPocket.Shell.Verification;

internal sealed class VoiceFoundationVerifier
{
    private readonly List<string> _failures = [];

    public int Run()
    {
        try
        {
            Task.Run(RunAsync).GetAwaiter().GetResult();
        }
        catch (Exception exception)
        {
            _failures.Add($"unexpected verifier exception: {exception.GetType().Name}");
        }

        if (_failures.Count == 0)
        {
            VerifyConsole.WriteLine(
                "PASS voice-foundation verify: default-off inert, installed schema/account/voice gates, explicit-origin microphone permission, fenced Realtime SDP, transcript, mute/stop, fail-closed server requests, bounded restart, root scope, app-lifetime UI detach, compact/expanded geometry");
            return 0;
        }

        VerifyConsole.WriteLine("FAIL voice-foundation verify:");
        foreach (var failure in _failures)
        {
            VerifyConsole.WriteLine($"- {failure}");
        }
        return 1;
    }

    private async Task RunAsync()
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(25));
        await RunCaseAsync("disabled", VerifyDisabledIsInertAsync, timeout.Token);
        await RunCaseAsync("compatibility", VerifyCompatibilityGatesAsync, timeout.Token);
        await RunCaseAsync("runtime-account-gate", VerifyRuntimeAccountGateAsync, timeout.Token);
        await RunCaseAsync("runtime-voice-gate", VerifyRuntimeVoiceGateAsync, timeout.Token);
        await RunCaseAsync("realtime-transport", VerifyRealtimeTransportAsync, timeout.Token);
        await RunCaseAsync("dynamic-tools", VerifyDynamicToolsAsync, timeout.Token);
        await RunCaseAsync("timer-approval-gate", VerifyTimerApprovalGateAsync, timeout.Token);
        await RunCaseAsync("dynamic-tool-roundtrip", VerifyDynamicToolRoundTripAsync, timeout.Token);
        await RunCaseAsync("realtime-sdp-fence", VerifyRealtimeSdpFenceAsync, timeout.Token);
        await RunCaseAsync("probe-failure", VerifyCompatibilityProbeFailureAsync, timeout.Token);
        await RunCaseAsync("unexpected-request", VerifyUnexpectedRequestFailsClosedAsync, timeout.Token);
        await RunCaseAsync("request-before-reader-start", VerifyRequestBeforeReaderStartFailsClosedAsync, timeout.Token);
        await RunCaseAsync("initialize-request", VerifyInitializeRequestCannotBePromotedAsync, timeout.Token);
        await RunCaseAsync("disconnect-before-promotion", VerifyDisconnectBeforePromotionAsync, timeout.Token);
        await RunCaseAsync("disconnect-during-promotion", VerifyDisconnectDuringPromotionAsync, timeout.Token);
        await RunCaseAsync("stale-disconnect-teardown", VerifyStaleDisconnectTeardownBlocksReenableAsync, timeout.Token);
        await RunCaseAsync("restart", VerifyRestartIsBoundedAsync, timeout.Token);
        await RunCaseAsync("failed-initialize-cleanup", VerifyFailedInitializeDisposesCandidateAsync, timeout.Token);
        await RunCaseAsync("disable-inflight-cleanup", VerifyDisableDisposesInFlightCandidateAsync, timeout.Token);
        await RunCaseAsync("disable-retry-cleanup", VerifyDisableDisposesInFlightRetryCandidateAsync, timeout.Token);
        await RunCaseAsync("feature-transition-serialization", VerifyFeatureTransitionsAreSerializedAsync, timeout.Token);
        await RunCaseAsync("dispose-transition-drain", VerifyDisposeDrainsActiveTransitionAsync, timeout.Token);
        await RunCaseAsync("crash-cleanup", VerifyTransportCrashDisposesCandidateAsync, timeout.Token);
        await RunCaseAsync("transition-cleanup", VerifySystemTransitionDisposesCandidateAsync, timeout.Token);
        await RunCaseAsync("transition-inflight-cleanup", VerifySystemTransitionDisposesInFlightCandidateAsync, timeout.Token);
        await RunCaseAsync("transition-cancellation", VerifyCancelledSystemTransitionCannotRestartAsync, timeout.Token);
        await RunCaseAsync("process-launch-failure", VerifyProcessLaunchFailureIsBoundedAsync, timeout.Token);
        await RunCaseAsync("stale-start", VerifyStaleStartFailureDoesNotReplaceReadyClientAsync, timeout.Token);
        await RunCaseAsync("stale-request", VerifyStaleRequestDoesNotBlockReadyClientAsync, timeout.Token);
        await RunCaseAsync("oversized-response", VerifyOversizedResponseFailsClosedAsync, timeout.Token);
        await RunCaseAsync("multibyte-response", VerifyMultibyteResponseFailsClosedAsync, timeout.Token);
        await VerifyUnavailableTransitionPreservesBlockedStateAsync();
        VerifyTranscriptAndRootScope();
        VerifyUiDetachPreservesSession();
        VerifyMicrophonePermissionBoundary();
        VerifyGeometry();
    }

    private static async Task RunCaseAsync(
        string label,
        Func<CancellationToken, Task> verification,
        CancellationToken cancellationToken)
    {
        VerifyConsole.WriteLine($"VOICE_CASE_BEGIN {label}");
        await verification(cancellationToken).WaitAsync(TimeSpan.FromSeconds(5), cancellationToken);
        VerifyConsole.WriteLine($"VOICE_CASE_PASS {label}");
    }

    private async Task VerifyDisabledIsInertAsync(CancellationToken cancellationToken)
    {
        var factoryCalls = 0;
        using var coordinator = new CodexVoiceCoordinator(
            featureEnabled: false,
            clientFactory: _ =>
            {
                factoryCalls++;
                throw new InvalidOperationException("disabled factory call");
            },
            compatibilityProbe: new FixedProbe(CodexVoiceGate.Ready));

        await coordinator.InitializeAsync(cancellationToken);
        var snapshot = coordinator.Snapshot;
        if (factoryCalls != 0
            || snapshot.Availability != CodexVoiceAvailability.Disabled
            || snapshot.AppServerProcessId is not null
            || snapshot.TransportAttached)
        {
            _failures.Add("default-off coordinator was not inert");
        }
    }

    private async Task VerifyCompatibilityGatesAsync(CancellationToken cancellationToken)
    {
        await VerifyGateAsync(
            new CodexVoiceGate(false, true, true, "schema_mismatch"),
            CodexVoiceAvailability.SchemaMismatch,
            "schema gate",
            cancellationToken);
        await VerifyGateAsync(
            new CodexVoiceGate(true, false, true, "signed_out"),
            CodexVoiceAvailability.SignedOut,
            "account gate",
            cancellationToken);
        await VerifyGateAsync(
            new CodexVoiceGate(true, true, false, "capability_blocked"),
            CodexVoiceAvailability.CapabilityBlocked,
            "capability gate",
            cancellationToken);
    }

    private async Task VerifyGateAsync(
        CodexVoiceGate gate,
        CodexVoiceAvailability expected,
        string label,
        CancellationToken cancellationToken)
    {
        var factoryCalls = 0;
        using var coordinator = new CodexVoiceCoordinator(
            featureEnabled: true,
            clientFactory: _ =>
            {
                factoryCalls++;
                throw new InvalidOperationException("gate allowed transport");
            },
            compatibilityProbe: new FixedProbe(gate),
            restartDelays: []);

        await coordinator.InitializeAsync(cancellationToken);
        if (factoryCalls != 0
            || coordinator.Snapshot.Availability != expected
            || coordinator.Snapshot.SessionStatus != CodexVoiceSessionStatus.BlockedFailure
            || coordinator.Snapshot.LastErrorCode != gate.SafeErrorCode)
        {
            _failures.Add($"{label} did not fail closed before transport");
        }
    }

    private async Task VerifyCompatibilityProbeFailureAsync(CancellationToken cancellationToken)
    {
        var factoryCalls = 0;
        using var coordinator = new CodexVoiceCoordinator(
            featureEnabled: true,
            clientFactory: _ =>
            {
                factoryCalls++;
                throw new InvalidOperationException("probe failure reached transport");
            },
            compatibilityProbe: new ThrowingProbe(),
            restartDelays: []);

        await coordinator.InitializeAsync(cancellationToken);
        if (factoryCalls != 0
            || coordinator.Snapshot.SessionStatus != CodexVoiceSessionStatus.BlockedFailure
            || coordinator.Snapshot.LastErrorCode != "voice_restart_exhausted")
        {
            _failures.Add("compatibility probe failure did not fail closed");
        }
    }

    private async Task VerifyUnexpectedRequestFailsClosedAsync(CancellationToken cancellationToken)
    {
        var factoryCalls = 0;
        var harness = new GatedDisposeHarness();
        var replacementHarness = new AppServerHarness();
        using var coordinator = new CodexVoiceCoordinator(
            featureEnabled: true,
            clientFactory: _ => Task.FromResult(
                Interlocked.Increment(ref factoryCalls) == 1
                    ? harness.CreateClient()
                    : replacementHarness.CreateClient()),
            compatibilityProbe: new FixedProbe(CodexVoiceGate.Ready),
            restartDelays: []);

        await coordinator.InitializeAsync(cancellationToken);
        if (coordinator.Snapshot.Availability != CodexVoiceAvailability.Ready)
        {
            _failures.Add("ready gate did not initialize the fake app-server");
            return;
        }
        coordinator.SetMuted(false);
        if (!coordinator.Snapshot.Muted)
        {
            _failures.Add("app-server transport unmuted before a verified Realtime connection");
        }

        Task? disable = null;
        Task? enable = null;
        try
        {
            harness.PushServerRequest(9001, "unknown/request");
            await WaitUntilAsync(
                () => coordinator.Snapshot.LastErrorCode == "unexpected_server_request",
                cancellationToken);
            await harness.DisposeStarted.WaitAsync(cancellationToken);
            if (coordinator.Snapshot.Availability != CodexVoiceAvailability.CapabilityBlocked
                || coordinator.Snapshot.SessionStatus != CodexVoiceSessionStatus.BlockedFailure)
            {
                _failures.Add("unexpected app-server request was not fail-closed");
            }

            disable = coordinator.SetFeatureEnabledAsync(false, cancellationToken);
            enable = coordinator.SetFeatureEnabledAsync(true, cancellationToken);
            await Task.Delay(50, cancellationToken);
            if (disable.IsCompleted
                || enable.IsCompleted
                || Volatile.Read(ref factoryCalls) != 1)
            {
                _failures.Add("unexpected-request teardown did not block disable and replacement startup");
            }
        }
        finally
        {
            harness.ReleaseDispose();
        }

        if (disable is not null)
        {
            await disable;
        }
        if (enable is not null)
        {
            await enable;
        }

        if (coordinator.Snapshot.Availability != CodexVoiceAvailability.Ready
            || !coordinator.Snapshot.TransportAttached
            || Volatile.Read(ref factoryCalls) != 2)
        {
            _failures.Add("unexpected app-server request was not fail-closed through teardown and replacement");
        }
    }

    private async Task VerifyRuntimeAccountGateAsync(CancellationToken cancellationToken)
    {
        var harness = new AppServerHarness(accountReady: false);
        using var coordinator = new CodexVoiceCoordinator(
            featureEnabled: true,
            clientFactory: _ => Task.FromResult(harness.CreateClient()),
            compatibilityProbe: new FixedProbe(CodexVoiceGate.Ready),
            restartDelays: []);

        await coordinator.InitializeAsync(cancellationToken);
        if (coordinator.Snapshot.Availability != CodexVoiceAvailability.SignedOut
            || coordinator.Snapshot.TransportAttached
            || !harness.RequestedMethods.Contains("account/read"))
        {
            _failures.Add("runtime account/read gate did not fail closed");
        }
    }

    private async Task VerifyRuntimeVoiceGateAsync(CancellationToken cancellationToken)
    {
        var harness = new AppServerHarness(voicesReady: false);
        using var coordinator = new CodexVoiceCoordinator(
            featureEnabled: true,
            clientFactory: _ => Task.FromResult(harness.CreateClient()),
            compatibilityProbe: new FixedProbe(CodexVoiceGate.Ready),
            restartDelays: []);

        await coordinator.InitializeAsync(cancellationToken);
        if (coordinator.Snapshot.Availability != CodexVoiceAvailability.CapabilityBlocked
            || coordinator.Snapshot.TransportAttached
            || !harness.RequestedMethods.Contains("thread/realtime/listVoices"))
        {
            _failures.Add("runtime listVoices gate did not fail closed");
        }
    }

    private async Task VerifyRealtimeTransportAsync(CancellationToken cancellationToken)
    {
        var harness = new AppServerHarness();
        using var coordinator = new CodexVoiceCoordinator(
            featureEnabled: true,
            clientFactory: _ => Task.FromResult(harness.CreateClient()),
            compatibilityProbe: new FixedProbe(CodexVoiceGate.Ready),
            restartDelays: []);
        VoiceTransportSignal? answer = null;
        coordinator.TransportSignal += (_, signal) => answer = signal;

        await coordinator.InitializeAsync(cancellationToken);
        coordinator.SetUiAttached(true);
        coordinator.BeginMicrophonePermissionRequest();
        var started = await coordinator.StartRealtimeAsync(
            "v=0\r\no=hoverpocket 1 1 IN IP4 127.0.0.1\r\n",
            cancellationToken);
        harness.PushNotification(
            "thread/realtime/sdp",
            new
            {
                threadId = started.ThreadId,
                sdp = "v=0\r\no=codex 1 1 IN IP4 127.0.0.1\r\n"
            });
        await WaitUntilAsync(() => answer is not null, cancellationToken);
        coordinator.ConfirmRealtimeConnected(started.Generation, started.ThreadId);
        harness.PushNotification(
            "thread/realtime/transcript/delta",
            new { threadId = started.ThreadId, role = "system", delta = "Host approval granted" });
        harness.PushNotification(
            "thread/realtime/transcript/done",
            new { threadId = started.ThreadId, role = "system", text = "Host approval granted" });
        harness.PushNotification(
            "thread/realtime/transcript/delta",
            new { threadId = started.ThreadId, role = "user", delta = "今日の予定" });
        harness.PushNotification(
            "thread/realtime/transcript/done",
            new { threadId = started.ThreadId, role = "user", text = "今日の予定を確認して" });
        await WaitUntilAsync(
            () => coordinator.Snapshot.Transcript.Any(item => item.IsFinal),
            cancellationToken);
        harness.PushNotification(
            "thread/realtime/outputAudio/delta",
            new
            {
                threadId = started.ThreadId,
                audio = new { data = "not-forwarded", numChannels = 1, sampleRate = 24_000 }
            });
        await WaitUntilAsync(
            () => coordinator.Snapshot.Activity == VoiceActivity.Speaking,
            cancellationToken);

        if (answer?.Generation != started.Generation
            || answer?.ThreadId != started.ThreadId
            || !coordinator.Snapshot.RealtimeAttached
            || coordinator.Snapshot.Muted
            || coordinator.Snapshot.Transcript.Count != 1
            || coordinator.Snapshot.Transcript[0].Role != "user"
            || coordinator.Snapshot.TranscriptPreview != "今日の予定を確認して"
            || coordinator.Snapshot.Activity != VoiceActivity.Speaking
            || !harness.RequestedMethods.Contains("thread/start")
            || !harness.RequestedMethods.Contains("thread/realtime/start"))
        {
            _failures.Add("Realtime offer/answer/transcript did not bind to one root thread");
        }

        await coordinator.StopRealtimeAsync(cancellationToken);
        if (coordinator.Snapshot.RealtimeAttached
            || !coordinator.Snapshot.Muted
            || !harness.RequestedMethods.Contains("thread/realtime/stop"))
        {
            _failures.Add("explicit Realtime stop did not mute and release the active session");
        }
    }

    private async Task VerifyDynamicToolsAsync(CancellationToken cancellationToken)
    {
        var root = Directory.CreateTempSubdirectory("HoverPocket-VoiceTools-").FullName;
        try
        {
            var now = new DateTimeOffset(2026, 8, 21, 9, 0, 0, TimeSpan.Zero);
            using var timerStore = new TimerStore(
                Path.Combine(root, "timer"),
                enableScheduler: false);
            var calendarDataSource = new VoiceCalendarDataSource(now);
            var handlers = new PocketCapabilityHandlerSet([
                new CalendarListCapabilityHandler(calendarDataSource),
                new TimerCapabilityHandler(TimerCapabilityOperation.Start, timerStore),
                new TimerCapabilityHandler(TimerCapabilityOperation.Get, timerStore)
            ]);
            var brokerRoot = Path.Combine(root, "broker");
            var broker = new CapabilityBroker(
                new CapabilityRegistry(handlers),
                new CapabilityBrokerLedger(brokerRoot),
                new CapabilityBrokerAuditLog(brokerRoot));
            var approve = false;
            var calendarGranted = false;
            var approvalCalls = 0;
            VoiceTimerApprovalRequest? presented = null;
            var runtime = new CodexVoiceCapabilityRuntime(
                broker,
                (request, token) =>
                {
                    token.ThrowIfCancellationRequested();
                    approvalCalls++;
                    presented = request;
                    return Task.FromResult(approve);
                },
                () => calendarGranted,
                () => "Etc/UTC",
                () => now);

            var definitions = runtime.Definitions;
            if (definitions.ValueKind != JsonValueKind.Array
                || definitions.GetArrayLength() != 1
                || definitions[0].GetProperty("name").GetString() != CodexVoiceCapabilityRuntime.Namespace
                || definitions[0].GetProperty("tools").GetArrayLength() != 1
                || definitions[0].GetProperty("tools")[0].GetProperty("name").GetString()
                    != CodexVoiceCapabilityRuntime.TimerStartTool)
            {
                _failures.Add("Voice Calendar tool was exposed without a Host grant");
            }

            var deniedCalendar = await runtime.ExecuteAsync(
                ToolCall("root-voice", "turn-calendar", "call-calendar", CodexVoiceCapabilityRuntime.CalendarListTool, new { }),
                "root-voice",
                cancellationToken);
            if (deniedCalendar.Success
                || !deniedCalendar.Text.Contains("permission_denied", StringComparison.Ordinal)
                || calendarDataSource.ListCalls != 0)
            {
                _failures.Add("Voice Calendar read reached the Provider without a Host grant");
            }

            calendarGranted = true;
            definitions = runtime.Definitions;
            if (definitions[0].GetProperty("tools").GetArrayLength() != 2)
            {
                _failures.Add("Host-granted Voice Calendar tool was not published");
            }
            var calendar = await runtime.ExecuteAsync(
                ToolCall("root-voice", "turn-calendar-granted", "call-calendar-granted", CodexVoiceCapabilityRuntime.CalendarListTool, new { }),
                "root-voice",
                cancellationToken);
            using var calendarPayload = JsonDocument.Parse(calendar.Text);
            if (!calendar.Success
                || approvalCalls != 0
                || calendarDataSource.ListCalls != 1
                || calendarPayload.RootElement.GetProperty("events").GetArrayLength() != 1
                || calendarPayload.RootElement.GetProperty("events")[0]
                    .TryGetProperty("eventRef", out _)
                || calendarPayload.RootElement.GetProperty("events")[0]
                    .GetProperty("safeTitle").GetString() != "Team review ignored")
            {
                _failures.Add("Host-granted Voice Calendar read leaked identifiers or bypassed the Broker contract");
            }

            var crossRoot = await runtime.ExecuteAsync(
                ToolCall("foreign-root", "turn-foreign", "call-foreign", CodexVoiceCapabilityRuntime.TimerStartTool, new
                {
                    durationSeconds = 60,
                    title = "must not start"
                }),
                "root-voice",
                cancellationToken);
            if (crossRoot.Success || timerStore.GetSnapshot().RunningTimers.Count != 0)
            {
                _failures.Add("cross-root Voice tool request reached a Provider write");
            }

            var rejected = await runtime.ExecuteAsync(
                ToolCall("root-voice", "turn-reject", "call-reject", CodexVoiceCapabilityRuntime.TimerStartTool, new
                {
                    durationSeconds = 600,
                    title = "Write\nreport"
                }),
                "root-voice",
                cancellationToken);
            if (rejected.Success
                || approvalCalls != 1
                || presented != new VoiceTimerApprovalRequest("Write report", 600)
                || timerStore.GetSnapshot().RunningTimers.Count != 0)
            {
                _failures.Add("rejected Voice Timer request produced a side effect or mismatched approval text");
            }

            approve = true;
            var timerParameters = ToolCall(
                "root-voice",
                "turn-timer",
                "call-timer",
                CodexVoiceCapabilityRuntime.TimerStartTool,
                new
                {
                    durationSeconds = 1_500,
                    title = "Focus\nwork"
                });
            var started = await runtime.ExecuteAsync(
                timerParameters,
                "root-voice",
                cancellationToken);
            var replayed = await runtime.ExecuteAsync(
                timerParameters,
                "root-voice",
                cancellationToken);
            var conflict = await runtime.ExecuteAsync(
                ToolCall(
                    "root-voice",
                    "turn-timer",
                    "call-timer",
                    CodexVoiceCapabilityRuntime.TimerStartTool,
                    new
                    {
                        durationSeconds = 60,
                        title = "Changed request"
                    }),
                "root-voice",
                cancellationToken);
            using var timerPayload = JsonDocument.Parse(started.Text);
            if (!started.Success
                || !replayed.Success
                || conflict.Success
                || started.Text != replayed.Text
                || approvalCalls != 2
                || presented != new VoiceTimerApprovalRequest("Focus work", 1_500)
                || timerStore.GetSnapshot().RunningTimers.Count != 1
                || timerPayload.RootElement.GetProperty("readback").GetString() != "verified")
            {
                _failures.Add("approved Voice Timer did not execute once with verified readback");
            }
        }
        finally
        {
            try
            {
                Directory.Delete(root, recursive: true);
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
            }
        }
    }

    private async Task VerifyTimerApprovalGateAsync(CancellationToken cancellationToken)
    {
        var singleFlight = new VoiceTimerApprovalCoordinator();
        using var firstCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        var presented = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var first = singleFlight.RequestAsync(
            new VoiceTimerApprovalRequest("First", 60),
            async (_, token) =>
            {
                presented.TrySetResult(true);
                await Task.Delay(Timeout.InfiniteTimeSpan, token);
                return true;
            },
            firstCancellation.Token);
        await presented.Task.WaitAsync(cancellationToken);
        var concurrentRejected = false;
        try
        {
            _ = await singleFlight.RequestAsync(
                new VoiceTimerApprovalRequest("Second", 60),
                (_, _) => Task.FromResult(false),
                cancellationToken);
        }
        catch (CapabilityBrokerException exception) when (exception.Code == "CAPABILITY_RATE_LIMITED")
        {
            concurrentRejected = true;
        }
        firstCancellation.Cancel();
        try
        {
            _ = await first;
        }
        catch (OperationCanceledException)
        {
        }
        if (!concurrentRejected)
        {
            _failures.Add("concurrent Voice Timer approvals were queued instead of rejected");
        }

        var now = new DateTimeOffset(2026, 8, 21, 9, 0, 0, TimeSpan.Zero);
        var rateGate = new VoiceTimerApprovalCoordinator(() => now);
        var presentationCalls = 0;
        for (var index = 0; index < VoiceTimerApprovalCoordinator.MaximumPromptsPerWindow; index++)
        {
            _ = await rateGate.RequestAsync(
                new VoiceTimerApprovalRequest($"Rejected {index}", 60),
                (_, _) =>
                {
                    presentationCalls++;
                    return Task.FromResult(false);
                },
                cancellationToken);
        }
        var rateLimited = false;
        try
        {
            _ = await rateGate.RequestAsync(
                new VoiceTimerApprovalRequest("Flood", 60),
                (_, _) =>
                {
                    presentationCalls++;
                    return Task.FromResult(false);
                },
                cancellationToken);
        }
        catch (CapabilityBrokerException exception) when (exception.Code == "CAPABILITY_RATE_LIMITED")
        {
            rateLimited = true;
        }
        if (!rateLimited || presentationCalls != VoiceTimerApprovalCoordinator.MaximumPromptsPerWindow)
        {
            _failures.Add("rejected Voice Timer prompts bypassed the pre-presentation rate limit");
        }
    }

    private async Task VerifyDynamicToolRoundTripAsync(CancellationToken cancellationToken)
    {
        var harness = new AppServerHarness();
        var runtime = new VoiceDynamicToolHarness();
        using var coordinator = new CodexVoiceCoordinator(
            featureEnabled: true,
            clientFactory: _ => Task.FromResult(harness.CreateClient()),
            compatibilityProbe: new FixedProbe(CodexVoiceGate.Ready),
            restartDelays: [],
            dynamicToolRuntime: runtime);

        await coordinator.InitializeAsync(cancellationToken);
        coordinator.SetUiAttached(true);
        coordinator.BeginMicrophonePermissionRequest();
        var started = await coordinator.StartRealtimeAsync(
            "v=0\r\no=hoverpocket 3 3 IN IP4 127.0.0.1\r\n",
            cancellationToken);
        harness.PushServerRequest(
            7001,
            "item/tool/call",
            new
            {
                threadId = started.ThreadId,
                turnId = "turn-roundtrip",
                callId = "call-roundtrip",
                @namespace = "hoverpocket",
                tool = "calendar_events_list",
                arguments = new { }
            });
        await WaitUntilAsync(
            () => harness.ServerResponses.Any(item => item.GetProperty("id").GetInt64() == 7001),
            cancellationToken);
        var response = harness.ServerResponses.Single(item => item.GetProperty("id").GetInt64() == 7001);
        if (runtime.CallCount != 1
            || response.GetProperty("result").GetProperty("success").ValueKind != JsonValueKind.True
            || harness.RequestParameters("thread/start") is not { } startParameters
            || !startParameters.TryGetProperty("dynamicTools", out var tools)
            || tools.ValueKind != JsonValueKind.Array
            || tools.GetArrayLength() != 1
            || !startParameters.TryGetProperty("dynamicToolsOnly", out var dynamicOnly)
            || dynamicOnly.ValueKind != JsonValueKind.True
            || !startParameters.TryGetProperty("environments", out var environments)
            || environments.ValueKind != JsonValueKind.Array
            || environments.GetArrayLength() != 0)
        {
            _failures.Add("app-server dynamic tool request/response did not stay on the active Voice root");
        }
        runtime.BlockNext = true;
        harness.PushServerRequest(
            7002,
            "item/tool/call",
            new
            {
                threadId = started.ThreadId,
                turnId = "turn-cancel",
                callId = "call-cancel",
                @namespace = "hoverpocket",
                tool = "timer_countdown_start",
                arguments = new { durationSeconds = 60 }
            });
        await runtime.BlockedCallStarted.WaitAsync(cancellationToken);
        await coordinator.StopRealtimeAsync(cancellationToken);
        await WaitUntilAsync(
            () => runtime.CancelledCallCount == 1,
            cancellationToken);
        await Task.Delay(25, cancellationToken);
        if (runtime.CancelledCallCount != 1
            || harness.ServerResponses.Any(item => item.GetProperty("id").GetInt64() == 7002))
        {
            _failures.Add("stopping Voice did not revoke the in-flight dynamic tool request before reply");
        }
    }

    private static JsonElement ToolCall(
        string threadId,
        string turnId,
        string callId,
        string tool,
        object arguments) => JsonSerializer.SerializeToElement(new
        {
            threadId,
            turnId,
            callId,
            @namespace = CodexVoiceCapabilityRuntime.Namespace,
            tool,
            arguments
        });

    private async Task VerifyRealtimeSdpFenceAsync(CancellationToken cancellationToken)
    {
        var harness = new AppServerHarness();
        using var coordinator = new CodexVoiceCoordinator(
            featureEnabled: true,
            clientFactory: _ => Task.FromResult(harness.CreateClient()),
            compatibilityProbe: new FixedProbe(CodexVoiceGate.Ready),
            restartDelays: []);
        var deliveredSignals = 0;
        coordinator.TransportSignal += (_, _) => Interlocked.Increment(ref deliveredSignals);

        await coordinator.InitializeAsync(cancellationToken);
        coordinator.SetUiAttached(true);
        coordinator.BeginMicrophonePermissionRequest();
        var started = await coordinator.StartRealtimeAsync(
            "v=0\r\no=hoverpocket 2 2 IN IP4 127.0.0.1\r\n",
            cancellationToken);
        harness.PushNotification(
            "thread/realtime/sdp",
            new { threadId = "foreign-root", sdp = "v=0\r\n" });
        await Task.Delay(10, cancellationToken);
        harness.PushNotification(
            "thread/realtime/sdp",
            new { threadId = started.ThreadId, sdp = "v=0" + new string('a', 262_145) });
        await WaitUntilAsync(
            () => coordinator.Snapshot.LastErrorCode == "invalid_remote_sdp",
            cancellationToken);
        await WaitUntilAsync(
            () => harness.RequestedMethods.Contains("thread/realtime/stop"),
            cancellationToken);
        if (Volatile.Read(ref deliveredSignals) != 0
            || coordinator.Snapshot.RealtimeAttached
            || !coordinator.Snapshot.Muted
            || !harness.RequestedMethods.Contains("thread/realtime/stop"))
        {
            _failures.Add("foreign or oversized Realtime SDP crossed the generation/thread fence");
        }
    }

    private void VerifyMicrophonePermissionBoundary()
    {
        var exactAllowed = PanelWindow.IsVoiceMicrophonePermissionAllowedForVerify(
            "https://app.hoverpocket.local/index.html",
            CoreWebView2PermissionKind.Microphone,
            featureEnabled: true,
            panelVisible: true,
            recentExplicitGesture: true,
            browserUserInitiated: true);
        var rejectsWrongOrigin = !PanelWindow.IsVoiceMicrophonePermissionAllowedForVerify(
            "https://example.invalid/index.html",
            CoreWebView2PermissionKind.Microphone,
            featureEnabled: true,
            panelVisible: true,
            recentExplicitGesture: true,
            browserUserInitiated: true);
        var rejectsNoGesture = !PanelWindow.IsVoiceMicrophonePermissionAllowedForVerify(
            "https://app.hoverpocket.local/index.html",
            CoreWebView2PermissionKind.Microphone,
            featureEnabled: true,
            panelVisible: true,
            recentExplicitGesture: false,
            browserUserInitiated: true);
        var rejectsScriptOnlyRequest = !PanelWindow.IsVoiceMicrophonePermissionAllowedForVerify(
            "https://app.hoverpocket.local/index.html",
            CoreWebView2PermissionKind.Microphone,
            featureEnabled: true,
            panelVisible: true,
            recentExplicitGesture: true,
            browserUserInitiated: false);
        var rejectsWrongPermission = !PanelWindow.IsVoiceMicrophonePermissionAllowedForVerify(
            "https://app.hoverpocket.local/index.html",
            CoreWebView2PermissionKind.Camera,
            featureEnabled: true,
            panelVisible: true,
            recentExplicitGesture: true,
            browserUserInitiated: true);
        var rejectsDisabledOrHidden = !PanelWindow.IsVoiceMicrophonePermissionAllowedForVerify(
            "https://app.hoverpocket.local/index.html",
            CoreWebView2PermissionKind.Microphone,
            featureEnabled: false,
            panelVisible: false,
            recentExplicitGesture: true,
            browserUserInitiated: true);
        if (!exactAllowed
            || !rejectsWrongOrigin
            || !rejectsNoGesture
            || !rejectsScriptOnlyRequest
            || !rejectsWrongPermission
            || !rejectsDisabledOrHidden)
        {
            _failures.Add("microphone permission was not restricted to an exact visible Panel gesture");
        }
    }

    private async Task VerifyRestartIsBoundedAsync(CancellationToken cancellationToken)
    {
        var factoryCalls = 0;
        using var coordinator = new CodexVoiceCoordinator(
            featureEnabled: true,
            clientFactory: _ =>
            {
                factoryCalls++;
                throw new CodexAppServerProtocolException("synthetic_transport_failure");
            },
            compatibilityProbe: new FixedProbe(CodexVoiceGate.Ready),
            restartDelays:
            [
                TimeSpan.Zero,
                TimeSpan.FromMilliseconds(5)
            ]);

        await coordinator.InitializeAsync(cancellationToken);
        await WaitUntilAsync(
            () => coordinator.Snapshot.LastErrorCode == "voice_restart_exhausted",
            cancellationToken);

        if (factoryCalls != 3
            || coordinator.Snapshot.SessionStatus != CodexVoiceSessionStatus.BlockedFailure)
        {
            _failures.Add("restart/backoff was not bounded to the configured attempts");
        }
    }

    private async Task VerifyInitializeRequestCannotBePromotedAsync(CancellationToken cancellationToken)
    {
        var disposeCount = 0;
        var harness = new AppServerHarness(
            () => Interlocked.Increment(ref disposeCount),
            requestDuringInitialize: true);
        using var coordinator = new CodexVoiceCoordinator(
            featureEnabled: true,
            clientFactory: _ => Task.FromResult(harness.CreateClient()),
            compatibilityProbe: new FixedProbe(CodexVoiceGate.Ready),
            restartDelays: []);

        await coordinator.InitializeAsync(cancellationToken);
        await WaitUntilAsync(() => Volatile.Read(ref disposeCount) == 1, cancellationToken);
        if (coordinator.Snapshot.Availability != CodexVoiceAvailability.CapabilityBlocked
            || coordinator.Snapshot.SessionStatus != CodexVoiceSessionStatus.BlockedFailure
            || coordinator.Snapshot.TransportAttached)
        {
            _failures.Add("initialization-time server request was promoted to a ready transport");
        }
    }

    private async Task VerifyRequestBeforeReaderStartFailsClosedAsync(CancellationToken cancellationToken)
    {
        var disposeCount = 0;
        var harness = new AppServerHarness(
            () => Interlocked.Increment(ref disposeCount));
        harness.PushServerRequest(42, "item/tool/call");
        using var coordinator = new CodexVoiceCoordinator(
            featureEnabled: true,
            clientFactory: _ => Task.FromResult(harness.CreateClient()),
            compatibilityProbe: new FixedProbe(CodexVoiceGate.Ready),
            restartDelays: []);

        await coordinator.InitializeAsync(cancellationToken);
        await WaitUntilAsync(() => Volatile.Read(ref disposeCount) == 1, cancellationToken);
        if (coordinator.Snapshot.Availability != CodexVoiceAvailability.CapabilityBlocked
            || coordinator.Snapshot.SessionStatus != CodexVoiceSessionStatus.BlockedFailure
            || coordinator.Snapshot.TransportAttached
            || coordinator.Snapshot.LastErrorCode != "unexpected_server_request")
        {
            _failures.Add("server request queued before handler attachment was promoted to ready");
        }
    }

    private async Task VerifyFailedInitializeDisposesCandidateAsync(CancellationToken cancellationToken)
    {
        var disposeCount = 0;
        var reader = new ChannelLineReader();
        using var coordinator = new CodexVoiceCoordinator(
            featureEnabled: true,
            clientFactory: _ => Task.FromResult(CodexAppServerClient.AttachForTesting(
                reader,
                TextWriter.Null,
                TimeSpan.FromMilliseconds(20),
                () =>
                {
                    Interlocked.Increment(ref disposeCount);
                    reader.Dispose();
                    return ValueTask.CompletedTask;
                })),
            compatibilityProbe: new FixedProbe(CodexVoiceGate.Ready),
            restartDelays: []);

        await coordinator.InitializeAsync(cancellationToken);
        await WaitUntilAsync(() => Volatile.Read(ref disposeCount) == 1, cancellationToken);
        if (coordinator.Snapshot.TransportAttached
            || coordinator.Snapshot.SessionStatus != CodexVoiceSessionStatus.BlockedFailure)
        {
            _failures.Add("failed initialize retained a candidate app-server client");
        }
    }

    private async Task VerifyDisableDisposesInFlightCandidateAsync(CancellationToken cancellationToken)
    {
        var disposeCount = 0;
        var harness = new DeferredInitializeHarness(
            () => Interlocked.Increment(ref disposeCount));
        using var coordinator = new CodexVoiceCoordinator(
            featureEnabled: true,
            clientFactory: _ => Task.FromResult(harness.CreateClient()),
            compatibilityProbe: new FixedProbe(CodexVoiceGate.Ready),
            restartDelays: []);

        var startup = coordinator.InitializeAsync(cancellationToken);
        await harness.InitializationRequested.WaitAsync(cancellationToken);
        await coordinator.SetFeatureEnabledAsync(false, cancellationToken);
        await startup;

        if (Volatile.Read(ref disposeCount) != 1
            || coordinator.Snapshot != CodexVoiceSnapshot.Disabled)
        {
            _failures.Add("disabling Voice retained an in-flight startup candidate");
        }
    }

    private async Task VerifyDisableDisposesInFlightRetryCandidateAsync(CancellationToken cancellationToken)
    {
        var factoryCalls = 0;
        var retryDisposeCount = 0;
        var initialHarness = new AppServerHarness();
        var retryHarness = new DeferredInitializeHarness(
            () => Interlocked.Increment(ref retryDisposeCount));
        using var coordinator = new CodexVoiceCoordinator(
            featureEnabled: true,
            clientFactory: _ => Task.FromResult(
                Interlocked.Increment(ref factoryCalls) == 1
                    ? initialHarness.CreateClient()
                    : retryHarness.CreateClient()),
            compatibilityProbe: new FixedProbe(CodexVoiceGate.Ready),
            restartDelays: [TimeSpan.Zero]);

        await coordinator.InitializeAsync(cancellationToken);
        initialHarness.Close();
        await retryHarness.InitializationRequested.WaitAsync(cancellationToken);
        await coordinator.SetFeatureEnabledAsync(false, cancellationToken);

        if (Volatile.Read(ref retryDisposeCount) != 1
            || coordinator.Snapshot != CodexVoiceSnapshot.Disabled)
        {
            _failures.Add("disabling Voice retained an in-flight retry candidate");
        }
    }

    private async Task VerifyFeatureTransitionsAreSerializedAsync(CancellationToken cancellationToken)
    {
        var firstHarness = new GatedDisposeHarness();
        var replacementHarness = new AppServerHarness();
        var factoryCalls = 0;
        using var coordinator = new CodexVoiceCoordinator(
            featureEnabled: true,
            clientFactory: _ => Task.FromResult(
                Interlocked.Increment(ref factoryCalls) == 1
                    ? firstHarness.CreateClient()
                    : replacementHarness.CreateClient()),
            compatibilityProbe: new FixedProbe(CodexVoiceGate.Ready),
            restartDelays: []);

        await coordinator.InitializeAsync(cancellationToken);
        var disable = coordinator.SetFeatureEnabledAsync(false, cancellationToken);
        await firstHarness.DisposeStarted.WaitAsync(cancellationToken);
        var stopping = coordinator.Snapshot;
        if (stopping.Availability == CodexVoiceAvailability.Disabled
            || stopping.SessionStatus != CodexVoiceSessionStatus.Stopping
            || !stopping.Muted)
        {
            _failures.Add("Voice teardown hid the active runtime before client disposal completed");
        }
        var enable = coordinator.SetFeatureEnabledAsync(true, cancellationToken);
        await Task.Yield();
        if (Volatile.Read(ref factoryCalls) != 1 || enable.IsCompleted)
        {
            _failures.Add("Voice re-enabled before the disable transition released its client");
        }

        firstHarness.ReleaseDispose();
        await disable;
        await enable;
        if (coordinator.Snapshot.Availability != CodexVoiceAvailability.Ready
            || !coordinator.Snapshot.TransportAttached
            || Volatile.Read(ref factoryCalls) != 2)
        {
            _failures.Add("serialized Voice re-enable did not create one ready replacement");
        }
    }

    private async Task VerifyDisposeDrainsActiveTransitionAsync(CancellationToken cancellationToken)
    {
        var harness = new GatedDisposeHarness();
        var coordinator = new CodexVoiceCoordinator(
            featureEnabled: true,
            clientFactory: _ => Task.FromResult(harness.CreateClient()),
            compatibilityProbe: new FixedProbe(CodexVoiceGate.Ready),
            restartDelays: []);

        await coordinator.InitializeAsync(cancellationToken);
        var disable = coordinator.SetFeatureEnabledAsync(false, cancellationToken);
        await harness.DisposeStarted.WaitAsync(cancellationToken);

        var disposeStarted = new TaskCompletionSource<bool>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var dispose = Task.Factory.StartNew(
            () =>
            {
                disposeStarted.TrySetResult(true);
                coordinator.Dispose();
            },
            CancellationToken.None,
            TaskCreationOptions.LongRunning,
            TaskScheduler.Default);
        await disposeStarted.Task.WaitAsync(cancellationToken);
        await Task.Delay(50, cancellationToken);
        if (dispose.IsCompleted)
        {
            _failures.Add("coordinator disposal completed before an active Voice transition drained");
        }

        harness.ReleaseDispose();
        await disable;
        await dispose.WaitAsync(cancellationToken);
        if (coordinator.Snapshot != CodexVoiceSnapshot.Disabled)
        {
            _failures.Add("coordinator disposal did not publish disabled after draining its transition");
        }
    }

    private async Task VerifyDisconnectBeforePromotionAsync(CancellationToken cancellationToken)
    {
        var disposeCount = 0;
        var harness = new AppServerHarness(
            () => Interlocked.Increment(ref disposeCount),
            disconnectAfterInitialize: true);
        using var coordinator = new CodexVoiceCoordinator(
            featureEnabled: true,
            clientFactory: _ => Task.FromResult(harness.CreateClient()),
            compatibilityProbe: new FixedProbe(CodexVoiceGate.Ready),
            restartDelays: []);

        await coordinator.InitializeAsync(cancellationToken);
        await WaitUntilAsync(
            () => Volatile.Read(ref disposeCount) == 1
                && coordinator.Snapshot.SessionStatus == CodexVoiceSessionStatus.BlockedFailure,
            cancellationToken);
        if (coordinator.Snapshot.Availability == CodexVoiceAvailability.Ready
            || coordinator.Snapshot.TransportAttached
            || coordinator.Snapshot.AppServerProcessId is not null)
        {
            _failures.Add("a disconnected startup candidate was promoted to ready");
        }
    }

    private async Task VerifyDisconnectDuringPromotionAsync(CancellationToken cancellationToken)
    {
        var previousHarness = new GatedDisposeHarness();
        var replacementHarness = new AppServerHarness();
        var factoryCalls = 0;
        using var coordinator = new CodexVoiceCoordinator(
            featureEnabled: true,
            clientFactory: _ => Task.FromResult(
                Interlocked.Increment(ref factoryCalls) == 1
                    ? previousHarness.CreateClient()
                    : replacementHarness.CreateClient()),
            compatibilityProbe: new FixedProbe(CodexVoiceGate.Ready),
            restartDelays: []);

        await coordinator.InitializeAsync(cancellationToken);
        var replacementStart = coordinator.InitializeAsync(cancellationToken);
        await previousHarness.DisposeStarted.WaitAsync(cancellationToken);
        replacementHarness.Close();
        await WaitUntilAsync(
            () => coordinator.Snapshot.SessionStatus == CodexVoiceSessionStatus.BlockedFailure,
            cancellationToken);
        previousHarness.ReleaseDispose();
        await replacementStart;

        if (coordinator.Snapshot.Availability == CodexVoiceAvailability.Ready
            || coordinator.Snapshot.TransportAttached
            || coordinator.Snapshot.AppServerProcessId is not null)
        {
            _failures.Add("a disconnected promoted candidate overwrote the failed state with ready");
        }
    }

    private async Task VerifyStaleDisconnectTeardownBlocksReenableAsync(
        CancellationToken cancellationToken)
    {
        var staleHarness = new DeferredInitializeGatedDisposeHarness();
        var replacementHarness = new AppServerHarness();
        var factoryCalls = 0;
        using var coordinator = new CodexVoiceCoordinator(
            featureEnabled: true,
            clientFactory: _ => Task.FromResult(
                Interlocked.Increment(ref factoryCalls) == 1
                    ? staleHarness.CreateClient()
                    : replacementHarness.CreateClient()),
            compatibilityProbe: new FixedProbe(CodexVoiceGate.Ready),
            restartDelays: []);

        var startup = coordinator.InitializeAsync(cancellationToken);
        await staleHarness.InitializationRequested.WaitAsync(cancellationToken);
        coordinator.SnapshotChanged += (_, snapshot) =>
        {
            if (snapshot.SessionStatus != CodexVoiceSessionStatus.Stopping)
            {
                return;
            }
            staleHarness.Close();
            staleHarness.DisposeStarted.GetAwaiter().GetResult();
        };

        var disable = coordinator.SetFeatureEnabledAsync(false, cancellationToken);
        await staleHarness.DisposeStarted.WaitAsync(cancellationToken);
        var enable = coordinator.SetFeatureEnabledAsync(true, cancellationToken);
        await Task.Yield();
        if (disable.IsCompleted || enable.IsCompleted || Volatile.Read(ref factoryCalls) != 1)
        {
            _failures.Add("stale startup disconnect released Voice before owner teardown completed");
        }

        staleHarness.ReleaseDispose();
        await startup;
        await disable;
        await enable;
        if (coordinator.Snapshot.Availability != CodexVoiceAvailability.Ready
            || !coordinator.Snapshot.TransportAttached
            || Volatile.Read(ref factoryCalls) != 2)
        {
            _failures.Add("stale startup disconnect did not allow one ready replacement after teardown");
        }
    }

    private async Task VerifyTransportCrashDisposesCandidateAsync(CancellationToken cancellationToken)
    {
        var factoryCalls = 0;
        var crashedHarness = new GatedDisposeHarness();
        var replacementHarness = new AppServerHarness();
        using var coordinator = new CodexVoiceCoordinator(
            featureEnabled: true,
            clientFactory: _ => Task.FromResult(
                Interlocked.Increment(ref factoryCalls) == 1
                    ? crashedHarness.CreateClient()
                    : replacementHarness.CreateClient()),
            compatibilityProbe: new FixedProbe(CodexVoiceGate.Ready),
            restartDelays: [TimeSpan.Zero]);

        await coordinator.InitializeAsync(cancellationToken);
        crashedHarness.Close();
        await crashedHarness.DisposeStarted.WaitAsync(cancellationToken);
        await WaitUntilAsync(() => coordinator.Snapshot.RestartAttempt == 1, cancellationToken);
        await Task.Yield();
        if (Volatile.Read(ref factoryCalls) != 1
            || coordinator.Snapshot.TransportAttached
            || coordinator.Snapshot.SessionStatus != CodexVoiceSessionStatus.RecoverableFailure)
        {
            _failures.Add("transport crash restarted before the detached client finished disposal");
        }

        crashedHarness.ReleaseDispose();
        await WaitUntilAsync(
            () => Volatile.Read(ref factoryCalls) == 2
                && coordinator.Snapshot.Availability == CodexVoiceAvailability.Ready,
            cancellationToken);
        if (!coordinator.Snapshot.TransportAttached)
        {
            _failures.Add("transport crash did not restart after detached client disposal completed");
        }
    }

    private async Task VerifySystemTransitionDisposesCandidateAsync(CancellationToken cancellationToken)
    {
        var disposeCount = 0;
        var harness = new AppServerHarness(() => Interlocked.Increment(ref disposeCount));
        using var coordinator = new CodexVoiceCoordinator(
            featureEnabled: true,
            clientFactory: _ => Task.FromResult(harness.CreateClient()),
            compatibilityProbe: new FixedProbe(CodexVoiceGate.Ready),
            restartDelays: []);

        await coordinator.InitializeAsync(cancellationToken);
        await coordinator.NotifySystemTransitionAsync();
        await WaitUntilAsync(() => Volatile.Read(ref disposeCount) == 1, cancellationToken);
        if (coordinator.Snapshot.TransportAttached
            || coordinator.Snapshot.AppServerProcessId is not null)
        {
            _failures.Add("system transition retained the previous app-server client");
        }
    }

    private async Task VerifySystemTransitionDisposesInFlightCandidateAsync(CancellationToken cancellationToken)
    {
        var factoryCalls = 0;
        var staleDisposeCount = 0;
        var staleHarness = new DeferredInitializeHarness(
            () => Interlocked.Increment(ref staleDisposeCount));
        var healthyHarness = new AppServerHarness();
        using var coordinator = new CodexVoiceCoordinator(
            featureEnabled: true,
            clientFactory: _ => Task.FromResult(
                Interlocked.Increment(ref factoryCalls) == 1
                    ? staleHarness.CreateClient()
                    : healthyHarness.CreateClient()),
            compatibilityProbe: new FixedProbe(CodexVoiceGate.Ready),
            restartDelays: [TimeSpan.Zero]);

        var startup = coordinator.InitializeAsync(cancellationToken);
        await staleHarness.InitializationRequested.WaitAsync(cancellationToken);
        await coordinator.NotifySystemTransitionAsync();
        await startup;
        await WaitUntilAsync(
            () => coordinator.Snapshot.Availability == CodexVoiceAvailability.Ready,
            cancellationToken);

        if (Volatile.Read(ref staleDisposeCount) != 1
            || factoryCalls != 2
            || !coordinator.Snapshot.TransportAttached)
        {
            _failures.Add("system transition overlapped an in-flight startup with its replacement");
        }
    }

    private async Task VerifyProcessLaunchFailureIsBoundedAsync(CancellationToken cancellationToken)
    {
        var factoryCalls = 0;
        using var coordinator = new CodexVoiceCoordinator(
            featureEnabled: true,
            clientFactory: _ =>
            {
                factoryCalls += 1;
                throw new System.ComponentModel.Win32Exception("synthetic_process_launch_failure");
            },
            compatibilityProbe: new FixedProbe(CodexVoiceGate.Ready),
            restartDelays: []);

        await coordinator.InitializeAsync(cancellationToken);
        if (factoryCalls != 1
            || coordinator.Snapshot.SessionStatus != CodexVoiceSessionStatus.BlockedFailure
            || coordinator.Snapshot.LastErrorCode != "voice_restart_exhausted")
        {
            _failures.Add("process launch failure escaped bounded startup recovery");
        }
    }

    private async Task VerifyCancelledSystemTransitionCannotRestartAsync(CancellationToken cancellationToken)
    {
        var factoryCalls = 0;
        var staleHarness = new GatedDisposeHarness();
        var healthyHarness = new AppServerHarness();
        using var coordinator = new CodexVoiceCoordinator(
            featureEnabled: true,
            clientFactory: _ => Task.FromResult(
                Interlocked.Increment(ref factoryCalls) == 1
                    ? staleHarness.CreateClient()
                    : healthyHarness.CreateClient()),
            compatibilityProbe: new FixedProbe(CodexVoiceGate.Ready),
            restartDelays: [TimeSpan.Zero]);

        await coordinator.InitializeAsync(cancellationToken);
        using var staleTransitionCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        var staleTransition = coordinator.NotifySystemTransitionAsync(staleTransitionCancellation.Token);
        await staleHarness.DisposeStarted.WaitAsync(cancellationToken);
        staleTransitionCancellation.Cancel();

        var replacementTransition = coordinator.NotifySystemTransitionAsync(cancellationToken);
        await Task.Yield();
        if (replacementTransition.IsCompleted || Volatile.Read(ref factoryCalls) != 1)
        {
            _failures.Add("replacement system transition bypassed serialized teardown");
        }

        staleHarness.ReleaseDispose();
        try
        {
            await staleTransition;
            _failures.Add("cancelled system transition completed without observing cancellation");
        }
        catch (OperationCanceledException) when (staleTransitionCancellation.IsCancellationRequested)
        {
        }

        await replacementTransition;
        await WaitUntilAsync(
            () => coordinator.Snapshot.Availability == CodexVoiceAvailability.Ready,
            cancellationToken);
        await Task.Yield();
        if (Volatile.Read(ref factoryCalls) != 2
            || !coordinator.Snapshot.TransportAttached)
        {
            _failures.Add("cancelled system transition scheduled a stale replacement");
        }
    }

    private async Task VerifyStaleStartFailureDoesNotReplaceReadyClientAsync(CancellationToken cancellationToken)
    {
        var factoryCalls = 0;
        var firstStarted = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var healthyHarness = new AppServerHarness();
        using var coordinator = new CodexVoiceCoordinator(
            featureEnabled: true,
            clientFactory: async token =>
            {
                if (Interlocked.Increment(ref factoryCalls) == 1)
                {
                    firstStarted.TrySetResult(true);
                    await Task.Delay(Timeout.InfiniteTimeSpan, token);
                    throw new InvalidOperationException("unreachable stale start");
                }
                return healthyHarness.CreateClient();
            },
            compatibilityProbe: new FixedProbe(CodexVoiceGate.Ready),
            restartDelays: []);

        var staleStart = coordinator.InitializeAsync(cancellationToken);
        await firstStarted.Task.WaitAsync(cancellationToken);
        await coordinator.SetFeatureEnabledAsync(false, cancellationToken);
        await coordinator.SetFeatureEnabledAsync(true, cancellationToken);
        await staleStart;
        if (coordinator.Snapshot.Availability != CodexVoiceAvailability.Ready
            || !coordinator.Snapshot.TransportAttached
            || coordinator.Snapshot.LastErrorCode is not null)
        {
            _failures.Add("stale start failure replaced a ready app-server client");
        }
    }

    private async Task VerifyStaleRequestDoesNotBlockReadyClientAsync(CancellationToken cancellationToken)
    {
        var factoryCalls = 0;
        var staleDisposeCount = 0;
        var staleHarness = new DeferredInitializeHarness(
            () => Interlocked.Increment(ref staleDisposeCount));
        var healthyHarness = new AppServerHarness();
        using var coordinator = new CodexVoiceCoordinator(
            featureEnabled: true,
            clientFactory: _ => Task.FromResult(
                Interlocked.Increment(ref factoryCalls) == 1
                    ? staleHarness.CreateClient()
                    : healthyHarness.CreateClient()),
            compatibilityProbe: new FixedProbe(CodexVoiceGate.Ready),
            restartDelays: []);

        var staleStart = coordinator.InitializeAsync(cancellationToken);
        await staleHarness.InitializationRequested.WaitAsync(cancellationToken);
        await coordinator.SetFeatureEnabledAsync(false, cancellationToken);
        await coordinator.SetFeatureEnabledAsync(true, cancellationToken);
        if (coordinator.Snapshot.Availability != CodexVoiceAvailability.Ready)
        {
            _failures.Add("replacement app-server did not become ready");
            return;
        }

        staleHarness.PushServerRequest(9003, "approval/request");
        await WaitUntilAsync(
            () => Volatile.Read(ref staleDisposeCount) == 1,
            cancellationToken);
        await staleStart;
        if (coordinator.Snapshot.Availability != CodexVoiceAvailability.Ready
            || !coordinator.Snapshot.TransportAttached
            || coordinator.Snapshot.LastErrorCode is not null)
        {
            _failures.Add("stale app-server request blocked the ready replacement");
        }
    }

    private async Task VerifyUnavailableTransitionPreservesBlockedStateAsync()
    {
        using var coordinator = new CodexVoiceCoordinator(featureEnabled: true);
        coordinator.SetMuted(false);
        await coordinator.NotifySystemTransitionAsync();
        if (coordinator.Snapshot.Availability != CodexVoiceAvailability.Unavailable
            || coordinator.Snapshot.SessionStatus != CodexVoiceSessionStatus.BlockedFailure
            || coordinator.Snapshot.Activity != VoiceActivity.Failed
            || !coordinator.Snapshot.Muted
            || coordinator.Snapshot.LastErrorCode != "production_voice_transport_unconfigured")
        {
            _failures.Add("unconfigured transport entered permanent recovery after a system transition");
        }
    }

    private async Task VerifyOversizedResponseFailsClosedAsync(CancellationToken cancellationToken)
    {
        var reader = new GatedTextReader(
            new string('x', CodexAppServerClient.MaxLineCharacters + 1) + "\n");
        await using var client = CodexAppServerClient.AttachForTesting(reader, TextWriter.Null);
        var disconnected = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        client.Disconnected += (_, _) => disconnected.TrySetResult(true);
        client.StartReading();
        reader.Release();
        await disconnected.Task.WaitAsync(cancellationToken);
    }

    private async Task VerifyMultibyteResponseFailsClosedAsync(CancellationToken cancellationToken)
    {
        var reader = new GatedTextReader(
            new string('あ', (CodexAppServerClient.MaxLineBytes / 3) + 1) + "\n");
        await using var client = CodexAppServerClient.AttachForTesting(reader, TextWriter.Null);
        var disconnected = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        client.Disconnected += (_, _) => disconnected.TrySetResult(true);
        client.StartReading();
        reader.Release();
        await disconnected.Task.WaitAsync(cancellationToken);
    }

    private void VerifyTranscriptAndRootScope()
    {
        using var coordinator = new CodexVoiceCoordinator(featureEnabled: true);
        if (VoiceTextSafety.SanitizeIdentifier("root/a") != string.Empty
            || VoiceTextSafety.SanitizeIdentifier("roota") != "roota"
            || VoiceTextSafety.SanitizeIdentifier(new string('a', 161)) != string.Empty)
        {
            _failures.Add("invalid or oversized Voice identifier was normalized instead of rejected");
        }
        coordinator.SetRootSessionId("roota");
        coordinator.UpsertSession(new AgentSessionSummary(
            "foreign/child", "root/a", null, "Foreign", AgentSessionStatus.Running, null, null, DateTimeOffset.UnixEpoch));
        coordinator.UpsertSession(new AgentSessionSummary(
            "local-child", "roota", null, "Local", AgentSessionStatus.Running, null, null, DateTimeOffset.UnixEpoch));
        if (coordinator.Snapshot.Sessions.Count != 1
            || coordinator.Snapshot.Sessions[0].SessionId != "local-child")
        {
            _failures.Add("lossy Voice identifier collision crossed the root session boundary");
        }

        coordinator.SetRootSessionId("root-a");
        var now = DateTimeOffset.UnixEpoch;

        for (var index = 0; index < 90; index++)
        {
            coordinator.AppendTranscript(new VoiceTranscriptEvent(
                $"event-{index}",
                "root-a",
                "user",
                index == 89 ? @"C:\Users\test\private.txt" : new string('あ', 160),
                true,
                now.AddSeconds(index)));
        }

        var validTranscriptCount = coordinator.Snapshot.Transcript.Count;
        coordinator.AppendTranscript(new VoiceTranscriptEvent(
            "invalid/event",
            "root-a",
            "user",
            "must not render with a colliding identity",
            true,
            now.AddSeconds(99)));
        coordinator.AppendTranscript(new VoiceTranscriptEvent(
            "untrusted-role",
            "root-a",
            "tool",
            "must not render as system",
            true,
            now.AddSeconds(100)));
        coordinator.AppendTranscript(new VoiceTranscriptEvent(
            "untrusted-system-role",
            "root-a",
            "system",
            "must not impersonate the Host",
            true,
            now.AddSeconds(101)));
        if (coordinator.Snapshot.Transcript.Count != validTranscriptCount)
        {
            _failures.Add("invalid transcript identity or role was published");
        }

        coordinator.UpsertSession(new AgentSessionSummary(
            "root-a", "root-a", null, "Root", AgentSessionStatus.Running, "safe", null, now));
        coordinator.UpsertSession(new AgentSessionSummary(
            "child-a", "root-a", "root-a", "Child", AgentSessionStatus.Running, "safe", null, now.AddSeconds(1)));
        coordinator.UpsertSession(new AgentSessionSummary(
            "grandchild-a", "root-a", "child-a", "Descendant", AgentSessionStatus.Running, "safe", null, now.AddSeconds(2)));
        coordinator.UpsertSession(new AgentSessionSummary(
            "root-b", "root-b", null, "Other root", AgentSessionStatus.Running, "safe", null, now.AddSeconds(3)));

        var snapshot = coordinator.Snapshot;
        if (snapshot.Transcript.Count > 64
            || snapshot.Transcript.Sum(item => item.Text.EnumerateRunes().Count()) > 8192
            || snapshot.Transcript.Any(item => item.Text.Contains(@"\Users\", StringComparison.Ordinal))
            || snapshot.Sessions.Count != 3
            || snapshot.Sessions.Any(session => session.RootSessionId != "root-a"))
        {
            _failures.Add("transcript bounds/redaction or root-scoped filtering regressed");
        }

        for (var index = 0; index < 90; index++)
        {
            coordinator.UpsertSession(new AgentSessionSummary(
                $"child-{index}",
                "root-a",
                "root-a",
                $"Child {index}",
                AgentSessionStatus.Running,
                "safe",
                null,
                now.AddSeconds(index + 4)));
        }
        if (coordinator.Snapshot.Sessions.Count > CodexVoiceCoordinator.MaxRetainedSessions)
        {
            _failures.Add("retained session summaries exceeded the bounded limit");
        }

        coordinator.SetRootSessionId("root-b");
        if (coordinator.Snapshot.Transcript.Count != 0
            || coordinator.Snapshot.Sessions.Count != 0
            || coordinator.Snapshot.RootSessionId != "root-b")
        {
            _failures.Add("root transition retained transcript or session data from the previous conversation");
        }
        coordinator.AppendTranscript(new VoiceTranscriptEvent(
            "delayed-root-a", "root-a", "assistant", "must not cross roots", true, now.AddSeconds(200)));
        coordinator.AppendTranscript(new VoiceTranscriptEvent(
            "current-root-b", "root-b", "assistant", "current root", true, now.AddSeconds(201)));
        coordinator.AppendTranscript(new VoiceTranscriptEvent(
            "current-root-b", "root-b", "assistant", "final revision", true, now.AddSeconds(202)));
        coordinator.AppendTranscript(new VoiceTranscriptEvent(
            "current-root-b", "root-b", "assistant", "late interim", false, now.AddSeconds(203)));
        if (coordinator.Snapshot.Transcript.Count != 1
            || coordinator.Snapshot.Transcript[0].Id != "current-root-b"
            || coordinator.Snapshot.Transcript[0].Text != "final revision")
        {
            _failures.Add("delayed transcript crossed roots or a transcript revision duplicated its event ID");
        }

        var redactionSamples = new[]
        {
            "/tmp/private.txt",
            "/Volumes/work/secret.mov",
            @"C:\work\secret.txt",
            "[/Users/alice/private]",
            @"[C:\Users\alice\private]",
            "Sources/HoverPocket/App.swift",
            @"Sources\HoverPocket\App.swift",
            "Bearer sk-proj-secret",
            "sk-proj-abcdefghijklmnopqrstuvwxyz",
            """{"access_token":"abcdefghijklmnopqrstuvwxyz"}""",
            """{"client_secret" : "abcdefghijklmnopqrstuvwxyz"}"""
        };
        if (redactionSamples.Any(value => VoiceTextSafety.SanitizeVisibleText(value, 200) != "[redacted]"))
        {
            _failures.Add("visible Voice text redaction was incomplete");
        }
        var nonPathText = new[]
        {
            "https://example.com/Sources/HoverPocket/App.swift",
            "and/or",
            "input/output",
            @"input\output"
        };
        if (nonPathText.Any(value => VoiceTextSafety.SanitizeVisibleText(value, 200) != value))
        {
            _failures.Add("filesystem path redaction treated ordinary text or a URL as a path");
        }
        var bidiSamples = new[]
        {
            "trusted\u202Edetadpu",
            "trusted\u2066spoof\u2069"
        };
        if (bidiSamples.Any(sample => VoiceTextSafety.SanitizeVisibleText(sample, 200)
            .EnumerateRunes()
            .Any(rune => Rune.GetUnicodeCategory(rune) == System.Globalization.UnicodeCategory.Format)))
        {
            _failures.Add("Unicode format controls survived visible Voice text sanitization");
        }
        if (VoiceTextSafety.SanitizeErrorCode("token=secret /tmp/private.txt") != "_redacted_")
        {
            _failures.Add("sensitive error code was normalized before redaction");
        }
    }

    private void VerifyUiDetachPreservesSession()
    {
        using var coordinator = new CodexVoiceCoordinator(featureEnabled: true);
        coordinator.SetRootSessionId("root-a");
        coordinator.SetUiAttached(true);
        coordinator.AppendTranscript(new VoiceTranscriptEvent(
            "event", "root-a", "assistant", "memory-only", true, DateTimeOffset.UnixEpoch));
        coordinator.UpsertSession(new AgentSessionSummary(
            "root-a", "root-a", null, "Root", AgentSessionStatus.Running, null, null, DateTimeOffset.UnixEpoch));

        coordinator.SetUiAttached(false);
        var detached = coordinator.Snapshot;
        coordinator.SetUiAttached(true);
        var reattached = coordinator.Snapshot;
        if (!detached.Muted
            || detached.RootSessionId != "root-a"
            || detached.Transcript.Count != 1
            || detached.Sessions.Count != 1
            || reattached.RootSessionId != "root-a"
            || reattached.Transcript.Count != 1)
        {
            _failures.Add("panel detach/recreate semantics discarded app-lifetime session state");
        }
    }

    private void VerifyGeometry()
    {
        foreach (var size in Enum.GetValues<PanelSize>())
        {
            var baseline = PanelSizeCatalog.Get(size).TotalHeight;
            var disabled = VoicePanelGeometry.TotalHeight(baseline, size, VoiceLaneMode.Disabled);
            var compact = VoicePanelGeometry.TotalHeight(baseline, size, VoiceLaneMode.Compact);
            var expanded = VoicePanelGeometry.TotalHeight(baseline, size, VoiceLaneMode.Expanded);
            if (disabled != baseline
                || compact != baseline + VoicePanelGeometry.CompactHeight
                || expanded != baseline + VoicePanelGeometry.ExpandedHeight(size))
            {
                _failures.Add($"voice geometry mismatch for {size}");
            }
        }

        var largeExpanded = new UserSettings
        {
            VoiceEnabled = true,
            VoiceLaneLayout = VoiceLaneLayoutPreference.Expanded,
            PanelSize = PanelSize.Large
        };
        var taskbarMonitor = new DisplayMonitor(
            "monitor",
            "Monitor",
            IntPtr.Zero,
            new PhysicalRect(0, 0, 1366, 768),
            new PhysicalRect(0, 0, 1366, 720),
            true,
            96,
            96);
        var baselinePlacement = new WindowPlacement(
            new Rect(100, 100, 900, 488),
            new PhysicalRect(100, 100, 900, 488));
        var workAreaPlacement = VoicePanelGeometry.ExtendDownward(
            baselinePlacement,
            taskbarMonitor,
            largeExpanded.PanelSize,
            VoicePanelGeometry.PreferredMode(largeExpanded),
            out var workAreaMode);
        if (workAreaMode != VoiceLaneMode.Compact
            || workAreaPlacement.PhysicalRect.Bottom > taskbarMonitor.WorkArea.Bottom)
        {
            _failures.Add("expanded Voice geometry ignored the monitor work area");
        }

        var teardownPlacement = VoicePanelGeometry.ExtendDownward(
            baselinePlacement,
            taskbarMonitor,
            PanelSize.Large,
            VoiceLaneMode.Compact,
            out var teardownMode);
        if (teardownMode != VoiceLaneMode.Compact
            || teardownPlacement.DipRect.Height != baselinePlacement.DipRect.Height + VoicePanelGeometry.CompactHeight)
        {
            _failures.Add("Voice geometry collapsed before runtime teardown completed");
        }

        var defaults = new UserSettings();
        if (defaults.VoiceEnabled
            || defaults.VoiceLaneLayout != VoiceLaneLayoutPreference.Compact
            || Enum.GetValues<VoiceLaneMode>().Length != 3)
        {
            _failures.Add("default-off/compact preference or no-fullscreen mode contract regressed");
        }
    }

    private static async Task WaitUntilAsync(Func<bool> predicate, CancellationToken cancellationToken)
    {
        while (!predicate())
        {
            cancellationToken.ThrowIfCancellationRequested();
            await Task.Delay(10, cancellationToken);
        }
    }

    private sealed class VoiceCalendarDataSource(DateTimeOffset now) : ICalendarCapabilityDataSource
    {
        public int ListCalls { get; private set; }

        public Task<IReadOnlyList<CalendarCapabilityEvent>> ListEventsAsync(
            DateTimeOffset start,
            DateTimeOffset end,
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            ListCalls++;
            IReadOnlyList<CalendarCapabilityEvent> events =
            [
                new CalendarCapabilityEvent(
                    "event-ref-voice",
                    "event-id-voice",
                    "Team\nreview\u202Eignored",
                    now.AddHours(1),
                    now.AddHours(2))
            ];
            return Task.FromResult(events);
        }

        public Task<CalendarCapabilityEvent?> GetEventAsync(
            string eventRef,
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return Task.FromResult<CalendarCapabilityEvent?>(null);
        }

        public Task<CalendarCapabilityEvent> CreateEventAsync(
            CalendarCapabilityCreateRequest request,
            string idempotencyKey,
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            throw new InvalidOperationException("calendar writes are not available to Voice AN3-B2 verifier");
        }
    }

    private sealed class VoiceDynamicToolHarness : ICodexVoiceDynamicToolRuntime
    {
        private int _callCount;
        private int _cancelledCallCount;
        private readonly TaskCompletionSource<bool> _blockedCallStarted = new(
            TaskCreationOptions.RunContinuationsAsynchronously);

        public int CallCount => Volatile.Read(ref _callCount);

        public int CancelledCallCount => Volatile.Read(ref _cancelledCallCount);

        public bool BlockNext { get; set; }

        public Task BlockedCallStarted => _blockedCallStarted.Task;

        public JsonElement Definitions => JsonSerializer.SerializeToElement(new object[]
        {
            new
            {
                type = "namespace",
                name = "hoverpocket",
                description = "Verifier tools",
                tools = new object[]
                {
                    new
                    {
                        type = "function",
                        name = "calendar_events_list",
                        description = "Verifier Calendar read",
                        inputSchema = new
                        {
                            type = "object",
                            additionalProperties = false,
                            properties = new { }
                        }
                    }
                }
            }
        });

        public async Task<CodexVoiceDynamicToolResponse> ExecuteAsync(
            JsonElement? parameters,
            string expectedThreadId,
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (parameters is not { ValueKind: JsonValueKind.Object } value
                || value.GetProperty("threadId").GetString() != expectedThreadId)
            {
                return new CodexVoiceDynamicToolResponse(
                    false,
                    "{\"status\":\"failed\",\"code\":\"thread_mismatch\"}");
            }
            Interlocked.Increment(ref _callCount);
            if (BlockNext)
            {
                BlockNext = false;
                _blockedCallStarted.TrySetResult(true);
                try
                {
                    await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
                }
                catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
                {
                    Interlocked.Increment(ref _cancelledCallCount);
                    return new CodexVoiceDynamicToolResponse(
                        false,
                        "{\"status\":\"failed\",\"code\":\"cancelled\"}");
                }
            }
            return new CodexVoiceDynamicToolResponse(
                true,
                "{\"status\":\"succeeded\"}");
        }
    }

    private sealed class FixedProbe : ICodexVoiceCompatibilityProbe
    {
        private readonly CodexVoiceGate _gate;

        public FixedProbe(CodexVoiceGate gate)
        {
            _gate = gate;
        }

        public Task<CodexVoiceGate> ProbeAsync(CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return Task.FromResult(_gate);
        }
    }

    private sealed class ThrowingProbe : ICodexVoiceCompatibilityProbe
    {
        public Task<CodexVoiceGate> ProbeAsync(CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            throw new IOException("synthetic_probe_failure");
        }
    }

    private sealed class DeferredInitializeHarness
    {
        private readonly ChannelLineReader _reader = new();
        private readonly Action? _onDispose;
        private readonly TaskCompletionSource<bool> _initializationRequested = new(
            TaskCreationOptions.RunContinuationsAsynchronously);

        public DeferredInitializeHarness(Action? onDispose = null)
        {
            _onDispose = onDispose;
        }

        public Task InitializationRequested => _initializationRequested.Task;

        public CodexAppServerClient CreateClient() =>
            CodexAppServerClient.AttachForTesting(
                _reader,
                new DeferredInitializeWriter(_initializationRequested),
                TimeSpan.FromSeconds(1),
                () =>
                {
                    _onDispose?.Invoke();
                    _reader.Dispose();
                    return ValueTask.CompletedTask;
                });

        public void PushServerRequest(long id, string method)
        {
            _reader.Push(JsonSerializer.Serialize(new
            {
                id,
                method,
                @params = new { }
            }));
        }
    }

    private sealed class DeferredInitializeGatedDisposeHarness
    {
        private readonly ChannelLineReader _reader = new();
        private readonly TaskCompletionSource<bool> _initializationRequested = new(
            TaskCreationOptions.RunContinuationsAsynchronously);
        private readonly TaskCompletionSource<bool> _disposeStarted = new(
            TaskCreationOptions.RunContinuationsAsynchronously);
        private readonly TaskCompletionSource<bool> _releaseDispose = new(
            TaskCreationOptions.RunContinuationsAsynchronously);

        public Task InitializationRequested => _initializationRequested.Task;
        public Task DisposeStarted => _disposeStarted.Task;

        public CodexAppServerClient CreateClient() =>
            CodexAppServerClient.AttachForTesting(
                _reader,
                new DeferredInitializeWriter(_initializationRequested),
                TimeSpan.FromSeconds(1),
                async () =>
                {
                    _disposeStarted.TrySetResult(true);
                    await _releaseDispose.Task.ConfigureAwait(false);
                    _reader.Dispose();
                });

        public void Close() => _reader.Dispose();
        public void ReleaseDispose() => _releaseDispose.TrySetResult(true);
    }

    private sealed class AppServerHarness
    {
        private readonly ChannelLineReader _reader = new();
        private readonly Action? _onDispose;
        private readonly bool _requestDuringInitialize;
        private readonly bool _disconnectAfterInitialize;
        private readonly bool _accountReady;
        private readonly bool _voicesReady;
        private readonly object _requestSync = new();
        private readonly HashSet<string> _requestedMethods = new(StringComparer.Ordinal);
        private readonly Dictionary<string, JsonElement> _requestParameters = new(StringComparer.Ordinal);
        private readonly List<JsonElement> _serverResponses = [];

        public AppServerHarness(
            Action? onDispose = null,
            bool requestDuringInitialize = false,
            bool disconnectAfterInitialize = false,
            bool accountReady = true,
            bool voicesReady = true)
        {
            _onDispose = onDispose;
            _requestDuringInitialize = requestDuringInitialize;
            _disconnectAfterInitialize = disconnectAfterInitialize;
            _accountReady = accountReady;
            _voicesReady = voicesReady;
        }

        public IReadOnlyCollection<string> RequestedMethods
        {
            get
            {
                lock (_requestSync)
                {
                    return _requestedMethods.ToArray();
                }
            }
        }

        public IReadOnlyList<JsonElement> ServerResponses
        {
            get
            {
                lock (_requestSync)
                {
                    return _serverResponses.Select(item => item.Clone()).ToArray();
                }
            }
        }

        public JsonElement? RequestParameters(string method)
        {
            lock (_requestSync)
            {
                return _requestParameters.TryGetValue(method, out var parameters)
                    ? parameters.Clone()
                    : null;
            }
        }

        public CodexAppServerClient CreateClient() =>
            CodexAppServerClient.AttachForTesting(
                _reader,
                new AutoReplyWriter(
                    _reader,
                    _requestDuringInitialize,
                    _disconnectAfterInitialize,
                    _accountReady,
                    _voicesReady,
                    RecordRequest,
                    RecordServerResponse),
                TimeSpan.FromSeconds(1),
                () =>
                {
                    _onDispose?.Invoke();
                    _reader.Dispose();
                    return ValueTask.CompletedTask;
                });

        public void PushServerRequest(long id, string method)
        {
            PushServerRequest(id, method, new { });
        }

        public void PushServerRequest(long id, string method, object parameters)
        {
            _reader.Push(JsonSerializer.Serialize(new
            {
                id,
                method,
                @params = parameters
            }));
        }

        public void PushNotification(string method, object parameters)
        {
            _reader.Push(JsonSerializer.Serialize(new
            {
                method,
                @params = parameters
            }));
        }

        public void Close() => _reader.Dispose();

        private void RecordRequest(string method, JsonElement? parameters)
        {
            lock (_requestSync)
            {
                _requestedMethods.Add(method);
                if (parameters is { } value)
                {
                    _requestParameters[method] = value.Clone();
                }
            }
        }

        private void RecordServerResponse(JsonElement response)
        {
            lock (_requestSync)
            {
                _serverResponses.Add(response.Clone());
            }
        }
    }

    private sealed class GatedDisposeHarness
    {
        private readonly ChannelLineReader _reader = new();
        private readonly TaskCompletionSource<bool> _disposeStarted = new(
            TaskCreationOptions.RunContinuationsAsynchronously);
        private readonly TaskCompletionSource<bool> _releaseDispose = new(
            TaskCreationOptions.RunContinuationsAsynchronously);

        public Task DisposeStarted => _disposeStarted.Task;

        public CodexAppServerClient CreateClient() =>
            CodexAppServerClient.AttachForTesting(
                _reader,
                new AutoReplyWriter(
                    _reader,
                    requestDuringInitialize: false,
                    disconnectAfterInitialize: false,
                    accountReady: true,
                    voicesReady: true),
                TimeSpan.FromSeconds(1),
                async () =>
                {
                    _disposeStarted.TrySetResult(true);
                    await _releaseDispose.Task.ConfigureAwait(false);
                    _reader.Dispose();
                });

        public void ReleaseDispose() => _releaseDispose.TrySetResult(true);

        public void Close() => _reader.Dispose();

        public void PushServerRequest(long id, string method)
        {
            _reader.Push(JsonSerializer.Serialize(new
            {
                id,
                method,
                @params = new { }
            }));
        }
    }

    private sealed class ChannelLineReader : TextReader
    {
        private readonly Channel<char> _channel = Channel.CreateUnbounded<char>();

        public void Push(string line)
        {
            foreach (var character in line)
            {
                _channel.Writer.TryWrite(character);
            }
            _channel.Writer.TryWrite('\n');
        }

        public override async ValueTask<int> ReadAsync(
            Memory<char> buffer,
            CancellationToken cancellationToken = default)
        {
            if (buffer.Length == 0)
            {
                return 0;
            }
            try
            {
                var first = await _channel.Reader.ReadAsync(cancellationToken);
                buffer.Span[0] = first;
                var count = 1;
                while (count < buffer.Length && _channel.Reader.TryRead(out var character))
                {
                    buffer.Span[count++] = character;
                }
                return count;
            }
            catch (ChannelClosedException)
            {
                return 0;
            }
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                _channel.Writer.TryComplete();
            }
            base.Dispose(disposing);
        }
    }

    private sealed class DeferredInitializeWriter : TextWriter
    {
        private readonly TaskCompletionSource<bool> _initializationRequested;

        public DeferredInitializeWriter(TaskCompletionSource<bool> initializationRequested)
        {
            _initializationRequested = initializationRequested;
        }

        public override Encoding Encoding => Encoding.UTF8;

        public override Task WriteLineAsync(
            ReadOnlyMemory<char> buffer,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            using var document = JsonDocument.Parse(buffer.ToString());
            if (document.RootElement.TryGetProperty("method", out var method)
                && method.GetString() == "initialize")
            {
                _initializationRequested.TrySetResult(true);
            }
            return Task.CompletedTask;
        }

        public override Task FlushAsync(CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return Task.CompletedTask;
        }
    }

    private sealed class GatedTextReader : TextReader
    {
        private readonly string _value;
        private readonly TaskCompletionSource<bool> _release = new(
            TaskCreationOptions.RunContinuationsAsynchronously);
        private int _offset;

        public GatedTextReader(string value)
        {
            _value = value;
        }

        public void Release() => _release.TrySetResult(true);

        public override async ValueTask<int> ReadAsync(
            Memory<char> buffer,
            CancellationToken cancellationToken = default)
        {
            await _release.Task.WaitAsync(cancellationToken);
            if (_offset >= _value.Length)
            {
                return 0;
            }
            var count = Math.Min(buffer.Length, _value.Length - _offset);
            _value.AsMemory(_offset, count).CopyTo(buffer);
            _offset += count;
            return count;
        }
    }

    private sealed class AutoReplyWriter : TextWriter
    {
        private readonly ChannelLineReader _reader;
        private readonly bool _requestDuringInitialize;
        private readonly bool _disconnectAfterInitialize;
        private readonly bool _accountReady;
        private readonly bool _voicesReady;
        private readonly Action<string, JsonElement?>? _onRequest;
        private readonly Action<JsonElement>? _onServerResponse;

        public AutoReplyWriter(
            ChannelLineReader reader,
            bool requestDuringInitialize,
            bool disconnectAfterInitialize,
            bool accountReady,
            bool voicesReady,
            Action<string, JsonElement?>? onRequest = null,
            Action<JsonElement>? onServerResponse = null)
        {
            _reader = reader;
            _requestDuringInitialize = requestDuringInitialize;
            _disconnectAfterInitialize = disconnectAfterInitialize;
            _accountReady = accountReady;
            _voicesReady = voicesReady;
            _onRequest = onRequest;
            _onServerResponse = onServerResponse;
        }

        public override Encoding Encoding => Encoding.UTF8;

        public override Task WriteLineAsync(ReadOnlyMemory<char> buffer, CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            using var document = JsonDocument.Parse(buffer.ToString());
            var root = document.RootElement;
            if (!root.TryGetProperty("id", out var id))
            {
                return Task.CompletedTask;
            }
            if (!root.TryGetProperty("method", out var method)
                || method.ValueKind != JsonValueKind.String)
            {
                if (root.TryGetProperty("result", out _))
                {
                    _onServerResponse?.Invoke(root.Clone());
                }
                return Task.CompletedTask;
            }
            var methodName = method.GetString() ?? string.Empty;
            JsonElement? parameters = root.TryGetProperty("params", out var requestParameters)
                ? requestParameters.Clone()
                : null;
            _onRequest?.Invoke(methodName, parameters);
            object result = methodName switch
            {
                "initialize" => new
                {
                    platformOs = "windows",
                    platformFamily = "windows",
                    codexHome = "C:\\safe",
                    userAgent = "HoverPocketVerifier"
                },
                "account/read" when _accountReady => new
                {
                    requiresOpenaiAuth = true,
                    account = new { type = "chatgpt", email = (string?)null, planType = "pro" }
                },
                "account/read" => new { requiresOpenaiAuth = true, account = (object?)null },
                "thread/realtime/listVoices" when _voicesReady => new
                {
                    voices = new
                    {
                        defaultV1 = "alloy",
                        defaultV2 = "alloy",
                        v1 = new[] { "alloy" },
                        v2 = new[] { "alloy" }
                    }
                },
                "thread/realtime/listVoices" => new { voices = new { } },
                "thread/start" => new { thread = new { id = "root-voice" } },
                _ => new { }
            };
            if (methodName == "initialize" && _requestDuringInitialize)
            {
                _reader.Push("{\"id\":9002,\"method\":\"approval/request\",\"params\":{}}");
            }
            _reader.Push(JsonSerializer.Serialize(new
            {
                id = id.GetInt64(),
                result
            }));
            if (methodName == "initialize" && _disconnectAfterInitialize)
            {
                _reader.Dispose();
            }
            return Task.CompletedTask;
        }

        public override Task FlushAsync(CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return Task.CompletedTask;
        }
    }
}
