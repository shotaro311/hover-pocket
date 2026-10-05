using System.Windows;
using System.Windows.Interop;
using HoverPocket.Shell.Bridge;
using HoverPocket.Shell.Providers.Assets;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;

namespace HoverPocket.Shell.Windows;

internal sealed class AssetOrganizerWindow : Window
{
    private readonly WebView2 _web = new();
    private AssetPaneController? _pane;
    private Rect _restore;
    private bool _fullscreen;
    private bool _closed;
    internal CoreWebView2? WebViewForVerify => _web.CoreWebView2;
    internal FrameworkElement WebSurfaceForVerify => _web;
    internal string DragTraceForVerify => _pane?.DragTraceForVerify ?? "no-pane";
    internal string DragStateForVerify => _pane?.DragStateForVerify ?? "no-pane";
    internal bool InternalAssetDragForVerify => _pane?.InternalDragForVerify == true;
    public AssetOrganizerWindow(PanelBridgeController bridge, string dataRoot)
    {
        Title = bridge.CurrentSettings.Language == HoverPocket.Shell.Configuration.AppLanguage.English ? "HoverPocket — Assets" : "HoverPocket — 素材";
        Width = Math.Min(1100, SystemParameters.WorkArea.Width * .9); Height = Math.Min(720, SystemParameters.WorkArea.Height * .9); MinWidth = 480; MinHeight = 360;
        Background = new System.Windows.Media.SolidColorBrush(System.Windows.Media.Color.FromRgb(4, 4, 6));
        var host = new System.Windows.Controls.Grid(); host.Children.Add(_web); Content = host; WindowStartupLocation = WindowStartupLocation.CenterScreen;
        _web.CreationProperties = new CoreWebView2CreationProperties { UserDataFolder = Path.Combine(dataRoot, "AssetWebView2") };
        Loaded += async (_, _) =>
        {
            try
            {
                await _web.EnsureCoreWebView2Async();
                if (_closed) return;
                _web.CoreWebView2.Settings.AreDevToolsEnabled = false;
                _web.CoreWebView2.Settings.AreDefaultContextMenusEnabled = false;
                _web.CoreWebView2.Settings.IsStatusBarEnabled = false;
                _web.CoreWebView2.NewWindowRequested += (_, args) => args.Handled = true;
                _web.CoreWebView2.PermissionRequested += (_, args) => args.State = CoreWebView2PermissionState.Deny;
                _web.CoreWebView2.NavigationStarting += (_, args) => { if (args.Uri != "https://app.hoverpocket.local/library.html") args.Cancel = true; };
                _web.CoreWebView2.SetVirtualHostNameToFolderMapping("app.hoverpocket.local", Path.Combine(AppContext.BaseDirectory, "ui"), CoreWebView2HostResourceAccessKind.DenyCors);
                var dispatcher = new BridgeDispatcher(async json =>
                {
                    if (_closed || Dispatcher.HasShutdownStarted) return;
                    await Dispatcher.InvokeAsync(() => { if (!_closed && _web.CoreWebView2 is not null) _web.CoreWebView2.PostWebMessageAsJson(json); }).Task;
                });
                _pane = new(bridge.AssetLibrary, this, dispatcher, _web.CoreWebView2, ApplyLayout, () => "assets", bridge.AssetPlayback, capture: (kind, folder) => bridge.AssetCaptureRequested?.Invoke(kind, folder) ?? Task.CompletedTask, webSurface: _web);
                dispatcher.Register("panel.beginTextInput", (_, _) => Task.FromResult<object?>(new { ok = true }));
                dispatcher.Register("panel.endTextInput", (_, _) => Task.FromResult<object?>(new { ok = true }));
                dispatcher.Register("assets.language", (_, _) => Task.FromResult<object?>(new { language = bridge.CurrentSettings.Language == HoverPocket.Shell.Configuration.AppLanguage.English ? "en" : "ja" }));
                _web.CoreWebView2.WebMessageReceived += async (_, args) => await dispatcher.HandleRawMessageAsync(args.TryGetWebMessageAsString());
                _web.CoreWebView2.Navigate("https://app.hoverpocket.local/library.html");
            }
            catch (Exception ex) when (ex is InvalidOperationException or System.Runtime.InteropServices.COMException)
            { System.Windows.MessageBox.Show(this, "素材画面を起動できませんでした。WebView2の状態を確認してください。", "HoverPocket"); }
        };
        Closing += (_, args) => { if (!args.Cancel) { _closed = true; _pane?.Dispose(); _web.Dispose(); } };
        AllowDrop = true;
        System.Windows.DragEventHandler assetDragOver = (_, args) => { if (_pane?.HandleInternalDrag(args) == true) return; if (args.Data.GetDataPresent(System.Windows.DataFormats.FileDrop)) { args.Effects = System.Windows.DragDropEffects.Copy; args.Handled = true; } };
        PreviewDragEnter += assetDragOver; PreviewDragOver += assetDragOver;
        PreviewDragLeave += (_, _) => _pane?.ClearDragHover();
        PreviewDrop += async (_, args) => { if (_pane?.HandleInternalDrag(args, drop: true) == true) return; if (_pane is not null && args.Data.GetDataPresent(System.Windows.DataFormats.FileDrop)) { args.Handled = true; await _pane.ImportPathsAsync((string[])args.Data.GetData(System.Windows.DataFormats.FileDrop)); } };
    }
    internal async Task<bool> ShowForVoiceAsync(string? assetId, CancellationToken token)
    {
        var deadline = DateTime.UtcNow.AddSeconds(20);
        while (!_closed && DateTime.UtcNow < deadline)
        {
            token.ThrowIfCancellationRequested();
            if (_web.CoreWebView2 is { } web && await web.ExecuteScriptAsync("!!window.hpLibrary") == "true")
            {
                if (assetId is null) return IsVisible;
                var nonce = System.Text.Json.JsonSerializer.Serialize(Guid.NewGuid().ToString("N"));
                var id = System.Text.Json.JsonSerializer.Serialize(assetId);
                await web.ExecuteScriptAsync($"window.hpVoicePreview=null; window.hpLibrary.showAsset({id}).then(ok=>window.hpVoicePreview={{nonce:{nonce},ok}},()=>window.hpVoicePreview={{nonce:{nonce},ok:false}})");
                while (!_closed && DateTime.UtcNow < deadline)
                {
                    token.ThrowIfCancellationRequested();
                    var status = await web.ExecuteScriptAsync($"window.hpVoicePreview?.nonce==={nonce} ? window.hpVoicePreview.ok : null");
                    if (status is "true" or "false") return status == "true" && IsVisible;
                    await Task.Delay(50, token);
                }
                return false;
            }
            await Task.Delay(50, token);
        }
        return false;
    }
    private void ApplyLayout(AssetPreviewLayout layout)
    {
        if (_fullscreen == layout.Fullscreen) return;
        _fullscreen = layout.Fullscreen;
        if (_fullscreen)
        {
            _restore = new Rect(Left, Top, ActualWidth, ActualHeight);
            var screen = System.Windows.Forms.Screen.FromHandle(new WindowInteropHelper(this).Handle);
            var scale = System.Windows.Media.VisualTreeHelper.GetDpi(this);
            WindowState = WindowState.Normal; WindowStyle = WindowStyle.None; ResizeMode = ResizeMode.NoResize;
            Left = screen.Bounds.Left / scale.DpiScaleX; Top = screen.Bounds.Top / scale.DpiScaleY;
            Width = screen.Bounds.Width / scale.DpiScaleX; Height = screen.Bounds.Height / scale.DpiScaleY;
        }
        else { WindowStyle = WindowStyle.SingleBorderWindow; ResizeMode = ResizeMode.CanResize; Left = _restore.Left; Top = _restore.Top; Width = _restore.Width; Height = _restore.Height; }
    }
}
