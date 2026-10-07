using System.Text.Json;

namespace HoverPocket.Shell.Providers.Assets;

internal static class AssetPreviewFormats
{
    private static readonly Dictionary<string, string[]> Formats = Load();
    private static Dictionary<string, string[]> Load()
    {
        using var stream = typeof(AssetPreviewFormats).Assembly.GetManifestResourceStream("AssetLibrary.preview-formats.json")!;
        return JsonSerializer.Deserialize<Dictionary<string, string[]>>(stream)!;
    }
    internal static string Kind(string extension) => extension == "pdf" ? "pdf" :
        Formats.FirstOrDefault(group => group.Value.Contains(extension, StringComparer.OrdinalIgnoreCase)).Key ?? "other";
}
