using System.Text;
using System.Text.Json;
using System.Threading.Channels;
using System.Windows;
using HoverPocket.Shell.Configuration;
using HoverPocket.Shell.Display;
using HoverPocket.Shell.Voice;

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
                "PASS voice-foundation verify: default-off inert, schema/account/capability gates, fail-closed server requests, bounded restart, root scope, bounded redacted transcript, app-lifetime UI detach, compact/expanded geometry");
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
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(15));
        await RunCaseAsync("disabled", VerifyDisabledIsInertAsync, timeout.Token);
        await RunCaseAsync("compatibility", VerifyCompatibilityGatesAsync, timeout.Token);
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
            || coordinator.Snapshot.SessionStatus != CodexVoiceSessionStatus.BlockedFailure)
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
        if (coordinator.Snapshot.Muted)
        {
            _failures.Add("ready app-server transport could not unmute");
        }
        coordinator.SetMuted(true);

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

        var filesystemPaths = new[]
        {
            "/tmp/private.txt",
            "/Volumes/work/secret.mov",
            @"C:\work\secret.txt",
            "[/Users/alice/private]",
            @"[C:\Users\alice\private]",
            "Sources/HoverPocket/App.swift",
            "Bearer sk-proj-secret",
            "sk-proj-abcdefghijklmnopqrstuvwxyz"
        };
        if (filesystemPaths.Any(path => VoiceTextSafety.SanitizeVisibleText(path, 200) != "[redacted]"))
        {
            _failures.Add("filesystem path redaction was incomplete");
        }
        var nonPathText = new[]
        {
            "https://example.com/Sources/HoverPocket/App.swift",
            "and/or",
            "input/output"
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

        public AppServerHarness(
            Action? onDispose = null,
            bool requestDuringInitialize = false,
            bool disconnectAfterInitialize = false)
        {
            _onDispose = onDispose;
            _requestDuringInitialize = requestDuringInitialize;
            _disconnectAfterInitialize = disconnectAfterInitialize;
        }

        public CodexAppServerClient CreateClient() =>
            CodexAppServerClient.AttachForTesting(
                _reader,
                new AutoReplyWriter(
                    _reader,
                    _requestDuringInitialize,
                    _disconnectAfterInitialize),
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

        public void Close() => _reader.Dispose();
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
                new AutoReplyWriter(_reader, requestDuringInitialize: false, disconnectAfterInitialize: false),
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

        public AutoReplyWriter(
            ChannelLineReader reader,
            bool requestDuringInitialize,
            bool disconnectAfterInitialize)
        {
            _reader = reader;
            _requestDuringInitialize = requestDuringInitialize;
            _disconnectAfterInitialize = disconnectAfterInitialize;
        }

        public override Encoding Encoding => Encoding.UTF8;

        public override Task WriteLineAsync(ReadOnlyMemory<char> buffer, CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            using var document = JsonDocument.Parse(buffer.ToString());
            var root = document.RootElement;
            if (root.TryGetProperty("id", out var id)
                && root.TryGetProperty("method", out var method)
                && method.GetString() == "initialize")
            {
                if (_requestDuringInitialize)
                {
                    _reader.Push("{\"id\":9002,\"method\":\"approval/request\",\"params\":{}}");
                }
                _reader.Push($"{{\"id\":{id.GetInt64()},\"result\":{{\"ready\":true}}}}");
                if (_disconnectAfterInitialize)
                {
                    _reader.Dispose();
                }
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
