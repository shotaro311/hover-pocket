using System.Text.Json;
using System.Windows;
using HoverPocket.Shell.Bridge;
using WpfDataFormats = System.Windows.DataFormats;
using WpfDataObject = System.Windows.DataObject;
using WpfDragDrop = System.Windows.DragDrop;
using WpfDragDropEffects = System.Windows.DragDropEffects;
using WpfTextDataFormat = System.Windows.TextDataFormat;

namespace HoverPocket.Shell.Providers.Sticky;

internal sealed class StickyBridgeController
{
    private readonly StickyNotesStore _store;

    public StickyBridgeController()
        : this(new StickyNotesStore())
    {
    }

    public StickyBridgeController(StickyNotesStore store)
    {
        _store = store;
    }

    public void Attach(BridgeDispatcher dispatcher)
    {
        dispatcher.Register("sticky.getState", (_, _) => Task.FromResult<object?>(_store.BuildState()));
        dispatcher.Register("sticky.create", CreateNoteAsync);
        dispatcher.Register("sticky.update", UpdateNoteAsync);
        dispatcher.Register("sticky.archive", ArchiveNoteAsync);
        dispatcher.Register("sticky.archiveDropped", ArchiveDroppedNoteAsync);
        dispatcher.Register("sticky.delete", DeleteNoteAsync);
        dispatcher.Register("sticky.discard", DiscardNoteAsync);
        dispatcher.Register("sticky.undo", UndoAsync);
        dispatcher.Register("sticky.move", MoveNoteAsync);
        dispatcher.Register("sticky.setGridSize", SetGridSizeAsync);
        dispatcher.Register("sticky.setUndoToastVisible", SetUndoToastVisibleAsync);
        dispatcher.Register("sticky.startExternalDrag", StartExternalDragAsync);
    }

    private Task<object?> CreateNoteAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var color = ReadOptionalColor(parameters, "color") ?? StickyNoteColor.Yellow;
        var note = _store.CreateNote(color);
        return Task.FromResult<object?>(new { note, state = _store.BuildState() });
    }

    private Task<object?> UpdateNoteAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var id = ReadRequiredGuid(parameters, "id");
        var title = ReadOptionalString(parameters, "title") ?? string.Empty;
        var body = ReadOptionalString(parameters, "body") ?? string.Empty;
        var color = ReadOptionalColor(parameters, "color") ?? StickyNoteColor.Yellow;
        var updated = _store.UpdateNote(id, title, body, color);
        return Task.FromResult<object?>(new { updated, state = _store.BuildState() });
    }

    private Task<object?> ArchiveNoteAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var archived = _store.ArchiveNote(ReadRequiredGuid(parameters, "id"));
        return Task.FromResult<object?>(new { archived, state = _store.BuildState() });
    }

    private Task<object?> ArchiveDroppedNoteAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var archived = _store.ArchiveDroppedNote(ReadRequiredGuid(parameters, "id"));
        return Task.FromResult<object?>(new { archived, state = _store.BuildState() });
    }

    private Task<object?> DeleteNoteAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var deleted = _store.DeleteNote(ReadRequiredGuid(parameters, "id"));
        return Task.FromResult<object?>(new { deleted, state = _store.BuildState() });
    }

    private Task<object?> DiscardNoteAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var discarded = _store.DiscardNote(ReadRequiredGuid(parameters, "id"));
        return Task.FromResult<object?>(new { discarded, state = _store.BuildState() });
    }

    private Task<object?> UndoAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        _ = parameters;
        cancellationToken.ThrowIfCancellationRequested();
        var undone = _store.UndoLastAction();
        return Task.FromResult<object?>(new { undone, state = _store.BuildState() });
    }

    private Task<object?> MoveNoteAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var moved = _store.MoveNote(ReadRequiredGuid(parameters, "id"), ReadRequiredInt32(parameters, "toIndex"));
        return Task.FromResult<object?>(new { moved, state = _store.BuildState() });
    }

    private Task<object?> SetGridSizeAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var gridSize = ReadOptionalGridSize(parameters, "gridSize") ?? StickyNoteGridSize.Medium;
        _store.SetGridSize(gridSize);
        return Task.FromResult<object?>(_store.BuildState());
    }

    private Task<object?> SetUndoToastVisibleAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        _store.SetShowUndoToast(ReadRequiredBoolean(parameters, "visible"));
        return Task.FromResult<object?>(_store.BuildState());
    }

    private Task<object?> StartExternalDragAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var text = ReadOptionalString(parameters, "text");
        if (string.IsNullOrWhiteSpace(text))
        {
            var id = ReadOptionalGuid(parameters, "id");
            var note = id is null ? null : _store.Notes.FirstOrDefault(candidate => candidate.Id == id.Value);
            text = note is null ? string.Empty : BuildExternalDragText(note);
        }

        if (string.IsNullOrWhiteSpace(text))
        {
            return Task.FromResult<object?>(new { started = false, reason = "empty-text" });
        }

        var effect = StartDrag(text);
        return Task.FromResult<object?>(new { started = true, effect = effect.ToString() });
    }

    private static WpfDragDropEffects StartDrag(string text)
    {
        var app = System.Windows.Application.Current;
        if (app is null)
        {
            return WpfDragDropEffects.None;
        }

        if (!app.Dispatcher.CheckAccess())
        {
            return app.Dispatcher.Invoke(() => StartDrag(text));
        }

        var source = ResolveDragSource(app);
        if (source is null)
        {
            return WpfDragDropEffects.None;
        }

        var data = new WpfDataObject();
        data.SetText(text, WpfTextDataFormat.UnicodeText);
        data.SetData(WpfDataFormats.UnicodeText, text);
        return WpfDragDrop.DoDragDrop(source, data, WpfDragDropEffects.Copy);
    }

    private static DependencyObject? ResolveDragSource(System.Windows.Application app)
    {
        return app.Windows
            .OfType<Window>()
            .FirstOrDefault(window => window.IsVisible)
            ?? app.MainWindow;
    }

    private static string BuildExternalDragText(StickyNoteItem note)
    {
        var body = note.Body.Trim();
        if (!string.IsNullOrWhiteSpace(body))
        {
            return body;
        }

        return note.Title.Trim();
    }

    private static Guid ReadRequiredGuid(JsonElement? parameters, string propertyName)
    {
        var value = ReadOptionalGuid(parameters, propertyName);
        if (value is null)
        {
            throw new InvalidOperationException($"Missing guid parameter: {propertyName}");
        }

        return value.Value;
    }

    private static Guid? ReadOptionalGuid(JsonElement? parameters, string propertyName)
    {
        var value = ReadOptionalString(parameters, propertyName);
        if (Guid.TryParse(value, out var parsed))
        {
            return parsed;
        }

        return null;
    }

    private static int ReadRequiredInt32(JsonElement? parameters, string propertyName)
    {
        if (parameters is null
            || !parameters.Value.TryGetProperty(propertyName, out var property)
            || property.ValueKind != JsonValueKind.Number
            || !property.TryGetInt32(out var value))
        {
            throw new InvalidOperationException($"Missing int parameter: {propertyName}");
        }

        return value;
    }

    private static bool ReadRequiredBoolean(JsonElement? parameters, string propertyName)
    {
        if (parameters is null
            || !parameters.Value.TryGetProperty(propertyName, out var property)
            || property.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
        {
            throw new InvalidOperationException($"Missing boolean parameter: {propertyName}");
        }

        return property.GetBoolean();
    }

    private static string? ReadOptionalString(JsonElement? parameters, string propertyName)
    {
        if (parameters is null
            || !parameters.Value.TryGetProperty(propertyName, out var property)
            || property.ValueKind != JsonValueKind.String)
        {
            return null;
        }

        return property.GetString();
    }

    private static StickyNoteColor? ReadOptionalColor(JsonElement? parameters, string propertyName)
    {
        var value = ReadOptionalString(parameters, propertyName);
        return Enum.TryParse<StickyNoteColor>(value, ignoreCase: true, out var color)
            ? color
            : null;
    }

    private static StickyNoteGridSize? ReadOptionalGridSize(JsonElement? parameters, string propertyName)
    {
        var value = ReadOptionalString(parameters, propertyName);
        return Enum.TryParse<StickyNoteGridSize>(value, ignoreCase: true, out var gridSize)
            ? gridSize
            : null;
    }
}
