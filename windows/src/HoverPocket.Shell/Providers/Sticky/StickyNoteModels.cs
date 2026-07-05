using System.Text.Json.Serialization;

namespace HoverPocket.Shell.Providers.Sticky;

internal enum StickyNoteColor
{
    Yellow,
    Pink,
    Mint,
    Blue,
    Lavender
}

internal enum StickyNoteGridSize
{
    Small,
    Medium,
    Large
}

internal enum StickyNoteUndoActionKind
{
    Archived,
    Deleted
}

internal sealed class StickyNoteItem
{
    public Guid Id { get; set; } = Guid.NewGuid();

    public string Title { get; set; } = string.Empty;

    public string Body { get; set; } = string.Empty;

    public StickyNoteColor Color { get; set; } = StickyNoteColor.Yellow;

    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;

    public DateTimeOffset UpdatedAt { get; set; } = DateTimeOffset.UtcNow;

    public DateTimeOffset? ArchivedAt { get; set; }

    public double SortIndex { get; set; }

    [JsonIgnore]
    public bool IsBlank => string.IsNullOrWhiteSpace(Title) && string.IsNullOrWhiteSpace(Body);

    public StickyNoteItem Clone()
    {
        return new StickyNoteItem
        {
            Id = Id,
            Title = Title,
            Body = Body,
            Color = Color,
            CreatedAt = CreatedAt,
            UpdatedAt = UpdatedAt,
            ArchivedAt = ArchivedAt,
            SortIndex = SortIndex
        };
    }
}

internal sealed record StickyNoteUndoAction(
    StickyNoteUndoActionKind Kind,
    StickyNoteItem Note,
    int PreviousIndex);

internal sealed class StickyNotePreferences
{
    public StickyNoteGridSize GridSize { get; set; } = StickyNoteGridSize.Medium;

    public bool ShowUndoToast { get; set; } = true;
}
