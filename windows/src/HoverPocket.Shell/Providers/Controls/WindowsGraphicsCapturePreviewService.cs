using System.Diagnostics;
using System.Runtime.InteropServices;
using Windows.Graphics.Capture;
using Windows.Graphics.DirectX;
using Windows.Graphics.DirectX.Direct3D11;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using WinBitmapEncoder = Windows.Graphics.Imaging.BitmapEncoder;
using WpfBitmapDecoder = System.Windows.Media.Imaging.BitmapDecoder;

namespace HoverPocket.Shell.Providers.Controls;

internal sealed class WindowsGraphicsCapturePreviewService : IMediaPreviewService, IDisposable
{
    private static readonly TimeSpan FirstFrameTimeout = TimeSpan.FromSeconds(2);
    private static readonly TimeSpan PreviewFrameInterval = TimeSpan.FromMilliseconds(100);
    private readonly object _sync = new();
    private IDirect3DDevice? _device;
    private GraphicsCaptureItem? _item;
    private Direct3D11CaptureFramePool? _framePool;
    private GraphicsCaptureSession? _captureSession;
    private Direct3D11CaptureFrame? _pendingFrame;
    private CancellationTokenSource? _captureCancellation;
    private TaskCompletionSource _firstFrame = NewFirstFrameSource();
    private Stopwatch? _captureClock;
    private nint? _windowHandle;
    private long _completeFrameCount;
    private long _encodedFrameCount;
    private long _replacedPendingFrameCount;
    private long _lastFrameEncodedAt;
    private int _initialBlackFrames;
    private bool _contentValidated;
    private int _processingFrames;
    private bool _disposed;

    public event EventHandler<MediaPreviewState>? StateChanged;

    public event EventHandler<MediaPreviewFrame>? FrameArrived;

    public MediaPreviewState CurrentState { get; private set; } = MediaPreviewState.Inactive;

    public async Task StartAsync(MediaSessionState media, CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (!media.Available)
        {
            SetFallback("fallback_no_session");
            return;
        }

        if (media.PreviewWindowHandle is not { } windowHandle || windowHandle == IntPtr.Zero)
        {
            SetFallback("fallback_no_window");
            return;
        }

        lock (_sync)
        {
            if (_windowHandle == windowHandle && _captureSession is not null)
            {
                return;
            }
        }

        StopResources();
        if (!GraphicsCaptureSession.IsSupported())
        {
            SetFallback("fallback_unsupported", "Windows Graphics Capture is unavailable.");
            return;
        }

        try
        {
            var captureCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            var device = CreateDirect3DDevice();
            var item = CreateCaptureItemForWindow(windowHandle);
            var framePool = Direct3D11CaptureFramePool.CreateFreeThreaded(
                device,
                DirectXPixelFormat.B8G8R8A8UIntNormalized,
                2,
                item.Size);
            var captureSession = framePool.CreateCaptureSession(item);
            if (OperatingSystem.IsWindowsVersionAtLeast(10, 0, 19041))
            {
                captureSession.IsCursorCaptureEnabled = false;
            }

            lock (_sync)
            {
                _device = device;
                _item = item;
                _framePool = framePool;
                _captureSession = captureSession;
                _captureCancellation = captureCancellation;
                _windowHandle = windowHandle;
                _completeFrameCount = 0;
                _encodedFrameCount = 0;
                _replacedPendingFrameCount = 0;
                _lastFrameEncodedAt = 0;
                _initialBlackFrames = 0;
                _contentValidated = false;
                _captureClock = Stopwatch.StartNew();
                _firstFrame = NewFirstFrameSource();
                framePool.FrameArrived += OnFrameArrived;
                item.Closed += OnCaptureItemClosed;
            }

            SetState(new MediaPreviewState("starting", false, true, 0, 0));
            captureSession.StartCapture();
            await _firstFrame.Task.WaitAsync(FirstFrameTimeout, cancellationToken);
        }
        catch (TimeoutException)
        {
            StopResources();
            SetFallback("fallback_first_frame_timeout", "Live preview produced no frame within two seconds.");
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            StopResources();
            throw;
        }
        catch (Exception ex) when (ex is COMException or InvalidOperationException or NotSupportedException)
        {
            StopResources();
            SetFallback("fallback_start_failed", $"Live preview could not start: {ex.GetType().Name}");
        }
    }

    public void Stop()
    {
        StopResources();
        SetState(MediaPreviewState.Inactive);
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        StopResources();
    }

    private void OnFrameArrived(Direct3D11CaptureFramePool sender, object args)
    {
        _ = args;
        Direct3D11CaptureFrame? newest = null;
        try
        {
            Direct3D11CaptureFrame? frame;
            while ((frame = sender.TryGetNextFrame()) is not null)
            {
                newest?.Dispose();
                newest = frame;
            }
        }
        catch (Exception ex) when (ex is COMException or ObjectDisposedException)
        {
            FailStream("fallback_stream_stopped", ex.GetType().Name);
            return;
        }

        if (newest is null)
        {
            return;
        }

        lock (_sync)
        {
            if (_captureSession is null
                || _captureCancellation is null
                || _captureCancellation.IsCancellationRequested)
            {
                newest.Dispose();
                return;
            }

            if (_pendingFrame is not null)
            {
                _replacedPendingFrameCount++;
                _pendingFrame.Dispose();
            }
            _pendingFrame = newest;
            _completeFrameCount++;
            _firstFrame.TrySetResult();
        }

        if (Interlocked.CompareExchange(ref _processingFrames, 1, 0) == 0)
        {
            _ = ProcessLatestFramesAsync();
        }
    }

    private void OnCaptureItemClosed(GraphicsCaptureItem sender, object args)
    {
        _ = sender;
        _ = args;
        FailStream("fallback_window_closed", "The captured window closed.");
    }

    private async Task ProcessLatestFramesAsync()
    {
        try
        {
            while (true)
            {
                Direct3D11CaptureFrame? frame;
                CancellationToken cancellationToken;
                lock (_sync)
                {
                    cancellationToken = _captureCancellation?.Token ?? new CancellationToken(true);
                }

                var lastEncodedAt = Volatile.Read(ref _lastFrameEncodedAt);
                if (lastEncodedAt != 0)
                {
                    var remaining = PreviewFrameInterval - Stopwatch.GetElapsedTime(lastEncodedAt);
                    if (remaining > TimeSpan.Zero)
                    {
                        await Task.Delay(remaining, cancellationToken);
                    }
                }

                lock (_sync)
                {
                    frame = _pendingFrame;
                    _pendingFrame = null;
                    cancellationToken = _captureCancellation?.Token ?? new CancellationToken(true);
                }

                if (frame is null || cancellationToken.IsCancellationRequested)
                {
                    frame?.Dispose();
                    return;
                }

                try
                {
                    var encoded = await EncodeFrameAsync(frame, cancellationToken);
                    Volatile.Write(ref _lastFrameEncodedAt, Stopwatch.GetTimestamp());
                    if (!_contentValidated)
                    {
                        if (encoded.LikelyBlack)
                        {
                            _initialBlackFrames++;
                            if (_initialBlackFrames >= 10)
                            {
                                FailStream("fallback_protected_content", "Captured frames remained black.");
                                return;
                            }

                            continue;
                        }

                        _contentValidated = true;
                    }

                    long frameCount;
                    long encodedFrameCount;
                    long replacedPendingFrameCount;
                    double fps;
                    lock (_sync)
                    {
                        _encodedFrameCount++;
                        frameCount = _completeFrameCount;
                        encodedFrameCount = _encodedFrameCount;
                        replacedPendingFrameCount = _replacedPendingFrameCount;
                        var seconds = Math.Max(0.001, _captureClock?.Elapsed.TotalSeconds ?? 0.001);
                        fps = encodedFrameCount / seconds;
                    }

                    SetState(new MediaPreviewState(
                        "live",
                        true,
                        false,
                        frameCount,
                        fps,
                        EncodedFrameCount: encodedFrameCount,
                        ReplacedPendingFrameCount: replacedPendingFrameCount));
                    FrameArrived?.Invoke(this, new MediaPreviewFrame(encoded.DataUrl, frameCount, fps));
                }
                finally
                {
                    frame.Dispose();
                }
            }
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception ex) when (ex is COMException or InvalidOperationException or ObjectDisposedException)
        {
            FailStream("fallback_stream_error", ex.GetType().Name);
        }
        finally
        {
            Interlocked.Exchange(ref _processingFrames, 0);
            lock (_sync)
            {
                if (_pendingFrame is not null
                    && _captureSession is not null
                    && _captureCancellation is { IsCancellationRequested: false }
                    && Interlocked.CompareExchange(ref _processingFrames, 1, 0) == 0)
                {
                    _ = ProcessLatestFramesAsync();
                }
            }
        }
    }

    private static async Task<EncodedFrame> EncodeFrameAsync(
        Direct3D11CaptureFrame frame,
        CancellationToken cancellationToken)
    {
        using var source = await SoftwareBitmap.CreateCopyFromSurfaceAsync(frame.Surface).AsTask(cancellationToken);
        using var stream = new InMemoryRandomAccessStream();
        var encoder = await WinBitmapEncoder.CreateAsync(WinBitmapEncoder.JpegEncoderId, stream).AsTask(cancellationToken);
        encoder.BitmapTransform.ScaledWidth = 392;
        encoder.BitmapTransform.ScaledHeight = 220;
        encoder.BitmapTransform.InterpolationMode = BitmapInterpolationMode.Fant;
        encoder.SetSoftwareBitmap(source);
        await encoder.FlushAsync().AsTask(cancellationToken);

        stream.Seek(0);
        var length = checked((uint)stream.Size);
        using var reader = new DataReader(stream.GetInputStreamAt(0));
        _ = await reader.LoadAsync(length).AsTask(cancellationToken);
        var bytes = new byte[length];
        reader.ReadBytes(bytes);
        return new EncodedFrame(
            $"data:image/jpeg;base64,{Convert.ToBase64String(bytes)}",
            IsLikelyBlackPreview(bytes));
    }

    private static bool IsLikelyBlackPreview(byte[] jpegBytes)
    {
        try
        {
            using var stream = new MemoryStream(jpegBytes, writable: false);
            var decoder = WpfBitmapDecoder.Create(
                stream,
                BitmapCreateOptions.PreservePixelFormat,
                BitmapCacheOption.OnLoad);
            var converted = new FormatConvertedBitmap(decoder.Frames[0], PixelFormats.Bgra32, null, 0);
            var stride = converted.PixelWidth * 4;
            var pixels = new byte[stride * converted.PixelHeight];
            converted.CopyPixels(pixels, stride, 0);
            var left = converted.PixelWidth / 10;
            var right = converted.PixelWidth - left;
            var top = converted.PixelHeight / 10;
            var bottom = converted.PixelHeight - top;
            var bright = 0;
            var sampled = 0;
            for (var y = top; y < bottom; y += 4)
            {
                for (var x = left; x < right; x += 4)
                {
                    var offset = y * stride + x * 4;
                    sampled++;
                    if (pixels[offset] > 14 || pixels[offset + 1] > 14 || pixels[offset + 2] > 14)
                    {
                        bright++;
                    }
                }
            }

            return sampled > 0 && bright < sampled / 100;
        }
        catch (Exception ex) when (ex is NotSupportedException or FileFormatException)
        {
            return false;
        }
    }

    private void FailStream(string mode, string error)
    {
        _ = Task.Run(() =>
        {
            StopResources();
            SetFallback(mode, error);
        });
    }

    private void SetFallback(string mode, string? error = null)
    {
        StopResources();
        SetState(MediaPreviewState.FallbackState(mode, error));
    }

    private void SetState(MediaPreviewState state)
    {
        var previous = CurrentState;
        CurrentState = state;
        if (!_disposed
            && (!string.Equals(previous.Mode, state.Mode, StringComparison.Ordinal)
                || previous.Live != state.Live
                || previous.Fallback != state.Fallback
                || !string.Equals(previous.Error, state.Error, StringComparison.Ordinal)))
        {
            StateChanged?.Invoke(this, state);
        }
    }

    private void StopResources()
    {
        Direct3D11CaptureFramePool? framePool;
        GraphicsCaptureItem? item;
        GraphicsCaptureSession? captureSession;
        Direct3D11CaptureFrame? pendingFrame;
        IDirect3DDevice? device;
        CancellationTokenSource? captureCancellation;

        lock (_sync)
        {
            framePool = _framePool;
            item = _item;
            captureSession = _captureSession;
            pendingFrame = _pendingFrame;
            device = _device;
            captureCancellation = _captureCancellation;
            _framePool = null;
            _item = null;
            _captureSession = null;
            _pendingFrame = null;
            _device = null;
            _captureCancellation = null;
            _windowHandle = null;
            _captureClock = null;
            _completeFrameCount = 0;
            _encodedFrameCount = 0;
            _replacedPendingFrameCount = 0;
            _firstFrame.TrySetCanceled();
        }

        captureCancellation?.Cancel();
        if (framePool is not null)
        {
            framePool.FrameArrived -= OnFrameArrived;
        }

        if (item is not null)
        {
            item.Closed -= OnCaptureItemClosed;
        }

        pendingFrame?.Dispose();
        captureSession?.Dispose();
        framePool?.Dispose();
        device?.Dispose();
        captureCancellation?.Dispose();
    }

    private static TaskCompletionSource NewFirstFrameSource() =>
        new(TaskCreationOptions.RunContinuationsAsynchronously);

    private sealed record EncodedFrame(string DataUrl, bool LikelyBlack);

    private static IDirect3DDevice CreateDirect3DDevice()
    {
        const uint createDeviceBgraSupport = 0x20;
        var result = D3D11CreateDevice(
            IntPtr.Zero,
            1,
            IntPtr.Zero,
            createDeviceBgraSupport,
            IntPtr.Zero,
            0,
            7,
            out var d3dDevice,
            out _,
            out var immediateContext);
        ThrowIfFailed(result);
        try
        {
            var dxgiDeviceId = new Guid("54EC77FA-1377-44E6-8C32-88FD5F44C84C");
            ThrowIfFailed(Marshal.QueryInterface(d3dDevice, in dxgiDeviceId, out var dxgiDevice));
            try
            {
                ThrowIfFailed(CreateDirect3D11DeviceFromDXGIDevice(dxgiDevice, out var inspectableDevice));
                try
                {
                    return WinRT.ComWrappersSupport.CreateRcwForComObject<IDirect3DDevice>(inspectableDevice);
                }
                finally
                {
                    _ = Marshal.Release(inspectableDevice);
                }
            }
            finally
            {
                _ = Marshal.Release(dxgiDevice);
            }
        }
        finally
        {
            if (immediateContext != IntPtr.Zero)
            {
                _ = Marshal.Release(immediateContext);
            }

            if (d3dDevice != IntPtr.Zero)
            {
                _ = Marshal.Release(d3dDevice);
            }
        }
    }

    private static GraphicsCaptureItem CreateCaptureItemForWindow(nint windowHandle)
    {
        using var factory = WinRT.ActivationFactory.Get("Windows.Graphics.Capture.GraphicsCaptureItem");
        var interopId = typeof(IGraphicsCaptureItemInterop).GUID;
        ThrowIfFailed(Marshal.QueryInterface(factory.ThisPtr, in interopId, out var interopPointer));
        try
        {
            var interop = (IGraphicsCaptureItemInterop)Marshal.GetObjectForIUnknown(interopPointer);
            var itemId = new Guid("79C3F95B-31F7-4EC2-A464-632EF5D30760");
            ThrowIfFailed(interop.CreateForWindow(windowHandle, ref itemId, out var itemPointer));
            try
            {
                return WinRT.ComWrappersSupport.CreateRcwForComObject<GraphicsCaptureItem>(itemPointer);
            }
            finally
            {
                _ = Marshal.Release(itemPointer);
            }
        }
        finally
        {
            _ = Marshal.Release(interopPointer);
        }
    }

    private static void ThrowIfFailed(int result)
    {
        if (result < 0)
        {
            Marshal.ThrowExceptionForHR(result);
        }
    }

    [ComImport]
    [Guid("3628E81B-3CAC-4C60-B7F4-23CE0E0C3356")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IGraphicsCaptureItemInterop
    {
        [PreserveSig]
        int CreateForWindow(IntPtr window, ref Guid interfaceId, out IntPtr result);

        [PreserveSig]
        int CreateForMonitor(IntPtr monitor, ref Guid interfaceId, out IntPtr result);
    }

    [DllImport("d3d11.dll")]
    private static extern int D3D11CreateDevice(
        IntPtr adapter,
        int driverType,
        IntPtr software,
        uint flags,
        IntPtr featureLevels,
        uint featureLevelCount,
        uint sdkVersion,
        out IntPtr device,
        out uint featureLevel,
        out IntPtr immediateContext);

    [DllImport("d3d11.dll")]
    private static extern int CreateDirect3D11DeviceFromDXGIDevice(
        IntPtr dxgiDevice,
        out IntPtr graphicsDevice);
}
