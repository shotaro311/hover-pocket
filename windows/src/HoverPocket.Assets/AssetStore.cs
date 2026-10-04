using System.Security.Cryptography;
using System.Text.Json;
using Microsoft.Data.Sqlite;

namespace HoverPocket.Assets;

// The gate serializes writers and pins originals throughout snapshot export. Readers use separate connections.
public sealed class AssetStore : IDisposable
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
    public Task<AssetPage> QueryAsync(AssetQuery query, CancellationToken token = default) => QueryCoreAsync(query, null, token);
    public async Task<bool> MatchesAsync(AssetQuery query, string id) => (await QueryCoreAsync(query with { Offset = 0, Limit = 1 }, id, CancellationToken.None)).Total > 0;
    private async Task<AssetPage> QueryCoreAsync(AssetQuery query, string? selectedId, CancellationToken token)
    {
        AssetFormat.ValidateQuery(query);
        await Ready;
        if (RecoveryWarning is not null) return new([], 0, [], [], []);
        await _readers.WaitAsync(token);
        try { return await Task.Run(() =>
        {
            token.ThrowIfCancellationRequested(); using var db = Open();
            var where = new List<string> { "a.trashed=$trash" }; var args = new List<(string, object?)> { ("trash", query.View == "trash") };
            if (selectedId is not null) { where.Add("a.id=$selected"); args.Add(("selected", selectedId)); }
            if (query.View == "favorites") where.Add("a.favorite=1");
            if (query.View == "uncategorized") where.Add("a.id NOT IN(SELECT m.asset FROM memberships m JOIN categories c ON c.id=m.category WHERE c.type='folder')");
            if (!string.IsNullOrEmpty(query.Kind)) { where.Add("a.kind=$kind"); args.Add(("kind", query.Kind)); }
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
            var total = Convert.ToInt64(Scalar(db, $"SELECT count(*) FROM assets a WHERE {clause}", args.ToArray()));
            args.Add(("limit", Math.Clamp(query.Limit, 1, 200))); args.Add(("offset", Math.Max(0, query.Offset)));
            var assets = ReadAssets(db, $"SELECT a.* FROM assets a WHERE {clause} ORDER BY a.created DESC,a.id LIMIT $limit OFFSET $offset", args.ToArray());
            return new AssetPage(assets, total, Categories(db, "folder"), Categories(db, "tag"), Searches(db));
        }, token); } finally { _readers.Release(); }
    }
    public async Task<Asset?> GetAsync(string id)
    {
        await Ready; if (RecoveryWarning is not null) return null; await _readers.WaitAsync();
        try { return await Task.Run(() => { using var db = Open(); return ReadAssets(db, "SELECT * FROM assets WHERE id=$id", ("id", id)).FirstOrDefault(); }); } finally { _readers.Release(); }
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
    public Task<int> EmptyTrashAsync(Func<string, Task<bool>> recycle) => Task.Run(async () =>
    {
        await Ready; Writable(); await _writer.WaitAsync();
        try
        {
            using var db = Open(); var removed = 0;
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
            using var db = Open();
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
