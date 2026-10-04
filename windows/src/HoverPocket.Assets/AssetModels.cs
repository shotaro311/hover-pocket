using System.Text;
using System.Text.Json;

namespace HoverPocket.Assets;

public sealed record Asset(string Id, string Name, string Extension, string Kind, string Sha256,
    long SizeBytes, string CreatedAt, bool Favorite, bool Trashed, bool InternetOrigin,
    string[] FolderIds, string[] TagIds);
public sealed record Category(string Id, string Name, string? ParentId);
public sealed record SavedSearch(string Id, string Name, AssetQuery Filter);
public sealed record AssetQuery(string Text = "", string View = "recent", string? Kind = null,
    string? FolderId = null, string? TagId = null, int Offset = 0, int Limit = 80,
    string[]? FolderIds = null, string[]? TagIds = null, string? CreatedAfter = null, string? CreatedBefore = null, int Version = 1);
public sealed record AssetPage(Asset[] Items, long Total, Category[] Folders, Category[] Tags, SavedSearch[] Searches);
public sealed record ImportResult(string Status, string? AssetId = null, string? Error = null);
public sealed record ExportResult(long AssetCount, long ExcludedPending);
public sealed record AssetManifest(int Version, string CreatedAt, Asset[] Assets, Category[] Folders,
    Category[] Tags, SavedSearch[] Searches, long ExcludedPending = 0);

public static class AssetFormat
{
    public const int Version = 1;
    public static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web) { WriteIndented = true };
    private static readonly Lazy<Dictionary<string, string>> CaseFold = new(() =>
    {
        using var stream = typeof(AssetFormat).Assembly.GetManifestResourceStream("AssetLibrary.case-fold.json")!;
        return JsonSerializer.Deserialize<Dictionary<string, string>>(stream)!;
    });
    public static string Normalize(string value)
    {
        var normalized = value.Normalize(NormalizationForm.FormKC); var result = new StringBuilder(normalized.Length);
        foreach (var rune in normalized.EnumerateRunes()) { var text = rune.ToString(); result.Append(CaseFold.Value.GetValueOrDefault(text, text)); }
        return result.ToString();
    }
    public static string Kind(string extension) => extension.ToLowerInvariant() switch
    {
        "jpg" or "jpeg" or "png" or "gif" or "bmp" or "webp" or "tif" or "tiff" => "image",
        "mp4" or "mov" or "m4v" or "webm" or "avi" or "mkv" => "video",
        "pdf" => "pdf", _ => "other"
    };
    public static string RelativePath(Asset asset) => $"originals/{asset.Id}{(asset.Extension.Length > 0 ? "." + asset.Extension : "")}";
    public static void Validate(Asset asset)
    {
        if (!Guid.TryParseExact(asset.Id, "D", out _) || string.IsNullOrWhiteSpace(asset.Name) || asset.Extension.Length > 32
            || asset.Extension.Any(c => !(c is >= 'a' and <= 'z' or >= '0' and <= '9')) || asset.SizeBytes < 0
            || asset.Sha256.Length != 64 || asset.Sha256.Any(c => !(c is >= 'a' and <= 'f' or >= '0' and <= '9'))
            || !IsUtc(asset.CreatedAt) || asset.Kind != Kind(asset.Extension)
            || asset.FolderIds.Distinct().Count() != asset.FolderIds.Length || asset.TagIds.Distinct().Count() != asset.TagIds.Length)
            throw new InvalidDataException("Invalid asset manifest.");
    }
    public static bool IsUtc(string value) => (value.EndsWith('Z') || value.EndsWith("+00:00", StringComparison.Ordinal))
        && DateTimeOffset.TryParse(value, out var date) && date.Offset == TimeSpan.Zero;
    public static void ValidateQuery(AssetQuery query)
    {
        if (query.Version != 1 || query.Text is null || query.Offset < 0 || query.Limit is < 1 or > 200 || query.View is not ("recent" or "favorites" or "uncategorized" or "trash")
            || query.Kind is not (null or "" or "image" or "video" or "pdf" or "other")
            || query.CreatedAfter is not null && !IsUtc(query.CreatedAfter) || query.CreatedBefore is not null && !IsUtc(query.CreatedBefore))
            throw new InvalidDataException("Unsupported search filter.");
    }
}
