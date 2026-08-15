using System.Text.Json;
using HoverPocket.Shell.Capabilities;
using HoverPocket.Shell.Configuration;
using HoverPocket.Shell.Providers;
using HoverPocket.Shell.Providers.AiLane;
using HoverPocket.Shell.Providers.Clipboard;
using HoverPocket.Shell.Providers.CodexVoice;
using HoverPocket.Shell.Providers.Sticky;
using HoverPocket.Shell.Providers.Timer;
using HoverPocket.Shell.Services;
using HoverPocket.Shell.Windows;

namespace HoverPocket.Shell.Verification;

internal sealed class VoiceE2EIsolationVerifier
{
    private static readonly HashSet<string> ReceiptAllowlist = new(StringComparer.Ordinal)
    {
        "schemaVersion",
        "availability",
        "featureEnabled",
        "sessionStatus",
        "sessionCount",
        "rootThreadPresent",
        "transportAttached",
        "appServerProcessPresent",
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
            VerifyIsolationMode(root);
            VerifySingleInstanceNames();
            VerifySafeStopEvent();
            VerifyWebRuntimeContract();

            var options = StartupOptions.Parse(
            [
                HoverPocketApplicationData.VoiceE2EFlag,
                HoverPocketApplicationData.VoiceE2ERootFlag,
                root
            ]);
            var applicationData = HoverPocketApplicationData.ResolveForBuild(options, debugBuild: true);
            VerifyPersistenceAndSafeDefaults(applicationData);
            VerifyReceipt(applicationData);
            VerifyExternalIntegrationsDisabled(applicationData);
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
                "PASS voice-e2e-isolation verify: Debug-only fresh temp root, Release rejects E2E flags, distinct IPC, isolated persistence, safe defaults, OAuth/updater disabled, receipt allowlist/redaction/atomic transitions/safe close/feature-off");
            return 0;
        }

        VerifyConsole.WriteLine("FAIL voice-e2e-isolation verify:");
        foreach (var failure in _failures)
        {
            VerifyConsole.WriteLine($"- {failure}");
        }

        return 1;
    }

    private void VerifyIsolationMode(string root)
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
        Check(!debug.ExternalIntegrationsEnabled, "Debug isolated mode left external integrations enabled");

        CheckRejected(
            requested,
            debugBuild: false,
            "Release accepted the Voice E2E flags");
        CheckRejected(
            StartupOptions.Parse([HoverPocketApplicationData.VoiceE2EFlag]),
            debugBuild: false,
            "Release accepted --voice-e2e without a root");
        CheckRejected(
            StartupOptions.Parse([HoverPocketApplicationData.VoiceE2ERootFlag, root]),
            debugBuild: false,
            "Release accepted --voice-e2e-root without the explicit mode flag");
        CheckRejected(
            StartupOptions.Parse([HoverPocketApplicationData.VoiceE2ERootFlag]),
            debugBuild: false,
            "Release accepted an empty --voice-e2e-root flag");

        var releaseProduction = HoverPocketApplicationData.ResolveForBuild(
            StartupOptions.Parse([]),
            debugBuild: false);
        Check(!releaseProduction.IsIsolatedVoiceE2E, "Release without E2E flags did not resolve production mode");

#if DEBUG
        var compiled = HoverPocketApplicationData.Resolve(requested);
        Check(compiled.IsIsolatedVoiceE2E, "compiled Debug resolver did not enable isolation");
#else
        CheckRejectedCompiled(requested, "compiled Release resolver accepted E2E flags");
#endif

        CheckRejected(
            StartupOptions.Parse([HoverPocketApplicationData.VoiceE2EFlag]),
            debugBuild: true,
            "explicit E2E flag without root was accepted");
        CheckRejected(
            StartupOptions.Parse([HoverPocketApplicationData.VoiceE2ERootFlag, root]),
            debugBuild: true,
            "isolated root without explicit flag was accepted");
        CheckRejected(
            StartupOptions.Parse([HoverPocketApplicationData.VoiceE2ERootFlag]),
            debugBuild: true,
            "empty isolated root flag without explicit mode was accepted");

        var outsideRoot = Path.Combine(
            Path.GetPathRoot(root) ?? "C:\\",
            HoverPocketApplicationData.VoiceE2ERootPrefix + Guid.NewGuid().ToString("N"));
        CheckRejected(
            StartupOptions.Parse(
            [
                HoverPocketApplicationData.VoiceE2EFlag,
                HoverPocketApplicationData.VoiceE2ERootFlag,
                outsideRoot
            ]),
            debugBuild: true,
            "root outside system temp was accepted");

        var nonFreshRoot = Path.Combine(
            Path.GetTempPath(),
            HoverPocketApplicationData.VoiceE2ERootPrefix + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(nonFreshRoot);
        try
        {
            File.WriteAllText(Path.Combine(nonFreshRoot, "occupied"), "verify");
            CheckRejected(
                StartupOptions.Parse(
                [
                    HoverPocketApplicationData.VoiceE2EFlag,
                    HoverPocketApplicationData.VoiceE2ERootFlag,
                    nonFreshRoot
                ]),
                debugBuild: true,
                "non-fresh isolated root was accepted");
        }
        finally
        {
            Directory.Delete(nonFreshRoot, recursive: true);
        }
    }

    private void VerifySingleInstanceNames()
    {
        var secondInstanceProbe = StartupOptions.Parse(["--second-instance-probe"]);
        Check(
            secondInstanceProbe.SecondInstanceProbe && secondInstanceProbe.IsVerify,
            "second-instance probe did not select verifier isolation");

        var names = new[]
        {
            SingleInstanceNames.Production,
            SingleInstanceNames.Verification,
            SingleInstanceNames.VoiceE2E
        };
        Check(
            names.Select(item => item.MutexName).Distinct(StringComparer.Ordinal).Count() == names.Length,
            "Voice E2E mutex was not distinct from product/verifier mutexes");
        Check(
            names.Select(item => item.ShowPanelEventName).Distinct(StringComparer.Ordinal).Count() == names.Length,
            "Voice E2E open-request event was not distinct from product/verifier events");
        Check(
            SingleInstanceNames.Production.StopEventName is null
            && SingleInstanceNames.Verification.StopEventName is null
            && SingleInstanceNames.VoiceE2E.StopEventName is { Length: > 0 },
            "Voice E2E safe-stop event was not isolated from product/verifier IPC");
        Check(
            !SingleInstanceNames.VoiceE2E.MutexName.Contains("Shell.SingleInstance", StringComparison.Ordinal)
            && !SingleInstanceNames.VoiceE2E.ShowPanelEventName.Contains("Shell.ShowPanel", StringComparison.Ordinal),
            "Voice E2E IPC retained a product IPC name");
    }

    private void VerifyWebRuntimeContract()
    {
        var scriptPath = Path.Combine(AppContext.BaseDirectory, "ui", "voice", "voice-lane.js");
        var appScriptPath = Path.Combine(AppContext.BaseDirectory, "ui", "js", "app.js");
        if (!File.Exists(scriptPath))
        {
            _failures.Add("deployed Voice WebView2 runtime script was missing");
            return;
        }

        if (!File.Exists(appScriptPath))
        {
            _failures.Add("deployed panel WebView2 application script was missing");
            return;
        }

        var script = File.ReadAllText(scriptPath);
        var appScript = File.ReadAllText(appScriptPath);
        var requiredFragments = new[]
        {
            "let operationEpoch = 0;",
            "if (epoch !== operationEpoch)",
            "navigator.mediaDevices.getUserMedia",
            "remoteAudio.play()",
            "remoteAudioPlaybackSucceeded",
            "remoteAudioPlaybackFailed",
            "microphoneAcquired",
            "microphoneStopped",
            "remoteAudioTrackReceived",
            "remoteAudioTrackStopped",
            "track.addEventListener(\"ended\"",
            "codexVoice.transportAttached",
            "codexVoice.transportDetached",
            "const shouldStopPendingNativeStart = sessionStarting && !transportAttached;",
            "if (shouldStopPendingNativeStart)",
            "request(\"codexVoice.stop\").catch(() => {});",
            "export function handleVoiceRuntimeReset(request)",
            "cleanupTransport(request, true)",
            "notifyMediaEvent(request, \"safeClose\")"
        };
        foreach (var fragment in requiredFragments)
        {
            Check(script.Contains(fragment, StringComparison.Ordinal), $"Voice WebView2 runtime contract was missing: {fragment}");
        }

        Check(
            !script.Contains("remoteAudio.play().catch(() => {})", StringComparison.Ordinal),
            "Voice WebView2 runtime swallowed playback outcome");
        Check(
            appScript.Contains("on(\"codexVoice.runtimeReset\"", StringComparison.Ordinal)
            && appScript.Contains("handleVoiceRuntimeReset(request);", StringComparison.Ordinal),
            "panel WebView2 runtime did not bind the explicit Voice runtime reset event");
    }

    private void VerifySafeStopEvent()
    {
        if (!SingleInstanceGate.TryAcquire(SingleInstanceNames.VoiceE2E, out var gate)
            || gate is null)
        {
            _failures.Add("Voice E2E safe-stop verifier could not acquire isolated IPC");
            return;
        }

        using (gate)
        using (var observed = new ManualResetEventSlim())
        {
            gate.StopRequested += (_, _) => observed.Set();
            using var stopEvent = EventWaitHandle.OpenExisting(
                SingleInstanceNames.VoiceE2E.StopEventName!);
            stopEvent.Set();
            Check(observed.Wait(TimeSpan.FromSeconds(2)), "Voice E2E safe-stop event was not delivered");
        }
    }

    private void VerifyPersistenceAndSafeDefaults(HoverPocketApplicationData applicationData)
    {
        foreach (var path in applicationData.PersistentDirectories)
        {
            Check(IsUnderRoot(applicationData.RootDirectory, path), $"persistent path escaped isolation: {Path.GetFileName(path)}");
        }

        Check(IsUnderRoot(applicationData.RootDirectory, applicationData.SettingsPath), "settings path escaped isolation");
        Check(IsUnderRoot(applicationData.RootDirectory, applicationData.VoiceE2EReceiptPath), "receipt path escaped isolation");

        var registry = ProviderRegistry.CreateDefault();
        var settingsStore = new UserSettingsStore(applicationData);
        var settings = settingsStore.Load(registry.ProviderIds);
        Check(settings.AiNativeEnabled, "isolated default did not enable AI-native");
        Check(settings.CodexVoiceEnabled, "isolated default did not enable Voice");
        Check(settings.CodexVoiceLayoutMode == VoiceLaneLayoutMode.Compact, "isolated default was not Compact");
        Check(!settings.CodexVoiceAutoListen, "isolated default enabled auto-listen");
        Check(!settings.CodexVoiceCalendarReadEnabled, "isolated default enabled Calendar read");
        Check(!settings.AutoCheckForUpdates, "isolated default enabled updater checks");
        Check(!settings.StartWithWindows, "isolated default enabled startup registration");
        Check(settings.ClipboardPrivateMode, "isolated default enabled Clipboard monitoring");
        Check(
            HoverShellController.ShouldKeepPanelOpenForVoiceE2E(applicationData),
            "isolated Voice E2E mode did not retain the panel for explicit UI interaction");
        Check(
            PanelWindow.ShouldExposeToAutomation(applicationData),
            "isolated Voice E2E mode did not expose the panel to UI automation");
        Check(
            !HoverShellController.ShouldRunHealthTimer(applicationData),
            "isolated Voice E2E mode enabled automatic native style repair");
        Check(
            !HoverShellController.ShouldKeepPanelOpenForVoiceE2E(
                HoverPocketApplicationData.ProductionDefault()),
            "production mode retained the panel with the Voice E2E policy");
        Check(
            !PanelWindow.ShouldExposeToAutomation(
                HoverPocketApplicationData.ProductionDefault()),
            "production mode exposed the panel with the Voice E2E automation policy");
        Check(
            HoverShellController.ShouldRunHealthTimer(
                HoverPocketApplicationData.ProductionDefault()),
            "production mode disabled native style repair");

        var sticky = new StickyNotesStore(applicationData.StickyDirectory);
        using var timer = new TimerStore(applicationData.TimerDirectory, enableScheduler: false);
        var clipboard = new ClipboardHistoryStore(applicationData.ClipboardDirectory);
        var aiAudit = new AiLaneAuditLog(applicationData.AiLaneRootDirectory);
        _ = new CapabilityBrokerLedger(applicationData.CapabilityBrokerDirectory);
        _ = new CapabilityBrokerAuditLog(applicationData.CapabilityBrokerDirectory);

        Check(PathEquals(sticky.RootDirectory, applicationData.StickyDirectory), "Sticky store bypassed resolver");
        Check(PathEquals(timer.StorageDirectory, applicationData.TimerDirectory), "Timer store bypassed resolver");
        Check(PathEquals(clipboard.StorageDirectory, applicationData.ClipboardDirectory), "Clipboard store bypassed resolver");
        Check(IsUnderRoot(applicationData.RootDirectory, aiAudit.LogDirectory), "AI audit store bypassed resolver");
    }

    private void VerifyReceipt(HoverPocketApplicationData applicationData)
    {
        var featureOffPath = Path.Combine(applicationData.RootDirectory, "feature-off-receipt.json");
        var featureOffStore = CodexVoiceE2EReceiptStore.CreateForVerifier(featureOffPath);
        featureOffStore.RecordSnapshot(Snapshot(featureEnabled: false));
        featureOffStore.RecordMediaEvent(CodexVoiceMediaEventKind.MicrophoneAcquired);
        Check(!File.Exists(featureOffPath), "feature-off receipt path had a side effect");

        var store = CodexVoiceE2EReceiptStore.CreateForVerifier(applicationData.VoiceE2EReceiptPath);
        var transcript = new[]
        {
            new CodexVoiceTranscriptEntry(
                "secret-thread",
                "user",
                "SECRET_TRANSCRIPT_USER",
                true,
                DateTimeOffset.UtcNow),
            new CodexVoiceTranscriptEntry(
                "secret-thread",
                "assistant",
                "SECRET_TRANSCRIPT_ASSISTANT",
                true,
                DateTimeOffset.UtcNow)
        };
        var sessions = new[]
        {
            new CodexVoiceThreadSummary(
                "secret-thread",
                IsCurrentRoot: true,
                Title: "SECRET_PROVIDER_DATA",
                Detail: "SECRET_TOKEN_SDP_PATH",
                State: CodexVoiceThreadState.Running,
                CreatedAt: DateTimeOffset.UtcNow,
                UpdatedAt: DateTimeOffset.UtcNow)
        };
        var active = Snapshot(
            featureEnabled: true,
            availability: CodexVoiceAvailability.Ready,
            sessionStatus: CodexVoiceSessionStatus.Connected,
            rootThreadId: "secret-thread",
            transportAttached: true,
            transcript: transcript,
            sessions: sessions,
            appServerProcessId: 987654321);
        store.RecordSnapshot(active);
        store.RecordMediaEvent(CodexVoiceMediaEventKind.MicrophoneAcquired);
        store.RecordMediaEvent(CodexVoiceMediaEventKind.RemoteAudioTrackReceived);
        store.RecordMediaEvent(CodexVoiceMediaEventKind.RemoteAudioPlaybackFailed);

        using (var failedPlayback = ReadReceipt(applicationData.VoiceE2EReceiptPath))
        {
            var root = failedPlayback.RootElement;
            Check(root.GetProperty("remoteAudioPlaybackReceived").GetBoolean(), "playback failure was not received");
            Check(!root.GetProperty("remoteAudioPlaybackCurrent").GetBoolean(), "playback failure left playback current");
            Check(!root.GetProperty("remoteAudioPlaybackEver").GetBoolean(), "playback failure was counted as successful ever playback");
            Check(root.GetProperty("lastTransportEvent").GetString() == "remote_audio_playback_failed", "playback failure event was not recorded");
        }

        store.RecordMediaEvent(CodexVoiceMediaEventKind.RemoteAudioPlaybackSucceeded);
        store.RecordMediaEvent(CodexVoiceMediaEventKind.TransportAttached);
        using (var succeededPlayback = ReadReceipt(applicationData.VoiceE2EReceiptPath))
        {
            var root = succeededPlayback.RootElement;
            Check(root.GetProperty("remoteAudioPlaybackCurrent").GetBoolean(), "playback success did not set current");
            Check(root.GetProperty("remoteAudioPlaybackEver").GetBoolean(), "playback success did not set ever");
            VerifyReceiptAllowlistAndRedaction(root, succeededPlayback.RootElement.GetRawText(), applicationData.RootDirectory);
        }

        store.RecordSnapshot(active with { TransportAttached = false });
        store.RecordMediaEvent(CodexVoiceMediaEventKind.SafeClose);
        using (var safelyClosed = ReadReceipt(applicationData.VoiceE2EReceiptPath))
        {
            var root = safelyClosed.RootElement;
            Check(!root.GetProperty("transportAttached").GetBoolean(), "safe close left transport attached");
            Check(!root.GetProperty("microphoneCurrent").GetBoolean(), "safe close left microphone current");
            Check(!root.GetProperty("remoteAudioTrackCurrent").GetBoolean(), "safe close left remote track current");
            Check(!root.GetProperty("remoteAudioPlaybackCurrent").GetBoolean(), "safe close left playback current");
            Check(root.GetProperty("lastTransportEvent").GetString() == "safe_close", "safe close event was not recorded");
        }

        store.RecordMediaEvent(CodexVoiceMediaEventKind.MicrophoneAcquired);
        using (var nextSession = ReadReceipt(applicationData.VoiceE2EReceiptPath))
        {
            var root = nextSession.RootElement;
            Check(!root.GetProperty("remoteAudioTrackReceived").GetBoolean(), "new session retained prior track received state");
            Check(root.GetProperty("remoteAudioTrackEver").GetBoolean(), "new session lost track ever state");
            Check(!root.GetProperty("remoteAudioPlaybackReceived").GetBoolean(), "new session retained prior playback received state");
            Check(root.GetProperty("remoteAudioPlaybackEver").GetBoolean(), "new session lost playback ever state");
        }

        Check(!File.Exists(applicationData.VoiceE2EReceiptPath + ".tmp"), "atomic receipt temp file remained after update");
        Check(CodexVoiceE2EReceiptStore.TryParseMediaEvent("microphoneAcquired", out _), "typed media event parser rejected a known event");
        Check(!CodexVoiceE2EReceiptStore.TryParseMediaEvent("token", out _), "typed media event parser accepted an unknown event");
    }

    private void VerifyReceiptAllowlistAndRedaction(
        JsonElement root,
        string json,
        string isolatedRoot)
    {
        var actual = root.EnumerateObject().Select(property => property.Name).ToHashSet(StringComparer.Ordinal);
        Check(actual.SetEquals(ReceiptAllowlist), "receipt properties did not exactly match the allowlist");
        Check(root.GetProperty("schemaVersion").GetInt32() == 1, "receipt schema version was not 1");
        Check(root.GetProperty("userTranscriptCount").GetInt32() == 1, "user transcript count was incorrect");
        Check(root.GetProperty("assistantTranscriptCount").GetInt32() == 1, "assistant transcript count was incorrect");
        Check(root.GetProperty("completeTranscriptCount").GetInt32() == 2, "complete transcript count was incorrect");
        Check(root.GetProperty("sessionCount").GetInt32() == 1, "session count was incorrect");
        Check(root.GetProperty("rootThreadPresent").GetBoolean(), "root presence was not recorded");
        Check(root.GetProperty("appServerProcessPresent").GetBoolean(), "app-server process presence was not recorded");

        var forbidden = new[]
        {
            "SECRET_TRANSCRIPT_USER",
            "SECRET_TRANSCRIPT_ASSISTANT",
            "SECRET_PROVIDER_DATA",
            "SECRET_TOKEN_SDP_PATH",
            "secret-thread",
            isolatedRoot,
            "987654321",
            "sdp",
            "token",
            "pid",
            "path",
            "provider"
        };
        foreach (var value in forbidden)
        {
            Check(!json.Contains(value, StringComparison.OrdinalIgnoreCase), $"receipt leaked forbidden value: {value}");
        }
    }

    private void VerifyExternalIntegrationsDisabled(HoverPocketApplicationData applicationData)
    {
        var updater = new UpdaterService(applicationData.ExternalIntegrationsEnabled);
        Check(!updater.IsEnabled, "isolated updater was enabled");
        Check(updater.CheckWithPromptsAsync().GetAwaiter().GetResult().Status == "disabled", "isolated updater did not fail closed");

        var oauth = new GoogleOAuthService(enabled: applicationData.ExternalIntegrationsEnabled);
        Check(!oauth.IsEnabled, "isolated OAuth was enabled");
        Check(!oauth.IsConfigured, "isolated OAuth loaded configuration");
        Check(oauth.StoredCredentialStatus() == GoogleOAuthStoredCredentialStatus.Missing, "isolated OAuth read a credential");
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

    private void CheckRejectedCompiled(StartupOptions options, string failure)
    {
        try
        {
            _ = HoverPocketApplicationData.Resolve(options);
            _failures.Add(failure);
        }
        catch (VoiceE2EConfigurationException)
        {
        }
    }

    private void Check(bool condition, string failure)
    {
        if (!condition)
        {
            _failures.Add(failure);
        }
    }

    private static JsonDocument ReadReceipt(string path)
    {
        return JsonDocument.Parse(File.ReadAllBytes(path));
    }

    private static bool IsUnderRoot(string root, string path)
    {
        var normalizedRoot = Path.TrimEndingDirectorySeparator(Path.GetFullPath(root));
        var normalizedPath = Path.GetFullPath(path);
        return normalizedPath.StartsWith(
            normalizedRoot + Path.DirectorySeparatorChar,
            StringComparison.OrdinalIgnoreCase)
            || PathEquals(normalizedRoot, normalizedPath);
    }

    private static bool PathEquals(string left, string right)
    {
        return string.Equals(
            Path.TrimEndingDirectorySeparator(Path.GetFullPath(left)),
            Path.TrimEndingDirectorySeparator(Path.GetFullPath(right)),
            StringComparison.OrdinalIgnoreCase);
    }

    private static CodexVoiceSnapshot Snapshot(
        bool featureEnabled,
        CodexVoiceAvailability availability = CodexVoiceAvailability.Disabled,
        CodexVoiceSessionStatus sessionStatus = CodexVoiceSessionStatus.Idle,
        string? rootThreadId = null,
        bool transportAttached = false,
        IReadOnlyList<CodexVoiceTranscriptEntry>? transcript = null,
        IReadOnlyList<CodexVoiceThreadSummary>? sessions = null,
        int? appServerProcessId = null)
    {
        return new CodexVoiceSnapshot(
            FeatureEnabled: featureEnabled,
            Availability: availability,
            SessionStatus: sessionStatus,
            RootThreadId: rootThreadId,
            TransportAttached: transportAttached,
            IsMuted: false,
            Transcript: transcript ?? Array.Empty<CodexVoiceTranscriptEntry>(),
            Sessions: sessions ?? Array.Empty<CodexVoiceThreadSummary>(),
            LastErrorCode: "SECRET_ERROR",
            AppServerProcessId: appServerProcessId,
            RestartAttempt: 0,
            VoiceCount: 19);
    }
}
