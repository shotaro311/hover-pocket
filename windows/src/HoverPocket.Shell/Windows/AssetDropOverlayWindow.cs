using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using HoverPocket.Assets;
using HoverPocket.Shell.Interop;
using HoverPocket.Shell.Providers.Assets;
using Border = System.Windows.Controls.Border;
using TextBlock = System.Windows.Controls.TextBlock;
using Brushes = System.Windows.Media.Brushes;
using Color = System.Windows.Media.Color;

namespace HoverPocket.Shell.Windows;

internal sealed class AssetDropOverlayWindow : NoActivateWindow
{
    private readonly AssetStore _store;
    private readonly Func<AssetDropPayload, string?, Task<string>> _import;
    private readonly StackPanel _items = new();
    private readonly TextBlock _status = new() { Text = "↓ ライブラリへ保存", Foreground = Brushes.White, Margin = new Thickness(12), FontSize = 13 };
    private readonly DispatcherTimer _hide = new() { Interval = TimeSpan.FromMilliseconds(350) };
    private readonly List<(Border Row, string? Folder)> _targets = [];
    private readonly List<string> _recent = [];
    private AssetNativeDropTarget? _native;
    private bool _busy, _expanded;
    private int _left, _top; private double _scale = 1;
    internal bool BusyForVerify => _busy;
    internal string StatusForVerify => _status.Text;
    internal string TraceForVerify => _native?.Trace ?? "uninitialized";
    internal AssetDropOverlayWindow(AssetStore store, Func<AssetDropPayload, string?, Task<string>> import) : base(allowsTransparency: false)
    {
        _store = store; _import = import; Width = 320; Height = 44;
        var body = new StackPanel(); body.Children.Add(_status); body.Children.Add(_items);
        Content = new Border { Background = new SolidColorBrush(Color.FromRgb(18, 20, 25)), BorderBrush = new SolidColorBrush(Color.FromRgb(90, 115, 155)), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(0, 0, 12, 12), Child = body };
        _hide.Tick += (_, _) => { _hide.Stop(); if (!_busy) Hide(); };
        Closed += (_, _) => { _hide.Stop(); _native?.Dispose(); _native = null; };
    }
    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        _native = new(Hwnd, Hover, Leave, (data, native, point) =>
        {
            if (_busy) return;
            var folder = Target(point)?.Folder;
            var payload = AssetDropPayload.Capture(data, _store.Root, native);
            _ = ImportAsync(payload, folder);
        }, ex => ShowFailure(ex.Message));
    }
    internal void ShowAt(AccessSurfaceWindow surface)
    {
        if (_busy || IsVisible) return;
        _expanded = false; _items.Children.Clear(); _targets.Clear(); _status.Text = "↓ ライブラリへ保存";
        _scale = VisualTreeHelper.GetDpi(surface).DpiScaleX;
        var anchor = surface.PointToScreen(new System.Windows.Point(surface.ActualWidth / 2, 0));
        var screen = System.Windows.Forms.Screen.FromPoint(new System.Drawing.Point((int)anchor.X, (int)anchor.Y)).Bounds;
        _left = Math.Clamp((int)(anchor.X - Width * _scale / 2), screen.Left, Math.Max(screen.Left, screen.Right - (int)(Width * _scale)));
        _top = screen.Top; EnsureHandle(); Resize(44); ShowNoActivate(); _hide.Interval = TimeSpan.FromSeconds(1.5); _hide.Start();
        _ = LoadFoldersAsync();
    }
    private async Task LoadFoldersAsync()
    {
        try
        {
            var page = await _store.QueryAsync(new(Limit: 100));
            _targets.Clear(); _items.Children.Clear(); AddTarget("未分類へ保存", null);
            var order = _recent.Concat(page.Items.SelectMany(item => item.FolderIds)).Concat(page.Folders.Select(folder => folder.Id)).Distinct();
            foreach (var id in order.Take(6)) if (page.Folders.FirstOrDefault(folder => folder.Id == id) is { } folder) AddTarget("▸ " + folder.Name, id);
            if (_expanded) Resize(44 + _targets.Count * 38);
        }
        catch { ShowFailure("保存先を読み込めませんでした。もう一度ドロップしてください。"); }
    }
    private void AddTarget(string text, string? folder)
    {
        var row = new Border { Height = 38, Margin = new Thickness(6, 0, 6, 0), CornerRadius = new CornerRadius(6), Background = Brushes.Transparent, Child = new TextBlock { Text = text, Foreground = Brushes.White, Margin = new Thickness(10, 8, 10, 8), TextTrimming = TextTrimming.CharacterEllipsis } };
        _targets.Add((row, folder)); _items.Children.Add(row);
    }
    private void Resize(double height) { Height = height; NativeMethods.SetWindowBoundsNoActivate(Hwnd, _left, _top, (int)(Width * _scale), (int)(Height * _scale), true); }
    private (Border Row, string? Folder)? Target(AssetDragPoint point)
    {
        foreach (var target in _targets)
        {
            var p = target.Row.PointFromScreen(new System.Windows.Point(point.X, point.Y));
            if (p.X >= 0 && p.X < target.Row.ActualWidth && p.Y >= 0 && p.Y < target.Row.ActualHeight) return target;
        }
        return null;
    }
    private bool Hover(AssetDragPoint point)
    {
        _hide.Stop(); if (_busy) return false;
        if (!_expanded) { _expanded = true; Resize(44 + _targets.Count * 38); }
        var selected = Target(point);
        foreach (var target in _targets) target.Row.Background = selected?.Row == target.Row ? new SolidColorBrush(Color.FromRgb(47, 66, 99)) : Brushes.Transparent;
        return true;
    }
    private void Leave() { _hide.Interval = TimeSpan.FromMilliseconds(350); _hide.Start(); }
    internal void ShowFailure(string message) { _status.Text = message; _hide.Interval = TimeSpan.FromSeconds(6); _hide.Start(); }
    internal async Task ImportAsync(AssetDropPayload payload, string? folder)
    {
        if (_busy) return;
        _busy = true; _hide.Stop(); _status.Text = "ライブラリへ保存しています…";
        try
        {
            _status.Text = await _import(payload, folder);
            if (folder is not null) { _recent.Remove(folder); _recent.Insert(0, folder); if (_recent.Count > 6) _recent.RemoveAt(6); }
            _hide.Interval = TimeSpan.FromSeconds(3);
        }
        catch (Exception ex) { _status.Text = ex is ArgumentException or IOException or InvalidOperationException ? ex.Message : "保存できませんでした。元のファイルと保存待ちのデータは保持しています。"; _hide.Interval = TimeSpan.FromSeconds(6); }
        finally { _busy = false; _hide.Start(); }
    }
}
