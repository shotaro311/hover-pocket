using HoverPocket.Assets;
using System.Security.Cryptography;

internal static class OrganizationChecks
{
    public static async Task<int> RunAsync(string root)
    {
        var checks = 0;
        void Check(bool ok, string label) { if (!ok) throw new Exception("FAILED organize: " + label); checks++; }
        async Task Reject(Func<Task> action, string label)
        {
            try { await action(); }
            catch (Exception ex) when (ex is ArgumentException or InvalidOperationException) { checks++; return; }
            throw new Exception("FAILED organize rejection: " + label);
        }
        using var store = new AssetStore(Path.Combine(root, "organize-library"));
        var a = await store.AddCategoryAsync("folder", "A"); var b = await store.AddCategoryAsync("folder", "B");
        var other = await store.AddCategoryAsync("folder", "Other"); var tag = await store.AddCategoryAsync("tag", "Tag");
        var ids = new List<string>();
        for (var i = 0; i < 2; i++)
        {
            var file = Path.Combine(root, $"organize-{i}.txt"); await File.WriteAllTextAsync(file, $"Generated organization fixture {i}");
            ids.Add((await store.ImportAsync(file, a)).AssetId!);
        }
        await store.UpdateAsync(ids.ToArray(), "classify", other); await store.UpdateAsync(ids.ToArray(), "classify", tag);
        var originals = (await store.QueryAsync(new())).Items.ToDictionary(value => value.Id, value => (store.OriginalPath(value), value.Sha256));
        var moved = await store.OrganizeAsync([ids[0], ids[1], ids[0]], a, new("folder", b));
        Check(moved.Changed == 2, "deduplicated bulk count");
        var first = (await store.GetAsync(ids[0]))!;
        Check(first.FolderIds.Contains(b) && first.FolderIds.Contains(other) && !first.FolderIds.Contains(a), "move removes only source membership");
        Check(first.TagIds.SequenceEqual([tag]), "tags preserved");
        await store.UpdateAsync([ids[0]], "rename", "renamed.txt");
        await store.UndoOrganizeAsync(moved.UndoToken);
        first = (await store.GetAsync(ids[0]))!;
        Check(first.FolderIds.Contains(a) && !first.FolderIds.Contains(b) && first.Name == "renamed.txt", "undo preserves unrelated rename");
        await Reject(() => store.UndoOrganizeAsync(moved.UndoToken), "token used once");
        var added = await store.OrganizeAsync(ids.ToArray(), null, new("folder", b));
        Check((await store.GetAsync(ids[0]))!.FolderIds.Length == 3, "all/search adds folder");
        await store.UndoOrganizeAsync(added.UndoToken);
        await store.UpdateAsync(ids.ToArray(), "trash");
        var restored = await store.OrganizeAsync(ids.ToArray(), a, new("folder", b));
        first = (await store.GetAsync(ids[0]))!;
        Check(!first.Trashed && first.FolderIds.Contains(a) && first.FolderIds.Contains(other) && first.FolderIds.Contains(b), "trash to folder restores and retains all prior folders");
        await store.UndoOrganizeAsync(restored.UndoToken);
        Check((await store.GetAsync(ids[0]))!.Trashed, "undo restores previous trash state");
        var starred = await store.OrganizeAsync(ids.ToArray(), null, new("favorite"));
        Check((await store.GetAsync(ids[0])) is { Favorite: true, Trashed: false }, "favorite sets true and restores");
        var again = await store.OrganizeAsync(ids.ToArray(), null, new("favorite"));
        Check(again.Changed == 0, "favorite is not a toggle");
        await store.UndoOrganizeAsync(starred.UndoToken);
        Check((await store.GetAsync(ids[0])) is { Favorite: false, Trashed: true }, "favorite undo restores both fields");
        var unfiled = await store.OrganizeAsync(ids.ToArray(), null, new("unfiled"));
        first = (await store.GetAsync(ids[0]))!;
        Check(first.FolderIds.Length == 0 && first.TagIds.SequenceEqual([tag]) && !first.Trashed, "unfiled clears folders but keeps tags and restores");
        await store.UndoOrganizeAsync(unfiled.UndoToken);
        await Reject(() => store.OrganizeAsync(ids.ToArray(), null, new("folder", tag)), "tag cannot be a folder target");
        await Reject(() => store.OrganizeAsync(ids.ToArray(), null, new("folder", "missing")), "missing folder rejected");
        await Reject(() => store.OrganizeAsync([ids[0], "missing"], null, new("folder", b)), "bulk missing item rejected");
        Check(!(await store.GetAsync(ids[0]))!.FolderIds.Contains(b) && (await store.GetAsync(ids[0]))!.Trashed, "failed bulk transaction rolls back earlier item");
        var conflict = await store.OrganizeAsync(ids.ToArray(), null, new("folder", b));
        await store.UpdateAsync([ids[1]], "classify", await store.AddCategoryAsync("folder", "Later"));
        await Reject(() => store.UndoOrganizeAsync(conflict.UndoToken), "later classification blocks stale undo");
        Check((await store.GetAsync(ids[0]))!.FolderIds.Contains(b), "failed bulk undo is atomic");
        foreach (var id in ids)
        {
            var asset = (await store.GetAsync(id))!; using var stream = File.OpenRead(store.OriginalPath(asset));
            Check(store.OriginalPath(asset) == originals[id].Item1 && Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant() == originals[id].Sha256, "original path and bytes unchanged");
        }
        Check(!Directory.EnumerateFileSystemEntries(Path.Combine(store.Root, "outbox")).Any(), "internal organization creates no file copies");
        return checks;
    }
}
