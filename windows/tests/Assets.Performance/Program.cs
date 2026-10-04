using System.Diagnostics;
using System.Text.Json;
using HoverPocket.Assets;
using Microsoft.Data.Sqlite;

var root = Path.Combine(Path.GetTempPath(), "HoverPocket-asset-performance", Guid.NewGuid().ToString("N"));
var results = new List<object>();
foreach (var count in new[] { 10000, 100000 })
{
    using var store = new AssetStore(Path.Combine(root, count.ToString())); await store.Ready;
    var folder = await store.AddCategoryAsync("folder", "旅行"); var tag = await store.AddCategoryAsync("tag", "ねこ animal");
    using (var db = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = Path.Combine(store.Root, "library.sqlite"), Pooling = false }.ToString()))
    {
        db.Open(); using var tx = db.BeginTransaction(); using var insert = db.CreateCommand(); insert.Transaction = tx;
        insert.CommandText = "INSERT INTO assets VALUES($id,$name,$normalized,$extension,$kind,$hash,10000,$created,$favorite,0,0)";
        foreach (var key in new[] { "id", "name", "normalized", "extension", "kind", "hash", "created", "favorite" }) insert.Parameters.AddWithValue("$" + key, "");
        using var membership = db.CreateCommand(); membership.Transaction = tx; membership.CommandText = "INSERT INTO memberships VALUES($id,$category)"; membership.Parameters.AddWithValue("$id", ""); membership.Parameters.AddWithValue("$category", "");
        var names = new[] { "猫の写真", "東京の旅行", "設計図", "素材 image", "画面 screenshot", "ＡＢＣ document", "ﾉｰﾄ", "動画 video", "PDF 資料", "犬 animal" };
        for (var i = 0; i < count; i++)
        {
            var id = Guid.NewGuid().ToString("D"); var name = names[i % names.Length] + $" {i:D6}";
            var kind = i % 10 < 7 ? "image" : i % 10 == 7 ? "video" : i % 10 == 8 ? "pdf" : "other";
            var ext = kind switch { "image" => "png", "video" => "mp4", "pdf" => "pdf", _ => "txt" };
            foreach (var (key, value) in new (string, object)[] { ("id", id), ("name", name), ("normalized", AssetFormat.Normalize(name)), ("extension", ext), ("kind", kind), ("hash", i.ToString("x64")), ("created", DateTimeOffset.UnixEpoch.AddSeconds(i).ToString("O")), ("favorite", i % 9 == 0 ? 1 : 0) }) insert.Parameters["$" + key].Value = value;
            insert.ExecuteNonQuery();
            if (i % 5 == 0) { membership.Parameters["$id"].Value = id; membership.Parameters["$category"].Value = tag; membership.ExecuteNonQuery(); }
            if (i % 7 == 0) { membership.Parameters["$id"].Value = id; membership.Parameters["$category"].Value = folder; membership.ExecuteNonQuery(); }
        }
        tx.Commit();
    }
    var queries = new AssetQuery[] { new(), new("猫"), new("図"), new("素材"), new("画面"), new("東京"), new("旅行"), new("ねこ"), new("ノート"), new("ＡＢＣ"), new("image"), new("video"), new("資料"), new("animal"), new("猫 png"), new("東京", FolderId:folder), new("animal", TagId:tag), new(View:"favorites"), new(View:"uncategorized"), new(Kind:"pdf") };
    foreach (var query in queries)
    {
        await store.QueryAsync(query); var samples = new List<double>();
        for (var run = 0; run < 5; run++) { var timer = Stopwatch.StartNew(); await store.QueryAsync(query); samples.Add(timer.Elapsed.TotalMilliseconds); }
        samples.Sort(); results.Add(new { count, query, samples, p95Ms = samples[(int)Math.Ceiling(.95 * samples.Count) - 1], maxMs = samples[^1] });
    }
}
var report = new { measurement = "SQLite query completion only; excludes IPC, debounce, paint, original media and baseline-machine acceptance", fixture = "generated metadata with 70% image, 10% video, 10% PDF, 10% other; folder/tag memberships", results };
Console.WriteLine(JsonSerializer.Serialize(report, AssetFormat.Json));
