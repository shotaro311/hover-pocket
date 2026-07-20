using System.Text.Json;
using System.Diagnostics;
using HoverPocket.Shell.Bridge;
using HoverPocket.Shell.Verification;

namespace HoverPocket.Shell.Providers.Controls;

internal sealed class ControlsVerifier
{
    private readonly bool _changeBrightness;
    private readonly bool _togglePlayback;
    private readonly bool _verifyLivePreview;
    private readonly bool _verifyLivePreviewFallback;
    private readonly List<string> _failures = [];

    public ControlsVerifier(
        bool changeBrightness = false,
        bool togglePlayback = false,
        bool verifyLivePreview = false,
        bool verifyLivePreviewFallback = false)
    {
        _changeBrightness = changeBrightness;
        _togglePlayback = togglePlayback;
        _verifyLivePreview = verifyLivePreview;
        _verifyLivePreviewFallback = verifyLivePreviewFallback;
    }

    public int Run()
    {
        try
        {
            Task.Run(RunAsync).GetAwaiter().GetResult();
        }
        catch (Exception ex)
        {
            _failures.Add($"unexpected exception: {ex.GetType().Name}: {ex.Message}");
        }

        if (_failures.Count == 0)
        {
            VerifyConsole.WriteLine("controls_verify=ok");
            return 0;
        }

        VerifyConsole.WriteLine("controls_verify=failed");
        foreach (var failure in _failures)
        {
            VerifyConsole.WriteLine($"controls_failure={failure}");
        }

        return 1;
    }

    private async Task RunAsync()
    {
        await VerifyDeterministicFlowAsync();
        await VerifyBrightnessDetectionRaceAsync();
        using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        await VerifyLiveVolumeAsync(cancellation.Token);
        await VerifyLiveDisplaysAsync(cancellation.Token);
        var media = await VerifyLiveMediaAsync(cancellation.Token);
        await VerifyFallbackPathsAsync(media, cancellation.Token);
        if (_verifyLivePreview)
        {
            await VerifyLivePreviewAsync(media, cancellation.Token);
        }
    }

    private async Task VerifyDeterministicFlowAsync()
    {
        var volume = new FakeVolumeService();
        var brightness = new FakeBrightnessService();
        var media = new FakeMediaService();
        using var controller = new ControlsBridgeController(volume, brightness, media, new FakePreviewService());

        var initial = await controller.GetSnapshotAsync(CancellationToken.None);
        if (!initial.Volume.Available || initial.Volume.Value != 40 || initial.Displays.Count != 1 || !initial.Media.Available)
        {
            _failures.Add("deterministic initial state did not combine all controls services");
        }

        var cachedReadCounts = (volume.ReadCount, brightness.ReadCount, media.ReadCount);
        _ = await controller.GetSnapshotAsync(CancellationToken.None);
        if (cachedReadCounts != (volume.ReadCount, brightness.ReadCount, media.ReadCount))
        {
            _failures.Add("deterministic immediate refresh did not reuse the Controls snapshot cache");
        }

        var changedVolume = await controller.SetVolumeAsync(72, CancellationToken.None);
        if (changedVolume.Volume.Value != 72)
        {
            _failures.Add("deterministic volume set did not read back the applied value");
        }

        var muted = await controller.ToggleMuteAsync(CancellationToken.None);
        if (!muted.Volume.Muted)
        {
            _failures.Add("deterministic mute toggle did not read back muted=true");
        }

        var brightnessReadsBeforeSet = brightness.ReadCount;
        var volumeReadsBeforeBrightnessSet = volume.ReadCount;
        var mediaReadsBeforeBrightnessSet = media.ReadCount;
        var changedBrightness = await controller.SetBrightnessAsync("display-1", 63, CancellationToken.None);
        if (changedBrightness.Displays.Single().Value != 63
            || brightness.ReadCount != brightnessReadsBeforeSet
            || volume.ReadCount != volumeReadsBeforeBrightnessSet
            || media.ReadCount != mediaReadsBeforeBrightnessSet)
        {
            _failures.Add(
                $"deterministic brightness set performed an unrelated refresh: "
                + $"value={changedBrightness.Displays.Single().Value}, "
                + $"brightness_reads={brightnessReadsBeforeSet}->{brightness.ReadCount}, "
                + $"volume_reads={volumeReadsBeforeBrightnessSet}->{volume.ReadCount}, "
                + $"media_reads={mediaReadsBeforeBrightnessSet}->{media.ReadCount}");
        }

        VerifyBridgeSerialization(changedBrightness);

        var paused = await controller.ExecuteMediaCommandAsync("playPause", null, CancellationToken.None);
        var rate = await controller.ExecuteMediaCommandAsync("rate", 1.5, CancellationToken.None);
        var seek = await controller.ExecuteMediaCommandAsync("seekRelative", 10, CancellationToken.None);
        var previous = await controller.ExecuteMediaCommandAsync("previous", null, CancellationToken.None);
        var next = await controller.ExecuteMediaCommandAsync("next", null, CancellationToken.None);
        if (paused.Media.IsPlaying
            || Math.Abs(rate.Media.PlaybackRate - 1.5) > 0.001
            || seek.Media.PositionSeconds != 30
            || !previous.Media.Available
            || !next.Media.Available)
        {
            _failures.Add("deterministic media commands did not return confirmed state");
        }

        await controller.SetActiveAsync(true);
        await controller.SetActiveAsync(false);
        if (volume.MonitorStartCount != 1
            || volume.MonitorStopCount != 1
            || media.MonitorStartCount != 1
            || media.MonitorStopCount != 1)
        {
            _failures.Add("deterministic Controls lifecycle did not start/stop monitoring exactly once");
        }

        VerifyConsole.WriteLine("controls_deterministic=ok");
    }

    private async Task VerifyBrightnessDetectionRaceAsync()
    {
        var brightness = new FakeBrightnessService(completeDetectionInBackground: true);
        using var controller = new ControlsBridgeController(
            new FakeVolumeService(),
            brightness,
            new FakeMediaService(readDelayMilliseconds: 80),
            new FakePreviewService());
        var snapshot = await controller.GetSnapshotAsync(CancellationToken.None);
        var display = snapshot.Displays.SingleOrDefault();
        if (display is not { Supported: true, Value: 45 })
        {
            _failures.Add(
                "background brightness result was lost while the combined snapshot was still loading");
            return;
        }

        VerifyConsole.WriteLine("controls_brightness_detection_race=ok");

        var inactiveBrightness = new FakeBrightnessService(completeDetectionInBackground: true);
        using var inactiveController = new ControlsBridgeController(
            new FakeVolumeService(),
            inactiveBrightness,
            new FakeMediaService(),
            new FakePreviewService());
        var detecting = await inactiveController.GetSnapshotAsync(CancellationToken.None);
        if (detecting.Displays.SingleOrDefault()?.Error != "Brightness detection is still running.")
        {
            _failures.Add("inactive brightness race did not begin with the expected temporary state");
            return;
        }

        await Task.Delay(50);
        var merged = await inactiveController.GetSnapshotAsync(CancellationToken.None);
        if (merged.Displays.SingleOrDefault() is not { Supported: true, Value: 45 })
        {
            _failures.Add("cached Controls snapshot did not merge completed background brightness detection");
            return;
        }

        VerifyConsole.WriteLine("controls_brightness_cached_merge=ok");
    }

    private void VerifyBridgeSerialization(ControlsSnapshot snapshot)
    {
        try
        {
            var mediaWithHandle = snapshot.Media with { PreviewWindowHandle = new IntPtr(1234) };
            var json = JsonSerializer.Serialize(snapshot with { Media = mediaWithHandle }, BridgeJson.Options);
            if (json.Contains("previewWindowHandle", StringComparison.OrdinalIgnoreCase))
            {
                _failures.Add("bridge serialization exposed the native media preview handle");
            }
        }
        catch (Exception ex)
        {
            _failures.Add($"bridge serialization failed for media state: {ex.GetType().Name}: {ex.Message}");
        }
    }

    private async Task VerifyLiveVolumeAsync(CancellationToken cancellationToken)
    {
        using var volume = new CoreAudioEndpointService();
        var initial = await volume.ReadAsync(cancellationToken);
        VerifyConsole.WriteLine($"volume_available={initial.Available}");
        VerifyConsole.WriteLine($"volume_value={initial.Value}");
        VerifyConsole.WriteLine($"mute_value={initial.Muted}");
        if (!initial.Available)
        {
            return;
        }

        var readback = await volume.SetVolumeAsync(initial.Value, cancellationToken);
        var verified = readback.Available && Math.Abs(readback.Value - initial.Value) <= 1;
        VerifyConsole.WriteLine($"volume_readback_verified={verified}");
        if (!verified)
        {
            _failures.Add("live volume same-value set/readback failed");
        }

        var muteReadback = await volume.ReadAsync(cancellationToken);
        var muteVerified = muteReadback.Available && muteReadback.Muted == initial.Muted;
        VerifyConsole.WriteLine($"mute_readback_verified={muteVerified}");
        if (!muteVerified)
        {
            _failures.Add("live mute readback was inconsistent");
        }
    }

    private async Task VerifyLiveDisplaysAsync(CancellationToken cancellationToken)
    {
        using var brightness = new MonitorBrightnessService();
        var timer = Stopwatch.StartNew();
        var displays = await brightness.ReadAsync(cancellationToken);
        timer.Stop();
        VerifyConsole.WriteLine($"display_initial_read_ms={timer.Elapsed.TotalMilliseconds:F1}");
        if (timer.Elapsed > TimeSpan.FromMilliseconds(350))
        {
            _failures.Add($"initial brightness response took {timer.Elapsed.TotalMilliseconds:F1}ms");
        }

        var detectionDeadline = DateTimeOffset.UtcNow + TimeSpan.FromSeconds(5);
        while (displays.Any(display => string.Equals(
                   display.Error,
                   "Brightness detection is still running.",
                   StringComparison.Ordinal))
               && DateTimeOffset.UtcNow < detectionDeadline)
        {
            await Task.Delay(100, cancellationToken);
            displays = await brightness.ReadAsync(cancellationToken);
        }

        timer.Restart();
        _ = await brightness.ReadAsync(cancellationToken);
        timer.Stop();
        VerifyConsole.WriteLine($"display_cached_read_ms={timer.Elapsed.TotalMilliseconds:F1}");
        if (timer.Elapsed > TimeSpan.FromMilliseconds(100))
        {
            _failures.Add($"cached brightness read took {timer.Elapsed.TotalMilliseconds:F1}ms");
        }

        VerifyConsole.WriteLine($"display_count={displays.Count}");
        foreach (var display in displays)
        {
            VerifyConsole.WriteLine(
                $"display={display.Name}|id={display.Id}|supported={display.Supported}|value={display.Value?.ToString() ?? ""}|error={display.Error ?? ""}");
        }

        if (!_changeBrightness)
        {
            VerifyConsole.WriteLine("brightness_change=skipped");
            return;
        }

        var target = displays.FirstOrDefault(display => display.Supported && display.Value is not null);
        if (target?.Value is not { } original)
        {
            VerifyConsole.WriteLine("brightness_change=unsupported");
            return;
        }

        var requested = original < 100 ? original + 1 : original - 1;
        try
        {
            timer.Restart();
            var changed = await brightness.SetBrightnessAsync(target.Id, requested, cancellationToken);
            timer.Stop();
            VerifyConsole.WriteLine($"brightness_write_ms={timer.Elapsed.TotalMilliseconds:F1}");
            var accepted = changed.FirstOrDefault(display => string.Equals(display.Id, target.Id, StringComparison.OrdinalIgnoreCase));
            var readback = await brightness.ReadTargetFreshAsync(target.Id, cancellationToken);
            var verified = accepted?.WriteVerified == true
                && readback is { Error: null, Value: { } readbackValue }
                && Math.Abs(readbackValue - requested) <= 1;
            VerifyConsole.WriteLine($"brightness_change_verified={verified}");
            if (!verified)
            {
                _failures.Add("brightness change did not read back the requested value");
            }
        }
        finally
        {
            var restored = await brightness.SetBrightnessAsync(target.Id, original, CancellationToken.None);
            var restoreAccepted = restored.FirstOrDefault(display => string.Equals(display.Id, target.Id, StringComparison.OrdinalIgnoreCase));
            var restoreReadback = await brightness.ReadTargetFreshAsync(target.Id, CancellationToken.None);
            var restoredOk = restoreAccepted?.WriteVerified == true
                && restoreReadback is { Error: null, Value: { } restoreValue }
                && Math.Abs(restoreValue - original) <= 1;
            VerifyConsole.WriteLine($"brightness_restore_verified={restoredOk}");
            if (!restoredOk)
            {
                _failures.Add("brightness restore readback failed");
            }
        }
    }

    private async Task<MediaSessionState> VerifyLiveMediaAsync(CancellationToken cancellationToken)
    {
        using var media = new WindowsMediaSessionService();
        await media.StartMonitoringAsync(cancellationToken);
        var initial = await media.ReadAsync(cancellationToken);
        VerifyConsole.WriteLine($"media_available={initial.Available}");
        VerifyConsole.WriteLine($"media_title={initial.Title}");
        VerifyConsole.WriteLine($"media_artist={initial.Artist}");
        VerifyConsole.WriteLine($"media_source={initial.Source}");
        VerifyConsole.WriteLine($"media_position={initial.PositionSeconds:F2}");
        VerifyConsole.WriteLine($"media_duration={initial.DurationSeconds:F2}");
        VerifyConsole.WriteLine($"media_playing={initial.IsPlaying}");
        VerifyConsole.WriteLine($"media_preview_window={initial.PreviewWindowHandle?.ToString() ?? ""}");

        if (!_togglePlayback)
        {
            VerifyConsole.WriteLine("media_toggle=skipped");
            return initial;
        }

        if (!initial.Available || !initial.CanPlayPause)
        {
            VerifyConsole.WriteLine("media_toggle=unsupported");
            return initial;
        }

        try
        {
            var toggled = await media.ExecuteAsync("playPause", null, cancellationToken);
            var verified = toggled.Available
                && toggled.Error is null
                && toggled.IsPlaying != initial.IsPlaying;
            VerifyConsole.WriteLine($"media_toggle_verified={verified}");
            if (!verified)
            {
                _failures.Add("media play/pause was not confirmed by readback");
            }
        }
        finally
        {
            var restoreCommand = initial.IsPlaying ? "play" : "pause";
            var restored = await media.ExecuteAsync(restoreCommand, null, CancellationToken.None);
            var restoredOk = restored.Available && restored.IsPlaying == initial.IsPlaying;
            VerifyConsole.WriteLine($"media_restore_verified={restoredOk}");
            if (!restoredOk)
            {
                _failures.Add("media playback state restore failed");
            }
        }

        return await media.ReadAsync(cancellationToken);
    }

    private async Task VerifyFallbackPathsAsync(MediaSessionState media, CancellationToken cancellationToken)
    {
        using var preview = new WindowsGraphicsCapturePreviewService();
        await preview.StartAsync(MediaSessionState.Empty(), cancellationToken);
        var noSession = preview.CurrentState;
        var noSessionOk = noSession.Fallback && noSession.Mode == "fallback_no_session";
        VerifyConsole.WriteLine($"preview_no_session_safe={noSessionOk}");
        if (!noSessionOk)
        {
            _failures.Add("preview no-session fallback did not activate");
        }

        var mediaWithoutWindow = media.Available
            ? media with { PreviewWindowHandle = null }
            : FakeMediaState() with { PreviewWindowHandle = null };
        await preview.StartAsync(mediaWithoutWindow, cancellationToken);
        var noWindow = preview.CurrentState;
        var noWindowOk = noWindow.Fallback && noWindow.Mode == "fallback_no_window";
        VerifyConsole.WriteLine($"preview_no_window_safe={noWindowOk}");
        VerifyConsole.WriteLine($"preview_fallback_mode={noWindow.Mode}");
        VerifyConsole.WriteLine($"preview_fallback={noWindow.Fallback}");
        if (!noWindowOk)
        {
            _failures.Add("preview no-window fallback did not activate");
        }

        if (_verifyLivePreviewFallback && !noWindowOk)
        {
            _failures.Add("explicit live preview fallback verification failed");
        }
    }

    private async Task VerifyLivePreviewAsync(MediaSessionState media, CancellationToken cancellationToken)
    {
        var target = media;
        var targetKind = "gsmtc_unique_window";
        if (!media.Available || media.PreviewWindowHandle is null)
        {
            var verificationWindow = MediaWindowResolver.ResolveUniqueProcessWindowForVerification("chrome", "youtube");
            if (verificationWindow is null)
            {
                VerifyConsole.WriteLine("preview_mode=fallback_no_window");
                VerifyConsole.WriteLine("preview_live_verified=false");
                _failures.Add("live preview was requested but no unique media or verification Chrome window was available");
                return;
            }

            targetKind = "verification_unique_chrome_window";
            target = FakeMediaState() with { PreviewWindowHandle = verificationWindow };
        }

        using var preview = new WindowsGraphicsCapturePreviewService();
        using var process = System.Diagnostics.Process.GetCurrentProcess();
        var cpuBefore = process.TotalProcessorTime;
        var wall = System.Diagnostics.Stopwatch.StartNew();
        await preview.StartAsync(target, cancellationToken);
        await Task.Delay(800, cancellationToken);
        wall.Stop();
        process.Refresh();
        var cpuDelta = process.TotalProcessorTime - cpuBefore;
        var normalizedCpu = wall.Elapsed.TotalMilliseconds <= 0
            ? 0
            : cpuDelta.TotalMilliseconds / wall.Elapsed.TotalMilliseconds / Environment.ProcessorCount * 100;
        var state = preview.CurrentState;
        var verified = state.Live && state.Mode == "live" && state.CompleteFrameCount > 0;
        VerifyConsole.WriteLine($"preview_target={targetKind}");
        VerifyConsole.WriteLine($"preview_mode={state.Mode}");
        VerifyConsole.WriteLine($"preview_complete_frames={state.CompleteFrameCount}");
        VerifyConsole.WriteLine($"preview_encoded_frames={state.EncodedFrameCount}");
        VerifyConsole.WriteLine($"preview_replaced_pending_frames={state.ReplacedPendingFrameCount}");
        VerifyConsole.WriteLine("preview_pending_queue_capacity=1");
        VerifyConsole.WriteLine($"preview_measured_fps={state.MeasuredFps:F1}");
        VerifyConsole.WriteLine($"preview_normalized_cpu_percent={normalizedCpu:F2}");
        VerifyConsole.WriteLine($"preview_live_verified={verified}");
        if (!verified)
        {
            _failures.Add("Windows Graphics Capture did not produce a live complete frame");
        }
    }

    private static MediaSessionState FakeMediaState() =>
        new(
            true,
            "Test media",
            "Artist",
            "Browser",
            null,
            20,
            120,
            true,
            1,
            true,
            true,
            true,
            true,
            true,
            "Browser",
            null);

    private sealed class FakeVolumeService : IVolumeEndpointService
    {
        private int _value = 40;
        private bool _muted;

        public int MonitorStartCount { get; private set; }

        public int MonitorStopCount { get; private set; }

        public int ReadCount { get; private set; }

        public event EventHandler<VolumeState>? StateChanged;

        public Task StartMonitoringAsync(CancellationToken cancellationToken)
        {
            MonitorStartCount++;
            return Task.CompletedTask;
        }

        public void StopMonitoring()
        {
            MonitorStopCount++;
        }

        public Task<VolumeState> ReadAsync(CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            ReadCount++;
            return Task.FromResult(new VolumeState(true, _value, _muted));
        }

        public Task<VolumeState> SetVolumeAsync(int value, CancellationToken cancellationToken)
        {
            _value = value;
            StateChanged?.Invoke(this, new VolumeState(true, _value, _muted));
            return ReadAsync(cancellationToken);
        }

        public Task<VolumeState> ToggleMuteAsync(CancellationToken cancellationToken)
        {
            _muted = !_muted;
            return ReadAsync(cancellationToken);
        }
    }

    private sealed class FakeBrightnessService : IMonitorBrightnessService
    {
        private readonly bool _completeDetectionInBackground;
        private int _value = 45;
        private int _detectionStarted;

        public FakeBrightnessService(bool completeDetectionInBackground = false)
        {
            _completeDetectionInBackground = completeDetectionInBackground;
        }

        public int ReadCount { get; private set; }

        public event EventHandler<IReadOnlyList<DisplayBrightnessState>>? StateChanged;

        public Task<IReadOnlyList<DisplayBrightnessState>> ReadAsync(CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            ReadCount++;
            if (_completeDetectionInBackground && Interlocked.Exchange(ref _detectionStarted, 1) == 0)
            {
                _ = Task.Run(async () =>
                {
                    await Task.Delay(20);
                    StateChanged?.Invoke(this,
                        [new DisplayBrightnessState("display-1", "Display", true, _value)]);
                });
                return Task.FromResult<IReadOnlyList<DisplayBrightnessState>>(
                    [new DisplayBrightnessState(
                        "display-1",
                        "Display",
                        false,
                        null,
                        "Brightness detection is still running.")]);
            }

            return Task.FromResult<IReadOnlyList<DisplayBrightnessState>>(
                [new DisplayBrightnessState("display-1", "Display", true, _value)]);
        }

        public Task<IReadOnlyList<DisplayBrightnessState>> SetBrightnessAsync(
            string displayId,
            int value,
            CancellationToken cancellationToken)
        {
            if (displayId == "display-1")
            {
                _value = value;
            }

            IReadOnlyList<DisplayBrightnessState> result =
                [new DisplayBrightnessState("display-1", "Display", true, _value, WriteVerified: true)];
            StateChanged?.Invoke(this, result);
            return Task.FromResult(result);
        }
    }

    private sealed class FakeMediaService : IMediaSessionService
    {
        private readonly int _readDelayMilliseconds;
        private bool _isPlaying = true;
        private double _position = 20;
        private double _rate = 1;

        public FakeMediaService(int readDelayMilliseconds = 0)
        {
            _readDelayMilliseconds = readDelayMilliseconds;
        }

        public int MonitorStartCount { get; private set; }

        public int MonitorStopCount { get; private set; }

        public int ReadCount { get; private set; }

        public event EventHandler<MediaSessionState>? StateChanged;

        public Task StartMonitoringAsync(CancellationToken cancellationToken)
        {
            MonitorStartCount++;
            return Task.CompletedTask;
        }

        public void StopMonitoring()
        {
            MonitorStopCount++;
        }

        public async Task<MediaSessionState> ReadAsync(CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (_readDelayMilliseconds > 0)
            {
                await Task.Delay(_readDelayMilliseconds, cancellationToken);
            }

            ReadCount++;
            return FakeMediaState() with
            {
                PositionSeconds = _position,
                IsPlaying = _isPlaying,
                PlaybackRate = _rate
            };
        }

        public async Task<MediaSessionState> ExecuteAsync(
            string command,
            double? value,
            CancellationToken cancellationToken)
        {
            switch (command.ToLowerInvariant())
            {
                case "playpause":
                    _isPlaying = !_isPlaying;
                    break;
                case "rate":
                    _rate = value ?? _rate;
                    break;
                case "seekrelative":
                    _position += value ?? 0;
                    break;
                case "seekabsolute":
                    _position = value ?? _position;
                    break;
            }

            var state = await ReadAsync(cancellationToken);
            StateChanged?.Invoke(this, state);
            return state;
        }
    }

    private sealed class FakePreviewService : IMediaPreviewService
    {
        public event EventHandler<MediaPreviewState>? StateChanged;

        public event EventHandler<MediaPreviewFrame>? FrameArrived
        {
            add { }
            remove { }
        }

        public MediaPreviewState CurrentState { get; private set; } = MediaPreviewState.Inactive;

        public Task StartAsync(MediaSessionState media, CancellationToken cancellationToken)
        {
            CurrentState = MediaPreviewState.FallbackState("fallback_no_window");
            StateChanged?.Invoke(this, CurrentState);
            return Task.CompletedTask;
        }

        public void Stop()
        {
            CurrentState = MediaPreviewState.Inactive;
        }
    }
}
