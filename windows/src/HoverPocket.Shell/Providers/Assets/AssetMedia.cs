using System.Windows.Media.Imaging;
using System.Windows.Media;
using HoverPocket.Assets;
using Windows.Storage;
using Windows.Storage.Streams;

namespace HoverPocket.Shell.Providers.Assets;

internal sealed record AssetFrame(string? DataUrl, double Width, double Height, int Pages = 1, string? Error = null, string ContentType = "image/jpeg", string? FailureCode = null);

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
                if (asset.Kind == "image")
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
                else if (asset.Kind == "pdf")
                {
                    stage = "pdf.worker";
                    var frame = await _pdf.RenderAsync(path, page, max, token);
                    if (frame.Error is not null || frame.DataUrl is null) return frame;
                    width = frame.Width; height = frame.Height; pages = frame.Pages;
                    using var stream = new MemoryStream(Convert.FromBase64String(frame.DataUrl[(frame.DataUrl.IndexOf(',') + 1)..]));
                    bitmap = BitmapDecoder.Create(stream, BitmapCreateOptions.None, BitmapCacheOption.OnLoad).Frames[0]; bitmap.Freeze();
                }
                else if (asset.Kind == "video")
                {
                    stage = "video.open";
                    var file = await StorageFile.GetFileFromPathAsync(path);
                    stage = "video.thumbnail";
                    using var output = await file.GetThumbnailAsync(global::Windows.Storage.FileProperties.ThumbnailMode.VideosView, (uint)Math.Min(max, 640), global::Windows.Storage.FileProperties.ThumbnailOptions.None);
                    stage = "video.properties";
                    var properties = await file.Properties.GetVideoPropertiesAsync(); width = properties.Width; height = properties.Height;
                    stage = "video.orientation";
                    if (properties.Orientation is global::Windows.Storage.FileProperties.VideoOrientation.Rotate90 or global::Windows.Storage.FileProperties.VideoOrientation.Rotate270) (width, height) = (height, width);
                    if (output is null || output.Type != global::Windows.Storage.FileProperties.ThumbnailType.Image) return new(null, width, height, Error: "この動画のポスターを生成できません。手動で再生を試してください。");
                    // Finish WinRT awaits before constructing WPF decoder objects: BitmapFrame metadata retains thread affinity.
                    stage = "video.decode";
                    using var stream = output.AsStreamForRead(); bitmap = BitmapDecoder.Create(stream, BitmapCreateOptions.None, BitmapCacheOption.OnLoad).Frames[0]; bitmap.Freeze();
                }
                else return new(null, 0, 0, Error: "この形式はプレビューに対応していません。原本の保存・取り出しはできます。");
                token.ThrowIfCancellationRequested();
                stage = "encode";
                byte[] bytes; var quality = thumbnail ? 75 : 90;
                var transparent = !thumbnail && asset.Kind == "image" && asset.Extension is "png" or "gif" or "webp";
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
        { return new(null, 0, 0, Error: "プレビューを生成できません。形式・破損・保護・Windowsのメディア機能を確認してください。原本は保存されています。", FailureCode: $"{stage}:{ex.GetType().Name}:{ex.HResult:X8}"); }
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
