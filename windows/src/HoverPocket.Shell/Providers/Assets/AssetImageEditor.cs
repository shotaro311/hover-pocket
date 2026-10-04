using System.Windows.Media;
using System.Windows.Media.Imaging;
using HoverPocket.Assets;
using HoverPocket.Shell.Capture;

namespace HoverPocket.Shell.Providers.Assets;

internal static class AssetImageEditor
{
    public static Task<BitmapSource> LoadAsync(AssetStore store, Asset asset)
    {
        if (asset.Kind != "image" || asset.Trashed) throw new InvalidOperationException("ライブラリ内の画像を選択してください。");
        var path = store.ReadOriginalPath(asset);
        return Task.Run(() =>
        {
            using var stream = File.OpenRead(path);
            var probe = BitmapDecoder.Create(stream, BitmapCreateOptions.DelayCreation, BitmapCacheOption.None).Frames[0];
            if ((long)probe.PixelWidth * probe.PixelHeight > 32_000_000)
                throw new InvalidOperationException("この画像は大きすぎるため編集できません。原本は保存されています。");
            var orientation = AssetMedia.ReadOrientation(probe);
            stream.Position = 0;
            var decoded = BitmapDecoder.Create(stream, BitmapCreateOptions.None, BitmapCacheOption.OnLoad).Frames[0];
            var pixels = new FormatConvertedBitmap(AssetMedia.ApplyOrientation(decoded, orientation), PixelFormats.Bgra32, null, 0);
            var stride = checked(pixels.PixelWidth * 4); var data = new byte[checked(stride * pixels.PixelHeight)];
            pixels.CopyPixels(data, stride, 0);
            var image = BitmapSource.Create(pixels.PixelWidth, pixels.PixelHeight, 96, 96, PixelFormats.Bgra32, null, data, stride);
            image.Freeze(); return image;
        });
    }
    public static async Task<ImportResult> SaveCopyAsync(AssetStore store, Asset source, BitmapSource image)
    {
        var files = new CaptureFiles(store); var stage = files.CreateStage();
        var name = string.Concat(Path.GetFileNameWithoutExtension(source.Name).Select(c => Path.GetInvalidFileNameChars().Contains(c) ? '_' : c));
        if (name.Length > 100) name = name[..100];
        var path = Path.Combine(stage, $"{name} 編集 {DateTime.Now:yyyy-MM-dd HH-mm-ss}.png");
        await CaptureFiles.WritePngAsync(path, image);
        var categories = await store.QueryAsync(new(Limit: 1));
        var folders = source.FolderIds.Intersect(categories.Folders.Select(item => item.Id)).ToArray();
        CaptureFiles.MarkComplete(stage, [path], folders.FirstOrDefault());
        var result = await store.ImportAsync(path, folders.FirstOrDefault());
        if (result.Status is not ("saved" or "duplicate"))
            throw new IOException("編集画像を保存できませんでした。原本と編集画像を保持しています。撮影設定の「保存待ちを再試行」から再保存できます。");
        if (result.Status == "saved")
            foreach (var category in folders.Concat(source.TagIds.Intersect(categories.Tags.Select(item => item.Id))))
                await store.UpdateAsync([result.AssetId!], "classify", category);
        await AssetRecycle.MoveAsync(stage);
        return result;
    }
}
