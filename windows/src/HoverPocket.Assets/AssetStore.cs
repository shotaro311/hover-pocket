using System.Security.Cryptography;
using Microsoft.Data.Sqlite;

namespace HoverPocket.Assets;

// The gate serializes writers and pins originals throughout snapshot export. Readers use separate connections.
public sealed partial class AssetStore : IDisposable
{
    private readonly SemaphoreSlim _writer = new(1);
    private readonly SemaphoreSlim _readers = new(1);
    private readonly Lazy<Task> _ready;
    private readonly string _database;
    private FileStream? _hostLock;
    private readonly Func<string, Task<bool>>? _recycle;
    public string Root { get; }
    public string? RecoveryWarning { get; private set; }
    public string? RecoveryNotice { get; private set; }
    internal Action<string>? ImportCheckpoint { get; set; }
    public event Action? Changed;
    public AssetStore(string root, Func<string, Task<bool>>? recycle = null)
    {
        Root = Path.GetFullPath(root); _database = Path.Combine(Root, "library.sqlite");
        _recycle = recycle;
        _ready = new(() => Task.Run(Initialize));
    }
    public Task Ready => _ready.Value;
    private SqliteConnection Open()
    {
        var db = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = _database, Pooling = false }.ToString());
        try { db.Open(); Execute(db, "PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;"); return db; }
        catch { db.Dispose(); throw; }
    }
    private void Initialize()
    {
        try { InitializeCore(); }
        catch (SqliteException) { RecoveryWarning = "ライブラリのDBを読み取れません。原本と破損したDBは保護されています。「DBの復旧」からスナップショットを選んでください。"; }
    }
    private void InitializeCore()
    {
        foreach (var directory in new[] { "originals", "staging", "cache", "outbox", "snapshots" }) Directory.CreateDirectory(Path.Combine(Root, directory));
        _hostLock = new FileStream(Path.Combine(Root, "writer.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
        using var db = Open();
        var version = Convert.ToInt32(Scalar(db, "PRAGMA user_version"));
        if (version > AssetFormat.Version) { RecoveryWarning = "このライブラリは新しい版で作成されています。対応するアプリへ更新してください。"; return; }
        if (!Equals(Scalar(db, "PRAGMA quick_check"), "ok")) { RecoveryWarning = "ライブラリの整合性を確認できません。原本とDBは保護されています。"; return; }
        Execute(db, "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;");
        using (var schema = typeof(AssetStore).Assembly.GetManifestResourceStream("AssetLibrary.001-initial.sql")!)
        using (var reader = new StreamReader(schema)) Execute(db, reader.ReadToEnd());
        // A journal with a completed original is recovered; interrupted copies remain available for diagnosis.
        using (var command = Command(db, "SELECT id,name,extension,created,internet,folder,sha256,size FROM imports"))
        using (var reader = command.ExecuteReader())
        {
            var pending = new List<(Asset Asset, string? Folder)>();
            while (reader.Read()) if (!reader.IsDBNull(6))
                pending.Add((new(reader.GetString(0), reader.GetString(1), reader.GetString(2), AssetFormat.Kind(reader.GetString(2)),
                    reader.GetString(6), reader.GetInt64(7), reader.GetString(3), false, false, reader.GetBoolean(4), [], []), reader.IsDBNull(5) ? null : reader.GetString(5)));
            reader.Close();
            foreach (var item in pending)
            {
                var path = OriginalPath(item.Asset);
                var staged = Path.Combine(Root, "staging", item.Asset.Id + ".partial");
                if (!File.Exists(path) && File.Exists(staged) && new FileInfo(staged).Length == item.Asset.SizeBytes && HashFile(staged) == item.Asset.Sha256)
                { File.Move(staged, path); File.SetAttributes(path, File.GetAttributes(path) | FileAttributes.ReadOnly); }
                if (File.Exists(path) && HashFile(path) == item.Asset.Sha256) { SetOriginalProperties(path,item.Asset); CommitImport(db, item.Asset, item.Folder); }
            }
        }
        var unfinished = Convert.ToInt64(Scalar(db, "SELECT count(*) FROM imports"));
        var uncertainPurges = Convert.ToInt64(Scalar(db, "SELECT count(*) FROM purges WHERE recycled=0"));
        if (unfinished + uncertainPurges > 0) RecoveryNotice = $"前回の未完了の取り込み {unfinished}件、ゴミ箱への移動確認待ち {uncertainPurges}件があります。元のファイルを選び直して取り込むか、Windowsのゴミ箱を確認してください。原本は自動削除しません。";
        Execute(db, "DELETE FROM assets WHERE id IN (SELECT id FROM purges WHERE recycled=1)");
        var today = Path.Combine(Root, "snapshots", $"daily-{DateTime.UtcNow:yyyy-MM-dd}.sqlite");
        if (!File.Exists(today)) { using var backup = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = today, Pooling = false }.ToString()); backup.Open(); db.BackupDatabase(backup); }
        if (_recycle is not null)
            foreach (var old in Directory.EnumerateFiles(Path.Combine(Root, "snapshots"), "daily-*.sqlite").OrderDescending().Skip(7))
                if (!_recycle(old).GetAwaiter().GetResult()) RecoveryNotice = (RecoveryNotice is null ? "" : RecoveryNotice + " ") + "古いDBスナップショットをWindowsのゴミ箱へ移せなかったため保持しています。";
    }
    private void Writable() { if (RecoveryWarning is not null) throw new InvalidOperationException(RecoveryWarning); }
    public string OriginalPath(Asset asset)
    {
        AssetFormat.Validate(asset); return Path.Combine(Root, AssetFormat.RelativePath(asset).Replace('/', Path.DirectorySeparatorChar));
    }
    public string ReadOriginalPath(Asset asset)
    {
        var path = OriginalPath(asset); var info = new FileInfo(path);
        if (!info.Exists || info.Length != asset.SizeBytes || info.LastWriteTimeUtc != DateTimeOffset.Parse(asset.CreatedAt).UtcDateTime || (info.Attributes & FileAttributes.ReparsePoint) != 0)
            throw new InvalidDataException("原本が欠損しているか変更されています。バックアップを確認してください。");
        return path;
    }
    public async Task<ImportResult> ImportAsync(string source, string? folderId = null, bool internet = false, CancellationToken token = default)
    {
        await Ready; Writable();
        return await Task.Run<ImportResult>(async () =>
        {
            await _writer.WaitAsync(token);
            try
            {
                var info = new FileInfo(source);
                if (!info.Exists || (info.Attributes & FileAttributes.ReparsePoint) != 0) return new("skipped");
                internet |= HasInternetOrigin(source);
                if (info.Length + 512L * 1024 * 1024 > new DriveInfo(Path.GetPathRoot(Root)!).AvailableFreeSpace) return new("failed", Error: "空き容量が不足しています。");
                var initialLength = info.Length; var initialTime = info.LastWriteTimeUtc;
                var id = Guid.NewGuid().ToString("D");
                var extension = Path.GetExtension(source).TrimStart('.').ToLowerInvariant();
                if (extension.Length > 32 || extension.Any(c => !char.IsAsciiLetterOrDigit(c))) extension = "";
                var name = Path.GetFileName(source); var created = DateTimeOffset.UtcNow.ToString("O");
                var staging = Path.Combine(Root, "staging", id + ".partial");
                using var db = Open();
                if (folderId is not null && Scalar(db,"SELECT id FROM categories WHERE id=$id AND type='folder'",("id",folderId)) is null) folderId=null;
                Execute(db, "INSERT INTO imports(id,name,extension,created,internet,folder) VALUES($id,$name,$ext,$created,$internet,$folder)",
                    ("id", id), ("name", name), ("ext", extension), ("created", created), ("internet", internet), ("folder", folderId));
                using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
                await using (var input = new FileStream(source, FileMode.Open, FileAccess.Read, FileShare.Read, 131072, true))
                await using (var output = new FileStream(staging, FileMode.CreateNew, FileAccess.Write, FileShare.None, 131072, true))
                {
                    var buffer = new byte[131072]; int count; long copied = 0;
                    while ((count = await input.ReadAsync(buffer, token)) > 0) { if (copied % (64L * 1024 * 1024) == 0 && new DriveInfo(Path.GetPathRoot(Root)!).AvailableFreeSpace < 512L * 1024 * 1024 + buffer.Length) throw new IOException("Storage reserve reached."); hash.AppendData(buffer, 0, count); await output.WriteAsync(buffer.AsMemory(0, count), token); copied += count; }
                    await output.FlushAsync(token); output.Flush(true);
                }
                info.Refresh();
                if (info.Length != initialLength || info.LastWriteTimeUtc != initialTime) return new("failed", Error: "コピー中に元のファイルが変更されました。再試行してください。");
                var sha = Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant();
                var existing = Scalar(db, "SELECT id FROM assets WHERE sha256=$hash", ("hash", sha)) as string;
                if (existing is not null)
                {
                    var original = ReadAssets(db, "SELECT * FROM assets WHERE id=$id", ("id", existing)).Single();
                    try
                    {
                        if (HashFile(ReadOriginalPath(original)) != original.Sha256) throw new InvalidDataException();
                    }
                    catch (Exception ex) when (ex is InvalidDataException or IOException or UnauthorizedAccessException)
                    {
                        return new("failed", Error: "同じ素材の原本が欠損・変更されているか、読み取れません。新しいファイルは保持しています。バックアップから原本を復旧して再試行してください。");
                    }
                    Execute(db, "UPDATE assets SET internet=MAX(internet,$internet) WHERE id=$id", ("internet", internet), ("id", existing));
                    if (folderId is not null) Execute(db, "INSERT OR IGNORE INTO memberships VALUES($id,$folder)", ("id", existing), ("folder", folderId));
                    Execute(db, "DELETE FROM imports WHERE id=$id", ("id", id));
                    if (_recycle is not null) await _recycle(staging);
                    var trashed = Convert.ToBoolean(Scalar(db, "SELECT trashed FROM assets WHERE id=$id", ("id", existing)));
                    Changed?.Invoke(); return new(trashed ? "restoreAvailable" : "duplicate", existing);
                }
                var asset = new Asset(id, name, extension, AssetFormat.Kind(extension), sha, initialLength, created, false, false, internet, [], []);
                Execute(db, "UPDATE imports SET sha256=$sha,size=$size WHERE id=$id", ("sha", sha), ("size", initialLength), ("id", id));
                ImportCheckpoint?.Invoke("copied");
                File.Move(staging, OriginalPath(asset));
                SetOriginalProperties(OriginalPath(asset), asset);
                ImportCheckpoint?.Invoke("moved");
                CommitImport(db, asset, folderId); ImportCheckpoint?.Invoke("committed"); Changed?.Invoke(); return new("saved", id);
            }
            catch (OperationCanceledException) { return new("cancelled"); }
            catch (IOException) { return new("failed", Error: "ファイルを読み書きできません。接続・空き容量・使用中のアプリを確認してください。"); }
            catch (UnauthorizedAccessException) { return new("failed", Error: "ファイルへのアクセスが許可されていません。"); }
            finally { _writer.Release(); }
        }, token);
    }
    private static void CommitImport(SqliteConnection db, Asset asset, string? folder)
    {
        using var tx = db.BeginTransaction();
        Insert(db, asset);
        if (folder is not null && Scalar(db,"SELECT id FROM categories WHERE id=$id AND type='folder'",("id",folder)) is not null) Execute(db, "INSERT OR IGNORE INTO memberships VALUES($id,$folder)", ("id", asset.Id), ("folder", folder));
        Execute(db, "DELETE FROM imports WHERE id=$id", ("id", asset.Id)); tx.Commit();
    }
    private static void Insert(SqliteConnection db, Asset a) => Execute(db,
        "INSERT OR IGNORE INTO assets VALUES($id,$name,$normalized,$ext,$kind,$hash,$size,$created,$favorite,$trash,$internet)",
        ("id", a.Id), ("name", a.Name), ("normalized", AssetFormat.Normalize(a.Name)), ("ext", a.Extension), ("kind", a.Kind),
        ("hash", a.Sha256), ("size", a.SizeBytes), ("created", a.CreatedAt), ("favorite", a.Favorite), ("trash", a.Trashed), ("internet", a.InternetOrigin));
    public Task<int> EmptyTrashAsync(Func<string, Task<bool>> recycle) => Task.Run(async () =>
    {
        await Ready; Writable(); await _writer.WaitAsync();
        try
        {
            using var db = Open(); var removed = 0;
            if (Scalar(db, "SELECT name FROM sqlite_master WHERE type='table' AND name='sync_meta'") is not null
                && SyncMeta(db, "groupId") is not null)
            {
                // Keep originals recoverable for the other device before removing the last local copy.
                if (SyncMeta(db, "enabled") != "1") throw new InvalidOperationException("同期を再開し、送信が完了してからゴミ箱を空にしてください。");
                var transport = RequireSyncRoot(db); CaptureSyncChanges(db);
                await ExportSyncEventsAsync(db, transport, CancellationToken.None);
                if (Convert.ToInt32(Scalar(db, "SELECT count(*) FROM sync_events WHERE exported=0")) > 0)
                    throw new InvalidOperationException("未送信の変更があります。同期が完了してからゴミ箱を空にしてください。");
            }
            foreach (var asset in ReadAssets(db, "SELECT * FROM assets WHERE trashed=1"))
            {
                var path = OriginalPath(asset); if (!File.Exists(path)) continue;
                Execute(db, "INSERT OR REPLACE INTO purges VALUES($id,$started,0)", ("id", asset.Id), ("started", DateTimeOffset.UtcNow.ToString("O")));
                if (!await recycle(path)) { Execute(db, "DELETE FROM purges WHERE id=$id", ("id", asset.Id)); continue; }
                Execute(db, "UPDATE purges SET recycled=1 WHERE id=$id", ("id", asset.Id));
                Execute(db, "DELETE FROM assets WHERE id=$id", ("id", asset.Id)); removed++;
            }
            Changed?.Invoke(); return removed;
        }
        finally { _writer.Release(); }
    });
    private async Task<T> WriteAsync<T>(Func<SqliteConnection, T> action)
    {
        await Ready; Writable(); await _writer.WaitAsync();
        try { return await Task.Run(() => { using var db = Open(); var value = action(db); Changed?.Invoke(); return value; }); }
        finally { _writer.Release(); }
    }
    public async Task<string> CopyOutAsync(string id, string? destination = null)
    {
        await Ready; await _writer.WaitAsync();
        try
        {
            var asset = await GetAsync(id) ?? throw new FileNotFoundException("素材が見つかりません。");
            var outputName = asset.Extension.Length > 0 ? Path.GetFileNameWithoutExtension(asset.Name) + "." + asset.Extension : asset.Name;
            destination ??= Path.Combine(Root, "outbox", Guid.NewGuid().ToString("D"), SafeName(outputName));
            Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
            await Task.Run(() => File.Copy(ReadOriginalPath(asset), destination, false));
            File.SetAttributes(destination, File.GetAttributes(destination) & ~FileAttributes.ReadOnly);
            await Task.Run(() => ApplyOrigin(destination, asset.InternetOrigin));
            return destination;
        }
        finally { _writer.Release(); }
    }
    private static string SafeName(string name)
    {
        var invalid = Path.GetInvalidFileNameChars(); var result = new string(name.Select(c => invalid.Contains(c) ? '_' : c).ToArray()).TrimEnd('.', ' ');
        if (string.IsNullOrWhiteSpace(result)) result = "asset";
        if (result.Length > 240) { var extension=Path.GetExtension(result); if(extension.Length>32)extension=""; var length=240-extension.Length; if(char.IsHighSurrogate(result[length-1]))length--; result=result[..length]+extension; }
        // Prefix avoids Windows reserved device names while preserving a useful display name.
        return "asset-" + result;
    }
    public async Task<Asset[]> OrphansAsync()
    {
        await Ready; return await Task.Run(() =>
        {
            using var db = Open(); var list = new List<Asset>();
            foreach (var path in Directory.EnumerateFiles(Path.Combine(Root, "originals")))
            {
                var id = Path.GetFileNameWithoutExtension(path); if (!Guid.TryParse(id, out _) || Scalar(db, "SELECT id FROM assets WHERE id=$id", ("id", id)) is not null) continue;
                var info = new FileInfo(path); var ext = info.Extension.TrimStart('.');
                list.Add(new(id, info.Name, ext, AssetFormat.Kind(ext), HashFile(path), info.Length, new DateTimeOffset(info.LastWriteTimeUtc).ToString("O"), false, false, HasInternetOrigin(path), [], []));
            }
            return list.ToArray();
        });
    }
    public Task<bool> RecoverOrphanAsync(Asset asset) => WriteAsync(db => { AssetFormat.Validate(asset); if (HashFile(ReadOriginalPath(asset)) != asset.Sha256) throw new InvalidDataException(); if (Scalar(db,"SELECT id FROM assets WHERE sha256=$hash",("hash",asset.Sha256)) is not null) return false; Insert(db, asset); return true; });
    private static async Task CopyFileAsync(string source, string target, CancellationToken token)
    { await using var input = new FileStream(source, FileMode.Open, FileAccess.Read, FileShare.Read, 131072, true); await using var output = new FileStream(target, FileMode.CreateNew, FileAccess.Write, FileShare.None, 131072, true); await input.CopyToAsync(output, token); await output.FlushAsync(token); output.Flush(true); }
    private static string HashFile(string path) { using var file = File.OpenRead(path); return Convert.ToHexString(SHA256.HashData(file)).ToLowerInvariant(); }
    private static bool HasInternetOrigin(string path)
    {
        if (!OperatingSystem.IsWindows()) return false;
        try { return File.ReadAllLines(path + ":Zone.Identifier").Any(line => line.Trim() is "ZoneId=3" or "ZoneId=4"); }
        catch (FileNotFoundException) { return false; } catch (DirectoryNotFoundException) { return false; }
        catch (IOException) { return true; } catch (UnauthorizedAccessException) { return true; }
    }
    private static void ApplyOrigin(string path, bool internet)
    {
        if (!internet || !OperatingSystem.IsWindows() || HasInternetOrigin(path)) return;
        var attributes=File.GetAttributes(path);
        if ((attributes & FileAttributes.ReadOnly)!=0) File.SetAttributes(path,attributes & ~FileAttributes.ReadOnly);
        try { File.WriteAllText(path + ":Zone.Identifier", "[ZoneTransfer]\r\nZoneId=3\r\n"); }
        finally { if ((attributes & FileAttributes.ReadOnly)!=0) File.SetAttributes(path,attributes); }
    }
    private static void SetOriginalProperties(string path, Asset asset)
    {
        var attributes=File.GetAttributes(path); File.SetAttributes(path,attributes & ~FileAttributes.ReadOnly);
        try { ApplyOrigin(path,asset.InternetOrigin); File.SetLastWriteTimeUtc(path,DateTimeOffset.Parse(asset.CreatedAt).UtcDateTime); }
        finally { File.SetAttributes(path,attributes|FileAttributes.ReadOnly); }
    }
    private static SqliteCommand Command(SqliteConnection db, string sql, params (string Key, object? Value)[] args)
    { var command = db.CreateCommand(); command.CommandText = sql; foreach (var arg in args) command.Parameters.AddWithValue("$" + arg.Key, arg.Value ?? DBNull.Value); return command; }
    private static void Execute(SqliteConnection db, string sql, params (string, object?)[] args) { using var command = Command(db, sql, args); command.ExecuteNonQuery(); }
    private static object? Scalar(SqliteConnection db, string sql, params (string, object?)[] args) { using var command = Command(db, sql, args); return command.ExecuteScalar(); }
    public void Dispose() { _hostLock?.Dispose(); _readers.Dispose(); _writer.Dispose(); }
}
