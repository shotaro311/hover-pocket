using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace HoverPocket.Shell.Providers.Sticky;

internal sealed class StickyNotesStore
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) }
    };

    private readonly List<StickyNoteItem> _notes = [];
    private StickyNotePreferences _preferences = new();

    public StickyNotesStore()
        : this(Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "HoverPocket",
            "sticky"))
    {
    }

    public StickyNotesStore(string rootDirectory)
    {
        RootDirectory = rootDirectory;
        NotesPath = Path.Combine(rootDirectory, "notes.json");
        PreferencesPath = Path.Combine(rootDirectory, "settings.json");
        Load();
    }

    public string RootDirectory { get; }

    public string NotesPath { get; }

    public string PreferencesPath { get; }

    public string? LastErrorMessage { get; private set; }

    public StickyNoteUndoAction? LastAction { get; private set; }

    public StickyNotePreferences Preferences => _preferences;

    public IReadOnlyList<StickyNoteItem> Notes => _notes;

    public IReadOnlyList<StickyNoteItem> ActiveNotes => _notes
        .Where(note => note.ArchivedAt is null)
        .OrderBy(note => note.SortIndex)
        .ThenByDescending(note => note.UpdatedAt)
        .ToArray();

    public StickyNoteItem CreateNote(StickyNoteColor color = StickyNoteColor.Yellow)
    {
        var now = DateTimeOffset.UtcNow;
        var note = new StickyNoteItem
        {
            Id = Guid.NewGuid(),
            Title = string.Empty,
            Body = string.Empty,
            Color = color,
            CreatedAt = now,
            UpdatedAt = now,
            ArchivedAt = null,
            SortIndex = NextSortIndexForNewNote()
        };
        _notes.Add(note);
        LastAction = null;
        SaveNotes();
        return note.Clone();
    }

    public bool UpdateNote(Guid id, string title, string body, StickyNoteColor color)
    {
        var note = FindNote(id);
        if (note is null)
        {
            return false;
        }

        note.Title = title;
        note.Body = body;
        note.Color = color;
        note.UpdatedAt = DateTimeOffset.UtcNow;
        SaveNotes();
        return true;
    }

    public bool ArchiveNote(Guid id)
    {
        var index = _notes.FindIndex(note => note.Id == id);
        if (index < 0)
        {
            return false;
        }

        var previous = _notes[index].Clone();
        _notes[index].ArchivedAt = DateTimeOffset.UtcNow;
        _notes[index].UpdatedAt = DateTimeOffset.UtcNow;
        LastAction = new StickyNoteUndoAction(StickyNoteUndoActionKind.Archived, previous, index);
        SaveNotes();
        return true;
    }

    public bool ArchiveDroppedNote(Guid id)
    {
        return ArchiveNote(id);
    }

    public bool DeleteNote(Guid id)
    {
        var index = _notes.FindIndex(note => note.Id == id);
        if (index < 0)
        {
            return false;
        }

        var removed = _notes[index].Clone();
        _notes.RemoveAt(index);
        LastAction = new StickyNoteUndoAction(StickyNoteUndoActionKind.Deleted, removed, index);
        SaveNotes();
        return true;
    }

    public bool DiscardNote(Guid id)
    {
        var index = _notes.FindIndex(note => note.Id == id);
        if (index < 0)
        {
            return false;
        }

        _notes.RemoveAt(index);
        SaveNotes();
        return true;
    }

    public bool DiscardIfBlank(Guid id)
    {
        var note = FindNote(id);
        return note is not null && note.IsBlank && DiscardNote(id);
    }

    public bool UndoLastAction()
    {
        if (LastAction is null)
        {
            return false;
        }

        switch (LastAction.Kind)
        {
            case StickyNoteUndoActionKind.Archived:
                RestoreArchivedNote(LastAction);
                break;
            case StickyNoteUndoActionKind.Deleted:
                RestoreDeletedNote(LastAction);
                break;
            default:
                return false;
        }

        LastAction = null;
        SaveNotes();
        return true;
    }

    public bool MoveNote(Guid id, int destinationIndex)
    {
        var active = ActiveNotes.Select(note => note.Clone()).ToList();
        var currentIndex = active.FindIndex(note => note.Id == id);
        if (currentIndex < 0)
        {
            return false;
        }

        var moved = active[currentIndex];
        active.RemoveAt(currentIndex);
        var boundedDestination = Math.Clamp(destinationIndex, 0, active.Count);
        active.Insert(boundedDestination, moved);

        var now = DateTimeOffset.UtcNow;
        for (var index = 0; index < active.Count; index++)
        {
            var note = FindNote(active[index].Id);
            if (note is null)
            {
                continue;
            }

            note.SortIndex = index;
            if (note.Id == id)
            {
                note.UpdatedAt = now;
            }
        }

        SaveNotes();
        return true;
    }

    public void SetPreferences(StickyNoteGridSize gridSize, bool showUndoToast)
    {
        _preferences.GridSize = gridSize;
        _preferences.ShowUndoToast = showUndoToast;
        SavePreferences();
    }

    public void SetGridSize(StickyNoteGridSize gridSize)
    {
        _preferences.GridSize = gridSize;
        SavePreferences();
    }

    public void SetShowUndoToast(bool showUndoToast)
    {
        _preferences.ShowUndoToast = showUndoToast;
        SavePreferences();
    }

    public object BuildState()
    {
        return new
        {
            notes = ActiveNotes,
            archivedCount = _notes.Count(note => note.ArchivedAt is not null),
            preferences = _preferences,
            lastAction = LastAction,
            lastErrorMessage = LastErrorMessage,
            storage = new
            {
                rootDirectory = RootDirectory,
                notesPath = NotesPath,
                preferencesPath = PreferencesPath
            }
        };
    }

    private void RestoreArchivedNote(StickyNoteUndoAction action)
    {
        var existing = FindNote(action.Note.Id);
        if (existing is not null)
        {
            CopyFrom(existing, action.Note);
            return;
        }

        _notes.Insert(InsertionIndex(action.PreviousIndex), action.Note.Clone());
    }

    private void RestoreDeletedNote(StickyNoteUndoAction action)
    {
        if (_notes.Any(note => note.Id == action.Note.Id))
        {
            return;
        }

        _notes.Insert(InsertionIndex(action.PreviousIndex), action.Note.Clone());
    }

    private void Load()
    {
        LoadNotes();
        LoadPreferences();
    }

    private void LoadNotes()
    {
        if (!File.Exists(NotesPath))
        {
            _notes.Clear();
            return;
        }

        try
        {
            var json = File.ReadAllText(NotesPath);
            var notes = JsonSerializer.Deserialize<List<StickyNoteItem>>(json, JsonOptions) ?? [];
            _notes.Clear();
            _notes.AddRange(Normalize(notes));
            LastErrorMessage = null;
        }
        catch (Exception ex) when (ex is JsonException or IOException or UnauthorizedAccessException)
        {
            _notes.Clear();
            LastAction = null;
            LastErrorMessage = "Sticky notes could not be loaded. Defaults were restored.";
            TrySaveNotes();
        }
    }

    private void LoadPreferences()
    {
        if (!File.Exists(PreferencesPath))
        {
            _preferences = new StickyNotePreferences();
            return;
        }

        try
        {
            var json = File.ReadAllText(PreferencesPath);
            _preferences = Normalize(JsonSerializer.Deserialize<StickyNotePreferences>(json, JsonOptions));
        }
        catch (Exception ex) when (ex is JsonException or IOException or UnauthorizedAccessException)
        {
            _preferences = new StickyNotePreferences();
            LastErrorMessage ??= "Sticky note settings could not be loaded. Defaults were restored.";
            TrySavePreferences();
        }
    }

    private void SaveNotes()
    {
        EnsureDirectory();
        File.WriteAllText(NotesPath, JsonSerializer.Serialize(_notes, JsonOptions));
        LastErrorMessage = null;
    }

    private void SavePreferences()
    {
        EnsureDirectory();
        File.WriteAllText(PreferencesPath, JsonSerializer.Serialize(_preferences, JsonOptions));
        LastErrorMessage = null;
    }

    private void TrySaveNotes()
    {
        try
        {
            SaveNotes();
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
        }
    }

    private void TrySavePreferences()
    {
        try
        {
            SavePreferences();
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
        }
    }

    private double NextSortIndexForNewNote()
    {
        var first = ActiveNotes.FirstOrDefault();
        return first is null ? 0 : first.SortIndex - 1;
    }

    private StickyNoteItem? FindNote(Guid id)
    {
        return _notes.FirstOrDefault(note => note.Id == id);
    }

    private int InsertionIndex(int preferredIndex)
    {
        return Math.Clamp(preferredIndex, 0, _notes.Count);
    }

    private void EnsureDirectory()
    {
        Directory.CreateDirectory(RootDirectory);
    }

    private static IEnumerable<StickyNoteItem> Normalize(IEnumerable<StickyNoteItem> notes)
    {
        foreach (var note in notes.Where(note => note.Id != Guid.Empty))
        {
            note.Title ??= string.Empty;
            note.Body ??= string.Empty;
            yield return note;
        }
    }

    private static StickyNotePreferences Normalize(StickyNotePreferences? preferences)
    {
        return preferences ?? new StickyNotePreferences();
    }

    private static void CopyFrom(StickyNoteItem target, StickyNoteItem source)
    {
        target.Title = source.Title;
        target.Body = source.Body;
        target.Color = source.Color;
        target.CreatedAt = source.CreatedAt;
        target.UpdatedAt = source.UpdatedAt;
        target.ArchivedAt = source.ArchivedAt;
        target.SortIndex = source.SortIndex;
    }
}
