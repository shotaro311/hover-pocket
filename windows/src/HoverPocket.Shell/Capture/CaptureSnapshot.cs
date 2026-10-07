using System.Runtime.InteropServices.WindowsRuntime;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using HoverPocket.Shell.Providers.Controls;
using Windows.Graphics.Capture;
using Windows.Graphics.DirectX;
using Windows.Graphics.Imaging;

namespace HoverPocket.Shell.Capture;

internal static class CaptureSnapshot
{
    public static async Task<BitmapSource> ReadAsync(GraphicsCaptureItem item, CancellationToken token)
    {
        if (item.Size.Width <= 0 || item.Size.Height <= 0 || (long)item.Size.Width * item.Size.Height > 32_000_000)
            throw new InvalidOperationException("capture_size_unsupported");
        using var device = WindowsGraphicsCapturePreviewService.CreateDirect3DDevice();
        using var pool = Direct3D11CaptureFramePool.CreateFreeThreaded(device, DirectXPixelFormat.B8G8R8A8UIntNormalized, 2, item.Size);
        using var session = pool.CreateCaptureSession(item);
        var ready = new TaskCompletionSource<Direct3D11CaptureFrame>(TaskCreationOptions.RunContinuationsAsynchronously);
        var accepting = 1;
        Direct3D11CaptureFrame? acquired = null;
        void Frame(Direct3D11CaptureFramePool source, object _) {
            try { if (source.TryGetNextFrame() is { } frame && (Interlocked.Exchange(ref accepting, 0) == 0 || !ready.TrySetResult(frame))) frame.Dispose(); }
            catch (Exception exception) { ready.TrySetException(exception); }
        }
        pool.FrameArrived += Frame;
        try
        {
            session.StartCapture();
            var frame = acquired = await ready.Task.WaitAsync(TimeSpan.FromSeconds(8), token);
            using var bitmap = await SoftwareBitmap.CreateCopyFromSurfaceAsync(frame.Surface, BitmapAlphaMode.Ignore).AsTask(token);
            var width = frame.ContentSize.Width; var height = frame.ContentSize.Height;
            if (width <= 0 || height <= 0 || width > bitmap.PixelWidth || height > bitmap.PixelHeight) throw new InvalidOperationException("capture_size_changed");
            var pixels = new byte[checked(bitmap.PixelWidth * bitmap.PixelHeight * 4)];
            bitmap.CopyToBuffer(pixels.AsBuffer());
            var image = BitmapSource.Create(width, height, 96, 96, PixelFormats.Bgr32, null, pixels, bitmap.PixelWidth * 4);
            image.Freeze();
            return image;
        }
        finally
        {
            Interlocked.Exchange(ref accepting, 0);
            pool.FrameArrived -= Frame;
            // A frame delivered after cancellation still owns a D3D surface.
            if (!ready.Task.IsCompleted) ready.TrySetCanceled();
            acquired?.Dispose();
            if (ready.Task.IsCompletedSuccessfully && !ReferenceEquals(acquired, ready.Task.Result)) ready.Task.Result.Dispose();
        }
    }
}
