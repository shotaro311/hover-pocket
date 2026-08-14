using System.Diagnostics;
using HoverPocket.Shell.Providers.CodexVoice;

namespace HoverPocket.Shell.Verification;

internal sealed class CodexVoiceCoordinatorVerifier
{
    private const string FakeServerEnvironmentVariable = "HOVERPOCKET_FAKE_CODEX_APP_SERVER";
    private const string FakeSignedOutEnvironmentVariable = "HOVERPOCKET_FAKE_CODEX_SIGNED_OUT";
    private readonly List<string> _failures = [];

    public async Task<int> RunAsync(CancellationToken cancellationToken = default)
    {
        await VerifyFeatureDisabledDoesNotStartCodexAsync(cancellationToken);
        await VerifySignedOutFailsClosedAsync(cancellationToken);
        await VerifyCoordinatorOutlivesTransientUiAsync(cancellationToken);
        VerifyTranscriptBounds();

        if (_failures.Count == 0)
        {
            VerifyConsole.WriteLine(
                "PASS codex-voice-coordinator verify: disabled no-start, account/capability gate, app-server ownership, fake WebRTC SDP/stop, transcript continuity, UI detach/reconnect, bounded crash restart, bounded memory");
            return 0;
        }

        VerifyConsole.WriteLine("FAIL codex-voice-coordinator verify:");
        foreach (var failure in _failures)
        {
            VerifyConsole.WriteLine($"- {failure}");
        }

        return 1;
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

    private async Task VerifyCoordinatorOutlivesTransientUiAsync(
        CancellationToken cancellationToken)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(20));

        var notifications = 0;
        int? appServerProcessId = null;
        await using (var coordinator = new CodexVoiceCoordinator(
            featureEnabled: true,
            clientFactory: StartFakeServerClientAsync,
            restartDelays: [TimeSpan.Zero, TimeSpan.FromMilliseconds(20)]))
        {
            coordinator.SnapshotChanged += (_, _) => notifications++;
            coordinator.SnapshotChanged += (_, _) =>
                throw new InvalidOperationException("intentional subscriber failure");

            await coordinator.InitializeAsync(timeout.Token);
            var initialized = coordinator.Snapshot;
            appServerProcessId = initialized.AppServerProcessId;
            if (initialized.Availability != CodexVoiceAvailability.Ready
                || appServerProcessId is null
                || initialized.VoiceCount != 1)
            {
                _failures.Add("enabled coordinator did not pass account/voice gates or own a ready app-server process");
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
            coordinator.MarkTransportAttached();
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
                || restarted.RootThreadId != "root-thread"
                || restarted.SessionStatus != CodexVoiceSessionStatus.Reconnecting
                || restarted.VoiceCount != 1)
            {
                _failures.Add("app-server crash did not recover with bounded restart while preserving root state");
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
        Environment.SetEnvironmentVariable(FakeServerEnvironmentVariable, "1");
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
}
