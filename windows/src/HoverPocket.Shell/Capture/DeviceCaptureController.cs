using System.Diagnostics;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using HoverPocket.Assets;
using Windows.Devices.Enumeration;
using Windows.Graphics.Imaging;
using Windows.Media.Capture;
using Windows.Media.Capture.Frames;
using Windows.Media.MediaProperties;
using Windows.Storage;

namespace HoverPocket.Shell.Capture;

internal sealed record CaptureDevice(string Id, string Name);
internal sealed record DeviceCaptureOptions(string Kind, string? CameraId, string? MicrophoneId, string? FolderId);

internal sealed class DeviceCaptureController : IDisposable
{
    private readonly AssetStore _store;
    private readonly CaptureFiles _files;
    private readonly Dispatcher _dispatcher;
    private readonly SemaphoreSlim _gate = new(1);
    private readonly DispatcherTimer _clock = new() { Interval = TimeSpan.FromSeconds(1) };
    private readonly Stopwatch _duration = new();
    private DeviceCaptureWindow? _window;
    private DeviceRecordingBadge? _badge;
    private MediaCapture? _capture;
    private MediaFrameReader? _frames;
    private DeviceCaptureOptions? _configured;
    private string? _stage, _path;
    private Task? _stopTask;
    private int _previewPending;
    private bool _busy, _disposed;
    public bool Recording { get; private set; }
    internal bool Busy => _busy;
    internal DeviceCaptureWindow? WindowForVerify => _window;
    public string Status { get; private set; } = "デバイスを選んで撮影・収録できます。";
    public event Action? StateChanged;
    internal DeviceCaptureController(AssetStore store)
    {
        _store = store; _files = new(store); _dispatcher = Dispatcher.CurrentDispatcher;
        _clock.Tick += (_, _) =>
        {
            _badge?.Update(_duration.Elapsed, _busy); _window?.Update(_busy, Recording, _duration.Elapsed, Status);
            if (!Recording || _busy || _stage is null) return;
            try { if (new DriveInfo(Path.GetPathRoot(_stage)!).AvailableFreeSpace < 512L * 1024 * 1024) { SetStatus("空き容量が少なくなったため停止して保存します。"); _ = StopAsync(); } }
            catch (IOException) { _ = StopAsync(); }
        };
    }
    internal void Open(string kind, string? folder)
    {
        if (_disposed) return;
        _window ??= new DeviceCaptureWindow(this);
        _window.Select(kind, folder, !Recording && !_busy); _window.Show(); _window.Activate(); _window.Update(_busy, Recording, _duration.Elapsed, Status);
        _ = _window.LoadDevicesAsync(_store);
    }
    internal static async Task<(CaptureDevice[] Cameras, CaptureDevice[] Microphones)> DevicesAsync()
    {
        var cameras = await DeviceInformation.FindAllAsync(DeviceClass.VideoCapture);
        var microphones = await DeviceInformation.FindAllAsync(DeviceClass.AudioCapture);
        return (cameras.Select(value => new CaptureDevice(value.Id, value.Name)).ToArray(), microphones.Select(value => new CaptureDevice(value.Id, value.Name)).ToArray());
    }
    private void SetStatus(string message)
    { Status = message; _window?.Update(_busy, Recording, _duration.Elapsed, message); StateChanged?.Invoke(); }
    internal async Task PreviewAsync(DeviceCaptureOptions options)
    {
        if (_busy || Recording || _disposed) return;
        await ExecuteAsync(async () => { await PrepareAsync(options with { Kind = "cameraPhoto", MicrophoneId = null }); SetStatus("カメラのプレビューを表示しています。"); });
    }
    internal async Task CaptureAsync(DeviceCaptureOptions options)
    {
        if (_busy || Recording || _disposed) return;
        await ExecuteAsync(async () =>
        {
            await PrepareAsync(options);
            _stage = _files.CreateStage();
            var extension = options.Kind == "cameraPhoto" ? "png" : options.Kind == "audio" ? "m4a" : "mp4";
            var label = options.Kind == "cameraPhoto" ? "カメラ写真" : options.Kind == "audio" ? "音声録音" : "カメラ動画";
            _path = Path.Combine(_stage, $"{label} {DateTime.Now:yyyy-MM-dd HH-mm-ss}.{extension}");
            var directory = await StorageFolder.GetFolderFromPathAsync(_stage);
            var file = await directory.CreateFileAsync(Path.GetFileName(_path), CreationCollisionOption.FailIfExists);
            if (options.Kind == "cameraPhoto")
            {
                await _capture!.CapturePhotoToStorageFileAsync(ImageEncodingProperties.CreatePng(), file);
                CaptureFiles.MarkComplete(_stage, [_path], options.FolderId);
                var saved = await _files.ImportCompletedAsync(_stage); _stage = null; _path = null;
                SetStatus($"写真をライブラリへ保存しました（{saved.Length}件）。");
            }
            else
            {
                var profile = options.Kind == "audio" ? MediaEncodingProfile.CreateM4a(AudioEncodingQuality.High) : MediaEncodingProfile.CreateMp4(VideoEncodingQuality.HD1080p);
                if (options.Kind != "audio" && options.MicrophoneId is null) profile.Audio = null;
                await _capture!.StartRecordToStorageFileAsync(profile, file);
                Recording = true; _duration.Restart(); _clock.Start();
                _badge ??= new DeviceRecordingBadge(() => StopAsync(), () => Open(options.Kind, options.FolderId));
                _badge.ShowAtTop(); SetStatus(label + "を収録しています。画面を閉じても続きます。");
            }
        });
    }
    private async Task ExecuteAsync(Func<Task> action)
    {
        _busy = true; SetStatus(Status); await _gate.WaitAsync();
        try { await action(); }
        catch (Exception ex)
        {
            if (Recording)
            {
                try { await _capture!.StopRecordAsync(); CaptureFiles.MarkComplete(_stage!, [_path!], _configured?.FolderId); } catch { }
                Recording = false; _duration.Stop(); _clock.Stop(); _badge?.Hide();
            }
            SetStatus(ex is UnauthorizedAccessException ? "カメラまたはマイクの利用が許可されていません。Windowsのプライバシー設定でデスクトップアプリの利用を許可してください。" : "撮影・収録を完了できませんでした。デバイスの接続と使用中のアプリを確認してください。保存待ちのファイルは保持しています。"); await ReleaseCaptureAsync();
        }
        finally { if (!Recording && _window?.IsVisible != true) await ReleaseCaptureAsync(); _gate.Release(); _busy = false; SetStatus(Status); }
    }
    private async Task PrepareAsync(DeviceCaptureOptions options)
    {
        if (options.Kind is not ("cameraPhoto" or "cameraVideo" or "audio")) throw new ArgumentException("撮影方法が不正です。");
        if (options.Kind != "audio" && string.IsNullOrEmpty(options.CameraId)) throw new ArgumentException("カメラを選択してください。");
        if (options.Kind == "audio" && string.IsNullOrEmpty(options.MicrophoneId)) throw new ArgumentException("マイクを選択してください。");
        if (_capture is not null && _configured == options) return;
        await ReleaseCaptureAsync(); _configured = options;
        _capture = new MediaCapture();
        var activeCapture = _capture;
        _capture.Failed += (_, _) => _dispatcher.BeginInvoke(async () => { if (!ReferenceEquals(_capture, activeCapture) || _disposed) return; SetStatus("デバイスとの接続が失われました。確定できる収録を保存します。"); if (Recording) await StopAsync(); else await ReleasePreviewAsync(); });
        _capture.RecordLimitationExceeded += _ => _dispatcher.BeginInvoke(async () => { if (ReferenceEquals(_capture, activeCapture) && !_disposed) await StopAsync(); });
        await _capture.InitializeAsync(new MediaCaptureInitializationSettings
        {
            VideoDeviceId = options.CameraId ?? "", AudioDeviceId = options.MicrophoneId ?? "",
            StreamingCaptureMode = options.Kind == "audio" ? StreamingCaptureMode.Audio : options.MicrophoneId is null ? StreamingCaptureMode.Video : StreamingCaptureMode.AudioAndVideo,
            MemoryPreference = MediaCaptureMemoryPreference.Cpu, SharingMode = MediaCaptureSharingMode.ExclusiveControl
        });
        if (options.Kind != "audio")
        {
            var source = _capture.FrameSources.Values.FirstOrDefault(value => value.Info.SourceKind == MediaFrameSourceKind.Color);
            if (source is not null)
            {
                var format = source.CurrentFormat.VideoFormat;
                var width = Math.Min(640u, format.Width); var height = format.Width == 0 ? 360u : Math.Max(1u, width * format.Height / format.Width);
                _frames = await _capture.CreateFrameReaderAsync(source, MediaEncodingSubtypes.Bgra8, new BitmapSize { Width = Math.Max(1u, width), Height = height });
                _frames.FrameArrived += FrameArrived;
                var result = await _frames.StartAsync();
                if (result != MediaFrameReaderStartStatus.Success) throw new IOException("カメラのプレビューを開始できませんでした。");
            }
        }
    }
    private void FrameArrived(MediaFrameReader sender, MediaFrameArrivedEventArgs args)
    {
        if (Interlocked.Exchange(ref _previewPending, 1) != 0) return;
        var queued = false;
        try
        {
            using var frame = sender.TryAcquireLatestFrame();
            if (frame?.VideoMediaFrame?.SoftwareBitmap is not { } original) return;
            using var bitmap = SoftwareBitmap.Convert(original, BitmapPixelFormat.Bgra8, BitmapAlphaMode.Ignore);
            var pixels = new byte[checked(bitmap.PixelWidth * bitmap.PixelHeight * 4)]; bitmap.CopyToBuffer(pixels.AsBuffer());
            var view = BitmapSource.Create(bitmap.PixelWidth, bitmap.PixelHeight, 96, 96, PixelFormats.Bgra32, null, pixels, bitmap.PixelWidth * 4); view.Freeze();
            _dispatcher.BeginInvoke(() => { try { if (!_disposed && ReferenceEquals(_frames, sender)) _window?.SetPreview(view); } finally { Volatile.Write(ref _previewPending, 0); } });
            queued = true;
        }
        catch (Exception ex) when (ex is ObjectDisposedException or InvalidOperationException or System.Runtime.InteropServices.COMException) { }
        finally { if (!queued) Volatile.Write(ref _previewPending, 0); }
    }
    public Task StopAsync()
    {
        if (_stopTask is { IsCompleted: false }) return _stopTask;
        return _stopTask = FinishAsync();
    }
    private async Task FinishAsync()
    {
        await _gate.WaitAsync();
        try
        {
            if (!Recording) return;
            _busy = true; SetStatus("収録を終了し、ライブラリへ保存しています…");
            await _capture!.StopRecordAsync(); Recording = false; _duration.Stop();
            CaptureFiles.MarkComplete(_stage!, [_path!], _configured?.FolderId);
            var ids = await _files.ImportCompletedAsync(_stage!); _stage = null; _path = null;
            SetStatus($"ライブラリへ保存しました（{ids.Length}件）。");
        }
        catch { Recording = false; SetStatus("収録の確定・保存に失敗しました。保存待ちのファイルを保持しています。「保存待ちを再試行」から確認してください。"); _window?.Show(); }
        finally { _duration.Stop(); _clock.Stop(); _badge?.Hide(); await ReleaseCaptureAsync(); _busy = false; _gate.Release(); SetStatus(Status); }
    }
    internal async Task ReleasePreviewAsync()
    { if (_busy || Recording) return; await _gate.WaitAsync(); try { await ReleaseCaptureAsync(); } finally { _gate.Release(); } }
    private async Task ReleaseCaptureAsync()
    {
        if (_frames is { } frames) { _frames = null; frames.FrameArrived -= FrameArrived; try { await frames.StopAsync(); } catch { } frames.Dispose(); }
        _capture?.Dispose(); _capture = null; _configured = null;
    }
    internal async Task RetryAsync()
    {
        if (_busy || Recording) return;
        await ExecuteAsync(async () => { var result = await _files.RetryPendingAsync(); SetStatus($"保存 {result.Saved}件・保存待ち {result.Failed}件。" + result.Error); });
    }
    internal void OpenPending()
    { Process.Start(new ProcessStartInfo(Path.Combine(_store.Root, "staging")) { UseShellExecute = true }); }
    public void Dispose()
    { _disposed = true; _clock.Stop(); _badge?.Close(); _window?.CloseForShutdown(); _frames?.Dispose(); _capture?.Dispose(); }
}
