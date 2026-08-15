using System.Text.Json;
using System.Runtime.InteropServices;
using HoverPocket.Shell.Bridge;

namespace HoverPocket.Shell.Providers.Controls;

internal sealed class ControlsBridgeController : IDisposable
{
    private static readonly TimeSpan OperationTimeout = TimeSpan.FromMilliseconds(1500);
    private static readonly TimeSpan BrightnessOperationTimeout = TimeSpan.FromSeconds(7);
    private static readonly TimeSpan SnapshotCacheLifetime = TimeSpan.FromMilliseconds(750);
    private static readonly TimeSpan FallbackRefreshInterval = TimeSpan.FromSeconds(10);
    private readonly IVolumeEndpointService _volume;
    private readonly IMonitorBrightnessService _brightness;
    private readonly IMediaSessionService _media;
    private readonly IMediaPreviewService _preview;
    private readonly IMediaSourceActivator _sourceActivator;
    private readonly SemaphoreSlim _activationGate = new(1, 1);
    private readonly SemaphoreSlim _snapshotGate = new(1, 1);
    private CancellationTokenSource? _activeCancellation;
    private Task? _fallbackRefreshTask;
    private ControlsSnapshot? _lastSnapshot;
    private IReadOnlyList<DisplayBrightnessState>? _latestDisplays;
    private bool _active;
    private bool _disposed;

    public ControlsBridgeController(
        IVolumeEndpointService? volume = null,
        IMonitorBrightnessService? brightness = null,
        IMediaSessionService? media = null,
        IMediaPreviewService? preview = null,
        IMediaSourceActivator? sourceActivator = null)
    {
        _volume = volume ?? new CoreAudioEndpointService();
        _brightness = brightness ?? new MonitorBrightnessService();
        _media = media ?? new WindowsMediaSessionService();
        _preview = preview ?? new WindowsGraphicsCapturePreviewService();
        _sourceActivator = sourceActivator ?? new MediaSourceActivator();
        _volume.StateChanged += OnVolumeStateChanged;
        _brightness.StateChanged += OnBrightnessStateChanged;
        _media.StateChanged += OnMediaStateChanged;
        _preview.StateChanged += OnPreviewStateChanged;
        _preview.FrameArrived += OnPreviewFrameArrived;
    }

    public event EventHandler<ControlsSnapshot>? SnapshotChanged;

    public event EventHandler<MediaPreviewState>? PreviewStateChanged;

    public event EventHandler<MediaPreviewFrame>? PreviewFrameArrived;

    public event EventHandler? MediaSourceOpened;

    public void Attach(BridgeDispatcher dispatcher)
    {
        dispatcher.Register("controls.getState", async (_, cancellationToken) => await GetSnapshotAsync(cancellationToken));
        dispatcher.Register("controls.setVolume", HandleSetVolumeAsync);
        dispatcher.Register("controls.toggleMute", HandleToggleMuteAsync);
        dispatcher.Register("controls.setBrightness", HandleSetBrightnessAsync);
        dispatcher.Register("controls.mediaCommand", HandleMediaCommandAsync);
        dispatcher.Register("controls.openMediaSource", HandleOpenMediaSourceAsync);
    }

    public async Task SetActiveAsync(bool active, CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        await _activationGate.WaitAsync(cancellationToken);
        try
        {
            if (_active == active)
            {
                return;
            }

            _active = active;
            if (!active)
            {
                var cancellation = _activeCancellation;
                _activeCancellation = null;
                _fallbackRefreshTask = null;
                // Stop capture while its linked token is still valid. Canceling first can
                // make the frame processor synchronously restart against an active session.
                _preview.Stop();
                cancellation?.Cancel();
                _volume.StopMonitoring();
                _media.StopMonitoring();
                cancellation?.Dispose();
                return;
            }

            var activeCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            _activeCancellation = activeCancellation;
            await Task.WhenAll(
                _volume.StartMonitoringAsync(activeCancellation.Token),
                _media.StartMonitoringAsync(activeCancellation.Token));
            var snapshot = await GetSnapshotAsync(activeCancellation.Token);
            PublishSnapshot(snapshot, force: true);
            await _preview.StartAsync(snapshot.Media, activeCancellation.Token);
            _fallbackRefreshTask = RunFallbackRefreshLoopAsync(activeCancellation.Token);
        }
        finally
        {
            _activationGate.Release();
        }
    }

    public async Task<ControlsSnapshot> GetSnapshotAsync(CancellationToken cancellationToken)
    {
        return await GetSnapshotAsync(cancellationToken, forceRefresh: false);
    }

    private async Task<ControlsSnapshot> GetSnapshotAsync(
        CancellationToken cancellationToken,
        bool forceRefresh)
    {
        ThrowIfDisposed();
        var cached = _lastSnapshot;
        if (!forceRefresh
            && cached is not null
            && DateTimeOffset.UtcNow - cached.RefreshedAt <= SnapshotCacheLifetime)
        {
            return MergeLatestDisplays(cached);
        }

        await _snapshotGate.WaitAsync(cancellationToken);
        try
        {
            cached = _lastSnapshot;
            if (!forceRefresh
                && cached is not null
                && DateTimeOffset.UtcNow - cached.RefreshedAt <= SnapshotCacheLifetime)
            {
                return MergeLatestDisplays(cached);
            }

            var displaysTask = ReadDisplaysSafelyAsync(cancellationToken);
            var volumeTask = ReadVolumeSafelyAsync(cancellationToken);
            var mediaTask = ReadMediaSafelyAsync(cancellationToken);
            await Task.WhenAll(displaysTask, volumeTask, mediaTask);
            var displays = Volatile.Read(ref _latestDisplays) ?? await displaysTask;
            var snapshot = new ControlsSnapshot(
                displays,
                await volumeTask,
                await mediaTask,
                _preview.CurrentState,
                DateTimeOffset.UtcNow);
            _lastSnapshot = snapshot;
            return snapshot;
        }
        finally
        {
            _snapshotGate.Release();
        }
    }

    public async Task<ControlsSnapshot> SetVolumeAsync(int value, CancellationToken cancellationToken)
    {
        ThrowIfDisposed();
        await AwaitOrFallbackAsync(
            Task.Run(() => _volume.SetVolumeAsync(Math.Clamp(value, 0, 100), CancellationToken.None), CancellationToken.None),
            new VolumeState(false, 0, false, "Volume command timed out."),
            cancellationToken);
        var snapshot = await GetSnapshotAsync(cancellationToken, forceRefresh: true);
        PublishSnapshot(snapshot, force: true);
        return snapshot;
    }

    public async Task<ControlsSnapshot> ToggleMuteAsync(CancellationToken cancellationToken)
    {
        ThrowIfDisposed();
        await AwaitOrFallbackAsync(
            Task.Run(() => _volume.ToggleMuteAsync(CancellationToken.None), CancellationToken.None),
            new VolumeState(false, 0, false, "Mute command timed out."),
            cancellationToken);
        var snapshot = await GetSnapshotAsync(cancellationToken, forceRefresh: true);
        PublishSnapshot(snapshot, force: true);
        return snapshot;
    }

    public async Task<ControlsSnapshot> SetMutedAsync(bool muted, CancellationToken cancellationToken)
    {
        ThrowIfDisposed();
        var current = await GetSnapshotAsync(cancellationToken, forceRefresh: true);
        if (!current.Volume.Available || current.Volume.Muted == muted)
        {
            return current;
        }
        return await ToggleMuteAsync(cancellationToken);
    }

    public async Task<ControlsSnapshot> SetBrightnessAsync(
        string displayId,
        int value,
        CancellationToken cancellationToken)
    {
        ThrowIfDisposed();
        var fallbackDisplays = _lastSnapshot?.Displays
            ?? [new DisplayBrightnessState("display:timeout", "Display", false, null, "Brightness command timed out.")];
        var displays = await AwaitOrFallbackAsync(
            _brightness.SetBrightnessAsync(displayId, Math.Clamp(value, 0, 100), cancellationToken),
            fallbackDisplays,
            cancellationToken,
            BrightnessOperationTimeout);
        Volatile.Write(ref _latestDisplays, displays);
        var current = _lastSnapshot;
        ControlsSnapshot snapshot;
        if (current is not null)
        {
            snapshot = current with
            {
                Displays = displays,
                RefreshedAt = DateTimeOffset.UtcNow
            };
        }
        else
        {
            var volumeTask = ReadVolumeSafelyAsync(cancellationToken);
            var mediaTask = ReadMediaSafelyAsync(cancellationToken);
            await Task.WhenAll(volumeTask, mediaTask);
            snapshot = new ControlsSnapshot(
                displays,
                await volumeTask,
                await mediaTask,
                _preview.CurrentState,
                DateTimeOffset.UtcNow);
        }

        PublishSnapshot(snapshot, force: true);
        return snapshot;
    }

    public async Task<ControlsSnapshot> ExecuteMediaCommandAsync(
        string command,
        double? value,
        CancellationToken cancellationToken)
    {
        ThrowIfDisposed();
        await AwaitOrFallbackAsync(
            Task.Run(() => _media.ExecuteAsync(command, value, CancellationToken.None), CancellationToken.None),
            MediaSessionState.Empty("Media command timed out."),
            cancellationToken);
        var snapshot = await GetSnapshotAsync(cancellationToken, forceRefresh: true);
        PublishSnapshot(snapshot, force: true);
        if (_active)
        {
            await _preview.StartAsync(snapshot.Media, cancellationToken);
        }

        return snapshot;
    }

    public async Task<ControlsSnapshot> OpenMediaSourceAsync(CancellationToken cancellationToken)
    {
        ThrowIfDisposed();
        var snapshot = await GetSnapshotAsync(cancellationToken);
        if (!snapshot.Media.Available
            || !_sourceActivator.TryActivate(snapshot.Media.PreviewWindowHandle))
        {
            var unavailable = snapshot with
            {
                Media = snapshot.Media with { Error = "The playing window could not be brought to the front." }
            };
            PublishSnapshot(unavailable, force: true);
            return unavailable;
        }

        MediaSourceOpened?.Invoke(this, EventArgs.Empty);
        return snapshot;
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _volume.StateChanged -= OnVolumeStateChanged;
        _brightness.StateChanged -= OnBrightnessStateChanged;
        _media.StateChanged -= OnMediaStateChanged;
        _preview.StateChanged -= OnPreviewStateChanged;
        _preview.FrameArrived -= OnPreviewFrameArrived;
        _activeCancellation?.Cancel();
        _volume.StopMonitoring();
        _media.StopMonitoring();
        _preview.Stop();
        _activeCancellation?.Dispose();
        _activationGate.Dispose();
        _snapshotGate.Dispose();
        if (_volume is IDisposable volumeDisposable)
        {
            volumeDisposable.Dispose();
        }

        if (_brightness is IDisposable brightnessDisposable)
        {
            brightnessDisposable.Dispose();
        }

        if (_media is IDisposable mediaDisposable)
        {
            mediaDisposable.Dispose();
        }

        if (_preview is IDisposable previewDisposable)
        {
            previewDisposable.Dispose();
        }
    }

    private async Task RunFallbackRefreshLoopAsync(CancellationToken cancellationToken)
    {
        using var timer = new PeriodicTimer(FallbackRefreshInterval);
        try
        {
            while (await timer.WaitForNextTickAsync(cancellationToken))
            {
                var snapshot = await GetSnapshotAsync(cancellationToken, forceRefresh: true);
                PublishSnapshot(snapshot, force: true);
                await _preview.StartAsync(snapshot.Media, cancellationToken);
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
    }

    private void OnVolumeStateChanged(object? sender, VolumeState volume)
    {
        _ = sender;
        var current = _lastSnapshot;
        if (!_active || current is null)
        {
            return;
        }

        PublishSnapshot(current with { Volume = volume, RefreshedAt = DateTimeOffset.UtcNow });
    }

    private void OnBrightnessStateChanged(
        object? sender,
        IReadOnlyList<DisplayBrightnessState> displays)
    {
        _ = sender;
        Volatile.Write(ref _latestDisplays, displays);
        var current = _lastSnapshot;
        if (!_active || current is null)
        {
            return;
        }

        PublishSnapshot(current with { Displays = displays, RefreshedAt = DateTimeOffset.UtcNow });
    }

    private void OnMediaStateChanged(object? sender, MediaSessionState media)
    {
        _ = sender;
        var current = _lastSnapshot;
        if (!_active || current is null)
        {
            return;
        }

        PublishSnapshot(current with { Media = media, RefreshedAt = DateTimeOffset.UtcNow });
        var cancellationToken = _activeCancellation?.Token ?? CancellationToken.None;
        _ = Task.Run(async () =>
        {
            try
            {
                await _preview.StartAsync(media, cancellationToken);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
            }
        }, CancellationToken.None);
    }

    private void OnPreviewStateChanged(object? sender, MediaPreviewState preview)
    {
        _ = sender;
        var current = _lastSnapshot;
        if (current is not null)
        {
            _lastSnapshot = current with { Preview = preview, RefreshedAt = DateTimeOffset.UtcNow };
        }

        if (_active)
        {
            PreviewStateChanged?.Invoke(this, preview);
        }
    }

    private void OnPreviewFrameArrived(object? sender, MediaPreviewFrame frame)
    {
        _ = sender;
        if (_active)
        {
            PreviewFrameArrived?.Invoke(this, frame);
        }
    }

    private void PublishSnapshot(ControlsSnapshot snapshot, bool force = false)
    {
        var previous = _lastSnapshot;
        _lastSnapshot = snapshot;
        if (_active && (force || !SnapshotsEquivalent(previous, snapshot)))
        {
            SnapshotChanged?.Invoke(this, snapshot);
        }
    }

    private ControlsSnapshot MergeLatestDisplays(ControlsSnapshot snapshot)
    {
        var latest = Volatile.Read(ref _latestDisplays);
        if (latest is null || snapshot.Displays.SequenceEqual(latest))
        {
            return snapshot;
        }

        var merged = snapshot with
        {
            Displays = latest,
            RefreshedAt = DateTimeOffset.UtcNow
        };
        _lastSnapshot = merged;
        return merged;
    }

    private static bool SnapshotsEquivalent(ControlsSnapshot? left, ControlsSnapshot right)
    {
        return left is not null
            && left.Displays.SequenceEqual(right.Displays)
            && left.Volume == right.Volume
            && left.Media == right.Media
            && left.Preview == right.Preview;
    }

    private async Task<object?> HandleSetVolumeAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        return await SetVolumeAsync(ReadRequiredInt(parameters, "value"), cancellationToken);
    }

    private async Task<object?> HandleToggleMuteAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        _ = parameters;
        return await ToggleMuteAsync(cancellationToken);
    }

    private async Task<object?> HandleSetBrightnessAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        return await SetBrightnessAsync(
            ReadRequiredString(parameters, "id"),
            ReadRequiredInt(parameters, "value"),
            cancellationToken);
    }

    private async Task<object?> HandleMediaCommandAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        return await ExecuteMediaCommandAsync(
            ReadRequiredString(parameters, "command"),
            ReadOptionalDouble(parameters, "value"),
            cancellationToken);
    }

    private async Task<object?> HandleOpenMediaSourceAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        _ = parameters;
        return await OpenMediaSourceAsync(cancellationToken);
    }

    private static string ReadRequiredString(JsonElement? parameters, string propertyName)
    {
        if (parameters is null
            || !parameters.Value.TryGetProperty(propertyName, out var property)
            || property.ValueKind != JsonValueKind.String)
        {
            throw new InvalidOperationException($"Missing string parameter: {propertyName}");
        }

        return property.GetString() ?? string.Empty;
    }

    private static int ReadRequiredInt(JsonElement? parameters, string propertyName)
    {
        if (parameters is null
            || !parameters.Value.TryGetProperty(propertyName, out var property)
            || !property.TryGetInt32(out var value))
        {
            throw new InvalidOperationException($"Missing integer parameter: {propertyName}");
        }

        return value;
    }

    private static double? ReadOptionalDouble(JsonElement? parameters, string propertyName)
    {
        if (parameters is null || !parameters.Value.TryGetProperty(propertyName, out var property))
        {
            return null;
        }

        return property.ValueKind == JsonValueKind.Number && property.TryGetDouble(out var value)
            ? value
            : null;
    }

    private void ThrowIfDisposed()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
    }

    private Task<IReadOnlyList<DisplayBrightnessState>> ReadDisplaysSafelyAsync(CancellationToken cancellationToken)
    {
        return AwaitOrFallbackAsync(
            Task.Run(() => _brightness.ReadAsync(CancellationToken.None), CancellationToken.None),
            [new DisplayBrightnessState("display:timeout", "Display", false, null, "Brightness detection timed out.")],
            cancellationToken);
    }

    private Task<VolumeState> ReadVolumeSafelyAsync(CancellationToken cancellationToken)
    {
        return AwaitOrFallbackAsync(
            Task.Run(() => _volume.ReadAsync(CancellationToken.None), CancellationToken.None),
            new VolumeState(false, 0, false, "Volume detection timed out."),
            cancellationToken);
    }

    private Task<MediaSessionState> ReadMediaSafelyAsync(CancellationToken cancellationToken)
    {
        return AwaitOrFallbackAsync(
            Task.Run(() => _media.ReadAsync(CancellationToken.None), CancellationToken.None),
            MediaSessionState.Empty("Media detection timed out."),
            cancellationToken);
    }

    private static async Task<T> AwaitOrFallbackAsync<T>(
        Task<T> operation,
        T fallback,
        CancellationToken cancellationToken,
        TimeSpan? timeout = null)
    {
        try
        {
            return await operation.WaitAsync(timeout ?? OperationTimeout, cancellationToken);
        }
        catch (TimeoutException)
        {
            ObserveLaterFault(operation);
            return fallback;
        }
        catch (Exception ex) when (ex is COMException or UnauthorizedAccessException or InvalidOperationException)
        {
            return fallback;
        }
    }

    private static void ObserveLaterFault(Task operation)
    {
        _ = operation.ContinueWith(
            completed => _ = completed.Exception,
            CancellationToken.None,
            TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously,
            TaskScheduler.Default);
    }
}
