using System.Runtime.InteropServices;
using Windows.Media.Control;
using Windows.Storage.Streams;

namespace HoverPocket.Shell.Providers.Controls;

internal sealed class WindowsMediaSessionService : IMediaSessionService, IDisposable
{
    private const uint MaximumArtworkBytes = 5 * 1024 * 1024;
    private static readonly TimeSpan CommandConfirmationTimeout = TimeSpan.FromMilliseconds(1500);
    private static readonly TimeSpan EventRefreshDebounce = TimeSpan.FromMilliseconds(90);
    private static readonly TimeSpan EmptyArtworkCacheLifetime = TimeSpan.FromSeconds(5);
    private readonly SemaphoreSlim _managerGate = new(1, 1);
    private readonly SemaphoreSlim _eventRefreshGate = new(1, 1);
    private readonly object _artworkCacheSync = new();
    private GlobalSystemMediaTransportControlsSessionManager? _manager;
    private GlobalSystemMediaTransportControlsSession? _observedSession;
    private CancellationTokenSource? _monitorCancellation;
    private string? _artworkCacheKey;
    private string? _artworkCacheDataUrl;
    private DateTimeOffset _artworkCacheUpdatedAt;
    private long _stateVersion;
    private int _eventRefreshScheduled;
    private bool _monitoring;
    private bool _disposed;

    public event EventHandler<MediaSessionState>? StateChanged;

    public async Task StartMonitoringAsync(CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (_monitoring)
        {
            return;
        }

        _monitoring = true;
        _monitorCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        try
        {
            var manager = await GetManagerAsync(cancellationToken);
            manager.CurrentSessionChanged += OnManagerSessionChanged;
            manager.SessionsChanged += OnManagerSessionChanged;
            BindObservedSession(await GetCurrentSessionAsync(cancellationToken));
            Publish(await ReadAsync(cancellationToken));
        }
        catch
        {
            StopMonitoring();
            throw;
        }
    }

    public void StopMonitoring()
    {
        if (!_monitoring)
        {
            return;
        }

        _monitoring = false;
        _monitorCancellation?.Cancel();
        _monitorCancellation?.Dispose();
        _monitorCancellation = null;
        Interlocked.Exchange(ref _eventRefreshScheduled, 0);
        if (_manager is not null)
        {
            _manager.CurrentSessionChanged -= OnManagerSessionChanged;
            _manager.SessionsChanged -= OnManagerSessionChanged;
        }

        BindObservedSession(null);
        ClearArtworkCache();
    }

    public async Task<MediaSessionState> ReadAsync(CancellationToken cancellationToken)
    {
        try
        {
            var session = await GetCurrentSessionAsync(cancellationToken);
            return session is null
                ? MediaSessionState.Empty()
                : await ReadSessionAsync(session, cancellationToken);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception ex) when (ex is COMException or UnauthorizedAccessException or InvalidOperationException)
        {
            return MediaSessionState.Empty("Windows media session is unavailable.");
        }
    }

    public async Task<MediaSessionState> ExecuteAsync(
        string command,
        double? value,
        CancellationToken cancellationToken)
    {
        try
        {
            var session = await GetCurrentSessionAsync(cancellationToken);
            if (session is null)
            {
                return MediaSessionState.Empty("No media session is available.");
            }

            var initial = await ReadSessionAsync(session, cancellationToken);
            var normalizedCommand = command.ToLowerInvariant();
            var expectedPosition = initial.PositionSeconds;
            var expectedRate = initial.PlaybackRate;
            Func<MediaSessionState, bool>? confirmedByState = null;
            var requiresEventConfirmation = false;
            var versionBefore = Volatile.Read(ref _stateVersion);
            bool accepted;

            switch (normalizedCommand)
            {
                case "playpause" when initial.CanPlayPause:
                    accepted = await session.TryTogglePlayPauseAsync().AsTask(cancellationToken);
                    confirmedByState = state => state.IsPlaying != initial.IsPlaying;
                    break;
                case "play" when initial.CanPlayPause:
                    accepted = await session.TryPlayAsync().AsTask(cancellationToken);
                    confirmedByState = state => state.IsPlaying;
                    break;
                case "pause" when initial.CanPlayPause:
                    accepted = await session.TryPauseAsync().AsTask(cancellationToken);
                    confirmedByState = state => !state.IsPlaying;
                    break;
                case "previous" when initial.CanSkipPrevious:
                    accepted = await session.TrySkipPreviousAsync().AsTask(cancellationToken);
                    requiresEventConfirmation = true;
                    break;
                case "next" when initial.CanSkipNext:
                    accepted = await session.TrySkipNextAsync().AsTask(cancellationToken);
                    requiresEventConfirmation = true;
                    break;
                case "seekrelative" when initial.CanSeek:
                    expectedPosition = Math.Clamp(
                        initial.PositionSeconds + (value ?? 0),
                        0,
                        Math.Max(0, initial.DurationSeconds));
                    accepted = await SeekAbsoluteAsync(session, expectedPosition, cancellationToken);
                    confirmedByState = state => Math.Abs(state.PositionSeconds - expectedPosition) <= 1.5;
                    break;
                case "seekabsolute" when initial.CanSeek:
                    expectedPosition = Math.Clamp(value ?? 0, 0, Math.Max(0, initial.DurationSeconds));
                    accepted = await SeekAbsoluteAsync(session, expectedPosition, cancellationToken);
                    confirmedByState = state => Math.Abs(state.PositionSeconds - expectedPosition) <= 1.5;
                    break;
                case "rate" when initial.CanChangeRate:
                    expectedRate = Math.Clamp(value ?? 1, 0.25, 4);
                    accepted = await session.TryChangePlaybackRateAsync(expectedRate).AsTask(cancellationToken);
                    confirmedByState = state => Math.Abs(state.PlaybackRate - expectedRate) <= 0.01;
                    break;
                default:
                    return initial with { Error = "This media command is not supported by the current session." };
            }

            if (!accepted)
            {
                return (await SafeReadSessionAsync(session, cancellationToken)) with
                {
                    Error = "The media session rejected the command."
                };
            }

            var confirmed = await WaitForConfirmationAsync(
                session,
                confirmedByState,
                requiresEventConfirmation,
                versionBefore,
                cancellationToken);
            return confirmed.Confirmed
                ? confirmed.State
                : confirmed.State with { Error = "The media command was not confirmed by session state." };
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception ex) when (ex is COMException or UnauthorizedAccessException or InvalidOperationException)
        {
            return MediaSessionState.Empty("Media command failed.");
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        StopMonitoring();
        _eventRefreshGate.Dispose();
        _managerGate.Dispose();
    }

    private async Task<(MediaSessionState State, bool Confirmed)> WaitForConfirmationAsync(
        GlobalSystemMediaTransportControlsSession session,
        Func<MediaSessionState, bool>? statePredicate,
        bool requiresEventConfirmation,
        long versionBefore,
        CancellationToken cancellationToken)
    {
        var deadline = DateTimeOffset.UtcNow + CommandConfirmationTimeout;
        var latest = await SafeReadSessionAsync(session, cancellationToken);
        while (DateTimeOffset.UtcNow < deadline)
        {
            var stateConfirmed = statePredicate?.Invoke(latest) == true;
            var eventConfirmed = requiresEventConfirmation && Volatile.Read(ref _stateVersion) > versionBefore;
            if (stateConfirmed || eventConfirmed)
            {
                return (latest, true);
            }

            await Task.Delay(100, cancellationToken);
            latest = await SafeReadSessionAsync(session, cancellationToken);
            if (!latest.Available)
            {
                return (latest, false);
            }
        }

        return (latest, false);
    }

    private void OnManagerSessionChanged(
        GlobalSystemMediaTransportControlsSessionManager sender,
        object args)
    {
        _ = sender;
        _ = args;
        Interlocked.Increment(ref _stateVersion);
        ClearArtworkCache();
        QueueEventRefresh();
    }

    private void OnSessionStateChanged(GlobalSystemMediaTransportControlsSession sender, object args)
    {
        _ = sender;
        _ = args;
        Interlocked.Increment(ref _stateVersion);
        QueueEventRefresh();
    }

    private void OnMediaPropertiesChanged(GlobalSystemMediaTransportControlsSession sender, object args)
    {
        _ = sender;
        _ = args;
        Interlocked.Increment(ref _stateVersion);
        ClearArtworkCache();
        QueueEventRefresh();
    }

    private void BindObservedSession(GlobalSystemMediaTransportControlsSession? session)
    {
        if (ReferenceEquals(_observedSession, session))
        {
            return;
        }

        if (_observedSession is not null)
        {
            _observedSession.MediaPropertiesChanged -= OnMediaPropertiesChanged;
            _observedSession.PlaybackInfoChanged -= OnSessionStateChanged;
            _observedSession.TimelinePropertiesChanged -= OnSessionStateChanged;
        }

        ClearArtworkCache();
        _observedSession = session;
        if (_monitoring && session is not null)
        {
            session.MediaPropertiesChanged += OnMediaPropertiesChanged;
            session.PlaybackInfoChanged += OnSessionStateChanged;
            session.TimelinePropertiesChanged += OnSessionStateChanged;
        }
    }

    private void QueueEventRefresh()
    {
        var cancellationToken = _monitorCancellation?.Token ?? CancellationToken.None;
        if (!_monitoring || cancellationToken.IsCancellationRequested)
        {
            return;
        }

        if (Interlocked.Exchange(ref _eventRefreshScheduled, 1) != 0)
        {
            return;
        }

        _ = Task.Run(async () =>
        {
            long refreshedVersion = -1;
            try
            {
                await Task.Delay(EventRefreshDebounce, cancellationToken);
                refreshedVersion = Volatile.Read(ref _stateVersion);
                await _eventRefreshGate.WaitAsync(cancellationToken);
                try
                {
                    if (_monitoring)
                    {
                        BindObservedSession(await GetCurrentSessionAsync(cancellationToken));
                        Publish(await ReadAsync(cancellationToken));
                    }
                }
                finally
                {
                    _eventRefreshGate.Release();
                }
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
            }
            catch (ObjectDisposedException) when (_disposed)
            {
            }
            finally
            {
                Interlocked.Exchange(ref _eventRefreshScheduled, 0);
                if (_monitoring
                    && !cancellationToken.IsCancellationRequested
                    && refreshedVersion >= 0
                    && Volatile.Read(ref _stateVersion) != refreshedVersion)
                {
                    QueueEventRefresh();
                }
            }
        }, CancellationToken.None);
    }

    private void Publish(MediaSessionState state)
    {
        if (_monitoring && !_disposed)
        {
            StateChanged?.Invoke(this, state);
        }
    }

    private async Task<GlobalSystemMediaTransportControlsSessionManager> GetManagerAsync(
        CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (_manager is not null)
        {
            return _manager;
        }

        await _managerGate.WaitAsync(cancellationToken);
        try
        {
            _manager ??= await GlobalSystemMediaTransportControlsSessionManager
                .RequestAsync()
                .AsTask(cancellationToken);
            return _manager;
        }
        finally
        {
            _managerGate.Release();
        }
    }

    private async Task<GlobalSystemMediaTransportControlsSession?> GetCurrentSessionAsync(
        CancellationToken cancellationToken)
    {
        var manager = await GetManagerAsync(cancellationToken);
        var current = manager.GetCurrentSession();
        if (current is not null)
        {
            return current;
        }

        var playing = manager.GetSessions()
            .Where(session => session.GetPlaybackInfo().PlaybackStatus
                == GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing)
            .Take(2)
            .ToArray();
        return playing.Length == 1 ? playing[0] : null;
    }

    private async Task<MediaSessionState> SafeReadSessionAsync(
        GlobalSystemMediaTransportControlsSession session,
        CancellationToken cancellationToken)
    {
        try
        {
            return await ReadSessionAsync(session, cancellationToken);
        }
        catch (Exception ex) when (ex is COMException or InvalidOperationException)
        {
            return MediaSessionState.Empty("The media session disappeared.");
        }
    }

    private async Task<MediaSessionState> ReadSessionAsync(
        GlobalSystemMediaTransportControlsSession session,
        CancellationToken cancellationToken)
    {
        var media = await session.TryGetMediaPropertiesAsync().AsTask(cancellationToken);
        var playback = session.GetPlaybackInfo();
        var timeline = session.GetTimelineProperties();
        var controls = playback.Controls;
        var duration = Math.Max(0, (timeline.EndTime - timeline.StartTime).TotalSeconds);
        var position = Math.Clamp((timeline.Position - timeline.StartTime).TotalSeconds, 0, Math.Max(0, duration));
        var sourceAppUserModelId = session.SourceAppUserModelId ?? string.Empty;
        var title = media.Title ?? string.Empty;
        var artworkKey = string.Join('\u001f', sourceAppUserModelId, title, media.Artist, media.AlbumTitle);
        var artwork = await ReadArtworkCachedAsync(artworkKey, media.Thumbnail, cancellationToken);

        return new MediaSessionState(
            true,
            title,
            string.IsNullOrWhiteSpace(media.Artist) ? media.AlbumTitle ?? string.Empty : media.Artist,
            SourceLabel(sourceAppUserModelId),
            artwork,
            position,
            duration,
            playback.PlaybackStatus == GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing,
            playback.PlaybackRate ?? 1,
            controls.IsPlayPauseToggleEnabled || controls.IsPlayEnabled || controls.IsPauseEnabled,
            controls.IsPlaybackPositionEnabled,
            controls.IsPlaybackRateEnabled,
            controls.IsPreviousEnabled,
            controls.IsNextEnabled,
            sourceAppUserModelId,
            MediaWindowResolver.ResolveUnique(sourceAppUserModelId, title));
    }

    private async Task<string?> ReadArtworkCachedAsync(
        string cacheKey,
        IRandomAccessStreamReference? reference,
        CancellationToken cancellationToken)
    {
        lock (_artworkCacheSync)
        {
            if (string.Equals(_artworkCacheKey, cacheKey, StringComparison.Ordinal)
                && (_artworkCacheDataUrl is not null
                    || DateTimeOffset.UtcNow - _artworkCacheUpdatedAt <= EmptyArtworkCacheLifetime))
            {
                return _artworkCacheDataUrl;
            }
        }

        var artwork = await ReadArtworkAsync(reference, cancellationToken);
        lock (_artworkCacheSync)
        {
            _artworkCacheKey = cacheKey;
            _artworkCacheDataUrl = artwork;
            _artworkCacheUpdatedAt = DateTimeOffset.UtcNow;
        }
        return artwork;
    }

    private void ClearArtworkCache()
    {
        lock (_artworkCacheSync)
        {
            _artworkCacheKey = null;
            _artworkCacheDataUrl = null;
            _artworkCacheUpdatedAt = default;
        }
    }

    private static async Task<bool> SeekAbsoluteAsync(
        GlobalSystemMediaTransportControlsSession session,
        double seconds,
        CancellationToken cancellationToken)
    {
        var timeline = session.GetTimelineProperties();
        var target = timeline.StartTime + TimeSpan.FromSeconds(Math.Max(0, seconds));
        target = target > timeline.EndTime ? timeline.EndTime : target;
        return await session.TryChangePlaybackPositionAsync(target.Ticks).AsTask(cancellationToken);
    }

    private static async Task<string?> ReadArtworkAsync(
        IRandomAccessStreamReference? reference,
        CancellationToken cancellationToken)
    {
        if (reference is null)
        {
            return null;
        }

        try
        {
            using var stream = await reference.OpenReadAsync().AsTask(cancellationToken);
            var length = (uint)Math.Min(stream.Size, MaximumArtworkBytes);
            if (length == 0)
            {
                return null;
            }

            using var input = stream.GetInputStreamAt(0);
            using var reader = new DataReader(input);
            var loaded = await reader.LoadAsync(length).AsTask(cancellationToken);
            if (loaded == 0)
            {
                return null;
            }

            var bytes = new byte[loaded];
            reader.ReadBytes(bytes);
            var contentType = string.IsNullOrWhiteSpace(stream.ContentType) ? "image/png" : stream.ContentType;
            return $"data:{contentType};base64,{Convert.ToBase64String(bytes)}";
        }
        catch (Exception ex) when (ex is COMException or UnauthorizedAccessException or InvalidOperationException)
        {
            return null;
        }
    }

    private static string SourceLabel(string? sourceAppUserModelId)
    {
        var source = sourceAppUserModelId ?? string.Empty;
        if (source.Contains("chrome", StringComparison.OrdinalIgnoreCase))
        {
            return "Chrome";
        }

        if (source.Contains("msedge", StringComparison.OrdinalIgnoreCase))
        {
            return "Microsoft Edge";
        }

        if (source.Contains("spotify", StringComparison.OrdinalIgnoreCase))
        {
            return "Spotify";
        }

        var separator = source.LastIndexOfAny(['!', '\\', '/']);
        return separator >= 0 && separator + 1 < source.Length ? source[(separator + 1)..] : source;
    }
}
