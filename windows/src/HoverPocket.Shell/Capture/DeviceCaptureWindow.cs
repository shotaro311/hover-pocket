using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using HoverPocket.Assets;
using HoverPocket.Shell.Windows;
using HoverPocket.Shell.Interop;
using Button = System.Windows.Controls.Button;
using TextBlock = System.Windows.Controls.TextBlock;
using ListBox = System.Windows.Controls.ListBox;
using Image = System.Windows.Controls.Image;
using Brushes = System.Windows.Media.Brushes;
using Color = System.Windows.Media.Color;

namespace HoverPocket.Shell.Capture;

internal sealed class DeviceCaptureWindow : Window
{
    private readonly DeviceCaptureController _controller;
    private readonly ListBox _cameras = Devices(), _microphones = Devices(), _folders = Devices();
    private readonly Image _preview = new() { Height = 200, Stretch = Stretch.Uniform, Margin = new Thickness(0, 12, 0, 12) };
    private readonly TextBlock _status = new() { Foreground = Brushes.LightGray, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(3, 10, 3, 4) };
    private readonly TextBlock _time = new() { Foreground = Brushes.LightCoral, FontSize = 16 };
    private readonly Button _start = new(), _stop = new() { Content = "■ 停止して保存" }, _previewButton = new() { Content = "カメラを表示" };
    private readonly WrapPanel _modes = new();
    private string _kind = "cameraPhoto"; private string? _folder;
    private bool _closing, _loaded;
    internal DeviceCaptureWindow(DeviceCaptureController controller)
    {
        _controller = controller; Title = "HoverPocket — カメラ・録音"; Width = 620; Height = Math.Min(730, SystemParameters.WorkArea.Height * .88); MinWidth = 440; MinHeight = 400;
        WindowStartupLocation = WindowStartupLocation.CenterScreen; Background = new SolidColorBrush(Color.FromRgb(12, 14, 18)); Foreground = Brushes.White;
        Resources.MergedDictionaries.Add(new ResourceDictionary { Source = new Uri("/HoverPocket.Shell;component/Capture/EditorTheme.xaml", UriKind.Relative) });
        var body = new StackPanel { Margin = new Thickness(18) }; Content = new ScrollViewer { Content = body, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        body.Children.Add(new TextBlock { Text = "ライブラリへ撮影・録音", FontSize = 20, Foreground = Brushes.White, Margin = new Thickness(3, 0, 3, 12) });
        foreach (var (kind, label) in new[] { ("cameraPhoto", "写真"), ("cameraVideo", "カメラ動画"), ("audio", "音声録音") })
        { var button = new Button { Content = label, Tag = kind }; button.Click += (_, _) => { Select(kind, _folder, true); _ = _controller.ReleasePreviewAsync(); }; _modes.Children.Add(button); }
        body.Children.Add(_modes); body.Children.Add(_preview);
        Add(body, "カメラ", _cameras); Add(body, "マイク（動画では音声なしも選べます）", _microphones); Add(body, "保存先", _folders);
        _cameras.SelectionChanged += (_, _) => { _preview.Source = null; _ = _controller.ReleasePreviewAsync(); Update(_controller.Busy, _controller.Recording, TimeSpan.Zero, _controller.Status); };
        _folders.SelectionChanged += (_, _) => _folder = (_folders.SelectedItem as Category)?.Id;
        _microphones.SelectionChanged += (_, _) => Update(_controller.Busy, _controller.Recording, TimeSpan.Zero, _controller.Status);
        var actions = new WrapPanel(); actions.Children.Add(_previewButton); actions.Children.Add(_start); actions.Children.Add(_stop); body.Children.Add(actions); body.Children.Add(_time); body.Children.Add(_status);
        _previewButton.Click += async (_, _) => await controller.PreviewAsync(Options());
        _start.Click += async (_, _) => await controller.CaptureAsync(Options());
        _stop.Click += async (_, _) => await controller.StopAsync();
        var recovery = new WrapPanel(); body.Children.Add(recovery);
        var retry = new Button { Content = "保存待ちを再試行" }; retry.Click += async (_, _) => await controller.RetryAsync(); recovery.Children.Add(retry);
        var pending = new Button { Content = "保存待ちフォルダ" }; pending.Click += (_, _) => { try { controller.OpenPending(); } catch { _status.Text = "保存待ちフォルダを開けませんでした。"; } }; recovery.Children.Add(pending);
        Closing += (_, args) => { if (_closing) return; args.Cancel = true; Hide(); if (!controller.Recording) { _loaded = false; _ = controller.ReleasePreviewAsync(); } };
    }
    private static ListBox Devices() => new() { DisplayMemberPath = "Name", Height = 72, Background = new SolidColorBrush(Color.FromRgb(25, 28, 34)), Foreground = Brushes.White, BorderBrush = new SolidColorBrush(Color.FromRgb(53, 60, 72)), Margin = new Thickness(3, 4, 3, 10) };
    private static void Add(StackPanel panel, string label, UIElement element) { panel.Children.Add(new TextBlock { Text = label, Foreground = Brushes.LightGray, Margin = new Thickness(3, 4, 3, 0) }); panel.Children.Add(element); }
    internal void Select(string kind, string? folder, bool change)
    {
        if (!change) return; _kind = kind; _folder = folder;
        foreach (Button button in _modes.Children) button.Opacity = (string)button.Tag == kind ? 1 : .5;
        _preview.Visibility = kind == "audio" ? Visibility.Collapsed : Visibility.Visible;
        _cameras.IsEnabled = kind != "audio"; _previewButton.Visibility = kind == "audio" ? Visibility.Collapsed : Visibility.Visible;
        _microphones.IsEnabled = kind != "cameraPhoto";
        if (kind == "audio" && _microphones.SelectedIndex <= 0 && _microphones.Items.Count > 1) _microphones.SelectedIndex = 1;
        _start.Content = kind == "cameraPhoto" ? "撮影して保存" : "● 収録を開始";
        if (_folders.ItemsSource is Category[] folders) _folders.SelectedItem = folders.FirstOrDefault(value => value.Id == folder) ?? folders.FirstOrDefault();
        Update(_controller.Busy, _controller.Recording, TimeSpan.Zero, _controller.Status);
    }
    internal async Task LoadDevicesAsync(AssetStore store)
    {
        if (_loaded || _controller.Recording) return;
        try
        {
            var devices = await DeviceCaptureController.DevicesAsync(); var page = await store.QueryAsync(new(Limit: 1));
            _cameras.ItemsSource = devices.Cameras; _cameras.SelectedIndex = devices.Cameras.Length > 0 ? 0 : -1;
            _microphones.ItemsSource = new[] { new CaptureDevice("", "音声なし") }.Concat(devices.Microphones).ToArray(); _microphones.SelectedIndex = _kind == "audio" && devices.Microphones.Length > 0 ? 1 : 0;
            _folders.ItemsSource = new[] { new Category("", "未分類", null) }.Concat(page.Folders).ToArray(); Select(_kind, _folder, true);
            _loaded = true; Update(false, false, TimeSpan.Zero, devices.Cameras.Length == 0 && _kind != "audio" ? "カメラが見つかりません。接続してから画面を開き直してください。" : _controller.Status);
        }
        catch { _status.Text = "デバイスを読み込めませんでした。接続とWindowsのプライバシー設定を確認してください。"; }
    }
    private DeviceCaptureOptions Options() => new(_kind, (_cameras.SelectedItem as CaptureDevice)?.Id, _kind == "cameraPhoto" ? null : NullIfEmpty((_microphones.SelectedItem as CaptureDevice)?.Id), NullIfEmpty(_folder));
    private static string? NullIfEmpty(string? value) => string.IsNullOrEmpty(value) ? null : value;
    internal void SetPreview(BitmapSource image) => _preview.Source = image;
    internal void Update(bool busy, bool recording, TimeSpan duration, string status)
    {
        _status.Text = status; _time.Text = recording ? "● " + duration.ToString(@"hh\:mm\:ss") : "";
        _modes.IsEnabled = _folders.IsEnabled = !busy && !recording;
        _cameras.IsEnabled = !busy && !recording && _kind != "audio"; _microphones.IsEnabled = !busy && !recording && _kind != "cameraPhoto";
        _start.IsEnabled = !busy && !recording && (_kind == "audio" ? _microphones.SelectedIndex > 0 : _cameras.SelectedIndex >= 0);
        _stop.IsEnabled = recording && !busy; _previewButton.IsEnabled = !busy && !recording && _cameras.SelectedIndex >= 0;
        if (!recording && !IsVisible) _loaded = false;
    }
    internal void CloseForShutdown() { _closing = true; Close(); }
}

internal sealed class DeviceRecordingBadge : NoActivateWindow
{
    private readonly TextBlock _time = new() { Foreground = Brushes.LightCoral, Margin = new Thickness(12, 10, 8, 8), VerticalAlignment = VerticalAlignment.Center };
    private readonly Button _stop;
    internal DeviceRecordingBadge(Func<Task> stop, Action show)
    {
        Width = 285; Height = 46;
        Resources.MergedDictionaries.Add(new ResourceDictionary { Source = new Uri("/HoverPocket.Shell;component/Capture/EditorTheme.xaml", UriKind.Relative) });
        var row = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal, Background = new SolidColorBrush(Color.FromRgb(18, 20, 26)) };
        row.Children.Add(_time); _stop = new Button { Content = "■ 停止" }; _stop.Click += async (_, _) => { _stop.IsEnabled = false; await stop(); }; row.Children.Add(_stop);
        var details = new Button { Content = "表示" }; details.Click += (_, _) => show(); row.Children.Add(details); Content = row;
    }
    internal void Update(TimeSpan duration, bool busy) { _time.Text = "● " + duration.ToString(@"hh\:mm\:ss"); _stop.IsEnabled = !busy; }
    internal void ShowAtTop()
    {
        EnsureHandle(); var screen = System.Windows.Forms.Screen.FromPoint(System.Windows.Forms.Cursor.Position).Bounds; var scale = NativeMethods.GetScaleForWindow(Hwnd);
        NativeMethods.SetWindowBoundsNoActivate(Hwnd, screen.Left + (screen.Width - (int)(Width * scale)) / 2, screen.Top + 12, (int)(Width * scale), (int)(Height * scale), true); Update(TimeSpan.Zero, false); ShowNoActivate();
    }
}
