using System.Windows.Media.Imaging;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Windows.Media;
using HoverPocket.Assets;
using Windows.Storage;
using Windows.Storage.Streams;

namespace HoverPocket.Shell.Providers.Assets;

internal sealed record AssetFrame(string? DataUrl, double Width, double Height, int Pages = 1, string? Error = null, string ContentType = "image/jpeg", string? FailureCode = null, string? TextContent = null, bool Truncated = false);

internal sealed class AssetMedia(AssetStore store)
{
    private static readonly System.Runtime.CompilerServices.ConditionalWeakTable<AssetStore, AssetMedia> Shared = new();
    public static AssetMedia For(AssetStore store) => Shared.GetValue(store, value => new(value));
    private readonly AssetDecodeQueue _decoder = new();
    private readonly PdfRenderClient _pdf = new();
    internal Task StopPdfWorkerForVerifyAsync() => _pdf.StopForVerifyAsync();
    public async Task<AssetFrame> FrameAsync(Asset asset, int page, bool thumbnail, CancellationToken token)
    {
        var stage = "start";
        var kind = AssetPreviewFormats.Kind(asset.Extension);
        if (kind is "text" or "document")
        {
            try
            {
                var content = await Task.Run(() => AssetDocumentPreview.ReadAsync(store.ReadOriginalPath(asset), asset.Extension, token), token);
                return new(null, 860, 600, TextContent: thumbnail ? content.Text[..Math.Min(content.Text.Length, 700)] : content.Text, Truncated: content.Truncated);
            }
            catch (OperationCanceledException) { throw; }
            catch (InvalidDataException ex) { return new(null, 860, 600, Error: ex.Message); }
            catch (Exception ex) when (ex is IOException or InvalidDataException or System.Xml.XmlException or NotSupportedException or ArgumentException or System.Text.DecoderFallbackException)
            { return new(null, 860, 600, Error: "文書を表示できません。形式・破損・保護を確認してください。原本は保存されています。"); }
        }
        var cacheDirectory = Path.Combine(store.Root, "cache", thumbnail ? "thumbnails" : "previews");
        var cache = Path.Combine(cacheDirectory, $"{asset.Id}-{(thumbnail ? "thumb" : page.ToString())}.jpg");
        var metadata = cache + ".json";
        using var lease = await _decoder.AcquireAsync(thumbnail, token);
        try
        {
            return await Task.Run(async () =>
            {
                token.ThrowIfCancellationRequested();
                var path = store.ReadOriginalPath(asset);
                if (File.Exists(cache) && File.Exists(metadata))
                {
                    try
                    {
                        var frame = System.Text.Json.JsonSerializer.Deserialize<AssetFrame>(await File.ReadAllTextAsync(metadata, token))!;
                        var cachedBytes = await File.ReadAllBytesAsync(cache, token);
                        try { File.SetLastWriteTimeUtc(cache, DateTime.UtcNow); } catch (IOException) { } catch (UnauthorizedAccessException) { }
                        return frame with { DataUrl = "data:" + frame.ContentType + ";base64," + Convert.ToBase64String(cachedBytes) };
                    }
                    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.Text.Json.JsonException) { }
                }
                var max = thumbnail ? 240 : 2048;
                BitmapSource bitmap; double width; double height; var pages = 1;
                if (kind == "image")
                {
                    if (asset.Extension is "heic" or "heif" or "webp" or "avif" or "jxr" or "wdp" or "dng" or "cr2" or "cr3" or "nef" or "arw" or "orf" or "rw2")
                    {
                        var decoded = await DecodeModernImageAsync(path, max, token);
                        bitmap = decoded.Bitmap; width = decoded.Width; height = decoded.Height;
                    }
                    else
                    {
                    using var stream = File.OpenRead(path);
                    var probe = BitmapDecoder.Create(stream, BitmapCreateOptions.DelayCreation, BitmapCacheOption.None).Frames[0];
                    width = probe.PixelWidth; height = probe.PixelHeight;
                    var orientation = ReadOrientation(probe);
                    if (width <= 0 || height <= 0 || width * height > 250_000_000) return new(null, 0, 0, Error: "画像が大きすぎるため縮小プレビューを生成できません。");
                    if (asset.Extension != "jpg" && asset.Extension != "jpeg" && width * height > 32_000_000) return new(null, width, height, Error: "この大きさの画像はメモリ予算を超えるためプレビューを制限しています。原本の取り出しはできます。");
                    stream.Position = 0;
                    var image = new BitmapImage(); image.BeginInit(); image.CacheOption = BitmapCacheOption.OnLoad;
                    if (width >= height) image.DecodePixelWidth = (int)Math.Min(max, width); else image.DecodePixelHeight = (int)Math.Min(max, height);
                    image.StreamSource = stream; image.EndInit(); image.Freeze(); bitmap = image;
                    bitmap = ApplyOrientation(bitmap, orientation);
                    if (orientation >= 5) (width, height) = (height, width);
                    }
                }
                else if (asset.Kind == "pdf")
                {
                    stage = "pdf.worker";
                    var frame = await _pdf.RenderAsync(path, page, max, token);
                    if (frame.Error is not null || frame.DataUrl is null) return frame;
                    width = frame.Width; height = frame.Height; pages = frame.Pages;
                    using var stream = new MemoryStream(Convert.FromBase64String(frame.DataUrl[(frame.DataUrl.IndexOf(',') + 1)..]));
                    bitmap = BitmapDecoder.Create(stream, BitmapCreateOptions.None, BitmapCacheOption.OnLoad).Frames[0]; bitmap.Freeze();
                }
                else if (kind == "video")
                {
                    stage = "video.open";
                    var file = await StorageFile.GetFileFromPathAsync(path);
                    stage = "video.thumbnail";
                    using var output = await file.GetThumbnailAsync(global::Windows.Storage.FileProperties.ThumbnailMode.VideosView, (uint)Math.Min(max, 640), global::Windows.Storage.FileProperties.ThumbnailOptions.None);
                    stage = "video.properties";
                    var properties = await file.Properties.GetVideoPropertiesAsync(); width = properties.Width; height = properties.Height;
                    stage = "video.orientation";
                    if (properties.Orientation is global::Windows.Storage.FileProperties.VideoOrientation.Rotate90 or global::Windows.Storage.FileProperties.VideoOrientation.Rotate270) (width, height) = (height, width);
                    if (output is null || output.Type != global::Windows.Storage.FileProperties.ThumbnailType.Image) throw new IOException("動画のポスターを生成できません。");
                    // Finish WinRT awaits before constructing WPF decoder objects: BitmapFrame metadata retains thread affinity.
                    stage = "video.decode";
                    using var stream = output.AsStreamForRead(); bitmap = BitmapDecoder.Create(stream, BitmapCreateOptions.None, BitmapCacheOption.OnLoad).Frames[0]; bitmap.Freeze();
                }
                else return new(null, 0, 0, Error: "この形式はプレビューに対応していません。原本の保存・取り出しはできます。");
                token.ThrowIfCancellationRequested();
                stage = "encode";
                byte[] bytes; var quality = thumbnail ? 75 : 90;
                var transparent = kind == "image" && asset.Extension is "png" or "gif" or "webp" or "avif" or "heic" or "heif" or "ico";
                do
                {
                    BitmapEncoder encoder = transparent ? new PngBitmapEncoder() : new JpegBitmapEncoder { QualityLevel = quality }; encoder.Frames.Add(BitmapFrame.Create(bitmap));
                    using var output = new MemoryStream(); encoder.Save(output); bytes = output.ToArray(); quality -= 10;
                } while (thumbnail && bytes.Length > 65536 && quality >= 15);
                if (thumbnail && bytes.Length > 65536) return new(null, width, height, pages, "サムネイルを生成できません。");
                var result = new AssetFrame(null, width, height, pages, ContentType: transparent ? "image/png" : "image/jpeg");
                try
                {
                    Directory.CreateDirectory(cacheDirectory);
                    if (!thumbnail) await TrimPreviewCacheAsync(bytes.LongLength);
                    await File.WriteAllBytesAsync(cache, bytes, token);
                    await File.WriteAllTextAsync(metadata, System.Text.Json.JsonSerializer.Serialize(result), token);
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
                return result with { DataUrl = "data:" + result.ContentType + ";base64," + Convert.ToBase64String(bytes) };
            }, token);
        }
        catch (OperationCanceledException) { throw; }
        catch (InvalidDataException ex) { return new(null,0,0,Error:ex.Message); }
        catch (Exception ex) when (asset.Kind == "pdf" && ex.HResult == unchecked((int)0x8007052B))
        { return new(null,0,0,Error:"パスワードで保護されたPDFです。原本は保存済みです。OSで開くか、保護を解除したファイルを追加してください。"); }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            if (kind is "image" or "video" && AssetCompatibleMedia.Executable is not null)
            {
                try
                {
                    var compatible = await AssetCompatibleMedia.ConvertAsync(store, asset, "image", token);
                    var bytes = await File.ReadAllBytesAsync(compatible, token);
                    using var decoded = new MemoryStream(bytes);
                    BitmapSource bitmap = BitmapDecoder.Create(decoded, BitmapCreateOptions.None, BitmapCacheOption.OnLoad).Frames[0];
                    if (thumbnail)
                    {
                        var scale = Math.Min(1, 240d / Math.Max(bitmap.PixelWidth, bitmap.PixelHeight));
                        bitmap = new TransformedBitmap(bitmap, new ScaleTransform(scale, scale)); bitmap.Freeze();
                        do
                        {
                            var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap));
                            using var output = new MemoryStream(); encoder.Save(output); bytes = output.ToArray();
                            if (bytes.Length <= 65536) break;
                            bitmap = new TransformedBitmap(bitmap, new ScaleTransform(.75, .75)); bitmap.Freeze();
                        } while (Math.Max(bitmap.PixelWidth, bitmap.PixelHeight) > 32);
                        if (bytes.Length > 65536) throw new IOException("サムネイルの表示容量の上限を超えています。");
                    }
                    return new("data:image/png;base64," + Convert.ToBase64String(bytes), bitmap.PixelWidth, bitmap.PixelHeight, ContentType: "image/png");
                }
                catch (IOException) { }
            }
            var browserMime = asset.Extension switch { "webp" => "image/webp", "avif" => "image/avif", "svg" => "image/svg+xml", "gif" => "image/gif", "ico" => "image/x-icon", _ => null };
            if (browserMime is not null && asset.SizeBytes <= 8 * 1024 * 1024)
            {
                var bytes = await File.ReadAllBytesAsync(store.ReadOriginalPath(asset), token);
                return new("data:" + browserMime + ";base64," + Convert.ToBase64String(bytes), 860, 600, ContentType: browserMime);
            }
            return new(null, 0, 0, Error: "プレビューを生成できません。形式・破損・保護・Windowsのメディア機能を確認してください。原本は保存されています。", FailureCode: $"{stage}:{ex.GetType().Name}:{ex.HResult:X8}"); }
    }
    private static async Task<(BitmapSource Bitmap, double Width, double Height)> DecodeModernImageAsync(string path, int maximum, CancellationToken token)
    {
        var file = await StorageFile.GetFileFromPathAsync(path);
        using var stream = await file.OpenReadAsync();
        var decoder = await global::Windows.Graphics.Imaging.BitmapDecoder.CreateAsync(stream);
        var width = decoder.OrientedPixelWidth; var height = decoder.OrientedPixelHeight;
        if (width == 0 || height == 0 || (double)width * height > 250_000_000) throw new InvalidDataException("画像の画素数が表示の上限を超えています。");
        var scale = Math.Min(1, (double)maximum / Math.Max(width, height));
        var transform = new global::Windows.Graphics.Imaging.BitmapTransform { ScaledWidth = (uint)Math.Max(1, decoder.PixelWidth * scale), ScaledHeight = (uint)Math.Max(1, decoder.PixelHeight * scale) };
        using var software = await decoder.GetSoftwareBitmapAsync(global::Windows.Graphics.Imaging.BitmapPixelFormat.Bgra8,
            global::Windows.Graphics.Imaging.BitmapAlphaMode.Premultiplied, transform, global::Windows.Graphics.Imaging.ExifOrientationMode.RespectExifOrientation,
            global::Windows.Graphics.Imaging.ColorManagementMode.ColorManageToSRgb);
        token.ThrowIfCancellationRequested();
        var pixels = new byte[checked(software.PixelWidth * software.PixelHeight * 4)];
        software.CopyToBuffer(pixels.AsBuffer());
        var bitmap = BitmapSource.Create(software.PixelWidth, software.PixelHeight, 96, 96, PixelFormats.Pbgra32, null, pixels, software.PixelWidth * 4);
        bitmap.Freeze(); return (bitmap, width, height);
    }
    internal static ushort ReadOrientation(BitmapFrame frame)
    {
        try { if (frame.Metadata is BitmapMetadata data && data.ContainsQuery("/app1/ifd/{ushort=274}")) return Convert.ToUInt16(data.GetQuery("/app1/ifd/{ushort=274}")); }
        catch (NotSupportedException) { }
        return 1;
    }
    internal static BitmapSource ApplyOrientation(BitmapSource bitmap, ushort orientation)
    {
        var transforms = new TransformGroup();
        if (orientation is 2 or 4 or 5 or 7) transforms.Children.Add(new ScaleTransform(-1, 1));
        var rotation = orientation switch { 3 or 4 => 180, 5 or 6 => 90, 7 or 8 => 270, _ => 0 };
        if (rotation != 0) transforms.Children.Add(new RotateTransform(rotation));
        if (transforms.Children.Count == 0) return bitmap;
        var oriented = new TransformedBitmap(bitmap, transforms); oriented.Freeze(); return oriented;
    }
    private async Task TrimPreviewCacheAsync(long incomingBytes)
    {
        var files = new DirectoryInfo(Path.Combine(store.Root, "cache", "previews")).EnumerateFiles("*.jpg").OrderBy(f => f.LastWriteTimeUtc).ToArray();
        var size = files.Sum(f => f.Length + (File.Exists(f.FullName + ".json") ? new FileInfo(f.FullName + ".json").Length : 0));
        var budget = 2L * 1024 * 1024 * 1024 - incomingBytes - 1024;
        foreach (var file in files)
        {
            if (size <= budget) break;
            // Generated cache only; never original media or metadata.
            var length = file.Length + (File.Exists(file.FullName + ".json") ? new FileInfo(file.FullName + ".json").Length : 0);
            if (await AssetRecycle.MoveAsync(file.FullName)) { size -= length; if (File.Exists(file.FullName + ".json")) await AssetRecycle.MoveAsync(file.FullName + ".json"); }
        }
        if (size > budget) throw new IOException("Preview cache budget reached; render without persisting cache.");
    }
}

internal sealed class AssetDecodeQueue
{
    private readonly object _sync = new();
    private readonly PriorityQueue<TaskCompletionSource<IDisposable>, (int, long)> _waiting = new();
    private bool _active;
    private long _sequence;
    public Task<IDisposable> AcquireAsync(bool thumbnail, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        lock (_sync)
        {
            if (!_active) { _active = true; return Task.FromResult<IDisposable>(new DecodeLease(Release)); }
            if (_waiting.Count >= 240) return Task.FromCanceled<IDisposable>(new CancellationToken(true));
            var ready = new TaskCompletionSource<IDisposable>(TaskCreationOptions.RunContinuationsAsynchronously);
            _waiting.Enqueue(ready, (thumbnail ? 1 : 0, _sequence++));
            var registration = token.Register(() => ready.TrySetCanceled(token));
            _ = ready.Task.ContinueWith(_ => registration.Dispose(), TaskScheduler.Default);
            return ready.Task;
        }
    }
    private void Release()
    {
        lock (_sync)
        {
            while (_waiting.TryDequeue(out var ready, out _)) if (ready.TrySetResult(new DecodeLease(Release))) return;
            _active = false;
        }
    }
    private sealed class DecodeLease(Action release) : IDisposable
    {
        private Action? _release = release;
        public void Dispose() => Interlocked.Exchange(ref _release, null)?.Invoke();
    }
}
