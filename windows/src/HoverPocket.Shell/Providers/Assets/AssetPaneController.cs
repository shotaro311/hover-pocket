using System.Text.Json;
using System.Windows;
using System.Windows.Media.Imaging;
using HoverPocket.Assets;
using HoverPocket.Shell.Bridge;
using Microsoft.Web.WebView2.Core;
using MessageBox = System.Windows.MessageBox;
using DataObject = System.Windows.DataObject;
using DataFormats = System.Windows.DataFormats;
using DragDropEffects = System.Windows.DragDropEffects;

namespace HoverPocket.Shell.Providers.Assets;

internal sealed record AssetPreviewLayout(bool Active, bool Fullscreen = false, double Width = 0, double Height = 0, bool Organizer = false, bool PinOnly = false);

// One attachment owns one preview lease. Its URL never reveals the managed file system.
internal sealed class AssetPaneController : IDisposable
{
    private readonly AssetStore _store;
    private readonly AssetMedia _media;
    private readonly Window _owner;
    private readonly BridgeDispatcher _bridge;
    private readonly CoreWebView2 _web;
    private readonly Action<AssetPreviewLayout> _layout;
    private readonly Func<string> _provider;
    private readonly AssetPlaybackOwner _playback;
    private CancellationTokenSource? _preview;
    private CancellationTokenSource _thumbnails = new();
    private CancellationTokenSource? _import;
    private Asset? _selected;
    private string? _lease;
    private int _generation;
    private int _completed, _failed, _duplicates;
    private int _skipped, _restoreAvailable;
    private readonly System.Collections.Concurrent.ConcurrentDictionary<string,int> _skipReasons = new();
    private string? _lastImportError;
    private bool _disposed;
    private AssetPreviewLayout _previewLayout = new(false);
    private Asset[]? _undo;
    private readonly AssetMediaServer _mediaServer;
    private PreparedDrag? _preparedDrag;
    private bool _dragPreparing;
    private readonly FrameworkElement? _webSurface;
    private Rect _trashBounds;
    private bool _trashRequested, _trashHovered;
    private string? _dragToken;
    private sealed record AssetDropTarget(AssetDestination Destination, Rect Bounds);
    private AssetDropTarget[] _dropTargets = [];
    private AssetDestination? _dropTarget, _hoverTarget;
    internal string DragTraceForVerify { get; private set; } = "none";
    internal string DragStateForVerify { get; private set; } = "idle";
    internal bool InternalDragForVerify => _dragToken is not null;
    private const string InternalDragFormat = "HoverPocket.AssetDrag";
    private sealed record PreparedDrag(string Key, string[] Paths, long[] Sizes, DateTime[] Modified);
    public AssetPaneController(AssetStore store, Window owner, BridgeDispatcher bridge, CoreWebView2 web,
        Action<AssetPreviewLayout> layout, Func<string> provider, AssetPlaybackOwner playback, Action? openOrganizer = null, Func<string, string?, Task>? capture = null, FrameworkElement? webSurface = null)
    {
        _webSurface = webSurface;
        _store = store; _media = AssetMedia.For(store); _owner = owner; _bridge = bridge; _web = web; _layout = layout; _provider = provider; _playback = playback;
        _store.Changed += OnChanged;
        Register("assets.query", async p => await _store.QueryAsync(Parse<AssetQuery>(p)));
        Register("assets.matches", async p => new { matches = await _store.MatchesAsync(Parse<AssetQuery>(p!.Value.GetProperty("query")), Text(p, "id")) });
        Register("assets.selectionRange", async p => new { ids = await _store.SelectionRangeAsync(Parse<AssetQuery>(p!.Value.GetProperty("query")), Text(p, "anchorId"), Text(p, "targetId")) });
        Register("assets.update", UpdateAsync);
        Register("assets.undo", async _ => { if (_undo is not null) { await _store.RestoreMetadataAsync(_undo); _undo = null; } return new { ok = true }; });
        Register("assets.category", async p => new { id = await _store.AddCategoryAsync(Text(p, "type"), Text(p, "name"), Optional(p, "parentId")) });
        Register("assets.categoryUpdate", async p => new { ok = await _store.ChangeCategoryAsync(Text(p, "id"), Text(p, "operation"), Optional(p, "name"), Optional(p, "parentId")) });
        Register("assets.emptyTrash", async _ =>
        {
            using var pin = PinForDialog();
            if (MessageBox.Show(_owner, "素材をWindowsのゴミ箱へ移します。アプリ内の取り消しでは戻せません。続けますか？", "ゴミ箱を空にする", MessageBoxButton.OKCancel) != MessageBoxResult.OK) return new { cancelled = true };
            _undo = null; return new { removed = await _store.EmptyTrashAsync(AssetRecycle.MoveAsync) };
        });
        Register("assets.saveSearch", async p => new { ok = await _store.SaveSearchAsync(Text(p, "name"), Parse<AssetQuery>(p!.Value.GetProperty("filter"))) });
        Register("assets.thumbnail", async p => { var token = _thumbnails.Token; var asset = await _store.GetAsync(Text(p, "id")); return asset is null ? null : await _media.FrameAsync(asset, 1, true, token); });
        Register("assets.visibility", p => { _thumbnails.Cancel(); _thumbnails.Dispose(); _thumbnails = new(); if (!p!.Value.GetProperty("visible").GetBoolean()) _thumbnails.Cancel(); return Task.FromResult<object?>(new { ok = true }); });
        Register("assets.preview", PreviewAsync);
        Register("assets.transition", async p =>
        {
            if (_owner is not Windows.PanelWindow panel) return new { revision = 0L };
            if (p is { } value && value.TryGetProperty("cancel", out var revision)) { panel.CancelContentTransition(revision.GetInt64()); return new { revision = 0L }; }
            return new { revision = await panel.PrepareContentTransitionAsync() };
        });
        Register("assets.editImage", EditImageAsync);
        Register("assets.layout", p => { _previewLayout = _previewLayout with { Fullscreen = p!.Value.GetProperty("fullscreen").GetBoolean() }; _layout(_previewLayout); return Task.FromResult<object?>(new { ok = true }); });
        Register("assets.endPreview", _ => { EndPreview(); return Task.FromResult<object?>(new { ok = true }); });
        Register("assets.organizer", _ => { _previewLayout = new(true, Organizer: true); _layout(_previewLayout); return Task.FromResult<object?>(new { ok = true }); });
        Register("assets.openOrganizer", _ => { openOrganizer?.Invoke(); return Task.FromResult<object?>(new { ok = true }); });
        Register("assets.capture", async p => { var kind = Optional(p, "kind") ?? "settings"; if (kind is not ("settings" or "screenshot" or "recording" or "cameraPhoto" or "cameraVideo" or "audio")) throw new ArgumentException("Unknown capture action."); if (capture is not null) await capture(kind, Optional(p, "folderId")); return new { ok = capture is not null }; });
        Register("assets.pick", PickAsync);
        Register("assets.cancelImport", _ => { _import?.Cancel(); return Task.FromResult<object?>(new { ok = true }); });
        Register("assets.importState", _ => Task.FromResult<object?>(Progress()));
        Register("assets.clipboard", ClipboardAsync);
        Register("assets.copy", CopyAsync);
        Register("assets.dragTargets", p => { if (_dragToken is not null) ReadDropTargets(p!.Value); return Task.FromResult<object?>(new { ok = true }); });
        Register("assets.backup", BackupAsync);
        Register("assets.recover", async _ => { var items = await _store.OrphansAsync(); var recovered=0; foreach (var item in items) if(await _store.RecoverOrphanAsync(item)) recovered++; return new { recovered }; });
        Register("assets.databaseSnapshots", async _ => await _store.DatabaseSnapshotsAsync());
        Register("assets.restoreDatabase", async p =>
        {
            using var pin = PinForDialog();
            var name = Text(p, "name");
            if (MessageBox.Show(_owner, $"DBスナップショット {name} を復元します。これ以降の名前・分類等の変更は戻る可能性があります。原本と現在のDBは保持します。続けますか？", "DBの復旧", MessageBoxButton.OKCancel) != MessageBoxResult.OK) return new { cancelled = true };
            EndPreview(); await _store.RestoreDatabaseSnapshotAsync(name); return new { ok = true };
        });
        Register("assets.status", async _ => { await _store.Ready; return new { warning = _store.RecoveryWarning ?? _store.RecoveryNotice }; });
        Register("assets.cleanCopies", async _ =>
        {
            using var pin = PinForDialog();
            if (MessageBox.Show(_owner, "ドラッグやコピー用に作った作業ファイルをWindowsのゴミ箱へ移します。コピー先のアプリが使用中の場合は先に保存してください。続けますか？", "外部コピーの整理", MessageBoxButton.OKCancel) != MessageBoxResult.OK) return new { cancelled = true };
            var removed = 0;
            foreach (var directory in Directory.EnumerateDirectories(Path.Combine(_store.Root, "outbox"))) if (await AssetRecycle.MoveAsync(directory)) removed++;
            return new { removed };
        });
        _mediaServer = new AssetMediaServer(store, web,
            () => _selected is not null && _provider() == "assets" ? new(_selected, _lease) : null);
        web.ContainsFullScreenElementChanged += OnBrowserFullscreenChanged;
    }

    private void OnBrowserFullscreenChanged(object? sender, object args)
    {
        if (_disposed || !_previewLayout.Active || _selected?.Kind != "video") return;
        _previewLayout = _previewLayout with { Fullscreen = _web.ContainsFullScreenElement };
        _layout(_previewLayout);
        _ = _bridge.PostEventAsync("assets.fullscreenChanged", new { fullscreen = _previewLayout.Fullscreen });
    }
    private void Register(string method, Func<JsonElement?, Task<object?>> handler) => _bridge.Register(method, async (p, _) =>
    {
        try { return await handler(p); }
        catch (OperationCanceledException) { return new { cancelled = true }; }
        catch (InvalidDataException ex) { throw new InvalidOperationException(ex.Message); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException or JsonException or Microsoft.Data.Sqlite.SqliteException)
        { throw new InvalidOperationException("素材の操作を完了できませんでした。入力・アクセス権・空き容量を確認してください。"); }
    });
    private static T Parse<T>(JsonElement? p) => p is null ? Activator.CreateInstance<T>() : JsonSerializer.Deserialize<T>(p.Value.GetRawText(), AssetFormat.Json)!;
    private static string Text(JsonElement? p, string key) => Optional(p, key) ?? "";
    private static string? Optional(JsonElement? p, string key) => p is { } value && value.TryGetProperty(key, out var field) && field.ValueKind == JsonValueKind.String ? field.GetString() : null;
    private async Task<object?> UpdateAsync(JsonElement? p)
    {
        if (Text(p, "operation") == "undoOrganize") return new { ok = await _store.UndoOrganizeAsync(Text(p, "undoToken")) };
        var ids = p!.Value.GetProperty("ids").Deserialize<string[]>()!;
        if (Text(p, "operation") == "organize")
            return await _store.OrganizeAsync(ids, Optional(p, "sourceFolderId"), Parse<AssetDestination>(p.Value.GetProperty("destination")));
        var old = new List<Asset>(); foreach (var id in ids) if (await _store.GetAsync(id) is { } asset) old.Add(asset);
        await _store.UpdateAsync(ids, Text(p, "operation"), Optional(p, "value")); _undo = old.ToArray(); return new { ok = true };
    }
    private async Task<object?> PreviewAsync(JsonElement? p)
    {
        _playback.Claim(this);
        _mediaServer.CloseStreams();
        _preview?.Cancel(); _preview?.Dispose(); _preview = new(); var token = _preview.Token;
        var generation = ++_generation; var id = Text(p, "id");
        var asset = await _store.GetAsync(id) ?? throw new FileNotFoundException();
        if (generation != _generation || _disposed || token.IsCancellationRequested) return new { cancelled = true };
        if (_provider() != "assets") throw new InvalidOperationException("素材画面でプレビューしてください。");
        _selected = asset; _lease = Guid.NewGuid().ToString("N");
        _layout(_previewLayout with { Active = true, PinOnly = !_previewLayout.Active });
        _previewLayout = _previewLayout with { Active = true };
        var page = p!.Value.TryGetProperty("page", out var number) ? Math.Max(1, number.GetInt32()) : 1;
        var audio = AssetMediaServer.AudioMime(asset) is not null;
        var frame = audio ? new AssetFrame(null, 640, 160) : await _media.FrameAsync(asset, page, false, token);
        if (generation != _generation || _disposed) return new { cancelled = true };
        _previewLayout = new(true, _previewLayout.Fullscreen, frame.Width, frame.Height, _previewLayout.Organizer);
        // The client presents this layout after the preview image has decoded.
        return new { id, generation, asset.Kind, frame.DataUrl, frame.Width, frame.Height, frame.Pages, frame.Error,
            videoUrl = asset.Kind == "video" ? $"https://asset-media.hoverpocket.local/{_lease}/{asset.Id}" : null,
            audioUrl = audio ? $"https://asset-media.hoverpocket.local/{_lease}/{asset.Id}" : null };
    }
    private bool _editingImage;
    private Capture.InlineImageEditor? _inlineEditor;
    private async Task<object?> EditImageAsync(JsonElement? p)
    {
        if (_editingImage) return new { cancelled = true };
        _editingImage = true;
        using var pin = PinForDialog();
        var generation = _generation;
        try
        {
            var asset = await _store.GetAsync(Text(p, "id")) ?? throw new FileNotFoundException();
            var image = await AssetImageEditor.LoadAsync(_store, asset);
            if (_disposed || generation != _generation) return new { cancelled = true };
            if (_webSurface is null) throw new InvalidOperationException("編集画面を表示できませんでした。");
            _inlineEditor = new();
            ImportResult? result = null;
            var saved = await _inlineEditor.ShowAsync(_owner, _webSurface, _web, image,
                async edited => result = await AssetImageEditor.SaveCopyAsync(_store, asset, edited.Image));
            if (!saved || result is null || _disposed) return new { cancelled = true };
            return new { ok = true, result.AssetId, result.Status, asset = await _store.GetAsync(result.AssetId!) };
        }
        catch (Exception ex) when (ex is NotSupportedException or System.Runtime.InteropServices.ExternalException)
        { Services.AppDiagnostics.Record("asset.edit.failed", ex); throw new InvalidOperationException("この画像を編集できません。形式・破損・アクセス権を確認してください。原本は保持されています。"); }
        finally { _editingImage = false; _inlineEditor = null; }
    }
    public void EndPreview()
    {
        _inlineEditor?.Cancel();
        _playback.Release(this);
        _mediaServer.CloseStreams();
        ++_generation; _preview?.Cancel(); _selected = null; _lease = null;
        _previewLayout = new(false); _layout(_previewLayout);
        if (!_disposed) _ = _bridge.PostEventAsync("assets.previewEnded", new { });
    }
    private async Task<object?> PickAsync(JsonElement? p)
    {
        using var pin = PinForDialog();
        string[] paths = [];
        if (Text(p, "kind") == "folder")
        { var picker = new Microsoft.Win32.OpenFolderDialog { Title = "素材を追加するフォルダ", Multiselect = false }; if (picker.ShowDialog(_owner) == true) paths = [picker.FolderName]; }
        else { var picker = new Microsoft.Win32.OpenFileDialog { Title = "素材を追加", Multiselect = true }; if (picker.ShowDialog(_owner) == true) paths = picker.FileNames; }
        if (paths.Length > 0) await ImportPathsAsync(paths); return new { ok = true };
    }
    public async Task<bool> ImportPathsAsync(string[] paths, string? folderId = null, bool waitForCompletion = false, bool internet = false)
    {
        using var pin = PinForDialog();
        if (_import is not null) { await _bridge.PostEventAsync("assets.dropUnsupported",new {message="保存中です。処理が終わるか取り消してから追加してください。"}); return false; }
        var capacity = await Task.Run(() => { long bytes = 0; var count = 0; foreach (var path in Enumerate(paths)) { try { bytes += new FileInfo(path).Length; count++; } catch (IOException) { } catch (UnauthorizedAccessException) { } } return (count, bytes); });
        if ((capacity.count >= 1000 || capacity.bytes >= 1024L * 1024 * 1024)
            && MessageBox.Show(_owner, $"{capacity.count:N0}件、{capacity.bytes / (1024d * 1024):N1} MiBをコピーして保存します。続けますか？", "素材を追加", MessageBoxButton.OKCancel) != MessageBoxResult.OK) return false;
        if (_import is not null) return false;
        _import?.Dispose(); _import = new(); var cancellation = _import; _completed = _failed = _duplicates = _skipped = _restoreAvailable = 0; _skipReasons.Clear(); _lastImportError=null;
        var import = RunImportAsync(paths, cancellation, folderId, internet);
        if (waitForCompletion) await import;
        return !cancellation.IsCancellationRequested;
    }
    private async Task RunImportAsync(string[] paths, CancellationTokenSource cancellation, string? folderId = null, bool internet = false)
    {
        try
        {
            var folderMap = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            var restoreIds = new HashSet<string>();
            await Task.Run(async () =>
            {
                foreach (var file in Enumerate(paths, includeDirectories:true, skipped:reason=>{_skipped++;_skipReasons.AddOrUpdate(reason,1,(_,count)=>count+1);}))
                {
                    cancellation.Token.ThrowIfCancellationRequested();
                    string? category = folderId;
                    var isDirectory = Directory.Exists(file);
                    var root = paths.FirstOrDefault(p => Directory.Exists(p) && (string.Equals(Path.GetFullPath(file),Path.GetFullPath(p),StringComparison.OrdinalIgnoreCase) || file.StartsWith(Path.GetFullPath(p) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)));
                    if (root is not null)
                    {
                        var directory = isDirectory ? file : Path.GetDirectoryName(file)!; var current = Path.GetFullPath(root);
                        var parts = new[] { new DirectoryInfo(root).Name }.Concat(Path.GetRelativePath(root, directory).Split(Path.DirectorySeparatorChar).Where(p => p != "."));
                        foreach (var part in parts) { current = Path.Combine(current, part); if (!folderMap.TryGetValue(current, out var found)) folderMap[current] = found = await _store.AddCategoryAsync("folder", part, category); category = found; }
                    }
                    if (isDirectory) continue;
                    var origin = internet || File.Exists(file + ":Zone.Identifier");
                    var result = await _store.ImportAsync(file, category, origin, cancellation.Token);
                    if (result.Status == "duplicate" && result.AssetId is not null && category is not null)
                        await _store.OrganizeAsync([result.AssetId], null, new AssetDestination("folder", category));
                    if (result.Status == "saved") _completed++; else if (result.Status is "duplicate" or "restoreAvailable") { _duplicates++; if(result.Status=="restoreAvailable") { _restoreAvailable++; restoreIds.Add(result.AssetId!); } } else if (result.Status == "failed") { _failed++; _lastImportError=result.Error; } else if(result.Status=="skipped") _skipped++;
                    await _bridge.PostEventAsync("assets.importChanged", Progress());
                }
            });
            if (restoreIds.Count>0) await _bridge.PostEventAsync("assets.restoreAvailable", new { ids=restoreIds.ToArray() });
        }
        catch (OperationCanceledException) { }
        catch (IOException) { _failed++; }
        catch (UnauthorizedAccessException) { _failed++; }
        catch (Exception ex) when (ex is ArgumentException or InvalidOperationException or Microsoft.Data.Sqlite.SqliteException) { _failed++; _lastImportError="分類または保存の状態が変わりました。保存済みの素材は保持されています。再試行してください。"; }
        finally { if (ReferenceEquals(_import, cancellation)) { _import = null; cancellation.Dispose(); } await _bridge.PostEventAsync("assets.importChanged", Progress()); OnChanged(); }
    }
    private static IEnumerable<string> Enumerate(IEnumerable<string> paths, bool includeDirectories = false, Action<string>? skipped = null)
    {
        var stack = new Stack<IEnumerator<string>>(); stack.Push(paths.GetEnumerator());
        try
        {
            while (stack.TryPeek(out var iterator))
            {
                bool next; try { next = iterator.MoveNext(); } catch (IOException) { next = false; skipped?.Invoke("読み取り失敗"); } catch (UnauthorizedAccessException) { next = false; skipped?.Invoke("アクセス権なし"); }
                if (!next) { stack.Pop().Dispose(); continue; }
                var path = iterator.Current;
                FileAttributes attributes; try { attributes = File.GetAttributes(path); } catch (IOException) { skipped?.Invoke("読み取り失敗"); continue; } catch (UnauthorizedAccessException) { skipped?.Invoke("アクセス権なし"); continue; }
                if ((attributes & FileAttributes.ReparsePoint) != 0) { skipped?.Invoke("リンク・ジャンクション"); continue; }
                if ((attributes & FileAttributes.Directory) != 0)
                { if (!path.EndsWith(".app", StringComparison.OrdinalIgnoreCase)) { if (includeDirectories) yield return path; stack.Push(Directory.EnumerateFileSystemEntries(path).GetEnumerator()); } else skipped?.Invoke("アプリのパッケージ"); }
                else if (Path.GetFileName(path).ToLowerInvariant() is not ("thumbs.db" or "desktop.ini" or ".ds_store")) yield return path; else skipped?.Invoke("システムの管理ファイル");
            }
        }
        finally { while (stack.TryPop(out var iterator)) iterator.Dispose(); }
    }
    private object Progress() => new { busy = _import is not null, completed = _completed, failed = _failed, duplicates = _duplicates, skipped = _skipped, skipReasons = _skipReasons.ToArray(), restoreAvailable = _restoreAvailable, error = _lastImportError };
    private async Task<object?> ClipboardAsync(JsonElement? _)
    {
        if (System.Windows.Clipboard.ContainsFileDropList()) { await ImportPathsAsync(System.Windows.Clipboard.GetFileDropList().Cast<string>().ToArray()); return new { ok = true }; }
        var bitmap = System.Windows.Clipboard.GetImage(); if (bitmap is null) throw new ArgumentException("画像またはファイルをコピーしてください。URLだけの場合は画像をダウンロードしてから追加してください。");
        return await ImportBitmapAsync(bitmap);
    }
    public async Task<object?> ImportBitmapAsync(System.Windows.Media.Imaging.BitmapSource bitmap)
    {
        if (!bitmap.CanFreeze) throw new ArgumentException("この画像はファイルに保存してから追加してください。");
        bitmap.Freeze(); var folder = Path.Combine(_store.Root, "staging", Guid.NewGuid().ToString("N")); Directory.CreateDirectory(folder);
        var path = Path.Combine(folder, $"クリップボード画像 {DateTime.Now:yyyy-MM-dd HH-mm-ss}.png");
        await Task.Run(() => { var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap)); using var output = File.Create(path); encoder.Save(output); });
        var result = await _store.ImportAsync(path, internet: true);
        if (result.Status is "saved" or "duplicate" or "restoreAvailable") await AssetRecycle.MoveAsync(folder);
        return result;
    }
    private async Task<object?> CopyAsync(JsonElement? p)
    {
        using var pin = PinForDialog();
        var id = Text(p, "id"); string? destination = null;
        if (Text(p, "mode") == "save") { var picker = new Microsoft.Win32.SaveFileDialog { FileName = (await _store.GetAsync(id))?.Name }; if (picker.ShowDialog(_owner) != true) return new { cancelled = true }; destination = picker.FileName; if (File.Exists(destination)) throw new ArgumentException("上書きを避けるため新しいファイル名を指定してください。"); }
        var ids = p!.Value.TryGetProperty("ids", out var values) ? values.Deserialize<string[]>()! : new[] { id };
        if (Text(p, "mode") is "save" or "open") ids = [id];
        if (Text(p, "mode") == "open")
        {
            var asset = await _store.GetAsync(id) ?? throw new FileNotFoundException();
            if (new[] { "exe", "com", "bat", "cmd", "ps1", "vbs", "vbe", "js", "jse", "wsf", "wsh", "msi", "scr", "lnk", "hta", "reg", "url" }.Contains(asset.Extension)
                && MessageBox.Show(_owner, "実行ファイルやスクリプトをOSで開きます。信頼できる内容だけを実行してください。続けますか？", "ファイルを開く", MessageBoxButton.OKCancel) != MessageBoxResult.OK) return new { cancelled = true };
        }
        var drag = Text(p, "mode") == "drag";
        if (drag) DragStateForVerify = "requested";
        if (drag && _dragPreparing) { DragStateForVerify = "busy"; return new { preparing = true }; }
        ids = ids.Distinct().Order(StringComparer.Ordinal).ToArray();
        if (drag && p.Value.TryGetProperty("dropTargets", out _))
        {
            foreach (var value in ids) _store.ReadOriginalPath(await _store.GetAsync(value) ?? throw new FileNotFoundException());
            if ((GetAsyncKeyState(0x01) & 0x8000) == 0) return new { prepared = true };
            ReadDropTargets(p.Value);
            _trashBounds = Rect.Empty;
            if (p.Value.TryGetProperty("trashBounds", out var initialTrash) && initialTrash.ValueKind == JsonValueKind.Object)
            {
                var x = initialTrash.GetProperty("x").GetDouble(); var y = initialTrash.GetProperty("y").GetDouble(); var width = initialTrash.GetProperty("width").GetDouble(); var height = initialTrash.GetProperty("height").GetDouble();
                if (double.IsFinite(x) && double.IsFinite(y) && double.IsFinite(width) && double.IsFinite(height) && width > 0 && height > 0) _trashBounds = new(x, y, width, height);
            }
            _dropTarget = null; _dragToken = Guid.NewGuid().ToString("N"); _trashRequested = false;
            var data = new DataObject(new AssetDragDataObject(_store, ids, _dragToken));
            var lastMove = DateTime.MinValue;
            void Moved(object sender, System.Windows.QueryContinueDragEventArgs args)
            {
                if (_webSurface is null || DateTime.UtcNow - lastMove < TimeSpan.FromMilliseconds(35)) return;
                lastMove = DateTime.UtcNow;
                if (GetCursorPos(out var screenPoint))
                {
                    var point = _webSurface.PointFromScreen(new System.Windows.Point(screenPoint.X, screenPoint.Y));
                    _ = _bridge.PostEventAsync("assets.dragMoved", new { x = point.X, y = point.Y });
                }
            }
            _owner.QueryContinueDrag += Moved;
            DragStateForVerify = "active";
            try { DragStateForVerify = "ended-" + DragDrop.DoDragDrop(_owner, data, DragDropEffects.Copy | DragDropEffects.Move); }
            finally { _owner.QueryContinueDrag -= Moved; _dragToken = null; SetDropHover(null); _dropTargets = []; }
            return new { ok = true, dropTarget = _dropTarget, droppedInTrash = _dropTarget?.Kind == "trash" };
        }
        var key = string.Join(',', ids);
        var prepared = _preparedDrag;
        var copies = new List<string>();
        if (drag && prepared is not null && prepared.Key == key && prepared.Paths.Select((path,index) =>
            File.Exists(path) && new FileInfo(path).Length == prepared.Sizes[index] && File.GetLastWriteTimeUtc(path) == prepared.Modified[index]).All(valid => valid))
        {
            foreach (var value in ids) _store.ReadOriginalPath(await _store.GetAsync(value) ?? throw new FileNotFoundException());
            copies.AddRange(prepared.Paths);
        }
        else
        {
            if (drag) { _dragPreparing = true; await _bridge.PostEventAsync("assets.dragPreparing", new { }); }
            try { foreach (var value in ids) copies.Add(await _store.CopyOutAsync(value, destination)); }
            finally { _dragPreparing = false; }
        }
        if (drag)
        {
            if ((GetAsyncKeyState(0x01) & 0x8000) == 0)
            {
                DragStateForVerify = "prepared-button-released";
                _preparedDrag = new(key, copies.ToArray(), copies.Select(path => new FileInfo(path).Length).ToArray(), copies.Select(File.GetLastWriteTimeUtc).ToArray());
                await _bridge.PostEventAsync("assets.dragReady", new { });
                return new { prepared = true };
            }
            // A handed-out copy is never reused: the receiving app can edit it immediately.
            _preparedDrag = null;
            _trashBounds = Rect.Empty;
            _dropTargets = [];
            if (p.Value.TryGetProperty("trashBounds", out var bounds) && bounds.ValueKind == JsonValueKind.Object)
                _trashBounds = new Rect(bounds.GetProperty("x").GetDouble(), bounds.GetProperty("y").GetDouble(), bounds.GetProperty("width").GetDouble(), bounds.GetProperty("height").GetDouble());
            DragTraceForVerify = "no native target events";
            _trashRequested = false; _dragToken = Guid.NewGuid().ToString("N");
            var data = new DataObject(DataFormats.FileDrop, copies.ToArray()); data.SetData(InternalDragFormat, _dragToken);
            DragStateForVerify = "active";
            try { var effect = DragDrop.DoDragDrop(_owner, data, DragDropEffects.Copy | DragDropEffects.Move); DragStateForVerify = "ended-" + effect; }
            finally { _dragToken = null; SetTrashHover(false); }
            return new { ok = true, droppedInTrash = _trashRequested };
        }
        else if (Text(p, "mode") == "open") System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(copies.Single()) { UseShellExecute = true });
        else if (Text(p, "mode") != "save") { var files = new System.Collections.Specialized.StringCollection(); files.AddRange(copies.ToArray()); System.Windows.Clipboard.SetFileDropList(files); }
        return new { ok = true };
    }
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern short GetAsyncKeyState(int key);
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)] private struct NativePoint { public int X, Y; }
    [System.Runtime.InteropServices.DllImport("user32.dll")] [return: System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.Bool)] private static extern bool GetCursorPos(out NativePoint point);
    private void ReadDropTargets(JsonElement parameters)
    {
        if (!parameters.TryGetProperty("dropTargets", out var values) || values.ValueKind != JsonValueKind.Array || values.GetArrayLength() > 10000) throw new ArgumentException("Invalid drop targets.");
        var targets = new List<AssetDropTarget>();
        foreach (var item in values.EnumerateArray())
        {
            var target = Parse<AssetDestination>(item);
            if (target.Kind is not ("folder" or "trash" or "favorite" or "unfiled") || (target.Kind == "folder" && string.IsNullOrWhiteSpace(target.FolderId))) continue;
            var b = item.GetProperty("bounds"); var x = b.GetProperty("x").GetDouble(); var y = b.GetProperty("y").GetDouble(); var width = b.GetProperty("width").GetDouble(); var height = b.GetProperty("height").GetDouble();
            if (!double.IsFinite(x) || !double.IsFinite(y) || !double.IsFinite(width) || !double.IsFinite(height) || width <= 0 || height <= 0 || width > 100000 || height > 100000) continue;
            targets.Add(new(target, new Rect(x, y, width, height)));
        }
        _dropTargets = targets.ToArray();
    }
    public bool HandleInternalDrag(System.Windows.DragEventArgs args, bool drop = false)
    {
        if (!args.Data.GetDataPresent(InternalDragFormat, false)) return false;
        if (_dragToken is null || args.Data.GetData(InternalDragFormat, false) as string != _dragToken)
        { args.Effects = DragDropEffects.None; args.Handled = true; return true; }
        // CompositionControl receives OLE through WPF; regular WebView receives DOM drops.
        // Both report intent to the same UI operation; only assets.update mutates metadata.
        var target = _webSurface is null ? null : _dropTargets.FirstOrDefault(item => item.Bounds.Contains(args.GetPosition(_webSurface)))?.Destination;
        var over = target is not null || (_webSurface is not null && !_trashBounds.IsEmpty && _trashBounds.Contains(args.GetPosition(_webSurface)));
        DragTraceForVerify = $"drop={drop}, over={over}, point={args.GetPosition(_webSurface)}, target={_trashBounds}";
        args.Effects = over ? DragDropEffects.Move : DragDropEffects.None; args.Handled = true;
        SetDropHover(target ?? (over ? new AssetDestination("trash") : null));
        if (drop) { _trashRequested = over && (target is null || target.Kind == "trash"); _dropTarget = target ?? (over ? new AssetDestination("trash") : null); }
        return true;
    }
    public void ClearDragHover() => SetDropHover(null);
    private void SetDropHover(AssetDestination? target)
    {
        SetTrashHover(target?.Kind == "trash");
        if (_hoverTarget == target) return;
        _hoverTarget = target;
        if (!_disposed) _ = _bridge.PostEventAsync("assets.dragTargetHover", new { dropTarget = target });
    }
    private void SetTrashHover(bool hovered)
    {
        if (_trashHovered == hovered) return;
        _trashHovered = hovered;
        if (!_disposed) _ = _bridge.PostEventAsync("assets.trashHover", new { hovered });
    }
    public async Task ImportDropAsync(System.Windows.IDataObject data)
    {
        try
        {
            await ImportPayloadAsync(AssetDropPayload.Capture(data, _store.Root));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException or HttpRequestException or OperationCanceledException or System.Runtime.InteropServices.COMException)
        { await _bridge.PostEventAsync("assets.dropUnsupported", new { message = "取り込みを完了できませんでした。元ファイルと取り込み途中のファイルは保持されています。" }); }
    }
    internal async Task<string> ImportPayloadAsync(AssetDropPayload payload, string? folderId = null)
    {
        if (_import is not null) throw new InvalidOperationException("保存中です。完了してから追加してください。");
        payload = await payload.MaterializeAsync();
        if (!await ImportPathsAsync(payload.Paths, folderId, waitForCompletion: true, internet: payload.Internet)) throw new OperationCanceledException("取り込みを中止しました。元データと保存待ちファイルは保持しています。");
        if (_failed > 0 || _restoreAvailable > 0 || _skipped > 0)
            throw new IOException($"保存 {_completed}件。取り込めなかった項目があります。元データと保存待ちファイルは保持しています。");
        if (payload.Stage is not null) await AssetRecycle.MoveAsync(payload.Stage);
        return $"保存 {_completed}件・重複 {_duplicates}件";
    }
    internal Task ShowDropErrorAsync() => _bridge.PostEventAsync("assets.dropUnsupported", new { message = "取り込みを完了できませんでした。元データと保存待ちファイルは保持しています。" });
    private async Task<object?> BackupAsync(JsonElement? p)
    {
        using var pin = PinForDialog();
        var picker = new Microsoft.Win32.OpenFolderDialog { Title = Text(p, "mode") == "restore" ? "バックアップを復元（空ライブラリのみ）" : "バックアップの保存先" };
        if (picker.ShowDialog(_owner) != true) return new { cancelled = true };
        if (Text(p, "mode") == "restore")
        {
            var active = await _store.QueryAsync(new AssetQuery(View: "recent", Limit: 1));
            var trash = await _store.QueryAsync(new AssetQuery(View: "trash", Limit: 1));
            if (active.Total + trash.Total + active.Folders.Length + active.Tags.Length + active.Searches.Length > 0)
            {
                if (MessageBox.Show(_owner, "現在のライブラリを日時付きのフォルダへ退避して復元します。今の原本を削除せず、バックアップの検証が成功した後に切り替えます。続けますか？", "バックアップを復元", MessageBoxButton.OKCancel) != MessageBoxResult.OK) return new { cancelled = true };
                EndPreview(); await _store.ReplaceFromBackupAsync(picker.FolderName);
            }
            else await _store.RestoreAsync(picker.FolderName);
        }
        else { var result = await _store.ExportAsync(Path.Combine(picker.FolderName, $"HoverPocket-backup-{DateTime.Now:yyyyMMdd-HHmmss}")); return new { ok = true, result.AssetCount, result.ExcludedPending }; }
        return new { ok = true };
    }
    private void OnChanged() { _preparedDrag = null; if (!_disposed) _ = _bridge.PostEventAsync("assets.changed", new { }); }
    private IDisposable PinForDialog() { _layout(_previewLayout with { Active = true, PinOnly = true }); return new DialogPin(() => { if (!_disposed) _layout(_previewLayout); }); }
    public void Dispose() { _disposed = true; _inlineEditor?.Cancel(); _thumbnails.Cancel(); _thumbnails.Dispose(); _playback.Release(this); _store.Changed -= OnChanged; _mediaServer.Dispose(); _web.ContainsFullScreenElementChanged -= OnBrowserFullscreenChanged; _preview?.Cancel(); _preview?.Dispose(); _selected = null; _lease = null; }
}

internal sealed class DialogPin(Action release) : IDisposable { public void Dispose() => release(); }
