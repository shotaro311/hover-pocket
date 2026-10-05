using System.Text.Json;
using Microsoft.Data.Sqlite;

namespace HoverPocket.Assets;

public sealed partial class AssetStore
{
    public Task<ExportResult> ExportAsync(string destination, CancellationToken token = default) => Task.Run(() => ExportCoreAsync(destination, token), token);
    private async Task<ExportResult> ExportCoreAsync(string destination, CancellationToken token)
    {
        await Ready; Writable(); destination = Path.GetFullPath(destination);
        if (destination.StartsWith(Root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) || destination == Root || Directory.Exists(destination)) throw new ArgumentException("管理領域外の新しいフォルダを指定してください。");
        await _writer.WaitAsync(token);
        try
        {
            using var db = Open();
            var manifest = new AssetManifest(1, DateTimeOffset.UtcNow.ToString("O"), ReadAssets(db, "SELECT * FROM assets"), Categories(db, "folder"), Categories(db, "tag"), Searches(db), Convert.ToInt64(Scalar(db,"SELECT count(*) FROM imports")));
            var drive = new DriveInfo(Path.GetPathRoot(destination)!);
            if (manifest.Assets.Sum(a => a.SizeBytes) + 512L * 1024 * 1024 > drive.AvailableFreeSpace || (drive.DriveFormat == "FAT32" && manifest.Assets.Any(a => a.SizeBytes >= uint.MaxValue))) throw new IOException("バックアップ先の容量または形式が適していません。");
            var temporary = destination + ".partial-" + Guid.NewGuid().ToString("N"); Directory.CreateDirectory(Path.Combine(temporary, "originals"));
            foreach (var asset in manifest.Assets)
            {
                token.ThrowIfCancellationRequested(); var output = Path.Combine(temporary, AssetFormat.RelativePath(asset));
                await CopyFileAsync(OriginalPath(asset), output, token);
                if (await Task.Run(() => HashFile(output), token) != asset.Sha256) throw new InvalidDataException("原本のハッシュが一致しません。バックアップを完了できませんでした。");
            }
            await File.WriteAllTextAsync(Path.Combine(temporary, "manifest.json"), JsonSerializer.Serialize(manifest, AssetFormat.Json), token);
            Directory.Move(temporary, destination);
            return new(manifest.Assets.LongLength, manifest.ExcludedPending);
        }
        finally { _writer.Release(); }
    }
    public Task RestoreAsync(string source, CancellationToken token = default) => Task.Run(() => RestoreCoreAsync(source, token), token);
    private async Task RestoreCoreAsync(string source, CancellationToken token)
    {
        await Ready; Writable(); await _writer.WaitAsync(token);
        try
        {
            using var db = Open(); RejectSyncRestore(db);
            if (Convert.ToInt64(Scalar(db, "SELECT (SELECT count(*) FROM assets)+(SELECT count(*) FROM imports)+(SELECT count(*) FROM categories)+(SELECT count(*) FROM searches)")) != 0) throw new InvalidOperationException("復元は空のライブラリへ行ってください。現在の素材は変更されません。");
            var manifest = JsonSerializer.Deserialize<AssetManifest>(await File.ReadAllTextAsync(Path.Combine(source, "manifest.json"), token), AssetFormat.Json) ?? throw new InvalidDataException();
            if (manifest.Assets is null || manifest.Folders is null || manifest.Tags is null || manifest.Searches is null
                || (File.GetAttributes(Path.Combine(source, "originals")) & FileAttributes.ReparsePoint) != 0) throw new InvalidDataException();
            if (manifest.Version != 1 || !AssetFormat.IsUtc(manifest.CreatedAt) || manifest.Assets.Select(a => a.Id).Distinct().Count() != manifest.Assets.Length || manifest.Assets.Select(a => a.Sha256).Distinct().Count() != manifest.Assets.Length) throw new InvalidDataException("対応していないバックアップ形式です。");
            foreach (var asset in manifest.Assets)
            { AssetFormat.Validate(asset); var path = Path.Combine(source, AssetFormat.RelativePath(asset)); if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0 || new FileInfo(path).Length != asset.SizeBytes || await Task.Run(() => HashFile(path), token) != asset.Sha256) throw new InvalidDataException("バックアップの原本が欠損しているか変更されています。"); }
            if (manifest.Assets.Sum(a => a.SizeBytes) + 512L * 1024 * 1024 > new DriveInfo(Path.GetPathRoot(Root)!).AvailableFreeSpace) throw new IOException("空き容量が不足しています。");
            var categories = manifest.Folders.Concat(manifest.Tags).ToDictionary(c => c.Id);
            var folders = manifest.Folders.Select(c => c.Id).ToHashSet(); var tags = manifest.Tags.Select(c => c.Id).ToHashSet();
            if (manifest.Tags.Any(c => c.ParentId is not null) || categories.Values.Any(c => string.IsNullOrWhiteSpace(c.Name) || c.ParentId is not null && !folders.Contains(c.ParentId))) throw new InvalidDataException("分類の参照が不正です。");
            foreach (var category in categories.Values)
            { if (!Guid.TryParseExact(category.Id, "D", out _)) throw new InvalidDataException(); var seen = new HashSet<string> { category.Id }; var parent = category.ParentId; while (parent is not null) { if (!seen.Add(parent) || !categories.TryGetValue(parent, out var p)) throw new InvalidDataException("分類の参照が不正です。"); parent = p.ParentId; } }
            foreach (var asset in manifest.Assets) if (asset.FolderIds.Any(id => !folders.Contains(id)) || asset.TagIds.Any(id => !tags.Contains(id))) throw new InvalidDataException("分類の参照が不正です。");
            if (manifest.Searches.Select(s => s.Id).Distinct().Count() != manifest.Searches.Length) throw new InvalidDataException("検索の参照が不正です。");
            foreach (var search in manifest.Searches) { if (!Guid.TryParseExact(search.Id, "D", out _) || string.IsNullOrWhiteSpace(search.Name)) throw new InvalidDataException(); AssetFormat.ValidateQuery(search.Filter); }
            // Validate everything before writing. On interruption, originals remain discoverable for explicit recovery.
            using var tx = db.BeginTransaction(); Execute(db, "PRAGMA defer_foreign_keys=ON;");
            foreach (var (type, items) in new[] { ("folder", manifest.Folders), ("tag", manifest.Tags) }) foreach (var c in items)
                Execute(db, "INSERT INTO categories VALUES($id,$type,$name,$normalized,$parent)", ("id", c.Id), ("type", type), ("name", c.Name), ("normalized", AssetFormat.Normalize(c.Name)), ("parent", c.ParentId));
            foreach (var asset in manifest.Assets)
            {
                await CopyFileAsync(Path.Combine(source, AssetFormat.RelativePath(asset)), OriginalPath(asset), token);
                SetOriginalProperties(OriginalPath(asset), asset); Insert(db, asset);
                foreach (var id in asset.FolderIds.Concat(asset.TagIds)) Execute(db, "INSERT INTO memberships VALUES($asset,$category)", ("asset", asset.Id), ("category", id));
            }
            foreach (var search in manifest.Searches) Execute(db, "INSERT INTO searches VALUES($id,$name,$filter)", ("id", search.Id), ("name", search.Name), ("filter", JsonSerializer.Serialize(search.Filter, AssetFormat.Json)));
            tx.Commit(); Changed?.Invoke();
        }
        finally { _writer.Release(); }
    }
    public Task<string> ReplaceFromBackupAsync(string source, CancellationToken token = default) => Task.Run(() => ReplaceCoreAsync(source, token), token);
    private async Task<string> ReplaceCoreAsync(string source, CancellationToken token)
    {
        await Ready; Writable();
        var staged = Root + ".restore-" + Guid.NewGuid().ToString("N");
        using (var incoming = new AssetStore(staged)) await incoming.RestoreAsync(source, token);
        await _writer.WaitAsync(token);
        try { await _readers.WaitAsync(token); } catch { _writer.Release(); throw; }
        var archive = Root + ".archive-" + DateTime.UtcNow.ToString("yyyyMMdd-HHmmss") + "-" + Guid.NewGuid().ToString("N")[..8];
        try
        {
            using (var db = Open()) RejectSyncRestore(db);
            _hostLock?.Dispose(); _hostLock = null;
            Directory.Move(Root, archive);
            try { Directory.Move(staged, Root); Initialize(); }
            catch
            {
                _hostLock?.Dispose(); _hostLock = null;
                if (Directory.Exists(Root)) Directory.Move(Root, staged + ".failed");
                Directory.Move(archive, Root); Initialize(); throw;
            }
            Changed?.Invoke(); return archive;
        }
        finally
        {
            if (_hostLock is null && Directory.Exists(Root)) _hostLock = new FileStream(Path.Combine(Root, "writer.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
            _readers.Release(); _writer.Release();
        }
    }
    public Task<string[]> DatabaseSnapshotsAsync() => Task.Run(async () => { await Ready; return Directory.EnumerateFiles(Path.Combine(Root, "snapshots"), "*.sqlite").Select(Path.GetFileName).Where(name => name is not null).Cast<string>().OrderDescending().ToArray(); });
    public Task RestoreDatabaseSnapshotAsync(string name) => Task.Run(async () =>
    {
        await Ready;
        if (name != Path.GetFileName(name) || !name.EndsWith(".sqlite", StringComparison.Ordinal)) throw new ArgumentException("Invalid snapshot.");
        var path = Path.Combine(Root, "snapshots", name);
        using (var snapshot = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = path, Mode = SqliteOpenMode.ReadOnly, Pooling = false }.ToString()))
        {
            snapshot.Open(); if (Convert.ToInt32(Scalar(snapshot, "PRAGMA user_version")) != 1 || !Equals(Scalar(snapshot, "PRAGMA integrity_check"), "ok")) throw new InvalidDataException("このスナップショットは復元できません。");
        }
        await _writer.WaitAsync(); await _readers.WaitAsync();
        try
        {
            var candidate = _database + ".restored-" + Guid.NewGuid().ToString("N"); await CopyFileAsync(path, candidate, CancellationToken.None);
            using (var db = Open()) CopySyncStateForRestore(db, candidate);
            var archive = _database + ".preserved-" + DateTime.UtcNow.ToString("yyyyMMdd-HHmmss") + "-" + Guid.NewGuid().ToString("N")[..8];
            var moved = new List<string>(); var activated = false;
            try
            {
                foreach (var suffix in new[] { "", "-wal", "-shm" }) if (File.Exists(_database + suffix)) { File.Move(_database + suffix, archive + suffix); moved.Add(suffix); }
                File.Move(candidate, _database); activated = true;
                _hostLock?.Dispose(); _hostLock = null; RecoveryWarning = null; RecoveryNotice = null; Initialize();
                if (RecoveryWarning is not null) throw new InvalidDataException(RecoveryWarning);
            }
            catch
            {
                _hostLock?.Dispose(); _hostLock = null;
                if (activated) foreach (var suffix in new[] { "", "-wal", "-shm" }) if (File.Exists(_database + suffix)) File.Move(_database + suffix, candidate + ".failed" + suffix);
                foreach (var suffix in moved) File.Move(archive + suffix, _database + suffix);
                RecoveryWarning = null; RecoveryNotice = null; Initialize(); throw;
            }
            Changed?.Invoke();
        }
        finally { _readers.Release(); _writer.Release(); }
    });
}
