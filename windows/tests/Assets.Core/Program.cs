using HoverPocket.Assets;
using System.Security.Cryptography;
using System.Text.Json;
using Microsoft.Data.Sqlite;

var root = Path.Combine(Path.GetTempPath(), "HoverPocket-asset-tests", Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(root);
var source = Path.Combine(root, "ＡＢＣ_猫 image.PNG");
await File.WriteAllBytesAsync(source, Enumerable.Range(0, 100000).Select(i => (byte)(i % 251)).ToArray());
var sourceHash = Hash(source); var tests = 0;
void Check(bool condition, string name) { if (!condition) throw new Exception("FAILED: " + name); tests++; }
tests += await OrganizationChecks.RunAsync(root);
Check(AssetFormat.Normalize("Straße Σςσ ＡＢＣ") == AssetFormat.Normalize("STRASSE σσσ abc"), "full case fold expansions and sigma");
Check(AssetFormat.Normalize("İ") == "i\u0307" && AssetFormat.Normalize("ı") != AssetFormat.Normalize("I"), "locale independent dotted and dotless I");
async Task Reject(Func<Task> action, string name) { try { await action(); } catch (Exception ex) when (ex is InvalidDataException or InvalidOperationException or ArgumentException or IOException) { tests++; return; } throw new Exception("FAILED: " + name); }
using var store = new AssetStore(Path.Combine(root, "library"));
await store.Ready;
var folder = await store.AddCategoryAsync("folder", "資料"); var secondFolder = await store.AddCategoryAsync("folder", "別の分類");
var tag = await store.AddCategoryAsync("tag", "Ｈａｌｆ幅");
Check(tag == await store.AddCategoryAsync("tag", "Half幅"), "normalized category uniqueness");
var result = await store.ImportAsync(source, folder, true);
Check(result.Status == "saved", "durable import"); var id = result.AssetId!;
var saved = (await store.GetAsync(id))!;
Check(Hash(source) == sourceHash && Hash(store.OriginalPath(saved)) == sourceHash, "original preserved byte-for-byte");
Check((new FileInfo(source).Attributes & FileAttributes.ReadOnly) == 0, "source remains writable");
using (var rangeStore = new AssetStore(Path.Combine(root, "selection-ranges")))
{
    for (var i = 0; i < 6; i++)
    {
        var rangeSource = Path.Combine(root, $"range-{i}.txt");
        await File.WriteAllTextAsync(rangeSource, $"range fixture {i}" + new string('x', i * 3));
        await rangeStore.ImportAsync(rangeSource);
    }
    var ordered = (await rangeStore.QueryAsync(new())).Items.Select(asset => asset.Id).ToArray();
    foreach (var sort in new[] { "created", "name", "size" })
    foreach (var descending in new[] { false, true })
    {
        var query = new AssetQuery(Version: 2, Extension: "txt", SortBy: sort, Descending: descending);
        var all = (await rangeStore.QueryAsync(query)).Items;
        var keys = all.Select(asset => sort == "name" ? asset.Name : sort == "size" ? asset.SizeBytes.ToString("D20") : asset.CreatedAt).ToArray();
        Check(keys.SequenceEqual(descending ? keys.OrderDescending(StringComparer.Ordinal) : keys.Order(StringComparer.Ordinal)), $"{sort} sort direction {descending}");
        Check((await rangeStore.QueryAsync(query with { Offset = 2, Limit = 2 })).Items.Select(a => a.Id).SequenceEqual(all.Skip(2).Take(2).Select(a => a.Id)), "paging follows global sort");
        Check((await rangeStore.SelectionRangeAsync(query, all[1].Id, all[4].Id)).SequenceEqual(all[1..5].Select(a => a.Id)), "Shift selection follows global sort");
    }
    Check((await rangeStore.QueryAsync(new(Version: 2, Extension: "png"))).Total == 0, "format filter excludes other extensions");
    Check(!(await rangeStore.MatchesAsync(new(Version: 2, Extension: "png"), ordered[0])), "selection matching follows format filter");
    Check((await rangeStore.QueryAsync(new())).Extensions!.SequenceEqual(["txt"]), "format choices include stored extensions");
    var legacyQuery = JsonSerializer.Deserialize<AssetQuery>("{\"text\":\"\",\"view\":\"recent\",\"offset\":0,\"limit\":80}", AssetFormat.Json)!;
    Check((await rangeStore.QueryAsync(legacyQuery)).Items.Select(a => a.Id).SequenceEqual(ordered), "legacy query preserves date descending default");
    await Reject(() => rangeStore.QueryAsync(new(Version: 2, SortBy: "name;DROP TABLE assets")), "unknown sort cannot enter SQL");
    await Reject(() => rangeStore.QueryAsync(new(Version: 2, Extension: "' OR 1=1")), "invalid extension rejected");
    await Reject(() => rangeStore.QueryAsync(new(Extension: "txt")), "new filter requires its explicit version");
    await Reject(() => rangeStore.QueryAsync(new(Text: "\uD800")), "query failure inside the reader gate is propagated");
    Check((await rangeStore.GetAsync(ordered[0]).WaitAsync(TimeSpan.FromSeconds(5)))?.Id == ordered[0], "failed query releases the reader gate for item lookup");
    using (var cancelled = new CancellationTokenSource())
    {
        cancelled.Cancel();
        try { await rangeStore.SelectionRangeAsync(new(), ordered[0], ordered[1], cancelled.Token); throw new Exception("FAILED: cancelled selection completed"); }
        catch (OperationCanceledException) { tests++; }
    }
    var concurrentReads = await Task.WhenAll(Enumerable.Range(0, 12).Select(async index =>
    {
        var page = await rangeStore.QueryAsync(new(Offset: index % 6, Limit: 1));
        var selected = await rangeStore.GetAsync(ordered[index % 6]);
        var ids = await rangeStore.SelectionRangeAsync(new(), ordered[1], ordered[4]);
        return page.Items.Single().Id == selected?.Id && ids.SequenceEqual(ordered[1..5]);
    })).WaitAsync(TimeSpan.FromSeconds(10));
    Check(concurrentReads.All(value => value), "query, lookup and range readers remain usable after cancellation and concurrent requests");
    var range = await rangeStore.SelectionRangeAsync(new(Offset: 4, Limit: 1), ordered[1], ordered[4]);
    Check(range.SequenceEqual(ordered[1..5]), "selection range includes both endpoints beyond the visible page");
    Check((await rangeStore.SelectionRangeAsync(new(), ordered[4], ordered[1])).SequenceEqual(range), "reverse selection uses displayed order");
    Check((await rangeStore.SelectionRangeAsync(new(), ordered[2], ordered[2])).SequenceEqual([ordered[2]]), "same endpoint selects one item");
    await rangeStore.UpdateAsync([ordered[2]], "trash");
    Check((await rangeStore.SelectionRangeAsync(new(), ordered[1], ordered[4])).SequenceEqual(new[] { ordered[1], ordered[3], ordered[4] }), "range excludes hidden trash");
    Check((await rangeStore.SelectionRangeAsync(new(), ordered[2], ordered[4])).Length == 0, "missing range anchor cannot select unrelated items");
    await rangeStore.UpdateAsync([ordered[1], ordered[4]], "favorite");
    Check((await rangeStore.SelectionRangeAsync(new(View: "favorites"), ordered[1], ordered[4])).SequenceEqual([ordered[1], ordered[4]]), "range follows active filter");
}
var duplicate = await store.ImportAsync(source, secondFolder);
Check(duplicate.Status == "duplicate" && duplicate.AssetId == id, "SHA dedup");
Check((await store.GetAsync(id))!.FolderIds.Length == 2, "duplicate merges memberships");
foreach (var damage in new[] { "missing", "same-size-content" })
{
    var recycled = new List<string>();
    using var damaged = new AssetStore(Path.Combine(root, "duplicate-" + damage), path => { recycled.Add(path); return Task.FromResult(true); });
    var first = await damaged.ImportAsync(source); var managed = (await damaged.GetAsync(first.AssetId!))!;
    var managedPath = damaged.OriginalPath(managed);
    if (damage == "missing") File.Move(managedPath, Path.Combine(root, "preserved-duplicate-original.png"));
    else
    {
        File.SetAttributes(managedPath, FileAttributes.Normal);
        await File.WriteAllBytesAsync(managedPath, Enumerable.Repeat((byte)42, (int)managed.SizeBytes).ToArray());
        File.SetLastWriteTimeUtc(managedPath, DateTimeOffset.Parse(managed.CreatedAt).UtcDateTime);
    }
    var damagedHash = File.Exists(managedPath) ? Hash(managedPath) : null;
    var folderId = await damaged.AddCategoryAsync("folder", "must not merge on failure");
    var retry = await damaged.ImportAsync(source, folderId, true);
    Check(retry.Status == "failed" && retry.Error?.Contains("原本") == true, damage + " original refuses duplicate success");
    Check(recycled.Count == 0 && Hash(source) == sourceHash && Directory.EnumerateFiles(Path.Combine(damaged.Root, "staging"), "*.partial").Any(), damage + " retains incoming copy and source");
    Check((await damaged.GetAsync(managed.Id))!.FolderIds.Length == 0 && !(await damaged.GetAsync(managed.Id))!.InternetOrigin, damage + " leaves duplicate metadata unchanged");
    Check((File.Exists(managedPath) ? Hash(managedPath) : null) == damagedHash, damage + " leaves damaged original unchanged");
}
await store.UpdateAsync([id], "classify", tag);
Check((await store.QueryAsync(new(Text: "abc 猫"))).Total == 1, "NFKC and Japanese substring AND search");
Check((await store.QueryAsync(new(Text: "half幅"))).Total == 1, "tag search");
Check((await store.QueryAsync(new(FolderIds:[Guid.NewGuid().ToString("D"), secondFolder],TagIds:[tag]))).Total == 1, "OR within categories, AND across folder and tag filters");
Check((await store.QueryAsync(new(CreatedAfter:"2000-01-01T00:00:00Z",CreatedBefore:"2100-01-01T00:00:00Z"))).Total == 1, "inclusive and exclusive UTC date bounds");
Check((await store.QueryAsync(new(CreatedBefore:"2000-01-01T00:00:00Z"))).Total == 0, "date excludes later imports");
await Reject(() => store.SaveSearchAsync("unknown", new(Version:99)), "unknown saved query version rejected");
Check((await store.QueryAsync(new(Text: "' OR 1=1 --"))).Total == 0, "SQL metacharacters remain literals");
Check((await store.QueryAsync(new(View: "uncategorized"))).Total == 0, "uncategorized is folder membership");
await store.UpdateAsync([id], "favorite"); Check((await store.QueryAsync(new(View: "favorites"))).Total == 1, "favorite filter");
await store.UpdateAsync([id], "rename", "改名済み.pdf"); Check(Hash(store.OriginalPath(saved)) == sourceHash && (await store.GetAsync(id))!.Extension == "png", "rename preserves ID, path, extension, bytes");
await store.SaveSearchAsync("画像", new(Kind: "image", Version: 2, Extension: "png", SortBy: "name", Descending: false));
var copy = await store.CopyOutAsync(id); await File.WriteAllTextAsync(copy, "external edit");
Check(Hash(store.OriginalPath(saved)) == sourceHash, "external copy isolated");
await store.UpdateAsync([id], "trash");
Check((await store.QueryAsync(new())).Total == 0 && (await store.QueryAsync(new(View: "trash"))).Total == 1, "trash retains original");
Check((await store.ImportAsync(source)).Status == "restoreAvailable", "trash reimport cannot duplicate");
var backup = Path.Combine(root, "backup"); await store.ExportAsync(backup);
using var restored = new AssetStore(Path.Combine(root, "restored"));
await restored.RestoreAsync(backup);
var after = (await restored.GetAsync(id))!;
Check(after.Trashed && after.Favorite && after.InternetOrigin && after.FolderIds.Length == 2 && after.TagIds.Single() == tag, "portable metadata roundtrip");
Check(Hash(restored.OriginalPath(after)) == sourceHash, "backup byte integrity");
if (OperatingSystem.IsWindows()) Check((await File.ReadAllTextAsync(restored.OriginalPath(after)+":Zone.Identifier")).Contains("ZoneId=3"), "internet origin mark reapplied on restore");
Check((await restored.QueryAsync(new(View: "trash"))).Searches.Length == 1, "saved search roundtrip");
var restoredFilter = (await restored.QueryAsync(new())).Searches.Single().Filter;
Check(restoredFilter is { Version: 2, Extension: "png", SortBy: "name", Descending: false }, "format and order survive backup roundtrip");
await Reject(() => restored.RestoreAsync(backup), "nonempty restore refused");
await Reject(() => store.ExportAsync(Path.Combine(store.Root, "bad")), "backup inside managed root refused");
var manifestPath = Path.Combine(backup, "manifest.json"); var manifest = JsonSerializer.Deserialize<AssetManifest>(await File.ReadAllTextAsync(manifestPath), AssetFormat.Json)!;
using var invalid = new AssetStore(Path.Combine(root, "invalid"));
await File.WriteAllTextAsync(manifestPath, JsonSerializer.Serialize(manifest with { Version = 99 }, AssetFormat.Json));
await Reject(() => invalid.RestoreAsync(backup), "unknown manifest refused");
await File.WriteAllTextAsync(manifestPath, JsonSerializer.Serialize(manifest with { Assets = [manifest.Assets[0] with { Id = "../../escape" }] }, AssetFormat.Json));
await Reject(() => invalid.RestoreAsync(backup), "path traversal refused");
await File.WriteAllTextAsync(manifestPath, JsonSerializer.Serialize(manifest, AssetFormat.Json));
await File.WriteAllTextAsync(manifestPath, JsonSerializer.Serialize(manifest with { Assets = [manifest.Assets[0] with { TagIds = manifest.Assets[0].FolderIds }] }, AssetFormat.Json));
await Reject(() => invalid.RestoreAsync(backup), "folder cannot be restored as tag membership");
await File.WriteAllTextAsync(manifestPath, JsonSerializer.Serialize(manifest, AssetFormat.Json));
var backupOriginal = Path.Combine(backup, AssetFormat.RelativePath(saved)); await File.WriteAllTextAsync(backupOriginal, "corrupted");
await Reject(() => invalid.RestoreAsync(backup), "corrupt backup refused before writes");
Check((await invalid.QueryAsync(new())).Total == 0, "failed restore keeps empty database");
using var shared = new AssetStore(Path.Combine(root, "shared-fixture")); await shared.RestoreAsync(Path.Combine(AppContext.BaseDirectory, "fixture"));
var sharedAsset = (await shared.QueryAsync(new(View: "trash", Text: "abc 猫"))).Items.Single();
Check(sharedAsset.InternetOrigin && sharedAsset.Favorite && sharedAsset.FolderIds.Length == 1 && sharedAsset.TagIds.Length == 1, "canonical shared fixture compatibility");
Check((await shared.QueryAsync(new(View: "trash", Text: "half幅"))).Total == 1, "canonical normalization fixture");
var sharedFilters = (await shared.QueryAsync(new())).Searches;
Check(sharedFilters.Single(s => s.Filter.Version == 1).Filter is { Extension: null, SortBy: "created", Descending: true }, "canonical legacy saved search defaults");
Check((await shared.QueryAsync(sharedFilters.Single(s => s.Filter.Version == 2).Filter)).Items.Single().Id == sharedAsset.Id, "canonical v2 format and sort fixture");
var child = await store.AddCategoryAsync("folder", "子", folder);
await Reject(() => store.ChangeCategoryAsync(folder, "move", parent: child), "folder cycle rejected");
await store.ChangeCategoryAsync(folder, "delete");
Check((await store.GetAsync(id))!.TagIds.Length == 1 && File.Exists(store.OriginalPath(saved)), "category subtree deletion preserves originals and other memberships");
var beforeFailedRecycle = (await restored.QueryAsync(new(View: "trash"))).Total;
Check(await restored.EmptyTrashAsync(_ => Task.FromResult(false)) == 0 && (await restored.QueryAsync(new(View: "trash"))).Total == beforeFailedRecycle, "failed OS recycling retains metadata and original");
var backup2 = Path.Combine(root, "replacement-backup"); await shared.ExportAsync(backup2);
var archived = await restored.ReplaceFromBackupAsync(backup2);
Check(Directory.Exists(archived) && File.Exists(Path.Combine(archived, "originals", Path.GetFileName(store.OriginalPath(saved)))), "replacement archives existing library");
Check((await restored.QueryAsync(new(View: "trash"))).Items.Single().Id == sharedAsset.Id, "validated replacement activates incoming snapshot");
foreach (var phase in new[] { "copied", "moved", "committed" })
{
    var interruptedRoot = Path.Combine(root, "interrupted-" + phase);
    using (var interrupted = new AssetStore(interruptedRoot))
    {
        interrupted.ImportCheckpoint = checkpoint => { if (checkpoint == phase) throw new SimulatedCrash(); };
        try { await interrupted.ImportAsync(source); } catch (SimulatedCrash) { }
    }
    using var recovered = new AssetStore(interruptedRoot);
    var recoveredAsset = (await recovered.QueryAsync(new())).Items.Single();
    Check(Hash(recovered.OriginalPath(recoveredAsset)) == sourceHash && Hash(source) == sourceHash, "journal recovery after " + phase);
}
var snapshotRoot = Path.Combine(root,"snapshot-recovery"); string[] snapshots;
using (var firstStore = new AssetStore(snapshotRoot)) { await firstStore.Ready; await firstStore.ImportAsync(source); snapshots = await firstStore.DatabaseSnapshotsAsync(); }
var dbPath = Path.Combine(snapshotRoot,"library.sqlite");
using (var newer = new SqliteConnection(new SqliteConnectionStringBuilder {DataSource=dbPath,Pooling=false}.ToString())) { newer.Open(); using var command=newer.CreateCommand(); command.CommandText="PRAGMA user_version=99"; command.ExecuteNonQuery(); }
var newerHash=Hash(dbPath);
using (var newerStore = new AssetStore(snapshotRoot)) { await newerStore.Ready; Check(newerStore.RecoveryWarning is not null && Hash(dbPath)==newerHash,"future database preserved without writes"); await Reject(()=>newerStore.ImportAsync(source),"future database refuses import"); }
await File.WriteAllTextAsync(dbPath,"not a database");
using (var brokenStore = new AssetStore(snapshotRoot)) { await brokenStore.Ready; Check(brokenStore.RecoveryWarning is not null,"corrupt DB enters protected recovery"); await brokenStore.RestoreDatabaseSnapshotAsync(snapshots[0]); Check(brokenStore.RecoveryWarning is null && (await brokenStore.OrphansAsync()).Length==1,"snapshot restoration retains orphan original"); Check(Directory.EnumerateFiles(snapshotRoot,"library.sqlite.preserved-*").Any(),"corrupt database preserved during recovery"); }
if (OperatingSystem.IsWindows())
{
    var downloaded=Path.Combine(root,"downloaded.txt"); await File.WriteAllTextAsync(downloaded,"synthetic internet origin fixture"); await File.WriteAllTextAsync(downloaded+":Zone.Identifier","[ZoneTransfer]\r\nZoneId=3\r\n");
    using var originStore=new AssetStore(Path.Combine(root,"origin")); var imported=await originStore.ImportAsync(downloaded);
    Check((await originStore.GetAsync(imported.AssetId!))!.InternetOrigin,"NTFS source origin detected without File.Exists on ADS");
    var exported=await originStore.CopyOutAsync(imported.AssetId!); Check((await File.ReadAllTextAsync(exported+":Zone.Identifier")).Contains("ZoneId=3"),"external copy retains internet origin");
}
using (var changedStore=new AssetStore(Path.Combine(root,"changed-original")))
{
    var imported=await changedStore.ImportAsync(source); var asset=(await changedStore.GetAsync(imported.AssetId!))!;
    var path=changedStore.OriginalPath(asset); File.SetAttributes(path,FileAttributes.Normal); File.SetLastWriteTimeUtc(path,DateTime.UtcNow.AddMinutes(1));
    await Reject(()=>changedStore.CopyOutAsync(asset.Id),"changed original timestamp blocks extraction without repair");
    Check(File.Exists(path),"changed original retained for explicit recovery");
}
Console.WriteLine($"PASS {tests} asset storage checks; test data retained at an isolated temporary root.");
static string Hash(string path) { using var file = File.OpenRead(path); return Convert.ToHexString(SHA256.HashData(file)).ToLowerInvariant(); }
sealed class SimulatedCrash : Exception { }
