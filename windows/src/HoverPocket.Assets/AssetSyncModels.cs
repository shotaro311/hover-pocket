using System.Text.Json;
using System.Text.Json.Serialization;

namespace HoverPocket.Assets;

public sealed record AssetSyncEvent(int Version, string GroupId, string Revision, string DeviceId,
    string EntityType, string EntityId, string[] Parents, bool Deleted, Asset? Asset, Category? Category)
{
    [JsonIgnore] public string Key => EntityType + ":" + EntityId;
}
public sealed record AssetSyncConflict(string Revision, string EntityType, string EntityId, string Name, string? LocalName);
public sealed record AssetSyncStatus(bool Configured, string? TransportPath, string? GroupId, string? DeviceId,
    int Pending, int Outgoing, AssetSyncConflict[] Conflicts, string? Error = null, bool Enabled = false);
internal sealed record AssetSyncValue(bool Deleted, Asset? Asset, Category? Category);
internal sealed record AssetSyncHead(string Revision, AssetSyncValue Value);

public static class AssetSyncFormat
{
    public const int MaxEventBytes = 4 * 1024 * 1024;
    public static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web)
    {
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
        PropertyNameCaseInsensitive = false
    };
    public static bool IsId(string? value) => value is { Length: 36 } && Guid.TryParseExact(value, "D", out _) && value == value.ToLowerInvariant();
    public static bool IsHash(string? value) => value is { Length: 64 } && value.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f');
    public static AssetSyncEvent Parse(byte[] data)
    {
        if (data.Length > MaxEventBytes) throw new InvalidDataException("同期イベントが大きすぎます。");
        using var document = JsonDocument.Parse(data);
        RequireProperties(document.RootElement, ["version","groupId","revision","deviceId","entityType","entityId","parents","deleted","asset","category"]);
        var e = JsonSerializer.Deserialize<AssetSyncEvent>(data, Json) ?? throw new InvalidDataException("同期形式が不正です。");
        if (e.Version != 1 || !IsId(e.GroupId) || !IsId(e.Revision) || !IsId(e.DeviceId)
            || e.Parents is null || e.Parents.Length > 256 || e.Parents.Any(p => !IsId(p) || p == e.Revision)
            || e.Parents.Distinct().Count() != e.Parents.Length) throw new InvalidDataException("同期イベントの識別情報が不正です。");
        if (e.EntityType == "asset")
        {
            var a = e.Asset;
            if (a is null || e.Category is not null || a.Name is null || a.Extension is null || a.Sha256 is null
                || a.CreatedAt is null || a.FolderIds is null || a.TagIds is null || !IsId(a.Id)
                || !IsHash(e.EntityId) || a.Sha256 != e.EntityId
                || a.FolderIds.Concat(a.TagIds).Any(id => !IsId(id))) throw new InvalidDataException("素材の同期形式が不正です。");
            RequireProperties(document.RootElement.GetProperty("asset"), ["id","name","extension","kind","sha256","sizeBytes","createdAt","favorite","trashed","internetOrigin","folderIds","tagIds"]);
            AssetFormat.Validate(a);
        }
        else if (e.EntityType is "folder" or "tag")
        {
            var c = e.Category;
            if (e.Asset is not null || c is null || !IsId(e.EntityId) || c.Id != e.EntityId
                || string.IsNullOrWhiteSpace(c.Name) || c.ParentId is not null && !IsId(c.ParentId)
                || e.EntityType == "tag" && c.ParentId is not null) throw new InvalidDataException("分類の同期形式が不正です。");
            RequireProperties(document.RootElement.GetProperty("category"), ["id","name","parentId"]);
        }
        else throw new InvalidDataException("未対応の同期対象です。");
        return e;
    }
    private static void RequireProperties(JsonElement value, string[] names)
    {
        if (value.ValueKind != JsonValueKind.Object) throw new InvalidDataException("同期形式が不正です。");
        var actual = value.EnumerateObject().Select(p => p.Name).ToArray();
        if (actual.Length != names.Length || !actual.Order().SequenceEqual(names.Order())) throw new InvalidDataException("同期の必須項目が不正です。");
    }
    internal static AssetSyncValue Normalize(AssetSyncValue value) => value.Asset is { } a
        ? value with { Asset = a with { FolderIds = a.FolderIds.Order(StringComparer.Ordinal).ToArray(), TagIds = a.TagIds.Order(StringComparer.Ordinal).ToArray() } } : value;
    internal static string Snapshot(AssetSyncValue value) => JsonSerializer.Serialize(Normalize(value), Json);
    internal static bool Equal(AssetSyncValue a, AssetSyncValue b) => Snapshot(a) == Snapshot(b);
    internal static bool SameEvent(AssetSyncEvent a, AssetSyncEvent b) =>
        a.Version == b.Version && a.GroupId == b.GroupId && a.Revision == b.Revision && a.DeviceId == b.DeviceId
        && a.Key == b.Key && a.Parents.Order().SequenceEqual(b.Parents.Order())
        && Equal(new(a.Deleted, a.Asset, a.Category), new(b.Deleted, b.Asset, b.Category));

    internal static void SafePath(string path)
    {
        for (var p = Path.GetFullPath(path); !string.IsNullOrEmpty(p); p = Path.GetDirectoryName(p))
            if (Path.Exists(p) && (File.GetAttributes(p) & FileAttributes.ReparsePoint) != 0)
                throw new InvalidDataException("同期フォルダにリンクは使用できません。");
    }
    internal static string Marker(string root)
    {
        SafePath(root);
        var path = Path.Combine(root, "hoverpocket-sync.json"); SafePath(path);
        if (!File.Exists(path) || new FileInfo(path).Length > 1024) throw new InvalidDataException("同期グループの確認ファイルがありません。");
        using var doc = JsonDocument.Parse(File.ReadAllBytes(path));
        RequireProperties(doc.RootElement, ["version","groupId"]);
        var id = doc.RootElement.GetProperty("groupId").GetString();
        if (doc.RootElement.GetProperty("version").GetInt32() != 1 || !IsId(id)) throw new InvalidDataException("同期グループの形式が不正です。");
        return id!;
    }
}
