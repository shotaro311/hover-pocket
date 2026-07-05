using System.IO;
using HoverPocket.Shell.Verification;

namespace HoverPocket.Shell.Providers.Sticky;

internal sealed class StickyVerifier
{
    private readonly List<string> _failures = [];

    public int Run()
    {
        var root = Path.Combine(Path.GetTempPath(), "HoverPocket", "StickyVerify", Guid.NewGuid().ToString("N"));
        var store = new StickyNotesStore(root);

        VerifyCrud(store);
        VerifyReorder(store);
        VerifyArchiveUndo(store);
        VerifyDeleteUndo(store);
        VerifyBlankDiscard(store);
        VerifyPreferencesPersistence(store);
        VerifyPersistence(root);
        VerifyCorruptJsonRecovery(root);

        if (_failures.Count == 0)
        {
            VerifyConsole.WriteLine("PASS sticky verify: CRUD, reorder, archive/delete undo, blank discard, persistence, corrupt JSON recovery");
            VerifyConsole.WriteLine($"sticky_root={root}");
            return 0;
        }

        VerifyConsole.WriteLine("FAIL sticky verify:");
        foreach (var failure in _failures)
        {
            VerifyConsole.WriteLine($"- {failure}");
        }

        VerifyConsole.WriteLine($"sticky_root={root}");
        return 1;
    }

    private void VerifyCrud(StickyNotesStore store)
    {
        var note = store.CreateNote(StickyNoteColor.Yellow);
        if (store.ActiveNotes.Count != 1 || store.ActiveNotes[0].Id != note.Id)
        {
            _failures.Add("crud: created note was not active");
            return;
        }

        if (!store.UpdateNote(note.Id, "First", "Body", StickyNoteColor.Mint))
        {
            _failures.Add("crud: update returned false");
            return;
        }

        var updated = store.ActiveNotes.Single(candidate => candidate.Id == note.Id);
        if (updated.Title != "First" || updated.Body != "Body" || updated.Color != StickyNoteColor.Mint)
        {
            _failures.Add("crud: update values were not preserved");
        }

        if (updated.UpdatedAt < updated.CreatedAt)
        {
            _failures.Add("crud: updatedAt moved before createdAt");
        }
    }

    private void VerifyReorder(StickyNotesStore store)
    {
        var second = store.CreateNote(StickyNoteColor.Pink);
        store.UpdateNote(second.Id, "Second", "Second body", StickyNoteColor.Pink);
        var third = store.CreateNote(StickyNoteColor.Blue);
        store.UpdateNote(third.Id, "Third", "Third body", StickyNoteColor.Blue);

        var first = store.ActiveNotes.First(note => note.Title == "First");
        if (!store.MoveNote(first.Id, 0))
        {
            _failures.Add("reorder: move returned false");
            return;
        }

        var order = store.ActiveNotes.Select(note => note.Title).ToArray();
        if (!order.SequenceEqual(["First", "Third", "Second"]))
        {
            _failures.Add($"reorder: unexpected active order {string.Join(",", order)}");
        }

        var sortIndexes = store.ActiveNotes.Select(note => note.SortIndex).ToArray();
        if (!sortIndexes.SequenceEqual([0d, 1d, 2d]))
        {
            _failures.Add($"reorder: sortIndex values were not normalized: {string.Join(",", sortIndexes)}");
        }
    }

    private void VerifyArchiveUndo(StickyNotesStore store)
    {
        var note = store.ActiveNotes.First(candidate => candidate.Title == "Third");
        if (!store.ArchiveNote(note.Id))
        {
            _failures.Add("archive: archive returned false");
            return;
        }

        if (store.ActiveNotes.Any(candidate => candidate.Id == note.Id) || store.LastAction?.Kind != StickyNoteUndoActionKind.Archived)
        {
            _failures.Add("archive: note remained active or undo action was not archived");
        }

        if (!store.UndoLastAction() || store.ActiveNotes.All(candidate => candidate.Id != note.Id))
        {
            _failures.Add("archive: undo did not restore archived note");
        }
    }

    private void VerifyDeleteUndo(StickyNotesStore store)
    {
        var note = store.ActiveNotes.First(candidate => candidate.Title == "Second");
        if (!store.DeleteNote(note.Id))
        {
            _failures.Add("delete: delete returned false");
            return;
        }

        if (store.Notes.Any(candidate => candidate.Id == note.Id) || store.LastAction?.Kind != StickyNoteUndoActionKind.Deleted)
        {
            _failures.Add("delete: note remained in store or undo action was not deleted");
        }

        if (!store.UndoLastAction() || store.ActiveNotes.All(candidate => candidate.Id != note.Id))
        {
            _failures.Add("delete: undo did not restore deleted note");
        }
    }

    private void VerifyBlankDiscard(StickyNotesStore store)
    {
        var beforeCount = store.Notes.Count;
        var blank = store.CreateNote(StickyNoteColor.Lavender);
        if (!store.DiscardIfBlank(blank.Id))
        {
            _failures.Add("blank discard: blank note was not discarded");
            return;
        }

        if (store.Notes.Count != beforeCount || store.Notes.Any(note => note.Id == blank.Id))
        {
            _failures.Add("blank discard: blank note remained saved");
        }
    }

    private void VerifyPreferencesPersistence(StickyNotesStore store)
    {
        store.SetPreferences(StickyNoteGridSize.Large, showUndoToast: false);
        var reloaded = new StickyNotesStore(store.RootDirectory);
        if (reloaded.Preferences.GridSize != StickyNoteGridSize.Large || reloaded.Preferences.ShowUndoToast)
        {
            _failures.Add("preferences: grid size or undo toast visibility was not persisted");
        }
    }

    private void VerifyPersistence(string root)
    {
        var reloaded = new StickyNotesStore(root);
        var titles = reloaded.ActiveNotes.Select(note => note.Title).ToArray();
        if (!titles.SequenceEqual(["First", "Third", "Second"]))
        {
            _failures.Add($"persistence: restored order/content mismatch {string.Join(",", titles)}");
        }

        var colors = reloaded.ActiveNotes.Select(note => note.Color).ToArray();
        if (!colors.SequenceEqual([StickyNoteColor.Mint, StickyNoteColor.Blue, StickyNoteColor.Pink]))
        {
            _failures.Add($"persistence: restored colors mismatch {string.Join(",", colors)}");
        }
    }

    private void VerifyCorruptJsonRecovery(string root)
    {
        File.WriteAllText(Path.Combine(root, "notes.json"), "{ not valid json");
        File.WriteAllText(Path.Combine(root, "settings.json"), "{ not valid json");

        var recovered = new StickyNotesStore(root);
        if (recovered.ActiveNotes.Count != 0
            || recovered.Preferences.GridSize != StickyNoteGridSize.Medium
            || !recovered.Preferences.ShowUndoToast)
        {
            _failures.Add("corrupt JSON: defaults were not restored");
            return;
        }

        var note = recovered.CreateNote(StickyNoteColor.Yellow);
        recovered.UpdateNote(note.Id, "Recovered", "Writable after corrupt JSON", StickyNoteColor.Yellow);

        var reloaded = new StickyNotesStore(root);
        if (reloaded.ActiveNotes.Count != 1 || reloaded.ActiveNotes[0].Title != "Recovered")
        {
            _failures.Add("corrupt JSON: store was not writable after recovery");
        }
    }
}
