using System.Collections.Specialized;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using WpfClipboard = System.Windows.Clipboard;
using WpfDataFormats = System.Windows.DataFormats;
using WpfDataObject = System.Windows.DataObject;
using WpfTextDataFormat = System.Windows.TextDataFormat;

namespace HoverPocket.Shell.Providers.Clipboard;

internal sealed class ClipboardHistoryStore
{
    public const int MaxTextItems = 30;
    public const int MaxImageItems = 20;

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) }
    };

    private readonly object _gate = new();
    private readonly Func<DateTimeOffset> _clock;
    private readonly List<ClipboardTextHistoryItem> _textItems = [];
    private readonly List<ClipboardImageHistoryItem> _imageItems = [];

    public ClipboardHistoryStore(string? storageDirectory = null, Func<DateTimeOffset>? clock = null)
    {
        StorageDirectory = storageDirectory ?? DefaultStorageDirectory();
        HistoryPath = Path.Combine(StorageDirectory, "history.json");
        _clock = clock ?? (() => DateTimeOffset.UtcNow);
        Load();
    }

    public string StorageDirectory { get; }

    public string HistoryPath { get; }

    public string? LastErrorMessage { get; private set; }

    public IReadOnlyList<ClipboardTextHistoryItem> TextItems
    {
        get
        {
            lock (_gate)
            {
                return _textItems.Select(item => item.Clone()).ToArray();
            }
        }
    }

    public IReadOnlyList<ClipboardImageHistoryItem> ImageItems
    {
        get
        {
            lock (_gate)
            {
                return _imageItems.Select(item => item.Clone()).ToArray();
            }
        }
    }

    public void CaptureCurrentClipboard(string source)
    {
        try
        {
            WithClipboardRetry(() =>
            {
                if (WpfClipboard.ContainsText(WpfTextDataFormat.UnicodeText))
                {
                    var text = WpfClipboard.GetText(WpfTextDataFormat.UnicodeText);
                    AddText(text, source);
                }

                if (WpfClipboard.ContainsImage())
                {
                    var image = WpfClipboard.GetImage();
                    if (image is not null)
                    {
                        AddImage(image, source);
                    }
                }
            });
        }
        catch (Exception ex) when (ex is COMException or InvalidOperationException)
        {
            SetLastError("Clipboard could not be read. It may be locked by another app.");
        }
    }

    public bool AddText(string text, string source = "manual")
    {
        _ = source;
        if (string.IsNullOrWhiteSpace(text))
        {
            return false;
        }

        lock (_gate)
        {
            var existingIndex = _textItems.FindIndex(item => string.Equals(item.Text, text, StringComparison.Ordinal));
            if (existingIndex >= 0)
            {
                var existing = _textItems[existingIndex].Clone();
                existing.CreatedAt = _clock();
                _textItems.RemoveAt(existingIndex);
                _textItems.Insert(0, existing);
                SaveHistoryLocked();
                return false;
            }

            _textItems.Insert(0, new ClipboardTextHistoryItem
            {
                Id = Guid.NewGuid(),
                Text = text,
                CreatedAt = _clock()
            });
            TrimTextLocked();
            SaveHistoryLocked();
            return true;
        }
    }

    public bool AddImage(BitmapSource image, string source = "manual")
    {
        _ = source;
        var pngBytes = EncodePng(image);
        var hash = ComputeHash(pngBytes);

        lock (_gate)
        {
            var existingIndex = _imageItems.FindIndex(item => string.Equals(item.ContentHash, hash, StringComparison.OrdinalIgnoreCase));
            if (existingIndex >= 0)
            {
                var existing = _imageItems[existingIndex].Clone();
                _imageItems.RemoveAt(existingIndex);
                if (File.Exists(ImagePath(existing)))
                {
                    existing.CreatedAt = _clock();
                    _imageItems.Insert(0, existing);
                    SaveHistoryLocked();
                    return false;
                }
            }

            EnsureDirectory();
            var id = Guid.NewGuid();
            var fileName = $"{id:N}.png";
            File.WriteAllBytes(Path.Combine(StorageDirectory, fileName), pngBytes);
            _imageItems.Insert(0, new ClipboardImageHistoryItem
            {
                Id = id,
                FileName = fileName,
                ContentHash = hash,
                Width = image.PixelWidth,
                Height = image.PixelHeight,
                CreatedAt = _clock()
            });
            TrimImagesLocked();
            SaveHistoryLocked();
            return true;
        }
    }

    public bool CopyText(Guid id)
    {
        ClipboardTextHistoryItem? item;
        lock (_gate)
        {
            item = _textItems.FirstOrDefault(candidate => candidate.Id == id)?.Clone();
        }

        if (item is null)
        {
            return false;
        }

        WithClipboardRetry(() => WpfClipboard.SetText(item.Text, WpfTextDataFormat.UnicodeText));
        PromoteText(id);
        return true;
    }

    public bool CopyImage(Guid id)
    {
        ClipboardImageHistoryItem? item;
        lock (_gate)
        {
            item = _imageItems.FirstOrDefault(candidate => candidate.Id == id)?.Clone();
        }

        if (item is null)
        {
            return false;
        }

        var image = LoadBitmap(item);
        if (image is null)
        {
            return false;
        }

        WithClipboardRetry(() => WpfClipboard.SetImage(image));
        PromoteImage(id);
        return true;
    }

    public void Clear()
    {
        lock (_gate)
        {
            foreach (var image in _imageItems)
            {
                TryDeleteFile(ImagePath(image));
            }

            _textItems.Clear();
            _imageItems.Clear();
            SaveHistoryLocked();
        }
    }

    public WpfDataObject? BuildDragDataObject(ClipboardHistoryItemKind kind, Guid id)
    {
        lock (_gate)
        {
            if (kind == ClipboardHistoryItemKind.Text)
            {
                var textItem = _textItems.FirstOrDefault(item => item.Id == id);
                if (textItem is null)
                {
                    return null;
                }

                var data = new WpfDataObject();
                data.SetText(textItem.Text, WpfTextDataFormat.UnicodeText);
                data.SetData(WpfDataFormats.UnicodeText, textItem.Text);
                return data;
            }

            var imageItem = _imageItems.FirstOrDefault(item => item.Id == id);
            if (imageItem is null)
            {
                return null;
            }

            var image = LoadBitmap(imageItem);
            if (image is null)
            {
                return null;
            }

            var imageData = new WpfDataObject();
            imageData.SetImage(image);
            imageData.SetData(WpfDataFormats.Bitmap, image);
            imageData.SetFileDropList(new StringCollection { ImagePath(imageItem) });
            return imageData;
        }
    }

    public object BuildState(bool isMonitoring, bool privateMode, bool providerVisible)
    {
        lock (_gate)
        {
            return new
            {
                isMonitoring,
                privateMode,
                providerVisible,
                textLimit = MaxTextItems,
                imageLimit = MaxImageItems,
                textItems = _textItems.Select(item => new
                {
                    id = item.Id,
                    kind = "text",
                    text = item.Text,
                    previewText = item.PreviewText,
                    createdAt = item.CreatedAt
                }).ToArray(),
                imageItems = _imageItems.Select(item => new
                {
                    id = item.Id,
                    kind = "image",
                    fileName = item.FileName,
                    filePath = ImagePath(item),
                    contentHash = item.ContentHash,
                    width = item.Width,
                    height = item.Height,
                    createdAt = item.CreatedAt,
                    dataUrl = TryReadImageDataUrl(item)
                }).ToArray(),
                lastErrorMessage = LastErrorMessage,
                storage = new
                {
                    rootDirectory = StorageDirectory,
                    historyPath = HistoryPath
                }
            };
        }
    }

    public string ImagePath(ClipboardImageHistoryItem item)
    {
        return Path.Combine(StorageDirectory, item.FileName);
    }

    public void SetLastError(string? message)
    {
        lock (_gate)
        {
            LastErrorMessage = message;
        }
    }

    public static BitmapSource CreateProbeBitmap(int seed = 0)
    {
        const int width = 48;
        const int height = 48;
        var pixels = new byte[width * height * 4];
        for (var y = 0; y < height; y++)
        {
            for (var x = 0; x < width; x++)
            {
                var offset = (y * width + x) * 4;
                pixels[offset] = (byte)((x * 5 + seed) % 255);
                pixels[offset + 1] = (byte)((y * 5 + seed * 2) % 255);
                pixels[offset + 2] = (byte)((220 + seed * 3) % 255);
                pixels[offset + 3] = 255;
            }
        }

        var bitmap = BitmapSource.Create(width, height, 96, 96, PixelFormats.Bgra32, null, pixels, width * 4);
        bitmap.Freeze();
        return bitmap;
    }

    private void PromoteText(Guid id)
    {
        lock (_gate)
        {
            var index = _textItems.FindIndex(item => item.Id == id);
            if (index <= 0)
            {
                return;
            }

            var item = _textItems[index];
            _textItems.RemoveAt(index);
            _textItems.Insert(0, item);
            SaveHistoryLocked();
        }
    }

    private void PromoteImage(Guid id)
    {
        lock (_gate)
        {
            var index = _imageItems.FindIndex(item => item.Id == id);
            if (index <= 0)
            {
                return;
            }

            var item = _imageItems[index];
            _imageItems.RemoveAt(index);
            _imageItems.Insert(0, item);
            SaveHistoryLocked();
        }
    }

    private void Load()
    {
        lock (_gate)
        {
            if (!File.Exists(HistoryPath))
            {
                return;
            }

            try
            {
                var metadata = JsonSerializer.Deserialize<ClipboardHistoryMetadata>(File.ReadAllText(HistoryPath), JsonOptions)
                    ?? new ClipboardHistoryMetadata();
                _textItems.Clear();
                _textItems.AddRange(NormalizeText(metadata.TextItems).Take(MaxTextItems));
                _imageItems.Clear();
                _imageItems.AddRange(NormalizeImages(metadata.ImageItems).Where(item => File.Exists(ImagePath(item))).Take(MaxImageItems));
                LastErrorMessage = null;
            }
            catch (Exception ex) when (ex is JsonException or IOException or UnauthorizedAccessException)
            {
                _textItems.Clear();
                _imageItems.Clear();
                const string message = "Clipboard history could not be loaded. Defaults were restored.";
                LastErrorMessage = message;
                TrySaveHistoryLocked();
                LastErrorMessage = message;
            }
        }
    }

    private void SaveHistoryLocked()
    {
        EnsureDirectory();
        var metadata = new ClipboardHistoryMetadata
        {
            TextItems = _textItems.Select(item => item.Clone()).ToList(),
            ImageItems = _imageItems.Select(item => item.Clone()).ToList()
        };
        File.WriteAllText(HistoryPath, JsonSerializer.Serialize(metadata, JsonOptions));
        LastErrorMessage = null;
    }

    private void TrySaveHistoryLocked()
    {
        try
        {
            SaveHistoryLocked();
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
        }
    }

    private void TrimTextLocked()
    {
        if (_textItems.Count <= MaxTextItems)
        {
            return;
        }

        _textItems.RemoveRange(MaxTextItems, _textItems.Count - MaxTextItems);
    }

    private void TrimImagesLocked()
    {
        if (_imageItems.Count <= MaxImageItems)
        {
            return;
        }

        var removed = _imageItems.Skip(MaxImageItems).ToArray();
        _imageItems.RemoveRange(MaxImageItems, _imageItems.Count - MaxImageItems);
        foreach (var item in removed)
        {
            TryDeleteFile(ImagePath(item));
        }
    }

    private string? TryReadImageDataUrl(ClipboardImageHistoryItem item)
    {
        try
        {
            var path = ImagePath(item);
            return File.Exists(path)
                ? $"data:image/png;base64,{Convert.ToBase64String(File.ReadAllBytes(path))}"
                : null;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    private BitmapSource? LoadBitmap(ClipboardImageHistoryItem item)
    {
        var path = ImagePath(item);
        if (!File.Exists(path))
        {
            return null;
        }

        var bitmap = new BitmapImage();
        using var stream = File.OpenRead(path);
        bitmap.BeginInit();
        bitmap.CacheOption = BitmapCacheOption.OnLoad;
        bitmap.StreamSource = stream;
        bitmap.EndInit();
        bitmap.Freeze();
        return bitmap;
    }

    private static byte[] EncodePng(BitmapSource source)
    {
        var normalized = source.Format == PixelFormats.Bgra32
            ? source
            : new FormatConvertedBitmap(source, PixelFormats.Bgra32, null, 0);
        if (normalized.CanFreeze)
        {
            normalized.Freeze();
        }

        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(normalized));
        using var stream = new MemoryStream();
        encoder.Save(stream);
        return stream.ToArray();
    }

    private static string ComputeHash(byte[] data)
    {
        return Convert.ToHexString(SHA256.HashData(data)).ToLowerInvariant();
    }

    private static IEnumerable<ClipboardTextHistoryItem> NormalizeText(IEnumerable<ClipboardTextHistoryItem>? items)
    {
        foreach (var item in items ?? [])
        {
            if (item.Id == Guid.Empty || string.IsNullOrWhiteSpace(item.Text))
            {
                continue;
            }

            item.Text ??= string.Empty;
            yield return item;
        }
    }

    private static IEnumerable<ClipboardImageHistoryItem> NormalizeImages(IEnumerable<ClipboardImageHistoryItem>? items)
    {
        foreach (var item in items ?? [])
        {
            if (item.Id == Guid.Empty
                || string.IsNullOrWhiteSpace(item.FileName)
                || string.IsNullOrWhiteSpace(item.ContentHash))
            {
                continue;
            }

            yield return item;
        }
    }

    private void EnsureDirectory()
    {
        Directory.CreateDirectory(StorageDirectory);
    }

    private static void TryDeleteFile(string path)
    {
        try
        {
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
        }
    }

    private static void WithClipboardRetry(Action action)
    {
        Exception? last = null;
        for (var attempt = 0; attempt < 8; attempt++)
        {
            try
            {
                action();
                return;
            }
            catch (Exception ex) when (ex is COMException or InvalidOperationException)
            {
                last = ex;
                Thread.Sleep(80);
            }
        }

        throw new InvalidOperationException("Clipboard operation failed after retries.", last);
    }

    private static string DefaultStorageDirectory()
    {
        return Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "HoverPocket",
            "clipboard");
    }
}
