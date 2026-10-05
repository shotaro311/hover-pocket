using Microsoft.Data.Sqlite;

namespace HoverPocket.Assets;

public sealed record AssetDestination(string Kind, string? FolderId = null);
public sealed record AssetOrganizationResult(bool Ok, string UndoToken, int Changed);

public sealed partial class AssetStore
{
    private sealed record OrganizationChange(Asset Before, Asset After, bool Folders, bool Favorite, bool Trash);
    private readonly Dictionary<string, OrganizationChange[]> _organizationUndo = [];

    public Task<AssetOrganizationResult> OrganizeAsync(string[] ids, string? sourceFolderId, AssetDestination destination) => WriteAsync(db =>
    {
        if (ids is not { Length: > 0 and <= 10000 } || ids.Any(string.IsNullOrWhiteSpace)) throw new ArgumentException("素材を選択してください。");
        if (destination.Kind is not ("folder" or "trash" or "favorite" or "unfiled")) throw new ArgumentException("移動先が不正です。");
        using var tx = db.BeginTransaction();
        if (destination.Kind == "folder") RequireFolder(db, destination.FolderId);
        else if (destination.FolderId is not null) throw new ArgumentException("移動先が不正です。");
        var changes = new List<OrganizationChange>();
        foreach (var id in ids.Distinct(StringComparer.Ordinal))
        {
            var before = ReadAssets(db, "SELECT * FROM assets WHERE id=$id", ("id", id)).SingleOrDefault()
                ?? throw new ArgumentException("選択した素材が見つかりません。");
            var folders = destination.Kind is "folder" or "unfiled";
            var favorite = destination.Kind == "favorite";
            var trash = true;
            var after = before;
            if (folders)
            {
                var removeFolder = !before.Trashed && destination.Kind == "folder" ? sourceFolderId : null;
                if (removeFolder is not null) RequireFolder(db, removeFolder);
                var membership = destination.Kind == "unfiled" ? [] : before.FolderIds.Where(value => value != removeFolder).Append(destination.FolderId!).Distinct().ToArray();
                after = after with { FolderIds = membership, Trashed = false };
            }
            if (favorite) after = after with { Favorite = true, Trashed = false };
            if (destination.Kind == "trash") after = after with { Trashed = true };
            var change = new OrganizationChange(before, after, folders, favorite, trash);
            if (OrganizationMatches(before, after, change)) continue;
            ApplyOrganization(db, after, change);
            changes.Add(change);
        }
        tx.Commit();
        var token = Guid.NewGuid().ToString("N");
        // Undo is session-local; cap retained snapshots rather than persisting a second metadata history.
        if (_organizationUndo.Count >= 32) _organizationUndo.Remove(_organizationUndo.Keys.First());
        _organizationUndo.Add(token, changes.ToArray());
        return new AssetOrganizationResult(true, token, changes.Count);
    });

    public Task<bool> UndoOrganizeAsync(string undoToken) => WriteAsync(db =>
    {
        if (!_organizationUndo.TryGetValue(undoToken, out var changes)) throw new ArgumentException("この操作はすでに取り消されたか、取り消し期限が切れています。");
        using var tx = db.BeginTransaction();
        foreach (var change in changes)
        {
            var current = ReadAssets(db, "SELECT * FROM assets WHERE id=$id", ("id", change.After.Id)).SingleOrDefault();
            if (current is null || !OrganizationMatches(current, change.After, change))
                throw new InvalidOperationException("素材の分類がその後に変更されたため取り消せません。現在の内容を確認してください。");
            if (change.Folders) foreach (var folder in change.Before.FolderIds) RequireFolder(db, folder);
        }
        foreach (var change in changes) ApplyOrganization(db, change.Before, change);
        tx.Commit();
        _organizationUndo.Remove(undoToken);
        return true;
    });

    private static void RequireFolder(SqliteConnection db, string? id)
    {
        if (id is null || Scalar(db, "SELECT id FROM categories WHERE id=$id AND type='folder'", ("id", id)) is null)
            throw new ArgumentException("移動先または元のフォルダが見つかりません。");
    }

    private static bool OrganizationMatches(Asset current, Asset expected, OrganizationChange change) =>
        (!change.Folders || current.FolderIds.Order(StringComparer.Ordinal).SequenceEqual(expected.FolderIds.Order(StringComparer.Ordinal)))
        && (!change.Favorite || current.Favorite == expected.Favorite)
        && (!change.Trash || current.Trashed == expected.Trashed);

    private static void ApplyOrganization(SqliteConnection db, Asset value, OrganizationChange change)
    {
        if (change.Folders)
        {
            Execute(db, "DELETE FROM memberships WHERE asset=$id AND category IN (SELECT id FROM categories WHERE type='folder')", ("id", value.Id));
            foreach (var folder in value.FolderIds) Execute(db, "INSERT INTO memberships VALUES($id,$folder)", ("id", value.Id), ("folder", folder));
        }
        if (change.Favorite) Execute(db, "UPDATE assets SET favorite=$favorite WHERE id=$id", ("id", value.Id), ("favorite", value.Favorite));
        if (change.Trash) Execute(db, "UPDATE assets SET trashed=$trash WHERE id=$id", ("id", value.Id), ("trash", value.Trashed));
    }
}
