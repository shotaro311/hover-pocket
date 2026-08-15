using System.Diagnostics;
using HoverPocket.Shell.Providers.CodexVoice;

namespace HoverPocket.Shell.Verification;

internal sealed class CodexVoiceCoordinatorVerifier
{
    private const string FakeServerEnvironmentVariable = "HOVERPOCKET_FAKE_CODEX_APP_SERVER";
    private const string FakeSignedOutEnvironmentVariable = "HOVERPOCKET_FAKE_CODEX_SIGNED_OUT";
    private const string FakeExpectDynamicToolsEnvironmentVariable = "HOVERPOCKET_FAKE_CODEX_EXPECT_DYNAMIC_TOOLS";
    private const string FakeWebRtcFailureEnvironmentVariable = "HOVERPOCKET_FAKE_CODEX_WEBRTC_FAILURE";
    private readonly List<string> _failures = [];

    public async Task<int> RunAsync(CancellationToken cancellationToken = default)
    {
        VerifyProductionLaunchContract();
        await VerifyFeatureDisabledDoesNotStartCodexAsync(cancellationToken);
        await VerifySignedOutFailsClosedAsync(cancellationToken);
        await VerifyNegotiationFailureInvalidatesRootAsync(cancellationToken);
        await VerifyCoordinatorOutlivesTransientUiAsync(cancellationToken);
        await new CodexVoiceCapabilityToolAdapterVerifier(_failures).VerifyAsync(cancellationToken);
        VerifyTranscriptBounds();

        if (_failures.Count == 0)
        {
            VerifyConsole.WriteLine(
                "PASS codex-voice-coordinator verify: process-local realtime feature override, disabled no-start, account/capability gate, app-server ownership, fake WebRTC SDP/stop, root-scoped current/child/descendant cards, Broker-routed Voice tools with approval/readback/idempotency, transcript continuity, UI detach/reconnect, bounded crash restart, bounded memory");
            return 0;
        }

        VerifyConsole.WriteLine("FAIL codex-voice-coordinator verify:");
        foreach (var failure in _failures)
        {
            VerifyConsole.WriteLine($"- {failure}");
        }

        return 1;
    }

    private void VerifyProductionLaunchContract()
    {
        var options = CodexVoiceRuntimeHost.CreateProductionClientOptions();
        if (!options.ExperimentalApi || !options.EnableRealtimeConversation)
        {
            _failures.Add("production Voice app-server options did not enable experimental realtime");
        }

        const string executablePath = @"C:\Program Files\Codex\codex.exe";
        var startInfo = CodexExecutableResolver.CreateAppServerStartInfo(
            executablePath,
            options.EnableRealtimeConversation);
        var expectedArguments = new[]
        {
            "-c",
            CodexExecutableResolver.RealtimeConversationFeatureOverride,
            "app-server",
            "--stdio"
        };
        if (!string.Equals(startInfo.FileName, executablePath, StringComparison.OrdinalIgnoreCase)
            || !startInfo.ArgumentList.SequenceEqual(expectedArguments, StringComparer.Ordinal))
        {
            _failures.Add("production Voice app-server launch arguments lost the realtime override");
        }

        var fakeStartInfo = CodexExecutableResolver.CreateAppServerStartInfo(executablePath);
        if (!fakeStartInfo.ArgumentList.SequenceEqual(
                new[] { "app-server", "--stdio" },
                StringComparer.Ordinal))
        {
            _failures.Add("generic/fake app-server explicit launch contract was changed");
        }
    }

    private async Task VerifySignedOutFailsClosedAsync(CancellationToken cancellationToken)
    {
        await using var coordinator = new CodexVoiceCoordinator(
            featureEnabled: true,
            clientFactory: StartFakeSignedOutServerClientAsync,
            restartDelays: [TimeSpan.Zero]);

        await coordinator.InitializeAsync(cancellationToken);
        var snapshot = coordinator.Snapshot;
        if (snapshot.Availability != CodexVoiceAvailability.SignedOut
            || snapshot.SessionStatus != CodexVoiceSessionStatus.BlockedFailure
            || snapshot.LastErrorCode != "signed_out"
            || snapshot.AppServerProcessId is not null
            || snapshot.VoiceCount != 0)
        {
            _failures.Add("signed-out account did not fail closed before realtime became ready");
        }
    }

    private async Task VerifyFeatureDisabledDoesNotStartCodexAsync(
        CancellationToken cancellationToken)
    {
        var factoryCalled = false;
        await using var coordinator = new CodexVoiceCoordinator(
            featureEnabled: false,
            clientFactory: _ =>
            {
                factoryCalled = true;
                throw new InvalidOperationException("Disabled feature attempted to start Codex.");
            });

        await coordinator.InitializeAsync(cancellationToken);
        var snapshot = coordinator.Snapshot;
        if (factoryCalled)
        {
            _failures.Add("feature-disabled coordinator invoked the app-server factory");
        }

        if (snapshot.Availability != CodexVoiceAvailability.Disabled
            || snapshot.AppServerProcessId is not null
            || snapshot.TransportAttached)
        {
            _failures.Add("feature-disabled snapshot was not inert");
        }
    }

    private async Task VerifyNegotiationFailureInvalidatesRootAsync(
        CancellationToken cancellationToken)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(20));
        var toolAdapter = new StubDynamicToolAdapter();
        await using var coordinator = new CodexVoiceCoordinator(
            featureEnabled: true,
            clientFactory: StartFakeWebRtcFailureServerClientAsync,
            restartDelays: [TimeSpan.Zero],
            toolAdapter: toolAdapter);

        await coordinator.InitializeAsync(timeout.Token);
        try
        {
            _ = await coordinator.StartWebRtcAsync("v=0\r\ns=failed-offer\r\n", timeout.Token);
            _failures.Add("injected WebRTC failure unexpectedly succeeded");
        }
        catch (CodexAppServerRpcException)
        {
        }

        var failed = coordinator.Snapshot;
        if (failed.RootThreadId is not null
            || failed.Sessions.Count != 0
            || failed.SessionStatus != CodexVoiceSessionStatus.RecoverableFailure
            || toolAdapter.HandledCallCount != 0)
        {
            _failures.Add("WebRTC failure retained root scope, cards, or tool authority");
            return;
        }

        var recovered = await coordinator.StartWebRtcAsync(
            "v=0\r\ns=recovered-offer\r\n",
            timeout.Token);
        if (recovered.RootThreadId != "root-thread-2"
            || recovered.Sdp != "v=0\r\ns=fake-answer\r\n")
        {
            _failures.Add("WebRTC retry reused the failed root instead of creating a new root");
        }
    }

    private async Task VerifyCoordinatorOutlivesTransientUiAsync(
        CancellationToken cancellationToken)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(20));

        var notifications = 0;
        int? appServerProcessId = null;
        var toolAdapter = new StubDynamicToolAdapter();
        await using (var coordinator = new CodexVoiceCoordinator(
            featureEnabled: true,
            clientFactory: StartFakeServerClientAsync,
            restartDelays: [TimeSpan.Zero, TimeSpan.FromMilliseconds(20)],
            toolAdapter: toolAdapter))
        {
            coordinator.SnapshotChanged += (_, _) => notifications++;
            coordinator.SnapshotChanged += (_, _) =>
                throw new InvalidOperationException("intentional subscriber failure");

            await coordinator.InitializeAsync(timeout.Token);
            var initialized = coordinator.Snapshot;
            appServerProcessId = initialized.AppServerProcessId;
            if (initialized.Availability != CodexVoiceAvailability.Ready
                || appServerProcessId is null
                || initialized.VoiceCount != 1
                || toolAdapter.HandledCallCount != 0)
            {
                _failures.Add("enabled coordinator did not pass gates or rejected pre-ready tool calls");
                return;
            }

            var answer = await coordinator.StartWebRtcAsync(
                "v=0\r\ns=fake-offer\r\n",
                timeout.Token);
            if (answer.RootThreadId != "root-thread"
                || answer.Sdp != "v=0\r\ns=fake-answer\r\n"
                || coordinator.Snapshot.SessionStatus != CodexVoiceSessionStatus.Connecting)
            {
                _failures.Add("fake WebRTC offer/answer did not preserve the root thread or negotiating state");
            }
            var withSessions = await WaitForSnapshotAsync(
                coordinator,
                snapshot => snapshot.Sessions.Count == 5
                    && snapshot.Sessions.FirstOrDefault(session => session.ThreadId == "child-a")
                        ?.Detail == "実装を進めています",
                timeout.Token);
            if (withSessions is null
                || !withSessions.Sessions.Select(session => session.ThreadId).SequenceEqual(
                    ["root-thread", "paged-child", "current-root", "grandchild-a", "child-a"],
                    StringComparer.Ordinal)
                || withSessions.Sessions.Any(session => session.ThreadId is
                    "foreign-child" or "orphan" or "duplicate" or "duplicate-child")
                || withSessions.Sessions.Select(session => session.ThreadId)
                    .Distinct(StringComparer.Ordinal).Count() != withSessions.Sessions.Count
                || withSessions.Sessions.Single(session => session.ThreadId == "child-a").Detail
                    != "実装を進めています"
                || withSessions.Sessions.Single(session => session.ThreadId == "paged-child").Detail
                    != "2ページ目を取得しました"
                || withSessions.Sessions.Single(session => session.ThreadId == "grandchild-a").Detail
                    != "検証中"
                || withSessions.Sessions.Single(session => session.ThreadId == "child-a").State
                    != CodexVoiceThreadState.Running
                || withSessions.Sessions.Single(session => session.ThreadId == "grandchild-a").State
                    != CodexVoiceThreadState.Completed)
            {
                _failures.Add("root-scoped session cards leaked another tree or lost status/latest-message data");
            }
            coordinator.MarkTransportAttached();
            coordinator.ProcessNotificationForVerify(
                "thread/realtime/started",
                new { threadId = "attacker-thread" });
            if (coordinator.Snapshot.RootThreadId != "root-thread")
            {
                _failures.Add("mismatched realtime started notification replaced the root thread");
            }
            coordinator.ProcessNotificationForVerify(
                "thread/realtime/transcript/delta",
                new { threadId = "root-thread", role = "user", delta = "hello " });
            coordinator.ProcessNotificationForVerify(
                "thread/realtime/transcript/delta",
                new { threadId = "root-thread", role = "user", delta = "world" });
            coordinator.ProcessNotificationForVerify(
                "thread/realtime/transcript/done",
                new { threadId = "root-thread", role = "user" });

            var connected = coordinator.Snapshot;
            if (connected.SessionStatus != CodexVoiceSessionStatus.Connected
                || connected.RootThreadId != "root-thread"
                || connected.Transcript.Count != 1
                || connected.Transcript[0].Text != "hello world"
                || !connected.Transcript[0].IsComplete)
            {
                _failures.Add("connected coordinator state or transcript merge was incorrect");
            }

            coordinator.ClearTransientUiState();
            var detached = coordinator.Snapshot;
            if (detached.TransportAttached
                || !detached.IsMuted
                || detached.SessionStatus != CodexVoiceSessionStatus.Reconnecting
                || detached.RootThreadId != "root-thread"
                || detached.Transcript.Count != 1
                || detached.Transcript[0].Text != "hello world"
                || detached.AppServerProcessId != appServerProcessId)
            {
                _failures.Add("transient UI reset lost thread, transcript, or app-server state");
            }

            coordinator.AttachTransport();
            var reattached = coordinator.Snapshot;
            if (!reattached.TransportAttached
                || reattached.SessionStatus != CodexVoiceSessionStatus.Muted
                || reattached.RootThreadId != "root-thread")
            {
                _failures.Add("transport reattachment did not restore the logical session");
            }

            await coordinator.TriggerTransportExitForVerifyAsync(timeout.Token);
            var restarted = await WaitForSnapshotAsync(
                coordinator,
                snapshot => snapshot.Availability == CodexVoiceAvailability.Ready
                    && snapshot.AppServerProcessId is { } restartedProcessId
                    && restartedProcessId != appServerProcessId,
                timeout.Token);
            if (restarted is null
                || restarted.RestartAttempt != 1
                || restarted.RootThreadId is not null
                || restarted.SessionStatus != CodexVoiceSessionStatus.Idle
                || restarted.VoiceCount != 1)
            {
                _failures.Add("app-server crash did not recover with a new client generation and invalidated root");
            }
            else
            {
                appServerProcessId = restarted.AppServerProcessId;
                await coordinator.StopRealtimeAsync(timeout.Token);
                if (coordinator.Snapshot.SessionStatus != CodexVoiceSessionStatus.Closed)
                {
                    _failures.Add("realtime stop did not close only the audio session");
                }
            }

            if (notifications == 0)
            {
                _failures.Add("snapshot changes were not published");
            }
        }

        if (appServerProcessId is { } processId && IsProcessAlive(processId))
        {
            _failures.Add("coordinator disposal left the app-server process running");
        }
    }

    private static async Task<CodexVoiceSnapshot?> WaitForSnapshotAsync(
        CodexVoiceCoordinator coordinator,
        Func<CodexVoiceSnapshot, bool> predicate,
        CancellationToken cancellationToken)
    {
        for (var attempt = 0; attempt < 100; attempt++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var snapshot = coordinator.Snapshot;
            if (predicate(snapshot))
            {
                return snapshot;
            }

            await Task.Delay(25, cancellationToken);
        }

        return null;
    }

    private void VerifyTranscriptBounds()
    {
        var buffer = new CodexVoiceTranscriptBuffer(entryLimit: 2, characterLimit: 10);
        var now = DateTimeOffset.UtcNow;
        _ = buffer.AppendDelta("thread", "user", "12345", now);
        _ = buffer.MarkComplete("thread", "user", now);
        _ = buffer.AppendDelta("thread", "assistant", "67890", now);
        _ = buffer.MarkComplete("thread", "assistant", now);
        _ = buffer.AppendDelta("thread", "user", "ABCDE", now);

        var snapshot = buffer.Snapshot();
        if (snapshot.Count > 2
            || snapshot.Sum(entry => entry.Text.Length) > 10
            || snapshot.Any(entry => entry.Text.Contains("12345", StringComparison.Ordinal)))
        {
            _failures.Add("transcript buffer did not enforce entry and character limits");
        }

        var single = new CodexVoiceTranscriptBuffer(entryLimit: 1, characterLimit: 5);
        _ = single.AppendDelta("thread", "user", "0123456789", now);
        if (single.Snapshot().Single().Text != "56789")
        {
            _failures.Add("oversized active transcript was not tail-trimmed");
        }
    }

    private static async Task<CodexAppServerClient> StartFakeServerClientAsync(
        CancellationToken cancellationToken)
    {
        var executablePath = Environment.ProcessPath
            ?? throw new InvalidOperationException("Current executable path is unavailable.");
        var previousValue = Environment.GetEnvironmentVariable(FakeServerEnvironmentVariable);
        var previousToolExpectation = Environment.GetEnvironmentVariable(FakeExpectDynamicToolsEnvironmentVariable);
        Environment.SetEnvironmentVariable(FakeServerEnvironmentVariable, "1");
        Environment.SetEnvironmentVariable(FakeExpectDynamicToolsEnvironmentVariable, "1");
        try
        {
            return await CodexAppServerClient.StartAsync(
                new CodexAppServerClientOptions
                {
                    ExecutablePath = executablePath,
                    ClientName = "hover_pocket_coordinator_verify",
                    ClientTitle = "HoverPocket Coordinator Verifier",
                    ClientVersion = "0.0.0",
                    ExperimentalApi = true,
                    RequestTimeout = TimeSpan.FromSeconds(5)
                },
                cancellationToken);
        }
        finally
        {
            Environment.SetEnvironmentVariable(FakeServerEnvironmentVariable, previousValue);
            Environment.SetEnvironmentVariable(FakeExpectDynamicToolsEnvironmentVariable, previousToolExpectation);
        }
    }

    private static async Task<CodexAppServerClient> StartFakeSignedOutServerClientAsync(
        CancellationToken cancellationToken)
    {
        var previousValue = Environment.GetEnvironmentVariable(FakeSignedOutEnvironmentVariable);
        Environment.SetEnvironmentVariable(FakeSignedOutEnvironmentVariable, "1");
        try
        {
            return await StartFakeServerClientAsync(cancellationToken);
        }
        finally
        {
            Environment.SetEnvironmentVariable(FakeSignedOutEnvironmentVariable, previousValue);
        }
    }

    private static async Task<CodexAppServerClient> StartFakeWebRtcFailureServerClientAsync(
        CancellationToken cancellationToken)
    {
        var previousValue = Environment.GetEnvironmentVariable(FakeWebRtcFailureEnvironmentVariable);
        Environment.SetEnvironmentVariable(FakeWebRtcFailureEnvironmentVariable, "1");
        try
        {
            return await StartFakeServerClientAsync(cancellationToken);
        }
        finally
        {
            Environment.SetEnvironmentVariable(FakeWebRtcFailureEnvironmentVariable, previousValue);
        }
    }

    private static bool IsProcessAlive(int processId)
    {
        try
        {
            using var process = Process.GetProcessById(processId);
            return !process.HasExited;
        }
        catch (ArgumentException)
        {
            return false;
        }
    }

    private sealed class StubDynamicToolAdapter : ICodexVoiceCapabilityToolAdapter
    {
        public int HandledCallCount { get; private set; }

        public IReadOnlyList<object> DynamicTools { get; } =
        [
            new
            {
                type = "function",
                name = "hoverpocket_verify",
                description = "Verifier-only dynamic tool.",
                inputSchema = new
                {
                    type = "object",
                    properties = new { },
                    required = Array.Empty<string>(),
                    additionalProperties = false
                }
            }
        ];

        public Task<CodexAppServerReply> HandleAsync(
            CodexAppServerRequest request,
            CodexVoiceToolRequestContext context,
            CancellationToken cancellationToken)
        {
            _ = request;
            _ = context;
            cancellationToken.ThrowIfCancellationRequested();
            HandledCallCount++;
            return Task.FromResult(CodexAppServerReply.Failure(-32601, "Verifier tool calls are disabled."));
        }
    }
}
