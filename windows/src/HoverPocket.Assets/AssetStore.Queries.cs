using System.Text.Json;
using Microsoft.Data.Sqlite;

namespace HoverPocket.Assets;

public sealed partial class AssetStore
{
    public Task<AssetPage> QueryAsync(AssetQuery query, CancellationToken token = default) => QueryCoreAsync(query, null, token);
    public async Task<bool> MatchesAsync(AssetQuery query, string id) => (await QueryCoreAsync(query with { Offset = 0, Limit = 1 }, id, CancellationToken.None)).Total > 0;
    private async Task<AssetPage> QueryCoreAsync(AssetQuery query, string? selectedId, CancellationToken token)
    {
        AssetFormat.ValidateQuery(query);
        await Ready;
        if (RecoveryWarning is not null) return new([], 0, [], [], []);
        return await ReadAsync(db =>
        {
            var (clause, args) = QueryFilter(query);
            if (selectedId is not null) { clause += " AND a.id=$selected"; args.Add(("selected", selectedId)); }
            var total = Convert.ToInt64(Scalar(db, $"SELECT count(*) FROM assets a WHERE {clause}", args.ToArray()));
            args.Add(("limit", Math.Clamp(query.Limit, 1, 200))); args.Add(("offset", Math.Max(0, query.Offset)));
            var assets = ReadAssets(db, $"SELECT a.* FROM assets a WHERE {clause} ORDER BY {QueryOrder(query)} LIMIT $limit OFFSET $offset", args.ToArray());
            using var formats = Command(db, "SELECT DISTINCT extension FROM assets ORDER BY extension");
            using var formatRows = formats.ExecuteReader(); var extensions = new List<string>();
            while (formatRows.Read()) extensions.Add(formatRows.GetString(0));
            return new AssetPage(assets, total, Categories(db, "folder"), Categories(db, "tag"), Searches(db), extensions.ToArray());
        }, token);
    }
    private static (string Clause, List<(string Key, object? Value)> Args) QueryFilter(AssetQuery query)
    {
        var where = new List<string> { "a.trashed=$trash" }; var args = new List<(string, object?)> { ("trash", query.View == "trash") };
        if (query.View == "favorites") where.Add("a.favorite=1");
        if (query.View == "uncategorized") where.Add("a.id NOT IN(SELECT m.asset FROM memberships m JOIN categories c ON c.id=m.category WHERE c.type='folder')");
        if (!string.IsNullOrEmpty(query.Kind)) { where.Add("a.kind=$kind"); args.Add(("kind", query.Kind)); }
        if (query.Extension is not null) { where.Add("a.extension=$extension"); args.Add(("extension", query.Extension)); }
        foreach (var (key, values) in new[] { ("folder", (query.FolderIds ?? []).Concat(query.FolderId is null ? [] : new[] { query.FolderId }).Distinct().ToArray()), ("tag", (query.TagIds ?? []).Concat(query.TagId is null ? [] : new[] { query.TagId }).Distinct().ToArray()) })
            if (values.Length > 0)
            {
                var parameters = values.Select((value, index) => { var name = key + index; args.Add((name, value)); return "$" + name; });
                where.Add($"a.id IN(SELECT m.asset FROM memberships m WHERE m.category IN ({string.Join(',', parameters)}))");
            }
        if (query.CreatedAfter is not null) { where.Add("julianday(a.created)>=julianday($after)"); args.Add(("after", query.CreatedAfter)); }
        if (query.CreatedBefore is not null) { where.Add("julianday(a.created)<julianday($before)"); args.Add(("before", query.CreatedBefore)); }
        var i = 0;
        foreach (var word in AssetFormat.Normalize(query.Text).Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries))
        {
            var key = "q" + i++; args.Add((key, word));
            where.Add($"(instr(a.normalized,${key})>0 OR instr(a.extension,${key})>0 OR a.id IN(SELECT m.asset FROM memberships m JOIN categories c ON c.id=m.category WHERE c.type='tag' AND instr(c.normalized,${key})>0))");
        }
        var clause = string.Join(" AND ", where);
        return (clause, args);
    }
    private static string QueryOrder(AssetQuery query)
    {
        var column = query.SortBy switch { "name" => "a.normalized", "size" => "a.size", _ => "a.created" };
        return $"{column} {(query.Descending ? "DESC" : "ASC")},a.id";
    }
    public async Task<string[]> SelectionRangeAsync(AssetQuery query, string anchorId, string targetId, CancellationToken token = default)
    {
        AssetFormat.ValidateQuery(query);
        await Ready;
        if (RecoveryWarning is not null) return [];
        return await ReadAsync(db =>
        {
            var (clause, args) = QueryFilter(query);
            args.Add(("anchor", anchorId)); args.Add(("target", targetId));
            using var command = Command(db, $"""
                WITH ordered AS (
                    SELECT a.id,ROW_NUMBER() OVER (ORDER BY {QueryOrder(query)}) AS position FROM assets a WHERE {clause}
                ), bounds AS (
                    SELECT MIN(position) AS first,MAX(position) AS last,COUNT(*) AS count FROM ordered WHERE id IN ($anchor,$target)
                )
                SELECT id FROM ordered,bounds WHERE bounds.count=CASE WHEN $anchor=$target THEN 1 ELSE 2 END
                    AND position BETWEEN bounds.first AND bounds.last ORDER BY position
                """, args.ToArray());
            using var rows = command.ExecuteReader(); var ids = new List<string>();
            while (rows.Read()) { token.ThrowIfCancellationRequested(); ids.Add(rows.GetString(0)); }
            return ids.ToArray();
        }, token);
    }
    public async Task<Asset?> GetAsync(string id)
    {
        await Ready; if (RecoveryWarning is not null) return null;
        return await ReadAsync(db => ReadAssets(db, "SELECT * FROM assets WHERE id=$id", ("id", id)).FirstOrDefault());
    }
    private static Asset[] ReadAssets(SqliteConnection db, string sql, params (string, object?)[] args)
    {
        using var command = Command(db, sql, args); using var reader = command.ExecuteReader(); var list = new List<Asset>();
        while (reader.Read()) list.Add(new(reader.GetString(0), reader.GetString(1), reader.GetString(3), reader.GetString(4), reader.GetString(5), reader.GetInt64(6),
            reader.GetString(7), reader.GetBoolean(8), reader.GetBoolean(9), reader.GetBoolean(10), [], []));
        reader.Close();
        for (var i = 0; i < list.Count; i++)
        {
            using var membership = Command(db, "SELECT c.id,c.type FROM categories c JOIN memberships m ON m.category=c.id WHERE m.asset=$id", ("id", list[i].Id));
            using var rows = membership.ExecuteReader(); var folders = new List<string>(); var tags = new List<string>();
            while (rows.Read()) (rows.GetString(1) == "folder" ? folders : tags).Add(rows.GetString(0));
            list[i] = list[i] with { FolderIds = folders.ToArray(), TagIds = tags.ToArray() };
        }
        return list.ToArray();
    }
    private static Category[] Categories(SqliteConnection db, string type)
    {
        using var command = Command(db, "SELECT id,name,parent FROM categories WHERE type=$type ORDER BY normalized,id", ("type", type));
        using var rows = command.ExecuteReader(); var list = new List<Category>();
        while (rows.Read()) list.Add(new(rows.GetString(0), rows.GetString(1), rows.IsDBNull(2) ? null : rows.GetString(2))); return list.ToArray();
    }
    private static SavedSearch[] Searches(SqliteConnection db)
    {
        using var command = Command(db, "SELECT id,name,filter FROM searches ORDER BY name"); using var rows = command.ExecuteReader(); var list = new List<SavedSearch>();
        while (rows.Read()) list.Add(new(rows.GetString(0), rows.GetString(1), JsonSerializer.Deserialize<AssetQuery>(rows.GetString(2), AssetFormat.Json)!)); return list.ToArray();
    }
    // Callers complete initialization and handle recovery mode before entering the shared reader gate.
    private async Task<T> ReadAsync<T>(Func<SqliteConnection, T> action, CancellationToken token = default)
    {
        await _readers.WaitAsync(token);
        try
        {
            return await Task.Run(() =>
            {
                token.ThrowIfCancellationRequested();
                using var db = Open();
                return action(db);
            }, token);
        }
        finally { _readers.Release(); }
    }
}
