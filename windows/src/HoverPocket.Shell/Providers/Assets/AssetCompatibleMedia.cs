using System.Diagnostics;
using HoverPocket.Assets;

namespace HoverPocket.Shell.Providers.Assets;

internal static class AssetCompatibleMedia
{
    private static readonly SemaphoreSlim Work = new(1);
    internal static string? Executable => new[] { Path.Combine(AppContext.BaseDirectory, "MediaTools", "ffmpeg.exe") }
        .Concat((Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator).Select(path => Path.Combine(path.Trim('"'), "ffmpeg.exe")))
        .FirstOrDefault(File.Exists);
    internal static async Task<string> ConvertAsync(AssetStore store, Asset asset, string mode, CancellationToken token)
    {
        var executable = Executable ?? throw new IOException("互換プレビューを作るメディア処理が利用できません。原本は保存されています。");
        if (asset.SizeBytes > 2L * 1024 * 1024 * 1024) throw new IOException("互換プレビューの容量上限を超えています。原本は保存されています。");
        var ext = mode == "video" ? "mp4" : mode == "audio" ? "m4a" : "png";
        var directory = Path.Combine(store.Root, "cache", "compatible"); Directory.CreateDirectory(directory);
        var output = Path.Combine(directory, asset.Sha256 + "-v1-" + mode + "." + ext);
        await Work.WaitAsync(token);
        var temporary = Path.Combine(directory, Guid.NewGuid().ToString("N") + "." + ext);
        try
        {
            if (File.Exists(output)) return output;
            var start = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardError = true, RedirectStandardOutput = true };
            string[] common = ["-nostdin", "-hide_banner", "-loglevel", "error", "-threads", "2", "-max_alloc", "268435456", "-protocol_whitelist", "file,pipe", "-format_whitelist", "avi,matroska,webm,mov,mp4,m4a,3gp,3g2,mj2,mpeg,mpegts,asf,ogg,flac,wav,mp3,aac,aiff,caf,ac3,eac3,amr,ape,au,wv,png_pipe,jpeg_pipe,tiff_pipe,webp_pipe,bmp_pipe,ico,heif,avif,image2,gif,apng", "-i", store.ReadOriginalPath(asset)];
            string[] options = mode switch
            {
                "video" => ["-map", "0:v:0", "-map", "0:a:0?", "-vf", "scale=1920:1080:force_original_aspect_ratio=decrease:force_divisible_by=2", "-c:v", "h264_mf", "-b:v", "6M", "-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart"],
                "audio" => ["-map", "0:a:0", "-vn", "-c:a", "aac", "-b:a", "192k"],
                _ => ["-map", "0:v:0", "-frames:v", "1", "-vf", "scale=2048:2048:force_original_aspect_ratio=decrease"]
            };
            foreach (var arg in common.Concat(options).Concat(new[] { "-threads", "2", "-fs", "536870912", "-y", temporary })) start.ArgumentList.Add(arg);
            using var process = Process.Start(start) ?? throw new IOException("メディア処理を開始できません。");
            var errors = DrainAsync(process.StandardError, token); var stdout = DrainAsync(process.StandardOutput, token);
            using var limit = CancellationTokenSource.CreateLinkedTokenSource(token); limit.CancelAfter(TimeSpan.FromSeconds(120));
            try { await process.WaitForExitAsync(limit.Token); }
            catch (OperationCanceledException) { if (!process.HasExited) process.Kill(true); if (token.IsCancellationRequested) throw; throw new IOException("互換プレビューの生成が時間内に完了しませんでした。原本は保存されています。"); }
            await Task.WhenAll(errors, stdout);
            if (process.ExitCode != 0 || !File.Exists(temporary) || new FileInfo(temporary).Length == 0) throw new IOException("このコーデックの互換プレビューを生成できません。原本は保存されています。");
            var size = new FileInfo(temporary).Length;
            var cached = new DirectoryInfo(directory).GetFiles().Where(f => f.FullName != temporary).OrderBy(f => f.LastWriteTimeUtc).ToArray();
            var used = cached.Sum(f => f.Length);
            foreach (var file in cached)
            {
                if (used + size <= 2L * 1024 * 1024 * 1024) break;
                if (await AssetRecycle.MoveAsync(file.FullName)) used -= file.Length;
            }
            if (used + size > 2L * 1024 * 1024 * 1024) throw new IOException("互換プレビューの保存容量の上限に達しました。原本は保存されています。");
            File.Move(temporary, output); return output;
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); Work.Release(); }
    }
    private static async Task DrainAsync(StreamReader reader, CancellationToken token)
    {
        var buffer = new char[2048]; while (await reader.ReadAsync(buffer.AsMemory(), token) > 0) { }
    }
}
