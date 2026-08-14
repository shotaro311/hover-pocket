using System.Text.Json.Serialization;

namespace HoverPocket.Shell.Providers.Controls;

internal sealed record DisplayBrightnessState(
    string Id,
    string Name,
    bool Supported,
    int? Value,
    string? Error = null,
    bool? WriteVerified = null);

internal sealed record VolumeState(
    bool Available,
    int Value,
    bool Muted,
    string? Error = null);

internal sealed record MediaSessionState(
    bool Available,
    string Title,
    string Artist,
    string Source,
    string? ArtworkDataUrl,
    double PositionSeconds,
    double DurationSeconds,
    bool IsPlaying,
    double PlaybackRate,
    bool CanPlayPause,
    bool CanSeek,
    bool CanChangeRate,
    bool CanSkipPrevious,
    bool CanSkipNext,
    string SourceAppUserModelId,
    [property: JsonIgnore] nint? PreviewWindowHandle,
    string? Error = null)
{
    public static MediaSessionState Empty(string? error = null) =>
        new(
            false,
            string.Empty,
            string.Empty,
            string.Empty,
            null,
            0,
            0,
            false,
            1,
            false,
            false,
            false,
            false,
            false,
            string.Empty,
            null,
            error);
}

internal sealed record MediaPreviewState(
    string Mode,
    bool Live,
    bool Fallback,
    long CompleteFrameCount,
    double MeasuredFps,
    string? Error = null,
    long EncodedFrameCount = 0,
    long ReplacedPendingFrameCount = 0)
{
    public static MediaPreviewState Inactive { get; } = new("inactive", false, true, 0, 0);

    public static MediaPreviewState FallbackState(string mode, string? error = null) =>
        new(mode, false, true, 0, 0, error);
}

internal sealed record MediaPreviewFrame(
    string DataUrl,
    long CompleteFrameCount,
    double MeasuredFps);

internal sealed record ControlsSnapshot(
    IReadOnlyList<DisplayBrightnessState> Displays,
    VolumeState Volume,
    MediaSessionState Media,
    MediaPreviewState Preview,
    DateTimeOffset RefreshedAt);

internal interface IVolumeEndpointService
{
    event EventHandler<VolumeState>? StateChanged;

    Task StartMonitoringAsync(CancellationToken cancellationToken);

    void StopMonitoring();

    Task<VolumeState> ReadAsync(CancellationToken cancellationToken);

    Task<VolumeState> SetVolumeAsync(int value, CancellationToken cancellationToken);

    Task<VolumeState> ToggleMuteAsync(CancellationToken cancellationToken);
}

internal interface IMonitorBrightnessService
{
    event EventHandler<IReadOnlyList<DisplayBrightnessState>>? StateChanged;

    Task<IReadOnlyList<DisplayBrightnessState>> ReadAsync(CancellationToken cancellationToken);

    Task<IReadOnlyList<DisplayBrightnessState>> SetBrightnessAsync(
        string displayId,
        int value,
        CancellationToken cancellationToken);
}

internal interface IMediaSessionService
{
    event EventHandler<MediaSessionState>? StateChanged;

    Task StartMonitoringAsync(CancellationToken cancellationToken);

    void StopMonitoring();

    Task<MediaSessionState> ReadAsync(CancellationToken cancellationToken);

    Task<MediaSessionState> ExecuteAsync(
        string command,
        double? value,
        CancellationToken cancellationToken);
}

internal interface IMediaSourceActivator
{
    bool TryActivate(nint? windowHandle);
}

internal interface IMediaPreviewService
{
    event EventHandler<MediaPreviewState>? StateChanged;

    event EventHandler<MediaPreviewFrame>? FrameArrived;

    MediaPreviewState CurrentState { get; }

    Task StartAsync(MediaSessionState media, CancellationToken cancellationToken);

    void Stop();
}
