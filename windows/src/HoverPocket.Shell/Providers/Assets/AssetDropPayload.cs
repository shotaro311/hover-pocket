using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using DataFormats = System.Windows.DataFormats;
using IDataObject = System.Runtime.InteropServices.ComTypes.IDataObject;

namespace HoverPocket.Shell.Providers.Assets;

internal sealed record AssetDropPayload(string[] Paths, string? Stage = null, Uri? Url = null, bool Internet = false)
{
    private const long MaxBytes = 128L * 1024 * 1024;
    internal static bool Supports(System.Windows.IDataObject data) => !data.GetDataPresent(AssetDragDataObject.Marker, false)
        && (data.GetDataPresent(DataFormats.FileDrop) || data.GetDataPresent(DataFormats.Bitmap) || data.GetDataPresent("PNG")
            || data.GetDataPresent("FileGroupDescriptorW") || data.GetDataPresent("UniformResourceLocatorW") || data.GetDataPresent(DataFormats.UnicodeText));

    // Snapshot native data before the OLE Drop call returns; the source may release it immediately afterwards.
    internal static AssetDropPayload Capture(System.Windows.IDataObject data, string libraryRoot, IDataObject? native = null)
    {
        if (data.GetDataPresent(AssetDragDataObject.Marker, false)) throw new ArgumentException("ライブラリ内の素材はサイドバーへ移動してください。");
        if (data.GetDataPresent(DataFormats.FileDrop) && data.GetData(DataFormats.FileDrop) is string[] files) return new(files);
        string NewStage() { var path = Path.Combine(libraryRoot, "staging", "drop-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(path); return path; }
        if (native is not null && data.GetDataPresent("FileGroupDescriptorW"))
        {
            var stage = NewStage(); return new(ReadVirtualFiles(native, stage), stage, Internet: true);
        }
        if (data.GetDataPresent("PNG") && data.GetData("PNG") is Stream png)
        {
            var stage = NewStage(); var path = Path.Combine(stage, "ドロップ画像.png");
            using var output = new FileStream(path, FileMode.CreateNew); CopyBounded(png, output); return new([path], stage, Internet: true);
        }
        if (data.GetDataPresent(DataFormats.Bitmap) && data.GetData(DataFormats.Bitmap) is BitmapSource image)
        {
            if ((long)image.PixelWidth * image.PixelHeight > 32_000_000) throw new ArgumentException("画像が大きすぎます。ファイルとして追加してください。");
            var converted = new FormatConvertedBitmap(image, PixelFormats.Bgra32, null, 0);
            var pixels = new byte[checked(converted.PixelWidth * converted.PixelHeight * 4)];
            converted.CopyPixels(pixels, converted.PixelWidth * 4, 0);
            var detached = BitmapSource.Create(converted.PixelWidth, converted.PixelHeight, 96, 96, PixelFormats.Bgra32, null, pixels, converted.PixelWidth * 4);
            var stage = NewStage(); var path = Path.Combine(stage, "ドロップ画像.png");
            var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(detached)); using var output = new FileStream(path, FileMode.CreateNew); encoder.Save(output);
            return new([path], stage, Internet: true);
        }
        string? text = null;
        if (data.GetDataPresent("UniformResourceLocatorW"))
        {
            var value = data.GetData("UniformResourceLocatorW");
            text = value is Stream stream ? Encoding.Unicode.GetString(ReadBounded(stream, 32768)).TrimEnd('\0') : value as string;
        }
        text ??= data.GetDataPresent(DataFormats.UnicodeText) ? data.GetData(DataFormats.UnicodeText) as string : null;
        if (text?.Length <= 32768 && Uri.TryCreate(text.Trim(), UriKind.Absolute, out var uri) && uri.Scheme is "https" or "http" && string.IsNullOrEmpty(uri.UserInfo))
            return new([], NewStage(), uri, true);
        throw new ArgumentException("ファイル、画像データ、または画像・動画・音声の直接URLをドロップしてください。");
    }

    internal async Task<AssetDropPayload> MaterializeAsync(CancellationToken token = default)
    {
        if (Url is null) return this;
        using var handler = new HttpClientHandler { UseCookies = false, MaxAutomaticRedirections = 3 };
        using var client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(45) };
        using var response = await client.GetAsync(Url, HttpCompletionOption.ResponseHeadersRead, token);
        response.EnsureSuccessStatusCode();
        var mime = response.Content.Headers.ContentType?.MediaType?.ToLowerInvariant();
        var extension = mime switch
        {
            "image/png" => "png", "image/jpeg" => "jpg", "image/gif" => "gif", "image/webp" => "webp", "image/bmp" => "bmp",
            "video/mp4" => "mp4", "video/webm" => "webm", "video/quicktime" => "mov", "audio/mpeg" => "mp3", "audio/mp4" => "m4a", "audio/wav" or "audio/x-wav" => "wav", "audio/ogg" => "ogg",
            _ => throw new ArgumentException("このURLは画像・動画・音声の直接ファイルではありません。ファイルを保存してから追加してください。")
        };
        if (response.Content.Headers.ContentLength > MaxBytes) throw new IOException("URLからの取り込みは128MiBまでです。ファイルを保存してから追加してください。");
        var path = Path.Combine(Stage!, $"ドロップ素材 {DateTime.Now:yyyy-MM-dd HH-mm-ss}.{extension}");
        await using (var input = await response.Content.ReadAsStreamAsync(token))
        await using (var output = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536, true))
        {
            var buffer = new byte[65536]; long total = 0; int count;
            while ((count = await input.ReadAsync(buffer, token)) > 0)
            { total += count; if (total > MaxBytes) throw new IOException("取り込み上限128MiBを超えました。"); await output.WriteAsync(buffer.AsMemory(0, count), token); }
            await output.FlushAsync(token); output.Flush(true);
        }
        return this with { Paths = [path], Url = null };
    }

    private static string[] ReadVirtualFiles(IDataObject data, string stage)
    {
        var descriptor = GetBytes(data, "FileGroupDescriptorW", -1, 4 + 592 * 256);
        if (descriptor.Length < 4) throw new InvalidDataException("仮想ファイルの一覧が不正です。");
        var count = BitConverter.ToUInt32(descriptor, 0);
        if (count is 0 or > 256 || descriptor.Length < 4L + count * 592) throw new InvalidDataException("仮想ファイルの件数が不正です。");
        var paths = new List<string>();
        for (var index = 0; index < count; index++)
        {
            var offset = 4 + index * 592; var attributes = BitConverter.ToUInt32(descriptor, offset + 36);
            var name = Encoding.Unicode.GetString(descriptor, offset + 72, 520).Split('\0')[0];
            if ((attributes & 16) != 0 || string.IsNullOrWhiteSpace(name) || Path.GetFileName(name) != name || name.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0)
                throw new InvalidDataException("仮想フォルダや不正な名前は取り込めません。ファイルとして保存してください。");
            var directory = Path.Combine(stage, index.ToString()); Directory.CreateDirectory(directory);
            var path = Path.Combine(directory, name);
            var format = Format("FileContents", index, TYMED.TYMED_ISTREAM | TYMED.TYMED_HGLOBAL);
            data.GetData(ref format, out var medium);
            try
            {
                using var output = new FileStream(path, FileMode.CreateNew);
                if (medium.tymed == TYMED.TYMED_ISTREAM)
                {
                    var source = (IStream)Marshal.GetObjectForIUnknown(medium.unionmember);
                    var read = Marshal.AllocHGlobal(4);
                    try
                    {
                        var buffer = new byte[65536]; long total = 0;
                        while (true) { source.Read(buffer, buffer.Length, read); var size = Marshal.ReadInt32(read); if (size == 0) break; total += size; if (size < 0 || size > buffer.Length || total > MaxBytes) throw new IOException("仮想ファイルは128MiBまでです。"); output.Write(buffer, 0, size); }
                    }
                    finally { Marshal.FreeHGlobal(read); if (Marshal.IsComObject(source)) Marshal.ReleaseComObject(source); }
                }
                else if (medium.tymed == TYMED.TYMED_HGLOBAL) output.Write(GlobalBytes(medium.unionmember, MaxBytes));
                else throw new InvalidDataException("仮想ファイルの形式に対応していません。");
                output.Flush(true);
            }
            finally { ReleaseStgMedium(ref medium); }
            paths.Add(path);
        }
        return paths.ToArray();
    }
    internal static FORMATETC Format(string name, int index = -1, TYMED medium = TYMED.TYMED_HGLOBAL) => new() { cfFormat = unchecked((short)DataFormats.GetDataFormat(name).Id), dwAspect = DVASPECT.DVASPECT_CONTENT, lindex = index, tymed = medium };
    private static byte[] GetBytes(IDataObject data, string name, int index, long limit)
    { var format = Format(name, index); data.GetData(ref format, out var medium); try { return GlobalBytes(medium.unionmember, limit); } finally { ReleaseStgMedium(ref medium); } }
    private static byte[] GlobalBytes(nint handle, long limit)
    { var size = checked((long)GlobalSize(handle)); if (size > limit) throw new InvalidDataException("ドロップデータが大きすぎます。"); var pointer = GlobalLock(handle); if (pointer == 0) throw new IOException("ドロップデータを読み取れません。"); try { var bytes = new byte[(int)size]; Marshal.Copy(pointer, bytes, 0, bytes.Length); return bytes; } finally { GlobalUnlock(handle); } }
    private static byte[] ReadBounded(Stream input, int limit) { using var output = new MemoryStream(); CopyBounded(input, output, limit); return output.ToArray(); }
    private static void CopyBounded(Stream input, Stream output, long limit = MaxBytes)
    { var bytes = new byte[65536]; long total = 0; int count; while ((count = input.Read(bytes)) > 0) { total += count; if (total > limit) throw new IOException("ドロップデータが大きすぎます。"); output.Write(bytes, 0, count); } }
    [DllImport("kernel32.dll")] private static extern nuint GlobalSize(nint handle);
    [DllImport("kernel32.dll")] private static extern nint GlobalLock(nint handle);
    [DllImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GlobalUnlock(nint handle);
    [DllImport("ole32.dll")] private static extern void ReleaseStgMedium(ref STGMEDIUM medium);
}
