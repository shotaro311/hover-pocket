using System.Diagnostics;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Threading.Channels;
using HoverPocket.Shell.Providers.Controls;
using Windows.Graphics.Capture;
using Windows.Graphics.DirectX;
using Windows.Graphics.DirectX.Direct3D11;
using Windows.Media.Core;
using Windows.Media.MediaProperties;
using Windows.Media.Transcoding;
using Windows.Storage;
using Windows.Graphics.Imaging;

namespace HoverPocket.Shell.Capture;

internal sealed class ScreenRecorder : IDisposable
{
    private readonly Channel<Direct3D11CaptureFrame> _frames = Channel.CreateBounded<Direct3D11CaptureFrame>(1);
    private readonly CancellationTokenSource _stop = new();
    private readonly GraphicsCaptureItem _item;
    private readonly IDirect3DDevice _device;
    private readonly Direct3D11CaptureFramePool _pool;
    private readonly GraphicsCaptureSession _session;
    private readonly CaptureAudio? _audio;
    private readonly Stopwatch _clock = new();
    private readonly SemaphoreSlim _videoSample = new(1), _audioSample = new(1);
    private MediaStreamSource? _source;
    private long _videoCount, _audioCount;
    private bool _disposed;
    private byte[]? _lastPixels, _scratchPixels;
    private readonly int _width, _height;
    private readonly int _inputWidth, _inputHeight;
    public string? StopReason { get; private set; }
    public long VideoFrames => Interlocked.Read(ref _videoCount);
    public bool HasAudio => _audio is not null;
    public long MicrophonePackets => _audio?.MicrophonePackets ?? 0;
    public TimeSpan Duration => _clock.Elapsed;
    public Task Completion { get; private set; } = Task.CompletedTask;

    private ScreenRecorder(GraphicsCaptureItem item, bool systemAudio, bool microphone)
    {
        _item = item; _device = WindowsGraphicsCapturePreviewService.CreateDirect3DDevice();
        _inputWidth = item.Size.Width; _inputHeight = item.Size.Height;
        if ((long)_inputWidth * _inputHeight > 32_000_000) { _device.Dispose(); throw new NotSupportedException("収録対象が大きすぎます。小さい画面またはウィンドウを選択してください。"); }
        var scale = Math.Min(1, Math.Min(1920.0 / _inputWidth, 1080.0 / _inputHeight));
        _width = Math.Max(2, ((int)(_inputWidth * scale) / 2) * 2); _height = Math.Max(2, ((int)(_inputHeight * scale) / 2) * 2);
        try
        {
            _pool = Direct3D11CaptureFramePool.CreateFreeThreaded(_device, DirectXPixelFormat.B8G8R8A8UIntNormalized, 3, item.Size);
            _session = _pool.CreateCaptureSession(item);
            if (systemAudio || microphone) _audio = new(systemAudio, microphone);
            _pool.FrameArrived += OnFrame; _item.Closed += OnTargetClosed;
        }
        catch { _session?.Dispose(); _pool?.Dispose(); _device.Dispose(); throw; }
    }
    public static async Task<ScreenRecorder> StartAsync(GraphicsCaptureItem item, string path, bool systemAudio, bool microphone)
    {
        if (!GraphicsCaptureSession.IsSupported()) throw new NotSupportedException("このWindowsでは画面収録を利用できません。");
        var recorder = new ScreenRecorder(item, systemAudio, microphone);
        try
        {
            await recorder.PrepareAsync(path).WaitAsync(TimeSpan.FromSeconds(15));
            return recorder;
        }
        catch { recorder.Stop(); recorder.Dispose(); throw; }
    }
    private async Task PrepareAsync(string path)
    {
        var video = VideoEncodingProperties.CreateUncompressed(MediaEncodingSubtypes.Bgra8, (uint)_width, (uint)_height);
        // SoftwareBitmap rows are top-down; uncompressed RGB otherwise defaults to bottom-up.
        video.Properties[new Guid("644b4e48-1e02-4516-b0eb-c01ca9d49ac6")] = (uint)(_width * 4); // MF_MT_DEFAULT_STRIDE
        video.FrameRate.Numerator = 30; video.FrameRate.Denominator = 1;
        var descriptor = new VideoStreamDescriptor(video);
        _source = _audio is null ? new MediaStreamSource(descriptor) : new MediaStreamSource(descriptor, new AudioStreamDescriptor(AudioEncodingProperties.CreatePcm(48000, 2, 16)));
        _source.BufferTime = TimeSpan.Zero; _source.IsLive = true; _source.CanSeek = false;
        _source.Starting += OnStarting;
        _source.SampleRequested += OnSampleRequested;
        var profile = MediaEncodingProfile.CreateMp4(VideoEncodingQuality.HD1080p);
        profile.Video.Width = (uint)_width; profile.Video.Height = (uint)_height;
        profile.Video.FrameRate.Numerator = 30; profile.Video.FrameRate.Denominator = 1;
        profile.Video.Bitrate = 8_000_000;
        if (_audio is null) profile.Audio = null;
        else { profile.Audio.SampleRate = 48000; profile.Audio.ChannelCount = 2; profile.Audio.Bitrate = 192000; }
        var file = await StorageFile.GetFileFromPathAsync(path);
        var stream = await file.OpenAsync(FileAccessMode.ReadWrite);
        try
        {
            _clock.Start(); _session.StartCapture();
            var preparation = await new MediaTranscoder { HardwareAccelerationEnabled = true }.PrepareMediaStreamSourceTranscodeAsync(_source, stream, profile);
            if (!preparation.CanTranscode) throw new NotSupportedException("MP4エンコーダーを利用できません: " + preparation.FailureReason);
            Completion = FinishAsync(preparation, stream);
        }
        catch { stream.Dispose(); throw; }
    }
    private async Task FinishAsync(PrepareTranscodeResult preparation, global::Windows.Storage.Streams.IRandomAccessStream stream)
    { using (stream) { try { await preparation.TranscodeAsync(); await stream.FlushAsync(); } finally { Stop(); _clock.Stop(); } } }
    private void OnFrame(Direct3D11CaptureFramePool sender, object args)
    {
        try
        {
            while (sender.TryGetNextFrame() is { } frame)
            {
                if (_stop.IsCancellationRequested) { frame.Dispose(); continue; }
                if (frame.ContentSize.Width != _inputWidth || frame.ContentSize.Height != _inputHeight)
                { frame.Dispose(); Stop("対象のサイズが変わったため収録を終了しました。"); return; }
                if (!_frames.Writer.TryWrite(frame)) { if (_frames.Reader.TryRead(out var old)) old.Dispose(); if (!_frames.Writer.TryWrite(frame)) frame.Dispose(); }
            }
        }
        catch (Exception ex) when (ex is ObjectDisposedException or System.Runtime.InteropServices.COMException) { Stop("画面の取得が終了しました。"); }
    }
    private void OnTargetClosed(GraphicsCaptureItem sender, object args) => Stop("対象のウィンドウが閉じられました。");
    private void OnStarting(MediaStreamSource sender, MediaStreamSourceStartingEventArgs args)
    { _clock.Restart(); args.Request.SetActualStartPosition(TimeSpan.Zero); }
    private async void OnSampleRequested(MediaStreamSource sender, MediaStreamSourceSampleRequestedEventArgs args)
    {
        var deferral = args.Request.GetDeferral(); var audio = args.Request.StreamDescriptor is AudioStreamDescriptor;
        var gate = audio ? _audioSample : _videoSample;
        try
        {
            await gate.WaitAsync();
            try
            {
                if (_stop.IsCancellationRequested) { args.Request.Sample = null; return; }
                if (_audio?.Failure is not null) { Stop("音声デバイスが停止しました。接続とマイクの許可を確認してください。"); args.Request.Sample = null; return; }
                if (audio)
                {
                    var timestamp = TimeSpan.FromMilliseconds(Interlocked.Read(ref _audioCount) * 20);
                    var delay = timestamp + TimeSpan.FromMilliseconds(20) - _clock.Elapsed;
                    if (delay > TimeSpan.Zero) await Task.Delay(delay, _stop.Token);
                    var sample = MediaStreamSample.CreateFromBuffer(_audio!.ReadPcmBlock().AsBuffer(), timestamp); sample.Duration = TimeSpan.FromMilliseconds(20);
                    args.Request.Sample = sample; Interlocked.Increment(ref _audioCount);
                }
                else
                {
                    var timestamp = TimeSpan.FromSeconds(Interlocked.Read(ref _videoCount) / 30.0);
                    var delay = timestamp - _clock.Elapsed; if (delay > TimeSpan.Zero) await Task.Delay(delay, _stop.Token);
                    Direct3D11CaptureFrame? frame;
                    if (_lastPixels is null) frame = await _frames.Reader.ReadAsync(_stop.Token).AsTask().WaitAsync(TimeSpan.FromSeconds(5));
                    else _frames.Reader.TryRead(out frame);
                    if (frame is not null)
                    {
                        using (frame) using (var bitmap = await SoftwareBitmap.CreateCopyFromSurfaceAsync(frame.Surface))
                        {
                            var size = checked(bitmap.PixelWidth * bitmap.PixelHeight * 4);
                            if (_scratchPixels is null || _scratchPixels.Length != size) _scratchPixels = new byte[size];
                            bitmap.CopyToBuffer(_scratchPixels.AsBuffer()); _lastPixels = ScalePixels(_scratchPixels, bitmap.PixelWidth, _inputWidth, _inputHeight, _width, _height);
                        }
                    }
                    // The immutable CPU snapshot releases the capture pool immediately. Repeating
                    // it on the media clock preserves still screens and silent intervals at 30fps.
                    var sample = MediaStreamSample.CreateFromBuffer(_lastPixels!.AsBuffer(), timestamp); sample.Duration = TimeSpan.FromSeconds(1.0 / 30);
                    args.Request.Sample = sample; Interlocked.Increment(ref _videoCount);
                }
            }
            finally { gate.Release(); }
        }
        catch (OperationCanceledException) { args.Request.Sample = null; }
        catch (Exception) { Stop("収録のフレームを処理できませんでした。"); args.Request.Sample = null; }
        finally { deferral.Complete(); }
    }
    public void Stop(string? reason = null) { if (reason is not null) StopReason ??= reason; _stop.Cancel(); _frames.Writer.TryComplete(); }
    private static byte[] ScalePixels(byte[] source, int strideWidth, int inputWidth, int inputHeight, int width, int height)
    {
        var output = new byte[width * height * 4];
        var pixels = System.Runtime.InteropServices.MemoryMarshal.Cast<byte, uint>(source.AsSpan()); var target = System.Runtime.InteropServices.MemoryMarshal.Cast<byte, uint>(output.AsSpan());
        for (var y = 0; y < height; y++) { var row = y * inputHeight / height * strideWidth; for (var x = 0; x < width; x++) target[y * width + x] = pixels[row + x * inputWidth / width] | 0xFF000000; }
        return output;
    }
    public void Dispose()
    {
        if (_disposed) return; _disposed = true; Stop();
        _pool.FrameArrived -= OnFrame; _item.Closed -= OnTargetClosed;
        _session.Dispose(); _pool.Dispose(); while (_frames.Reader.TryRead(out var frame)) frame.Dispose();
        _audio?.Dispose(); _device.Dispose();
        if (_source is not null) { _source.SampleRequested -= OnSampleRequested; _source.Starting -= OnStarting; _source = null; }
        _scratchPixels = null; _lastPixels = null;
    }
}
