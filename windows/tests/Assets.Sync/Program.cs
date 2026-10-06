using HoverPocket.Assets;
using System.Security.Cryptography;
using System.Text.Json;

if (args.Length == 0) { await SyncChecks.RunAsync(); return; }
string? Arg(string key) { var i = Array.IndexOf(args, key); return i >= 0 && i + 1 < args.Length ? args[i + 1] : null; }
var root = Path.GetFullPath(Arg("--root") ?? throw new ArgumentException("--root required"));
if (!Path.GetFileName(root).StartsWith("HoverPocketSyncVerify-", StringComparison.Ordinal))
    throw new ArgumentException("Verification root leaf must start with HoverPocketSyncVerify-");
Directory.CreateDirectory(root);
using var store = new AssetStore(Path.Combine(root, "library"));
await store.Ready;
var action = Arg("--action") ?? "once";
if (action is "create" or "join")
{
    await store.ConfigureSyncAsync(Arg("--transport") ?? throw new ArgumentException("--transport required"), action == "create");
    await store.SetSyncEnabledAsync(true);
}
else if (action == "seed")
{
    var file = Path.Combine(root, "Windowsからの同期テスト.txt");
    await File.WriteAllTextAsync(file, "HoverPocket Windows sync verification 20261005 日本語\n");
    var folder = await store.AddCategoryAsync("folder", "Windows検証");
    var child = await store.AddCategoryAsync("folder", "子フォルダ", folder);
    var tag = await store.AddCategoryAsync("tag", "Windows検証タグ");
    var result = await store.ImportAsync(file, child);
    await store.UpdateAsync([result.AssetId!], "classify", tag);
}
else if (action is "rename" or "trash" or "restore" or "favorite")
{
    var all = (await store.QueryAsync(new(Limit:200))).Items.Concat((await store.QueryAsync(new(View:"trash", Limit:200))).Items);
    var target = all.Single(a => Arg("--sha") is { } hash ? a.Sha256 == hash : a.Name == "Windowsからの同期テスト.txt");
    await store.UpdateAsync([target.Id], action, Arg("--name") ?? "Windowsで変更_日本語");
}
var status = await store.SyncOnceAsync();
var page = await store.QueryAsync(new(Limit:200));
var trash = await store.QueryAsync(new(View:"trash",Limit:200));
var assets = page.Items.Concat(trash.Items).OrderBy(a=>a.Sha256).ToArray();
var manifest = new AssetManifest(1, DateTimeOffset.UtcNow.ToString("O"), assets, page.Folders, page.Tags, page.Searches);
var readback = new { status, manifest, originals = assets.Select(a => new { a.Sha256, actual = Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(store.OriginalPath(a)))) }) };
await File.WriteAllTextAsync(Path.Combine(root, "readback.json"), JsonSerializer.Serialize(readback, AssetFormat.Json));
Console.WriteLine(JsonSerializer.Serialize(new { action, assets=assets.Length, folders=page.Folders.Length, tags=page.Tags.Length, status },AssetFormat.Json));
if (status.Error is not null) Environment.ExitCode = 1;
