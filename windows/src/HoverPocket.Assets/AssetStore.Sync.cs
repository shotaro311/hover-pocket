using System.Text.Json;
using Microsoft.Data.Sqlite;

namespace HoverPocket.Assets;

public sealed partial class AssetStore
{
    private string? _syncError;
    private static void SyncSchema(SqliteConnection db)
    {
        using var resource = typeof(AssetStore).Assembly.GetManifestResourceStream("AssetLibrary.002-sync.sql")!;
        using var reader = new StreamReader(resource); Execute(db, reader.ReadToEnd());
    }
    private static string? SyncMeta(SqliteConnection db, string key) => Scalar(db, "SELECT value FROM sync_meta WHERE key=$key", ("key", key)) as string;
    private static void SetSyncMeta(SqliteConnection db, string key, string value) =>
        Execute(db, "INSERT INTO sync_meta(key,value) VALUES($key,$value) ON CONFLICT(key) DO UPDATE SET value=excluded.value", ("key", key), ("value", value));
    private async Task<T> SyncLocked<T>(Func<SqliteConnection, Task<T>> action, CancellationToken token = default)
    {
        await Ready; Writable(); await _writer.WaitAsync(token);
        try { return await Task.Run(async () => { using var db = Open(); SyncSchema(db); return await action(db); }, token); }
        finally { _writer.Release(); }
    }
    public Task<AssetSyncStatus> ConfigureSyncAsync(string transportPath, bool createGroup = false, CancellationToken token = default) => SyncLocked(db =>
    {
        var path = Path.GetFullPath(transportPath); AssetSyncFormat.SafePath(path);
        var comparison = OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
        if (path.Equals(Root, comparison) || path.StartsWith(Root + Path.DirectorySeparatorChar, comparison)
            || Root.StartsWith(path.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar, comparison))
            throw new InvalidDataException("ライブラリ保存先と同期転送先は分けてください。");
        if (createGroup && !File.Exists(Path.Combine(path, "hoverpocket-sync.json")))
        {
            Directory.CreateDirectory(path);
            if (Directory.EnumerateFileSystemEntries(path).Any(p => Path.GetFileName(p) is not (".stfolder" or ".stignore")))
                throw new InvalidDataException("新しい同期グループには空の専用フォルダを選んでください。");
            var bytes = JsonSerializer.SerializeToUtf8Bytes(new { version = 1, groupId = Guid.NewGuid().ToString("D") });
            AtomicSyncWrite(Path.Combine(path, "hoverpocket-sync.json"), bytes);
        }
        var group = AssetSyncFormat.Marker(path);
        if (SyncMeta(db, "groupId") is { } existing && existing != group)
            throw new InvalidDataException("登録済みと異なる同期グループです。接続先を確認してください。");
        // A safety latch survives DB corruption; it contains no settings or library data.
        var latch = Path.Combine(Root, "sync-configured"); AssetSyncFormat.SafePath(latch);
        if (!File.Exists(latch)) AtomicSyncWrite(latch, [1]);
        using var tx = db.BeginTransaction();
        SetSyncMeta(db, "groupId", group); SetSyncMeta(db, "transportPath", path);
        if (SyncMeta(db, "deviceId") is null) SetSyncMeta(db, "deviceId", Guid.NewGuid().ToString("D"));
        tx.Commit(); _syncError = null;
        return Task.FromResult(SyncStatus(db));
    }, token);
    public Task<bool> SetSyncEnabledAsync(bool enabled, CancellationToken token = default) => SyncLocked(db =>
    {
        if (enabled) RequireSyncRoot(db);
        SetSyncMeta(db, "enabled", enabled ? "1" : "0");
        return Task.FromResult(true);
    }, token);
    public Task<AssetSyncStatus> GetSyncStatusAsync(CancellationToken token = default) => SyncLocked(db => Task.FromResult(SyncStatus(db)), token);
    private AssetSyncStatus SyncStatus(SqliteConnection db)
    {
        var pendingConflicts = SyncEvents(db, "disposition='conflict'");
        var current = pendingConflicts.Length == 0 ? new Dictionary<string, AssetSyncValue>() : CurrentSyncValues(db);
        var conflicts = pendingConflicts.Select(e => new AssetSyncConflict(e.Revision, e.EntityType, e.EntityId,
            e.Asset?.Name ?? e.Category!.Name, current.GetValueOrDefault(e.Key)?.Asset?.Name ?? current.GetValueOrDefault(e.Key)?.Category?.Name)).ToArray();
        return new(SyncMeta(db, "groupId") is not null, SyncMeta(db, "transportPath"), SyncMeta(db, "groupId"), SyncMeta(db, "deviceId"),
            Convert.ToInt32(Scalar(db, "SELECT count(*) FROM sync_events WHERE disposition='pending'")),
            Convert.ToInt32(Scalar(db, "SELECT count(*) FROM sync_events WHERE exported=0")), conflicts, _syncError, SyncMeta(db, "enabled") == "1");
    }
    private static string RequireSyncRoot(SqliteConnection db)
    {
        var root = SyncMeta(db, "transportPath") ?? throw new InvalidOperationException("同期フォルダを設定してください。");
        if (AssetSyncFormat.Marker(root) != SyncMeta(db, "groupId")) throw new InvalidDataException("同期グループが変更されたため停止しました。接続先を確認してください。");
        foreach (var dir in new[] { "blobs", "events" }) AssetSyncFormat.SafePath(Path.Combine(root, dir));
        return root;
    }
    private static Dictionary<string, AssetSyncHead> SyncHeads(SqliteConnection db)
    {
        using var cmd = Command(db, "SELECT entity_key,revision,snapshot FROM sync_heads"); using var reader = cmd.ExecuteReader();
        var heads = new Dictionary<string, AssetSyncHead>(StringComparer.Ordinal);
        while (reader.Read()) heads.Add(reader.GetString(0), new(reader.GetString(1), JsonSerializer.Deserialize<AssetSyncValue>(reader.GetString(2), AssetSyncFormat.Json)!));
        return heads;
    }
    private static AssetSyncEvent[] SyncEvents(SqliteConnection db, string predicate)
    {
        using var cmd = Command(db, "SELECT body FROM sync_events WHERE " + predicate); using var reader = cmd.ExecuteReader();
        var events = new List<AssetSyncEvent>();
        while (reader.Read()) events.Add(JsonSerializer.Deserialize<AssetSyncEvent>(reader.GetString(0), AssetSyncFormat.Json)!);
        return events.ToArray();
    }
    private static Dictionary<string, AssetSyncValue> CurrentSyncValues(SqliteConnection db)
    {
        var values = ReadAssets(db, "SELECT * FROM assets").ToDictionary(a => "asset:" + a.Sha256, a => new AssetSyncValue(false, a, null), StringComparer.Ordinal);
        foreach (var type in new[] { "folder", "tag" })
            foreach (var c in Categories(db, type)) values.Add(type + ":" + c.Id, new(false, null, c));
        return values;
    }
    private static AssetSyncValue? CurrentSyncValue(SqliteConnection db, string key) => CurrentSyncValues(db).GetValueOrDefault(key);
    private static void SyncHead(SqliteConnection db, AssetSyncEvent e, AssetSyncValue actual) =>
        Execute(db, "INSERT INTO sync_heads(entity_key,revision,snapshot) VALUES($key,$revision,$snapshot) ON CONFLICT(entity_key) DO UPDATE SET revision=excluded.revision,snapshot=excluded.snapshot",
            ("key", e.Key), ("revision", e.Revision), ("snapshot", AssetSyncFormat.Snapshot(actual)));
    private static void AddSyncEvent(SqliteConnection db, AssetSyncEvent e, string disposition, bool exported) =>
        Execute(db, "INSERT INTO sync_events(revision,entity_key,body,disposition,exported) VALUES($revision,$key,$body,$state,$exported)",
            ("revision", e.Revision), ("key", e.Key), ("body", JsonSerializer.Serialize(e, AssetSyncFormat.Json)), ("state", disposition), ("exported", exported));
    private static void SyncDisposition(SqliteConnection db, string revision, string value) =>
        Execute(db, "UPDATE sync_events SET disposition=$state WHERE revision=$id", ("state", value), ("id", revision));
    private static AssetSyncEvent NewSyncEvent(SqliteConnection db, string key, AssetSyncValue value, string[] parents)
    {
        var split = key.IndexOf(':');
        var e = new AssetSyncEvent(1, SyncMeta(db, "groupId")!, Guid.NewGuid().ToString("D"), SyncMeta(db, "deviceId")!,
            key[..split], key[(split + 1)..], parents.Distinct().Order().ToArray(), value.Deleted, value.Asset, value.Category);
        return AssetSyncFormat.Parse(JsonSerializer.SerializeToUtf8Bytes(e, AssetSyncFormat.Json));
    }
    private static void CaptureSyncChanges(SqliteConnection db)
    {
        var current = CurrentSyncValues(db); var heads = SyncHeads(db);
        using var tx = db.BeginTransaction();
        foreach (var key in current.Keys.Union(heads.Keys).Order(StringComparer.Ordinal))
        {
            var head = heads.GetValueOrDefault(key);
            var value = current.GetValueOrDefault(key) ?? head!.Value with { Deleted = true };
            if (head is not null && AssetSyncFormat.Equal(head.Value, value)) continue;
            var e = NewSyncEvent(db, key, value, head is null ? [] : [head.Revision]);
            AddSyncEvent(db, e, "applied", false); SyncHead(db, e, value);
        }
        tx.Commit();
    }
    public Task<AssetSyncStatus> SyncOnceAsync(CancellationToken token = default, bool onlyWhenEnabled = false) => SyncLocked(async db =>
    {
        if (onlyWhenEnabled && SyncMeta(db, "enabled") != "1") return SyncStatus(db);
        var changed = false;
        try
        {
            var root = RequireSyncRoot(db); _syncError = null;
            CaptureSyncChanges(db);
            await ExportSyncEventsAsync(db, root, token);
            ReadSyncEvents(db, root, token);
            // A later event can arrive before its parents, original, or categories.
            for (var pass = 0; pass < 256; pass++)
            {
                var advanced = false;
                foreach (var e in SyncEvents(db, "disposition='pending'").OrderBy(e => e.EntityType == "asset" ? 1 : 0))
                {
                    token.ThrowIfCancellationRequested();
                    var result = await ApplySyncEventAsync(db, root, e, false, token);
                    if (result != "pending") { advanced = true; changed |= result == "applied"; }
                }
                if (!advanced) break;
            }
            return SyncStatus(db);
        }
        catch (Exception ex) when (ex is InvalidDataException or IOException or UnauthorizedAccessException or JsonException or SqliteException or InvalidOperationException or ArgumentException)
        {
            _syncError = ex is JsonException ? "同期ファイルを読み取れません。内容を確認してください。" : ex is SqliteException ? "同期データを保存できません。再試行してください。" : ex.Message;
            return SyncStatus(db);
        }
        finally { if (changed) Changed?.Invoke(); }
    }, token);
    private static void AtomicSyncWrite(string path, byte[] bytes)
    {
        AssetSyncFormat.SafePath(path); Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temporary = path + ".partial-" + Guid.NewGuid().ToString("N");
        using (var file = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None)) { file.Write(bytes); file.Flush(true); }
        AssetSyncFormat.SafePath(path);
        File.Move(temporary, path, false);
    }
    private async Task ExportSyncEventsAsync(SqliteConnection db, string root, CancellationToken token)
    {
        foreach (var e in SyncEvents(db, "exported=0"))
        {
            token.ThrowIfCancellationRequested(); RequireSyncRoot(db);
            if (e.Asset is { } a && !e.Deleted)
            {
                var blob = Path.Combine(root, "blobs", a.Sha256); AssetSyncFormat.SafePath(blob);
                if (File.Exists(blob))
                {
                    if (new FileInfo(blob).Length != a.SizeBytes || HashFile(blob) != a.Sha256) throw new InvalidDataException("転送先の原本が変更されています。同期を停止しました。");
                }
                else
                {
                    var local = ReadAssets(db, "SELECT * FROM assets WHERE sha256=$hash", ("hash", a.Sha256)).SingleOrDefault();
                    if (local is null) { _syncError = "未送信の原本が見つかりません。同期完了までゴミ箱を空にしないでください。"; continue; }
                    var original = ReadOriginalPath(local); AssetSyncFormat.SafePath(original);
                    Directory.CreateDirectory(Path.GetDirectoryName(blob)!);
                    var staged = blob + ".partial-" + Guid.NewGuid().ToString("N");
                    await CopyFileAsync(original, staged, token);
                    if (new FileInfo(staged).Length != a.SizeBytes || HashFile(staged) != a.Sha256) throw new InvalidDataException("原本のハッシュが一致しません。");
                    AssetSyncFormat.SafePath(blob);
                    try { File.Move(staged, blob, false); }
                    catch (IOException) when (File.Exists(blob))
                    { if (new FileInfo(blob).Length != a.SizeBytes || HashFile(blob) != a.Sha256) throw new InvalidDataException("転送先の原本が変更されています。"); }
                }
            }
            var file = Path.Combine(root, "events", e.DeviceId, e.Revision + ".json"); AssetSyncFormat.SafePath(file);
            if (File.Exists(file))
            {
                if (!AssetSyncFormat.SameEvent(ReadSyncFile(file), e)) throw new InvalidDataException("同じ同期IDの内容が変わっています。");
            }
            else AtomicSyncWrite(file, JsonSerializer.SerializeToUtf8Bytes(e, AssetSyncFormat.Json));
            Execute(db, "UPDATE sync_events SET exported=1 WHERE revision=$id", ("id", e.Revision));
        }
    }
    private static AssetSyncEvent ReadSyncFile(string path)
    {
        AssetSyncFormat.SafePath(path);
        if (new FileInfo(path).Length > AssetSyncFormat.MaxEventBytes) throw new InvalidDataException("同期イベントが大きすぎます。");
        return AssetSyncFormat.Parse(File.ReadAllBytes(path));
    }
    private static void ReadSyncEvents(SqliteConnection db, string root, CancellationToken token)
    {
        var dir = Path.Combine(root, "events"); if (!Directory.Exists(dir)) return;
        foreach (var device in Directory.EnumerateDirectories(dir))
        {
            AssetSyncFormat.SafePath(device);
            if (!AssetSyncFormat.IsId(Path.GetFileName(device))) continue;
            foreach (var path in Directory.EnumerateFiles(device, "*.json"))
            {
                token.ThrowIfCancellationRequested(); AssetSyncFormat.SafePath(path);
                var revision = Path.GetFileNameWithoutExtension(path); if (!AssetSyncFormat.IsId(revision)) continue;
                var e = ReadSyncFile(path);
                if (e.Revision != revision || e.DeviceId != Path.GetFileName(device) || e.GroupId != SyncMeta(db, "groupId"))
                    throw new InvalidDataException("別グループまたは不正な場所の同期イベントです。");
                if (Scalar(db, "SELECT body FROM sync_events WHERE revision=$id", ("id", revision)) is string existing)
                {
                    if (!AssetSyncFormat.SameEvent(JsonSerializer.Deserialize<AssetSyncEvent>(existing, AssetSyncFormat.Json)!, e))
                        throw new InvalidDataException("同じ同期IDの内容が変わっています。");
                    continue;
                }
                AddSyncEvent(db, e, "pending", true);
            }
        }
    }
    private static bool Ancestor(string older, string newer, IReadOnlyDictionary<string, AssetSyncEvent> events)
    {
        var pending = new Stack<string>(); var seen = new HashSet<string>(); pending.Push(newer);
        while (pending.TryPop(out var next))
        {
            if (next == older) return true;
            if (!seen.Add(next) || !events.TryGetValue(next, out var e)) continue;
            foreach (var parent in e.Parents) pending.Push(parent);
        }
        return false;
    }
    private async Task<string> ApplySyncEventAsync(SqliteConnection db, string root, AssetSyncEvent e, bool resolve, CancellationToken token)
    {
        var all = SyncEvents(db, "1=1").ToDictionary(value => value.Revision);
        if (resolve) all.Add(e.Revision, e);
        foreach (var p in e.Parents)
        {
            if (!all.TryGetValue(p, out var parent)) return "pending";
            if (parent.Key != e.Key || Ancestor(e.Revision, p, all)) throw new InvalidDataException("同期の親イベントが不正です。");
            if (Equals(Scalar(db, "SELECT disposition FROM sync_events WHERE revision=$id", ("id", p)), "pending")) return "pending";
        }
        var head = SyncHeads(db).GetValueOrDefault(e.Key);
        if (!resolve && head is not null)
        {
            if (Ancestor(e.Revision, head.Revision, all)) { SyncDisposition(db, e.Revision, "ignored"); return "ignored"; }
            if (!Ancestor(head.Revision, e.Revision, all)) { return MarkSyncConflict(db, e, all); }
        }
        try
        {
            // Validate references and bytes before any DB write. A staged original is reusable after a crash.
            if (e.Asset is { } asset && !e.Deleted)
            {
                foreach (var (type, ids) in new[] { ("folder", asset.FolderIds), ("tag", asset.TagIds) })
                    foreach (var id in ids)
                        if (Scalar(db, "SELECT id FROM categories WHERE id=$id AND type=$type", ("id", id), ("type", type)) is null
                            && !SyncCategoryDeleted(db, type, id)) return "pending";
                var local = ReadAssets(db, "SELECT * FROM assets WHERE sha256=$hash", ("hash", asset.Sha256)).SingleOrDefault();
                if (local is null)
                {
                    if (Scalar(db, "SELECT id FROM assets WHERE id=$id", ("id", asset.Id)) is not null) throw new SyncConflictException();
                    var blob = Path.Combine(root, "blobs", asset.Sha256); AssetSyncFormat.SafePath(blob);
                    if (!File.Exists(blob)) return "pending";
                    if (new FileInfo(blob).Length != asset.SizeBytes || HashFile(blob) != asset.Sha256) throw new InvalidDataException("受信した原本が破損または変更されています。");
                    var target = OriginalPath(asset); AssetSyncFormat.SafePath(target);
                    if (!File.Exists(target))
                    {
                        if (asset.SizeBytes + 512L * 1024 * 1024 > new DriveInfo(Path.GetPathRoot(Root)!).AvailableFreeSpace) throw new IOException("同期原本を保存する空き容量が不足しています。");
                        var stage = Path.Combine(Root, "staging", asset.Id + ".sync-" + Guid.NewGuid().ToString("N"));
                        await CopyFileAsync(blob, stage, token);
                        if (new FileInfo(stage).Length != asset.SizeBytes || HashFile(stage) != asset.Sha256) throw new InvalidDataException("受信した原本のハッシュが一致しません。");
                        File.Move(stage, target, false);
                    }
                    if (new FileInfo(target).Length != asset.SizeBytes || HashFile(target) != asset.Sha256) throw new InvalidDataException("保存先の原本を上書きできません。");
                    SetOriginalProperties(target, asset);
                }
                else
                {
                    var original = ReadOriginalPath(local);
                    if (local.SizeBytes != asset.SizeBytes || HashFile(original) != local.Sha256) throw new InvalidDataException("この端末の原本が変更されています。");
                    if (asset.InternetOrigin && !local.InternetOrigin) SetOriginalProperties(original, local with { InternetOrigin = true });
                }
            }
            if (e.Category is { } anyCategory
                && Scalar(db, "SELECT type FROM categories WHERE id=$id", ("id", anyCategory.Id)) is string actualType && actualType != e.EntityType)
                throw new SyncConflictException();
            if (e.Category is { } c && !e.Deleted)
            {
                if (c.ParentId is not null && Scalar(db, "SELECT id FROM categories WHERE id=$id AND type='folder'", ("id", c.ParentId)) is null)
                {
                    if (!SyncCategoryDeleted(db, "folder", c.ParentId)) return "pending";
                    c = c with { ParentId = null }; e = e with { Category = c };
                }
                if (Scalar(db, "SELECT id FROM categories WHERE type=$type AND COALESCE(parent,'')=$parent AND normalized=$name AND id<>$id",
                    ("type", e.EntityType), ("parent", c.ParentId ?? ""), ("name", AssetFormat.Normalize(c.Name)), ("id", c.Id)) is not null) throw new SyncConflictException();
                var parent = c.ParentId; var seen = new HashSet<string> { c.Id };
                while (parent is not null)
                {
                    if (!seen.Add(parent)) throw new SyncConflictException();
                    parent = Scalar(db, "SELECT parent FROM categories WHERE id=$id", ("id", parent)) as string;
                }
                if (Scalar(db, "SELECT type FROM categories WHERE id=$id", ("id", c.Id)) is string existingType && existingType != e.EntityType) throw new SyncConflictException();
            }
            using var tx = db.BeginTransaction();
            if (resolve) AddSyncEvent(db, all[e.Revision], "pending", false);
            ApplySyncValue(db, e);
            var actual = CurrentSyncValue(db, e.Key) ?? new AssetSyncValue(true, e.Asset, e.Category);
            SyncHead(db, e, actual); SyncDisposition(db, e.Revision, "applied");
            foreach (var conflict in SyncEvents(db, "disposition='conflict'").Where(value => value.Key == e.Key))
                if (Ancestor(conflict.Revision, e.Revision, all)) SyncDisposition(db, conflict.Revision, "ignored");
            if (e.Category is not null && e.Deleted) RefreshSyncSnapshots(db);
            tx.Commit(); return "applied";
        }
        catch (SqliteException ex) when (ex.SqliteErrorCode == 19)
        { return resolve ? "conflict" : MarkSyncConflict(db, e, all); }
        catch (SyncConflictException) { return resolve ? "conflict" : MarkSyncConflict(db, e, all); }
    }
    private static string MarkSyncConflict(SqliteConnection db, AssetSyncEvent e, IReadOnlyDictionary<string, AssetSyncEvent> all)
    {
        var conflicts = SyncEvents(db, "disposition='conflict'").Where(value => value.Key == e.Key && value.Revision != e.Revision).ToArray();
        if (conflicts.Any(value => Ancestor(e.Revision, value.Revision, all)))
        { SyncDisposition(db, e.Revision, "ignored"); return "ignored"; }
        foreach (var older in conflicts.Where(value => Ancestor(value.Revision, e.Revision, all)))
            SyncDisposition(db, older.Revision, "ignored");
        SyncDisposition(db, e.Revision, "conflict"); return "conflict";
    }
    private sealed class SyncConflictException : Exception;
    private static void ApplySyncValue(SqliteConnection db, AssetSyncEvent e)
    {
        if (e.Asset is { } asset)
        {
            var local = ReadAssets(db, "SELECT * FROM assets WHERE sha256=$hash", ("hash", asset.Sha256)).SingleOrDefault();
            if (e.Deleted)
            {
                if (local is not null) Execute(db, "UPDATE assets SET trashed=1 WHERE id=$id", ("id", local.Id));
                return;
            }
            var applied = local is null ? asset : asset with { Id = local.Id, Extension = local.Extension, Kind = local.Kind, CreatedAt = local.CreatedAt, InternetOrigin = asset.InternetOrigin || local.InternetOrigin };
            if (local is null) Insert(db, applied);
            else Execute(db, "UPDATE assets SET name=$name,normalized=$normal,favorite=$favorite,trashed=$trash,internet=$internet WHERE id=$id",
                ("name", applied.Name), ("normal", AssetFormat.Normalize(applied.Name)), ("favorite", applied.Favorite), ("trash", applied.Trashed), ("internet", applied.InternetOrigin), ("id", local.Id));
            Execute(db, "DELETE FROM memberships WHERE asset=$id", ("id", applied.Id));
            foreach (var id in applied.FolderIds.Concat(applied.TagIds)) Execute(db, "INSERT INTO memberships SELECT $asset,id FROM categories WHERE id=$category", ("asset", applied.Id), ("category", id));
        }
        else
        {
            var c = e.Category!;
            if (e.Deleted)
            {
                Execute(db, "DELETE FROM memberships WHERE category=$id", ("id", c.Id));
                Execute(db, "UPDATE categories SET parent=NULL WHERE parent=$id", ("id", c.Id));
                Execute(db, "DELETE FROM categories WHERE id=$id", ("id", c.Id));
            }
            else Execute(db, "INSERT INTO categories(id,type,name,normalized,parent) VALUES($id,$type,$name,$normal,$parent) ON CONFLICT(id) DO UPDATE SET name=excluded.name,normalized=excluded.normalized,parent=excluded.parent",
                ("id", c.Id), ("type", e.EntityType), ("name", c.Name), ("normal", AssetFormat.Normalize(c.Name)), ("parent", c.ParentId));
        }
    }
    private static bool SyncCategoryDeleted(SqliteConnection db, string type, string id) =>
        SyncHeads(db).GetValueOrDefault(type + ":" + id)?.Value.Deleted == true;
    private static void RefreshSyncSnapshots(SqliteConnection db)
    {
        foreach (var (key, value) in CurrentSyncValues(db))
            Execute(db, "UPDATE sync_heads SET snapshot=$snapshot WHERE entity_key=$key", ("key", key), ("snapshot", AssetSyncFormat.Snapshot(value)));
    }
    public Task<AssetSyncStatus> ResolveSyncConflictAsync(string revision, bool useRemote, CancellationToken token = default) => SyncLocked(async db =>
    {
        var root = RequireSyncRoot(db); CaptureSyncChanges(db);
        var conflicts = SyncEvents(db, "disposition='conflict'");
        var selected = conflicts.SingleOrDefault(e => e.Revision == revision) ?? throw new InvalidOperationException("この競合はすでに解決されています。");
        var head = SyncHeads(db).GetValueOrDefault(selected.Key);
        var parents = conflicts.Where(e => e.Key == selected.Key).Select(e => e.Revision)
            .Concat(head is null ? [] : [head.Revision]).Distinct().ToArray();
        var local = CurrentSyncValue(db, selected.Key);
        var value = useRemote ? new AssetSyncValue(selected.Deleted, selected.Asset, selected.Category)
            : local ?? new(true, selected.Asset, selected.Category);
        if (value.Asset is { } chosen && local?.Asset is { InternetOrigin: true })
            value = value with { Asset = chosen with { InternetOrigin = true } };
        var resolution = NewSyncEvent(db, selected.Key, value, parents);
        if (await ApplySyncEventAsync(db, root, resolution, true, token) != "applied")
            throw new InvalidOperationException("分類の参照や同名の分類を確認し、編集してから再試行してください。");
        _syncError = null; Changed?.Invoke(); await ExportSyncEventsAsync(db, root, token); return SyncStatus(db);
    }, token);
    private void CopySyncStateForRestore(SqliteConnection current, string candidate)
    {
        bool hasSync;
        try { hasSync = Scalar(current, "SELECT name FROM sqlite_master WHERE type='table' AND name='sync_meta'") is not null; }
        catch (SqliteException)
        {
            if (File.Exists(Path.Combine(Root, "sync-configured")))
                throw new InvalidOperationException("同期履歴を読み取れないためDBの巻き戻しを停止しました。完全バックアップを別の空ライブラリへ復元してください。");
            hasSync = false;
        }
        if (hasSync && SyncMeta(current, "enabled") == "1")
            throw new InvalidOperationException("ライブラリの同期を一時停止してからDBを復元してください。");
        using var target = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = candidate, Pooling = false }.ToString());
        target.Open(); SyncSchema(target);
        using var tx = target.BeginTransaction();
        foreach (var table in new[] { "sync_meta", "sync_events", "sync_heads" })
        {
            Execute(target, "DELETE FROM " + table);
            if (!hasSync) continue;
            using var command = Command(current, "SELECT * FROM " + table); using var rows = command.ExecuteReader();
            while (rows.Read())
            {
                var args = Enumerable.Range(0, rows.FieldCount).Select(i => ("v" + i, (object?)rows.GetValue(i))).ToArray();
                Execute(target, "INSERT INTO " + table + " VALUES(" + string.Join(",", args.Select(a => "$" + a.Item1)) + ")", args);
            }
        }
        if (hasSync) SetSyncMeta(target, "enabled", "0");
        tx.Commit();
    }
    private static void RejectSyncRestore(SqliteConnection db)
    {
        if (Scalar(db, "SELECT name FROM sqlite_master WHERE type='table' AND name='sync_meta'") is not null
            && SyncMeta(db, "groupId") is not null)
            throw new InvalidOperationException("同期履歴の巻き戻りを防ぐため、このライブラリのDB置換は停止しました。完全バックアップを別の空ライブラリへ復元してください。");
    }
}
