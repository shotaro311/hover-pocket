using System.Text.Json;

namespace HoverPocket.Assets;

public sealed partial class AssetStore
{
    public Task<string> AddCategoryAsync(string type, string name, string? parent = null) => WriteAsync(db =>
    {
        if (type is not ("folder" or "tag") || string.IsNullOrWhiteSpace(name)) throw new ArgumentException("分類名を入力してください。");
        if (type == "tag" && parent is not null) throw new ArgumentException("タグに親フォルダは指定できません。");
        if (parent is not null && Scalar(db, "SELECT id FROM categories WHERE id=$id AND type='folder'", ("id", parent)) is null) throw new ArgumentException("親フォルダが見つかりません。");
        var normalized = AssetFormat.Normalize(name.Trim());
        var existing = Scalar(db, "SELECT id FROM categories WHERE type=$type AND normalized=$name AND COALESCE(parent,'')=$parent", ("type", type), ("name", normalized), ("parent", parent ?? "")) as string;
        if (existing is not null) return existing;
        var id = Guid.NewGuid().ToString("D"); Execute(db, "INSERT INTO categories VALUES($id,$type,$name,$normalized,$parent)", ("id", id), ("type", type), ("name", name.Trim()), ("normalized", normalized), ("parent", parent)); return id;
    });
    public Task<bool> SaveSearchAsync(string name, AssetQuery filter) => WriteAsync(db =>
    { AssetFormat.ValidateQuery(filter); if (string.IsNullOrWhiteSpace(name)) throw new ArgumentException(); Execute(db, "INSERT INTO searches VALUES($id,$name,$filter)", ("id", Guid.NewGuid().ToString("D")), ("name", name), ("filter", JsonSerializer.Serialize(filter with { Offset = 0 }, AssetFormat.Json))); return true; });
    public Task<bool> RestoreMetadataAsync(Asset[] assets) => WriteAsync(db =>
    {
        using var tx = db.BeginTransaction();
        foreach (var a in assets)
        {
            Execute(db, "UPDATE assets SET name=$name,normalized=$normal,favorite=$favorite,trashed=$trash WHERE id=$id", ("name", a.Name), ("normal", AssetFormat.Normalize(a.Name)), ("favorite", a.Favorite), ("trash", a.Trashed), ("id", a.Id));
            Execute(db, "DELETE FROM memberships WHERE asset=$id", ("id", a.Id));
            foreach (var id in a.FolderIds.Concat(a.TagIds)) Execute(db, "INSERT INTO memberships VALUES($asset,$category)", ("asset", a.Id), ("category", id));
        }
        tx.Commit(); return true;
    });
    public Task<bool> ChangeCategoryAsync(string id, string operation, string? name = null, string? parent = null) => WriteAsync(db =>
    {
        using var tx = db.BeginTransaction();
        if (operation == "delete")
        {
            Execute(db, "PRAGMA defer_foreign_keys=ON; WITH RECURSIVE descendants(id) AS (SELECT $id UNION ALL SELECT c.id FROM categories c JOIN descendants d ON c.parent=d.id) DELETE FROM categories WHERE id IN (SELECT id FROM descendants)", ("id", id));
        }
        else if (operation == "rename")
        { if (string.IsNullOrWhiteSpace(name)) throw new ArgumentException("名前を入力してください。"); Execute(db, "UPDATE categories SET name=$name,normalized=$normalized WHERE id=$id", ("name", name), ("normalized", AssetFormat.Normalize(name)), ("id", id)); }
        else if (operation == "move")
        {
            if (parent is not null)
            {
                if (Scalar(db, "SELECT id FROM categories WHERE id=$id AND type='folder'", ("id", parent)) is null) throw new ArgumentException("親フォルダが見つかりません。");
                if (Convert.ToInt32(Scalar(db, "WITH RECURSIVE descendants(id) AS (SELECT $id UNION ALL SELECT c.id FROM categories c JOIN descendants d ON c.parent=d.id) SELECT count(*) FROM descendants WHERE id=$parent", ("id", id), ("parent", parent))) != 0) throw new ArgumentException("自分の配下には移動できません。");
            }
            Execute(db, "UPDATE categories SET parent=$parent WHERE id=$id AND type='folder'", ("parent", parent), ("id", id));
        }
        else throw new ArgumentException("Unknown category operation.");
        tx.Commit(); return true;
    });
    public Task<bool> UpdateAsync(string[] ids, string operation, string? value = null) => WriteAsync(db =>
    {
        using var tx = db.BeginTransaction();
        foreach (var id in ids.Distinct())
        {
            switch (operation)
            {
                case "favorite": Execute(db, "UPDATE assets SET favorite=NOT favorite WHERE id=$id", ("id", id)); break;
                case "trash": case "restore": Execute(db, "UPDATE assets SET trashed=$trash WHERE id=$id", ("trash", operation == "trash"), ("id", id)); break;
                case "rename": if (string.IsNullOrWhiteSpace(value)) throw new ArgumentException("名前を入力してください。"); Execute(db, "UPDATE assets SET name=$name,normalized=$normal WHERE id=$id", ("name", value), ("normal", AssetFormat.Normalize(value)), ("id", id)); break;
                case "classify": Execute(db, "INSERT OR IGNORE INTO memberships VALUES($id,$category)", ("id", id), ("category", value)); break;
                case "unclassify": Execute(db, "DELETE FROM memberships WHERE asset=$id AND category=$category", ("id", id), ("category", value)); break;
                default: throw new ArgumentException("Unknown operation.");
            }
        }
        tx.Commit(); return true;
    });
}
