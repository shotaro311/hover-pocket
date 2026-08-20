using System.Text;
using System.Text.Json;
using System.Threading.Channels;
using HoverPocket.Shell.Configuration;
using HoverPocket.Shell.Voice;

namespace HoverPocket.Shell.Verification;

internal sealed class VoiceFoundationVerifier
{
    private readonly List<string> _failures = [];

    public int Run()
    {
        try
        {
            RunAsync().GetAwaiter().GetResult();
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
        await RunCaseAsync("unexpected-request", VerifyUnexpectedRequestFailsClosedAsync, timeout.Token);
        await RunCaseAsync("initialize-request", VerifyInitializeRequestCannotBePromotedAsync, timeout.Token);
        await RunCaseAsync("restart", VerifyRestartIsBoundedAsync, timeout.Token);
        await RunCaseAsync("failed-initialize-cleanup", VerifyFailedInitializeDisposesCandidateAsync, timeout.Token);
        await RunCaseAsync("crash-cleanup", VerifyTransportCrashDisposesCandidateAsync, timeout.Token);
        await RunCaseAsync("oversized-response", VerifyOversizedResponseFailsClosedAsync, timeout.Token);
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

    private async Task VerifyUnexpectedRequestFailsClosedAsync(CancellationToken cancellationToken)
    {
        var harness = new AppServerHarness();
        using var coordinator = new CodexVoiceCoordinator(
            featureEnabled: true,
            clientFactory: _ => Task.FromResult(harness.CreateClient()),
            compatibilityProbe: new FixedProbe(CodexVoiceGate.Ready),
            restartDelays: []);

        await coordinator.InitializeAsync(cancellationToken);
        if (coordinator.Snapshot.Availability != CodexVoiceAvailability.Ready)
        {
            _failures.Add("ready gate did not initialize the fake app-server");
            return;
        }

        harness.PushServerRequest(9001, "unknown/request");
        await WaitUntilAsync(
            () => coordinator.Snapshot.LastErrorCode == "unexpected_server_request",
            cancellationToken);

        if (coordinator.Snapshot.Availability != CodexVoiceAvailability.CapabilityBlocked
            || coordinator.Snapshot.SessionStatus != CodexVoiceSessionStatus.BlockedFailure)
        {
            _failures.Add("unexpected app-server request was not fail-closed");
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

    private async Task VerifyTransportCrashDisposesCandidateAsync(CancellationToken cancellationToken)
    {
        var disposeCount = 0;
        var harness = new AppServerHarness(() => Interlocked.Increment(ref disposeCount));
        using var coordinator = new CodexVoiceCoordinator(
            featureEnabled: true,
            clientFactory: _ => Task.FromResult(harness.CreateClient()),
            compatibilityProbe: new FixedProbe(CodexVoiceGate.Ready),
            restartDelays: []);

        await coordinator.InitializeAsync(cancellationToken);
        harness.Close();
        await WaitUntilAsync(() => Volatile.Read(ref disposeCount) == 1, cancellationToken);
        if (coordinator.Snapshot.TransportAttached
            || coordinator.Snapshot.AppServerProcessId is not null)
        {
            _failures.Add("transport crash did not dispose and detach the app-server client");
        }
    }

    private async Task VerifyOversizedResponseFailsClosedAsync(CancellationToken cancellationToken)
    {
        var reader = new GatedTextReader(
            new string('x', CodexAppServerClient.MaxLineCharacters + 1) + "\n");
        await using var client = CodexAppServerClient.AttachForTesting(reader, TextWriter.Null);
        var disconnected = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        client.Disconnected += (_, _) => disconnected.TrySetResult(true);
        reader.Release();
        await disconnected.Task.WaitAsync(cancellationToken);
    }

    private void VerifyTranscriptAndRootScope()
    {
        using var coordinator = new CodexVoiceCoordinator(featureEnabled: true);
        coordinator.SetRootSessionId("root-a");
        var now = DateTimeOffset.UnixEpoch;

        for (var index = 0; index < 90; index++)
        {
            coordinator.AppendTranscript(new VoiceTranscriptEvent(
                $"event-{index}",
                "user",
                index == 89 ? @"C:\Users\test\private.txt" : new string('あ', 160),
                true,
                now.AddSeconds(index)));
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

        var absolutePaths = new[] { "/tmp/private.txt", "/Volumes/work/secret.mov", @"C:\work\secret.txt" };
        if (absolutePaths.Any(path => VoiceTextSafety.SanitizeVisibleText(path, 200) != "[redacted]"))
        {
            _failures.Add("absolute filesystem path redaction was incomplete");
        }
    }

    private void VerifyUiDetachPreservesSession()
    {
        using var coordinator = new CodexVoiceCoordinator(featureEnabled: true);
        coordinator.SetRootSessionId("root-a");
        coordinator.SetUiAttached(true);
        coordinator.AppendTranscript(new VoiceTranscriptEvent(
            "event", "assistant", "memory-only", true, DateTimeOffset.UnixEpoch));
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

    private sealed class AppServerHarness
    {
        private readonly ChannelLineReader _reader = new();
        private readonly Action? _onDispose;
        private readonly bool _requestDuringInitialize;

        public AppServerHarness(Action? onDispose = null, bool requestDuringInitialize = false)
        {
            _onDispose = onDispose;
            _requestDuringInitialize = requestDuringInitialize;
        }

        public CodexAppServerClient CreateClient() =>
            CodexAppServerClient.AttachForTesting(
                _reader,
                new AutoReplyWriter(_reader, _requestDuringInitialize),
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

        public AutoReplyWriter(ChannelLineReader reader, bool requestDuringInitialize)
        {
            _reader = reader;
            _requestDuringInitialize = requestDuringInitialize;
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
