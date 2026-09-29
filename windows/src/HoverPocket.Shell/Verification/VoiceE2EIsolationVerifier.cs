using System.Text.Json;
using HoverPocket.Shell.Configuration;
using HoverPocket.Shell.Providers;
using HoverPocket.Shell.Services;
using HoverPocket.Shell.Voice;

namespace HoverPocket.Shell.Verification;

internal sealed class VoiceE2EIsolationVerifier
{
    private static readonly HashSet<string> ReceiptAllowlist = new(StringComparer.Ordinal)
    {
        "schemaVersion",
        "providerId",
        "availability",
        "featureEnabled",
        "sessionStatus",
        "rootSessionPresent",
        "transportAttached",
        "realtimeAttached",
        "microphoneAcquired",
        "microphoneCurrent",
        "remoteAudioTrackReceived",
        "remoteAudioTrackCurrent",
        "remoteAudioTrackEver",
        "remoteAudioPlaybackReceived",
        "remoteAudioPlaybackCurrent",
        "remoteAudioPlaybackEver",
        "userTranscriptCount",
        "assistantTranscriptCount",
        "completeTranscriptCount",
        "timerCapabilityReadbackVerified",
        "physicalMediaUserConfirmed",
        "credentialCurrent",
        "lastTransportEvent"
    };

    private readonly List<string> _failures = [];

    public int Run()
    {
        var root = Path.Combine(
            Path.GetTempPath(),
            HoverPocketApplicationData.VoiceE2ERootPrefix + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var data = VerifyIsolation(root);
            VerifyPathsAndDefaults(data);
            VerifyCredentialStore(data);
            VerifySingleInstanceNames();
            VerifyReceipt(data);
            VerifyWebRuntimeContract();
        }
        catch (Exception exception)
        {
            _failures.Add($"unexpected verifier exception: {exception.GetType().Name}");
        }
        finally
        {
            try
            {
                Directory.Delete(root, recursive: true);
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                _failures.Add("temporary verifier root cleanup failed");
            }
        }

        if (_failures.Count == 0)
        {
            VerifyConsole.WriteLine(
                "PASS voice-e2e-isolation verify: Debug-only fresh temp root, verifier mutual exclusion, Release rejection, isolated IPC/storage/credentials/WebView2, safe defaults, external integration denial, allowlist-only atomic receipt and explicit media teardown");
            return 0;
        }
        VerifyConsole.WriteLine("FAIL voice-e2e-isolation verify:");
        foreach (var failure in _failures)
        {
            VerifyConsole.WriteLine($"- {failure}");
        }
        return 1;
    }

    private HoverPocketApplicationData VerifyIsolation(string root)
    {
        var requested = StartupOptions.Parse(
        [
            HoverPocketApplicationData.VoiceE2EFlag,
            HoverPocketApplicationData.VoiceE2ERootFlag,
            root
        ]);
        var debug = HoverPocketApplicationData.ResolveForBuild(requested, debugBuild: true);
        Check(debug.IsIsolatedVoiceE2E, "Debug did not enable explicit Voice E2E isolation");
        Check(PathEquals(root, debug.RootDirectory), "Debug did not resolve the explicit isolated root");
        Check(!debug.ExternalIntegrationsEnabled, "isolated mode left external integrations enabled");
        CheckRejected(requested, debugBuild: false, "Release accepted Voice E2E flags");
        CheckRejected(
            StartupOptions.Parse([HoverPocketApplicationData.VoiceE2EFlag]),
            debugBuild: true,
            "E2E flag without root was accepted");
        CheckRejected(
            StartupOptions.Parse([HoverPocketApplicationData.VoiceE2ERootFlag, root]),
            debugBuild: true,
            "E2E root without explicit mode was accepted");
        foreach (var verifier in new[] { "shell", "display", "ui" })
        {
            CheckRejected(
                StartupOptions.Parse(
                [
                    HoverPocketApplicationData.VoiceE2EFlag,
                    HoverPocketApplicationData.VoiceE2ERootFlag,
                    root,
                    "--verify",
                    verifier
                ]),
                debugBuild: true,
                $"Voice E2E was accepted together with the {verifier} verifier");
        }

        var occupied = Path.Combine(
            Path.GetTempPath(),
            HoverPocketApplicationData.VoiceE2ERootPrefix + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(occupied);
        try
        {
            File.WriteAllText(Path.Combine(occupied, "occupied"), "verify");
            CheckRejected(
                StartupOptions.Parse(
                [
                    HoverPocketApplicationData.VoiceE2EFlag,
                    HoverPocketApplicationData.VoiceE2ERootFlag,
                    occupied
                ]),
                debugBuild: true,
                "non-fresh isolated root was accepted");
        }
        finally
        {
            Directory.Delete(occupied, recursive: true);
        }
        return debug;
    }

    private void VerifyPathsAndDefaults(HoverPocketApplicationData data)
    {
        foreach (var path in data.PersistentDirectories)
        {
            Check(IsUnderRoot(data.RootDirectory, path), $"persistent path escaped root: {Path.GetFileName(path)}");
        }
        Check(IsUnderRoot(data.RootDirectory, data.SettingsPath), "settings path escaped root");
        Check(IsUnderRoot(data.RootDirectory, data.VoiceE2EReceiptPath), "receipt path escaped root");

        var production = HoverPocketApplicationData.ProductionDefault();
        Check(
            !string.Equals(
                data.OpenAIRealtimeCredentialTarget,
                production.OpenAIRealtimeCredentialTarget,
                StringComparison.Ordinal),
            "isolated OpenAI credential target matched production");
        Check(
            !string.Equals(
                data.GoogleOAuthCredentialTarget,
                production.GoogleOAuthCredentialTarget,
                StringComparison.Ordinal),
            "isolated Google OAuth target matched production");
        Check(
            !data.OpenAIRealtimeCredentialTarget.Contains(data.RootDirectory, StringComparison.OrdinalIgnoreCase),
            "credential target exposed the isolated path");

        var registry = ProviderRegistry.CreateDefault();
        var settings = data.CreateVoiceE2EDefaultSettings(registry.ProviderIds);
        Check(!settings.StartWithWindows, "isolated default enabled startup registration");
        Check(!settings.AutoCheckForUpdates, "isolated default enabled update checks");
        Check(!settings.AiNativeEnabled, "isolated default enabled AI-native execution");
        Check(!settings.VoiceEnabled, "isolated default enabled Voice before explicit Codex sign-in");
        Check(
            settings.VoiceProviderId == VoiceProviderIds.CodexAppServer,
            "isolated default did not preselect Codex app-server");
        Check(!settings.VoiceCalendarAccessGranted, "isolated default enabled Calendar access");
        Check(settings.ClipboardPrivateMode, "isolated default enabled Clipboard monitoring");
        Check(
            settings.ProviderVisibility.TryGetValue("timer", out var timerVisible)
            && timerVisible
            && settings.ProviderVisibility
                .Where(item => !string.Equals(item.Key, "timer", StringComparison.OrdinalIgnoreCase))
                .All(item => !item.Value),
            "isolated defaults did not confine the visible provider to Timer");
    }

    private void VerifySingleInstanceNames()
    {
        var names = new[]
        {
            SingleInstanceNames.Production,
            SingleInstanceNames.Verification,
            SingleInstanceNames.VoiceE2E
        };
        Check(
            names.Select(item => item.MutexName).Distinct(StringComparer.Ordinal).Count() == names.Length,
            "Voice E2E mutex was not distinct");
        Check(
            names.Select(item => item.ShowPanelEventName).Distinct(StringComparer.Ordinal).Count() == names.Length,
            "Voice E2E show event was not distinct");
        Check(
            SingleInstanceNames.Production.StopEventName is null
            && SingleInstanceNames.Verification.StopEventName is null
            && SingleInstanceNames.VoiceE2E.StopEventName is { Length: > 0 },
            "Voice E2E stop event was not isolated");
    }

    private void VerifyCredentialStore(HoverPocketApplicationData data)
    {
        var store = OpenAIRealtimeCredentialStoreFactory.Create(data);
        Check(
            store is EphemeralOpenAIRealtimeCredentialStore,
            "Voice E2E did not select the process-memory credential store");
        using (var input = new OpenAIRealtimeApiKey("sk-e2e-verifier-0123456789abcdef"))
        {
            store.Save(input);
        }
        Check(store.HasCredential(), "ephemeral credential save was not readable");
        using (var loaded = store.Load())
        {
            Check(
                loaded?.Reveal() == "sk-e2e-verifier-0123456789abcdef",
                "ephemeral credential readback did not match");
        }
        store.Delete();
        Check(!store.HasCredential(), "ephemeral credential delete did not clear memory");
        Check(
            OpenAIRealtimeCredentialStoreFactory.Create(
                HoverPocketApplicationData.ProductionDefault()) is OpenAIRealtimeCredentialStore,
            "production stopped using Windows Credential Manager");
    }

    private void VerifyReceipt(HoverPocketApplicationData data)
    {
        var store = new VoiceE2EReceiptStore(data.VoiceE2EReceiptPath);
        var now = DateTimeOffset.UtcNow;
        var snapshot = new CodexVoiceSnapshot(
            CodexVoiceAvailability.Ready,
            CodexVoiceSessionStatus.Idle,
            VoiceActivity.Listening,
            Muted: false,
            UiAttached: true,
            TransportAttached: true,
            RealtimeAttached: true,
            AppServerProcessId: null,
            RootSessionId: "SECRET_ROOT_SESSION",
            Transcript:
            [
                new VoiceTranscriptEvent(
                    "SECRET_EVENT",
                    "SECRET_ROOT_SESSION",
                    "user",
                    "SECRET_TRANSCRIPT_USER",
                    IsFinal: true,
                    Timestamp: now),
                new VoiceTranscriptEvent(
                    "SECRET_EVENT_2",
                    "SECRET_ROOT_SESSION",
                    "assistant",
                    "SECRET_TRANSCRIPT_ASSISTANT",
                    IsFinal: true,
                    Timestamp: now)
            ],
            TranscriptPreview: "SECRET_PREVIEW",
            Sessions:
            [
                new AgentSessionSummary(
                    SessionId: "SECRET_SESSION",
                    RootSessionId: "SECRET_ROOT_SESSION",
                    ParentSessionId: null,
                    Title: "SECRET_TITLE",
                    Status: AgentSessionStatus.Running,
                    SafeSummary: "SECRET_SUMMARY",
                    Progress: null,
                    UpdatedAt: now)
            ],
            VisibleSessionCount: 1,
            LastErrorCode: "SECRET_ERROR",
            RestartAttempt: 0);
        store.RecordSnapshot(
            snapshot,
            featureEnabled: true,
            providerId: VoiceProviderIds.CodexAppServer,
            credentialCurrent: false);

        var mismatchPath = Path.Combine(data.RootDirectory, "voice-e2e-provider-mismatch.json");
        var mismatchStore = new VoiceE2EReceiptStore(mismatchPath);
        mismatchStore.RecordSnapshot(
            snapshot,
            featureEnabled: true,
            providerId: VoiceProviderIds.OpenAIRealtimeByok,
            credentialCurrent: true);
        var mismatchLease = mismatchStore.BeginMediaAttempt();
        Check(
            mismatchStore.RecordRendererMediaEvent(
                mismatchLease,
                VoiceE2EMediaEventKind.MicrophoneAcquired),
            "provider mismatch fixture rejected microphone event");
        Check(
            mismatchStore.RecordRendererMediaEvent(
                mismatchLease,
                VoiceE2EMediaEventKind.RemoteAudioTrackReceived),
            "provider mismatch fixture rejected remote track event");
        Check(
            mismatchStore.RecordRendererMediaEvent(
                mismatchLease,
                VoiceE2EMediaEventKind.RemoteAudioPlaybackSucceeded),
            "provider mismatch fixture rejected remote playback event");
        mismatchStore.RecordMediaEvent(VoiceE2EMediaEventKind.TransportAttached);
        Check(
            !mismatchStore.CanRequestPhysicalMediaConfirmation,
            "BYOK receipt could request Codex-bound physical confirmation");
        Check(
            !mismatchStore.RecordPhysicalMediaUserConfirmation(),
            "BYOK receipt satisfied Codex-bound physical confirmation");
        mismatchStore.RecordSnapshot(
            snapshot,
            featureEnabled: true,
            providerId: VoiceProviderIds.CodexAppServer,
            credentialCurrent: false);
        Check(
            !mismatchStore.CanRequestPhysicalMediaConfirmation,
            "cross-provider media attempt satisfied Codex-bound confirmation");
        var firstLease = store.BeginMediaAttempt();
        Check(
            !store.RecordRendererMediaEvent(
                "stale-media-lease",
                VoiceE2EMediaEventKind.MicrophoneAcquired),
            "receipt accepted an unknown media lease");
        var activeLease = store.BeginMediaAttempt();
        store.RecordSnapshot(
            snapshot,
            featureEnabled: true,
            providerId: VoiceProviderIds.CodexAppServer,
            credentialCurrent: false);
        Check(
            !store.RecordRendererMediaEvent(
                firstLease,
                VoiceE2EMediaEventKind.MicrophoneAcquired),
            "receipt accepted a previous-attempt media lease");
        Check(
            !store.RecordRendererMediaEvent(
                activeLease,
                VoiceE2EMediaEventKind.RemoteAudioPlaybackSucceeded),
            "receipt accepted playback before a remote track");
        Check(
            store.RecordRendererMediaEvent(
                activeLease,
                VoiceE2EMediaEventKind.MicrophoneAcquired),
            "receipt rejected a correlated microphone event");
        Check(
            store.RecordRendererMediaEvent(
                activeLease,
                VoiceE2EMediaEventKind.RemoteAudioTrackReceived),
            "receipt rejected a correlated remote track event");
        Check(
            store.RecordRendererMediaEvent(
                activeLease,
                VoiceE2EMediaEventKind.RemoteAudioPlaybackSucceeded),
            "receipt rejected a correlated remote playback event");
        Check(!store.PhysicalMediaUserConfirmed, "renderer diagnostics forged physical confirmation");
        Check(
            !VoiceE2EReceiptStore.TryParseMediaEvent("physicalMediaUserConfirmed", out _),
            "renderer event parser accepted host-owned physical confirmation");
        store.RecordMediaEvent(VoiceE2EMediaEventKind.TransportAttached);
        Check(store.CanRequestPhysicalMediaConfirmation, "physical media confirmation was not host-gated");
        Check(store.RecordPhysicalMediaUserConfirmation(), "host-owned physical media confirmation failed");
        Check(!store.CanRequestPhysicalMediaConfirmation, "physical media confirmation remained replayable");
        store.RecordTimerCapabilityReadback();

        using (var document = JsonDocument.Parse(File.ReadAllText(data.VoiceE2EReceiptPath)))
        {
            var names = document.RootElement.EnumerateObject()
                .Select(property => property.Name)
                .ToHashSet(StringComparer.Ordinal);
            Check(names.SetEquals(ReceiptAllowlist), "receipt fields escaped the explicit allowlist");
            Check(document.RootElement.GetProperty("microphoneCurrent").GetBoolean(), "receipt missed current microphone");
            Check(document.RootElement.GetProperty("remoteAudioTrackEver").GetBoolean(), "receipt missed remote audio track");
            Check(document.RootElement.GetProperty("remoteAudioPlaybackEver").GetBoolean(), "receipt missed remote playback");
            Check(document.RootElement.GetProperty("userTranscriptCount").GetInt32() == 1, "receipt user transcript count was wrong");
            Check(document.RootElement.GetProperty("assistantTranscriptCount").GetInt32() == 1, "receipt assistant transcript count was wrong");
            Check(document.RootElement.GetProperty("timerCapabilityReadbackVerified").GetBoolean(), "receipt missed verified Timer capability readback");
            Check(document.RootElement.GetProperty("physicalMediaUserConfirmed").GetBoolean(), "receipt missed host-owned physical media confirmation");
            Check(
                document.RootElement.GetProperty("providerId").GetString()
                    == VoiceE2EReceiptStore.ExpectedPhysicalProviderId,
                "receipt provider was not bound to Codex app-server");
        }

        store.RecordSnapshot(
            snapshot,
            featureEnabled: true,
            providerId: VoiceProviderIds.OpenAIRealtimeByok,
            credentialCurrent: true);
        using (var switchedAway = JsonDocument.Parse(File.ReadAllText(data.VoiceE2EReceiptPath)))
        {
            Check(!switchedAway.RootElement.GetProperty("microphoneAcquired").GetBoolean(), "provider switch retained microphone evidence");
            Check(!switchedAway.RootElement.GetProperty("remoteAudioTrackEver").GetBoolean(), "provider switch retained remote track evidence");
            Check(!switchedAway.RootElement.GetProperty("remoteAudioPlaybackEver").GetBoolean(), "provider switch retained remote playback evidence");
            Check(switchedAway.RootElement.GetProperty("userTranscriptCount").GetInt32() == 0, "provider switch retained user transcript evidence");
            Check(switchedAway.RootElement.GetProperty("assistantTranscriptCount").GetInt32() == 0, "provider switch retained assistant transcript evidence");
            Check(!switchedAway.RootElement.GetProperty("timerCapabilityReadbackVerified").GetBoolean(), "provider switch retained Timer evidence");
            Check(!switchedAway.RootElement.GetProperty("physicalMediaUserConfirmed").GetBoolean(), "provider switch retained physical confirmation");
        }
        store.RecordSnapshot(
            snapshot,
            featureEnabled: true,
            providerId: VoiceProviderIds.CodexAppServer,
            credentialCurrent: false);
        store.RecordTimerCapabilityReadback();
        Check(
            !store.CanRequestPhysicalMediaConfirmation,
            "provider roundtrip reused a previous media attempt");
        Check(
            !store.RecordRendererMediaEvent(
                activeLease,
                VoiceE2EMediaEventKind.MicrophoneAcquired),
            "provider roundtrip accepted a previous media lease");
        using (var switchedBack = JsonDocument.Parse(File.ReadAllText(data.VoiceE2EReceiptPath)))
        {
            Check(switchedBack.RootElement.GetProperty("userTranscriptCount").GetInt32() == 0, "provider roundtrip restored stale user transcript evidence");
            Check(switchedBack.RootElement.GetProperty("assistantTranscriptCount").GetInt32() == 0, "provider roundtrip restored stale assistant transcript evidence");
            Check(!switchedBack.RootElement.GetProperty("timerCapabilityReadbackVerified").GetBoolean(), "provider roundtrip restored stale Timer evidence");
        }

        var recoveredLease = store.BeginMediaAttempt();
        store.RecordSnapshot(
            snapshot,
            featureEnabled: true,
            providerId: VoiceProviderIds.CodexAppServer,
            credentialCurrent: false);
        Check(
            store.RecordRendererMediaEvent(
                recoveredLease,
                VoiceE2EMediaEventKind.MicrophoneAcquired),
            "fresh provider-bound attempt rejected microphone evidence");
        Check(
            store.RecordRendererMediaEvent(
                recoveredLease,
                VoiceE2EMediaEventKind.RemoteAudioTrackReceived),
            "fresh provider-bound attempt rejected remote track evidence");
        Check(
            store.RecordRendererMediaEvent(
                recoveredLease,
                VoiceE2EMediaEventKind.RemoteAudioPlaybackSucceeded),
            "fresh provider-bound attempt rejected remote playback evidence");
        store.RecordMediaEvent(VoiceE2EMediaEventKind.TransportAttached);
        Check(
            store.RecordPhysicalMediaUserConfirmation(),
            "fresh provider-bound attempt rejected physical confirmation");
        store.RecordTimerCapabilityReadback();
        using (var recovered = JsonDocument.Parse(File.ReadAllText(data.VoiceE2EReceiptPath)))
        {
            Check(recovered.RootElement.GetProperty("userTranscriptCount").GetInt32() == 1, "fresh provider-bound attempt missed user transcript evidence");
            Check(recovered.RootElement.GetProperty("assistantTranscriptCount").GetInt32() == 1, "fresh provider-bound attempt missed assistant transcript evidence");
            Check(recovered.RootElement.GetProperty("timerCapabilityReadbackVerified").GetBoolean(), "fresh provider-bound attempt missed Timer evidence");
            Check(recovered.RootElement.GetProperty("physicalMediaUserConfirmed").GetBoolean(), "fresh provider-bound attempt missed physical confirmation");
        }
        var payload = File.ReadAllText(data.VoiceE2EReceiptPath);
        Check(!payload.Contains("SECRET_", StringComparison.Ordinal), "receipt leaked transcript/session/error content");
        Check(!File.Exists(data.VoiceE2EReceiptPath + ".tmp"), "receipt left a partial file");

        store.RecordMediaEvent(VoiceE2EMediaEventKind.TransportDetached);
        Check(
            !store.RecordRendererMediaEvent(
                recoveredLease,
                VoiceE2EMediaEventKind.MicrophoneAcquired),
            "receipt accepted a media event after host teardown");
        Check(
            !VoiceE2EReceiptStore.TryParseMediaEvent("safeClose", out _),
            "renderer event parser accepted a host-owned safe-close transition");

        store.RecordShutdown(credentialCurrent: false);
        using var closed = JsonDocument.Parse(File.ReadAllText(data.VoiceE2EReceiptPath));
        Check(!closed.RootElement.GetProperty("microphoneCurrent").GetBoolean(), "safe close retained microphone state");
        Check(!closed.RootElement.GetProperty("remoteAudioTrackCurrent").GetBoolean(), "safe close retained remote track state");
        Check(!closed.RootElement.GetProperty("remoteAudioPlaybackCurrent").GetBoolean(), "safe close retained playback state");
        Check(!closed.RootElement.GetProperty("transportAttached").GetBoolean(), "safe close retained transport state");
        Check(!closed.RootElement.GetProperty("realtimeAttached").GetBoolean(), "safe close retained realtime state");
        Check(!closed.RootElement.GetProperty("credentialCurrent").GetBoolean(), "credential deletion readback was not recorded");
    }

    private void VerifyWebRuntimeContract()
    {
        var scriptPath = Path.Combine(AppContext.BaseDirectory, "ui", "js", "app.js");
        if (!File.Exists(scriptPath))
        {
            _failures.Add("deployed panel WebView2 script was missing");
            return;
        }
        var script = File.ReadAllText(scriptPath);
        foreach (var fragment in new[]
        {
            "voice.mediaEvent",
            "microphoneAcquired",
            "microphoneStopped",
            "remoteAudioTrackReceived",
            "remoteAudioTrackStopped",
            "remoteAudioPlaybackSucceeded",
            "remoteAudioPlaybackFailed",
            "remoteAudioPlaybackStopped",
            "mediaLease",
            "voice.confirmPhysicalMedia"
        })
        {
            Check(script.Contains(fragment, StringComparison.Ordinal), $"WebRTC receipt contract was missing: {fragment}");
        }
        Check(
            !script.Contains("audio.play().catch(() => undefined)", StringComparison.Ordinal),
            "WebRTC runtime swallowed remote audio playback outcome");
    }

    private void CheckRejected(StartupOptions options, bool debugBuild, string failure)
    {
        try
        {
            _ = HoverPocketApplicationData.ResolveForBuild(options, debugBuild);
            _failures.Add(failure);
        }
        catch (VoiceE2EConfigurationException)
        {
        }
    }

    private static bool PathEquals(string left, string right) =>
        string.Equals(
            Path.TrimEndingDirectorySeparator(Path.GetFullPath(left)),
            Path.TrimEndingDirectorySeparator(Path.GetFullPath(right)),
            StringComparison.OrdinalIgnoreCase);

    private static bool IsUnderRoot(string root, string path)
    {
        var normalizedRoot = Path.TrimEndingDirectorySeparator(Path.GetFullPath(root));
        var normalizedPath = Path.GetFullPath(path);
        return PathEquals(normalizedRoot, normalizedPath)
            || normalizedPath.StartsWith(
                normalizedRoot + Path.DirectorySeparatorChar,
                StringComparison.OrdinalIgnoreCase);
    }

    private void Check(bool condition, string failure)
    {
        if (!condition)
        {
            _failures.Add(failure);
        }
    }
}
