using HoverPocket.Assets;
using Microsoft.Web.WebView2.Core;

namespace HoverPocket.Shell.Providers.Assets;

internal sealed record AssetMediaLease(Asset Asset, string? Token);

// The pane supplies the current lease; this attachment owns HTTP responses and their streams.
internal sealed class AssetMediaServer : IDisposable
{
    internal static string? AudioMime(Asset asset) => asset.Kind == "other" ? asset.Extension.ToLowerInvariant() switch
    {
        "m4a" => "audio/mp4", "aac" => "audio/aac", "mp3" => "audio/mpeg",
        "wav" => "audio/wav", "ogg" => "audio/ogg", "flac" => "audio/flac", _ => null
    } : null;
    private readonly AssetStore _store;
    private readonly CoreWebView2 _web;
    private readonly Func<AssetMediaLease?> _selection;
    private readonly HashSet<BoundedReadStream> _resourceStreams = [];

    public AssetMediaServer(AssetStore store, CoreWebView2 web, Func<AssetMediaLease?> selection)
    {
        _store = store;
        _web = web;
        _selection = selection;
        web.AddWebResourceRequestedFilter("https://asset-media.hoverpocket.local/*", CoreWebView2WebResourceContext.All);
        web.WebResourceRequested += ServeMedia;
    }

    private async void ServeMedia(object? sender, CoreWebView2WebResourceRequestedEventArgs args)
    {
        using var deferral = args.GetDeferral();
        try
        {
            var selection = _selection(); var asset = selection?.Asset; var uri = new Uri(args.Request.Uri);
            if (asset is null || (asset.Kind != "video" && AudioMime(asset) is null) || uri.AbsolutePath != $"/{selection?.Token}/{asset.Id}")
            { args.Response = _web.Environment.CreateWebResourceResponse(null, 403, "Forbidden", "Access-Control-Allow-Origin: https://app.hoverpocket.local\r\n"); return; }
            var file = new FileStream(_store.ReadOriginalPath(asset), FileMode.Open, FileAccess.Read, FileShare.Read, 65536, true);
            var start = 0L; var end = file.Length - 1; var ranged = false;
            if (args.Request.Headers.Contains("Range"))
            {
                var range = args.Request.Headers.GetHeader("Range");
                var parts = range.StartsWith("bytes=", StringComparison.Ordinal) ? range[6..].Split('-') : [];
                if (parts.Length != 2 || !long.TryParse(parts[0], out start) || start < 0 || start >= file.Length
                    || (parts[1].Length > 0 && (!long.TryParse(parts[1], out end) || end < start)))
                { file.Dispose(); args.Response = _web.Environment.CreateWebResourceResponse(null, 416, "Range Not Satisfiable", $"Content-Range: bytes */{asset.SizeBytes}\r\n"); return; }
                end = Math.Min(end, file.Length - 1); ranged = true;
            }
            file.Position = start;
            var mime = AudioMime(asset) ?? (asset.Extension switch { "webm" => "video/webm", "mov" => "video/quicktime", _ => "video/mp4" });
            var headers = $"Access-Control-Allow-Origin: https://app.hoverpocket.local\r\nContent-Type: {mime}\r\nAccept-Ranges: bytes\r\nContent-Length: {end - start + 1}\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n";
            if (ranged) headers += $"Content-Range: bytes {start}-{end}/{file.Length}\r\n";
            var stream = new BoundedReadStream(file, end - start + 1, value => { lock (_resourceStreams) _resourceStreams.Remove(value); });
            lock (_resourceStreams) _resourceStreams.Add(stream);
            args.Response = _web.Environment.CreateWebResourceResponse(stream, ranged ? 206 : 200, ranged ? "Partial Content" : "OK", headers);
            await Task.CompletedTask;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { args.Response = _web.Environment.CreateWebResourceResponse(null, 404, "Not Found", "Access-Control-Allow-Origin: https://app.hoverpocket.local\r\n"); }
    }
    public void CloseStreams()
    {
        BoundedReadStream[] streams;
        lock (_resourceStreams)
        {
            streams = _resourceStreams.ToArray();
            _resourceStreams.Clear();
        }
        foreach (var stream in streams) stream.Dispose();
    }

    public void Dispose()
    {
        _web.WebResourceRequested -= ServeMedia;
        CloseStreams();
    }
}

internal sealed class BoundedReadStream(Stream inner, long length, Action<BoundedReadStream> completed) : Stream
{
    private readonly long _length = length;
    private long remaining = length;
    private readonly object _sync = new();
    public override bool CanRead => true; public override bool CanSeek => false; public override bool CanWrite => false;
    public override long Length => _length; public override long Position { get => _length - remaining; set => throw new NotSupportedException(); }
    public override int Read(byte[] buffer, int offset, int count) => Read(buffer.AsSpan(offset, count));
    public override int Read(Span<byte> buffer)
    {
        lock (_sync)
        {
            if (remaining == 0) return 0;
            var read = inner.Read(buffer[..(int)Math.Min(buffer.Length, remaining)]); remaining -= read;
            if (remaining == 0 || read == 0) { inner.Dispose(); remaining = 0; completed(this); }
            return read;
        }
    }
    protected override void Dispose(bool disposing) { if (disposing) { lock (_sync) { inner.Dispose(); remaining = 0; } completed(this); } base.Dispose(disposing); }
    public override void Flush() => throw new NotSupportedException(); public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
    public override void SetLength(long value) => throw new NotSupportedException(); public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
}
