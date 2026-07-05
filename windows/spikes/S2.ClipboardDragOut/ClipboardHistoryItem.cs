using System.IO;
using System.Windows.Media.Imaging;

namespace S2.ClipboardDragOut;

public enum ClipboardItemKind
{
    Text,
    Image,
}

public sealed class ClipboardHistoryItem
{
    private ClipboardHistoryItem(
        ClipboardItemKind kind,
        string displayText,
        string? text,
        BitmapSource? image,
        byte[]? pngBytes,
        string? pngPath,
        string hash,
        string source)
    {
        Kind = kind;
        DisplayText = displayText;
        Text = text;
        Image = image;
        PngBytes = pngBytes;
        PngPath = pngPath;
        Hash = hash;
        Source = source;
        CapturedAt = DateTimeOffset.Now;
    }

    public ClipboardItemKind Kind { get; }

    public string DisplayText { get; }

    public string? Text { get; }

    public BitmapSource? Image { get; }

    public byte[]? PngBytes { get; }

    public string? PngPath { get; }

    public string Hash { get; }

    public string Source { get; }

    public DateTimeOffset CapturedAt { get; }

    public static ClipboardHistoryItem TextItem(string text, string hash, string source)
    {
        var preview = text.Length > 80 ? $"{text[..80]}..." : text;
        return new ClipboardHistoryItem(ClipboardItemKind.Text, $"Text: {preview}", text, null, null, null, hash, source);
    }

    public static ClipboardHistoryItem ImageItem(BitmapSource image, byte[] pngBytes, string pngPath, string hash, string source)
    {
        return new ClipboardHistoryItem(
            ClipboardItemKind.Image,
            $"Image: {image.PixelWidth}x{image.PixelHeight}, PNG {pngBytes.Length} bytes, {Path.GetFileName(pngPath)}",
            null,
            image,
            pngBytes,
            pngPath,
            hash,
            source);
    }
}
