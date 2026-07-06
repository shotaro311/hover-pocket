using System.Text.Json.Serialization;

namespace HoverPocket.Shell.Providers.Clipboard;

internal enum ClipboardHistoryItemKind
{
    Text,
    Image
}

internal sealed class ClipboardTextHistoryItem
{
    public Guid Id { get; set; } = Guid.NewGuid();

    public string Text { get; set; } = string.Empty;

    public bool Favorite { get; set; }

    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;

    [JsonIgnore]
    public string PreviewText
    {
        get
        {
            var collapsed = Text
                .ReplaceLineEndings(" ")
                .Trim();
            return string.IsNullOrEmpty(collapsed) ? "Empty text" : collapsed;
        }
    }

    public ClipboardTextHistoryItem Clone()
    {
        return new ClipboardTextHistoryItem
        {
            Id = Id,
            Text = Text,
            Favorite = Favorite,
            CreatedAt = CreatedAt
        };
    }
}

internal sealed class ClipboardImageHistoryItem
{
    public Guid Id { get; set; } = Guid.NewGuid();

    public string FileName { get; set; } = string.Empty;

    public string ContentHash { get; set; } = string.Empty;

    public int Width { get; set; }

    public int Height { get; set; }

    public bool Favorite { get; set; }

    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;

    public ClipboardImageHistoryItem Clone()
    {
        return new ClipboardImageHistoryItem
        {
            Id = Id,
            FileName = FileName,
            ContentHash = ContentHash,
            Width = Width,
            Height = Height,
            Favorite = Favorite,
            CreatedAt = CreatedAt
        };
    }
}

internal sealed class ClipboardHistoryMetadata
{
    public List<ClipboardTextHistoryItem> TextItems { get; set; } = [];

    public List<ClipboardImageHistoryItem> ImageItems { get; set; } = [];
}
