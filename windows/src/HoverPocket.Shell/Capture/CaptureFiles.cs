using System.Text.Json;
using System.Windows.Media.Imaging;
using HoverPocket.Assets;
using HoverPocket.Shell.Providers.Assets;

namespace HoverPocket.Shell.Capture;

internal sealed record CapturePending(string[] Files, string? FolderId);
internal sealed record CaptureRetryResult(int Saved, int Failed, string? Error);
internal sealed class CaptureFiles(AssetStore store)
{
    public string CreateStage()
    {
        var directory = Path.Combine(store.Root, "staging", "capture-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(directory);
        if (new DriveInfo(Path.GetPathRoot(directory)!).AvailableFreeSpace < 512L * 1024 * 1024) throw new IOException("保存先の空き容量が不足しています。");
        return directory;
    }
    public static async Task WritePngAsync(string path, BitmapSource bitmap)
    { await Task.Run(() => { var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap)); using var file = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None); encoder.Save(file); file.Flush(true); }); }
    public static void MarkComplete(string stage, string[] files, string? folder)
    { using var stream = new FileStream(Path.Combine(stage, "complete.json"), FileMode.CreateNew, FileAccess.Write, FileShare.None); JsonSerializer.Serialize(stream, new CapturePending(files.Select(Path.GetFileName).Cast<string>().ToArray(), folder)); stream.Flush(true); }
    public async Task<int> ImportCompletedAsync(string stage)
    {
        var pending = JsonSerializer.Deserialize<CapturePending>(await File.ReadAllTextAsync(Path.Combine(stage, "complete.json"))) ?? throw new InvalidDataException("保存待ちの記録が不正です。");
        if (pending.Files is not { Length: >= 1 and <= 2 } || pending.Files.Any(name => string.IsNullOrEmpty(name) || Path.GetFileName(name) != name || Path.GetExtension(name) is not (".png" or ".mp4"))) throw new InvalidDataException("保存待ちファイルが不正です。");
        var folder = pending.FolderId;
        if (folder is not null && !(await store.QueryAsync(new(Limit: 1))).Folders.Any(item => item.Id == folder)) folder = null;
        var ids = new HashSet<string>();
        foreach (var name in pending.Files)
        {
            var result = await store.ImportAsync(Path.Combine(stage, name), folder);
            if (result.Status == "restoreAvailable") throw new IOException("同じ素材がアプリのゴミ箱にあります。ライブラリで復元してから再試行してください。");
            if (result.Status is not ("saved" or "duplicate")) throw new IOException(result.Error ?? "ライブラリへの保存に失敗しました。保存待ちファイルは保持されています。");
            if (result.AssetId is not null) ids.Add(result.AssetId);
        }
        await AssetRecycle.MoveAsync(stage); return ids.Count;
    }
    public async Task<CaptureRetryResult> RetryPendingAsync()
    {
        await store.Ready; var count = 0; var failed = 0; string? error = null;
        foreach (var directory in Directory.EnumerateDirectories(Path.Combine(store.Root, "staging"), "capture-*"))
        {
            if (!File.Exists(Path.Combine(directory, "complete.json"))) continue;
            try { count += await ImportCompletedAsync(directory); }
            catch (Exception ex) when (ex is JsonException or InvalidDataException or IOException or UnauthorizedAccessException)
            {
                failed++;
                error ??= ex is JsonException ? "保存待ちの記録が壊れています。保存待ちフォルダの画像・動画を確認してください。" : ex.Message;
            }
        }
        return new(count, failed, error);
    }
}
