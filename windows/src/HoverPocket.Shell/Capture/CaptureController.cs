using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using HoverPocket.Assets;
using HoverPocket.Shell.Providers.Assets;
using Windows.Graphics.Capture;
using Button = System.Windows.Controls.Button;
using CheckBox = System.Windows.Controls.CheckBox;
using TextBox = System.Windows.Controls.TextBox;
using ComboBox = System.Windows.Controls.ComboBox;
using Panel = System.Windows.Controls.Panel;
using Brushes = System.Windows.Media.Brushes;

namespace HoverPocket.Shell.Capture;

internal sealed record CapturePreferences(string ScreenshotKey = "Ctrl+Alt+S", string RecordingKey = "Ctrl+Alt+R", bool SystemAudio = true, bool Microphone = true, string? FolderId = null, bool OpenEditorAfterScreenshot = true, int ScreenshotToastSeconds = 5);

internal sealed class CaptureController : IDisposable
{
    private readonly AssetStore _store;
    private readonly CaptureFiles _files;
    private readonly CaptureHotkeys _hotkeys;
    private readonly string _preferencesPath;
    private readonly DispatcherTimer _clock = new() { Interval = TimeSpan.FromSeconds(1) };
    private readonly Func<Task> _hideShell;
    private readonly Action _restoreShell;
    private readonly Action _openLibrary;
    private CapturePreferences _preferences = new();
    private CaptureWindow? _window;
    private ScreenshotToastWindow? _toast;
    internal ScreenshotToastWindow? ToastForVerify => _toast;
    private ScreenRecorder? _recorder;
    private DeviceCaptureController? _deviceCapture;
    private Task? _finishRecording;
    private string? _recordingStage;
    private bool _busy, _disposed;
    private string _status = "撮影と収録の準備ができています。";
    public bool Recording => _recorder is not null || _deviceCapture?.Recording == true;
    public bool Busy => _busy || _deviceCapture?.Busy == true;
    public string Status => _status;
    internal CapturePreferences? WindowPreferencesForVerify => _window?.Preferences;
    internal bool SettingsVisibleForVerify => _window?.IsVisible == true;
    internal nint RecordingOwnerForVerify { get; private set; }
    public event Action? StateChanged;
    public event Action<string>? RecordingError;
    public CaptureController(AssetStore store, string settingsRoot, Func<Task> hideShell, Action restoreShell, Action openLibrary)
    {
        _store = store; _files = new(store); _hideShell = hideShell; _restoreShell = restoreShell; _openLibrary = openLibrary;
        _preferencesPath = Path.Combine(settingsRoot, "capture-settings.json");
        try { if (File.Exists(_preferencesPath)) _preferences = JsonSerializer.Deserialize<CapturePreferences>(File.ReadAllText(_preferencesPath)) ?? new(); }
        catch (Exception ex) when (ex is IOException or JsonException or UnauthorizedAccessException) { _status = "撮影設定を読めませんでした。既定値で開始します。"; }
        if (_preferences.ScreenshotToastSeconds is < 0 or > 30) _preferences = _preferences with { ScreenshotToastSeconds = 5 };
        _hotkeys = new(record => { if (record) _ = ToggleRecordingAsync(); else _ = ScreenshotAsync(); });
        try { _status = _hotkeys.Apply(_preferences.ScreenshotKey, _preferences.RecordingKey); }
        catch (ArgumentException) { _preferences = new(); _status = _hotkeys.Apply(_preferences.ScreenshotKey, _preferences.RecordingKey); }
        _clock.Tick += (_, _) => Tick();
    }
    public void Open(string? folder = null, bool useCurrentFolder = false)
    {
        if (_disposed) return;
        if (_window is null)
        {
            _window = new CaptureWindow(this, _preferences with { FolderId = useCurrentFolder || folder is not null ? folder : _preferences.FolderId }, _status);
            _window.Closed += (_, _) => _window = null;
            _window.Update(_busy, Recording, _recorder?.Duration ?? TimeSpan.Zero, _status);
            _window.Show(); _ = LoadFoldersAsync();
        }
        else { _window.Show(); _window.Activate(); if (useCurrentFolder || folder is not null) _window.SelectFolder(folder); }
    }
    private async Task LoadFoldersAsync()
    {
        try { var page = await _store.QueryAsync(new(Limit: 1)); _window?.LoadFolders(page.Folders); }
        catch (Exception ex) { Report("素材ライブラリを開けません: " + ex.Message); }
    }
    private void Report(string message) { _status = message; _window?.Update(_busy, Recording, _recorder?.Duration ?? TimeSpan.Zero, message); StateChanged?.Invoke(); }
    public void SavePreferences(CapturePreferences preferences)
    {
        if (preferences.ScreenshotToastSeconds is < 0 or > 30) throw new ArgumentOutOfRangeException(nameof(preferences), "通知時間は0〜30秒で指定してください。");
        var status = _hotkeys.Apply(preferences.ScreenshotKey, preferences.RecordingKey);
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_preferencesPath)!);
            var temporary = _preferencesPath + ".tmp";
            using (var output = new FileStream(temporary, FileMode.Create, FileAccess.Write, FileShare.None)) { JsonSerializer.Serialize(output, preferences); output.Flush(true); }
            File.Move(temporary, _preferencesPath, true); _preferences = preferences; Report(status);
        }
        catch { _hotkeys.Apply(_preferences.ScreenshotKey, _preferences.RecordingKey); throw; }
    }
    public Task FromLibraryAsync(string kind, string? folder)
    {
        if (kind is "cameraPhoto" or "cameraVideo" or "audio")
        {
            if (_busy || _recorder is not null) throw new InvalidOperationException("画面収録を終了してからカメラ・録音を開いてください。");
            if (_deviceCapture is null) { _deviceCapture = new(_store); _deviceCapture.StateChanged += () => Report(_deviceCapture.Status); }
            _deviceCapture.Open(kind, folder); return Task.CompletedTask;
        }
        if (kind == "screenshot") return ScreenshotAsync(folderId: folder, useCurrentFolder: true);
        if (kind == "recording") return ToggleRecordingAsync(folderId: folder, useCurrentFolder: true);
        if (kind != "settings") throw new ArgumentException("Unknown capture action.", nameof(kind));
        Open(folder, useCurrentFolder: true); return Task.CompletedTask;
    }
    public async Task ScreenshotAsync(Func<Task<BitmapSource?>>? selectForVerify = null, string? folderId = null, bool useCurrentFolder = false)
    {
        if (Busy || Recording || _disposed) return;
        var options = _window?.Preferences ?? _preferences;
        if (useCurrentFolder) options = options with { FolderId = folderId };
        CloseToast();
        string? savedAsset = null;
        _window?.Hide(); _busy = true; Report("範囲を選択してください。");
        try
        {
            try
            {
                await _hideShell();
                if (selectForVerify is not null)
                {
                    var image = await selectForVerify();
                    if (image is null) { Report("撮影をキャンセルしました。"); return; }
                    savedAsset = await SaveScreenshotAsync(image, new(image, false), options.FolderId);
                }
                else
                {
                    await Task.Delay(160); var bounds = System.Windows.Forms.SystemInformation.VirtualScreen;
                    var bitmap = await Task.Run(() => ScreenshotSelectionWindow.CaptureDesktop(bounds));
                    var selection = new ScreenshotSelectionWindow(bitmap, bounds, async (original, edited) => { savedAsset = await SaveScreenshotAsync(original, edited, options.FolderId); });
                    selection.ShowDialog();
                    if (selection.Error is not null) throw new InvalidOperationException("選択画像を作成できませんでした。もう一度撮影してください。", selection.Error);
                    if (selection.Result is null) Report("撮影をキャンセルしました。");
                }
            }
            finally { _restoreShell(); }
            if (savedAsset is not null && options.ScreenshotToastSeconds > 0 && !_disposed)
                await ShowScreenshotToastAsync(savedAsset, options.ScreenshotToastSeconds);
        }
        catch (Exception ex) { Report("撮影・保存に失敗しました: " + ex.Message); }
        finally { _busy = false; if (!_disposed) Report(_status); }
    }
    private async Task<string?> SaveScreenshotAsync(BitmapSource image, EditedScreenshot result, string? folderId)
    {
        var stage = _files.CreateStage(); var name = $"スクリーンショット {DateTime.Now:yyyy-MM-dd HH-mm-ss}"; var paths = new List<string>();
        var edited = Path.Combine(stage, name + ".png"); await CaptureFiles.WritePngAsync(edited, result.Image); paths.Add(edited);
        if (result.KeepOriginal) { var original = Path.Combine(stage, name + " 元画像.png"); await CaptureFiles.WritePngAsync(original, image); paths.Add(original); }
        CaptureFiles.MarkComplete(stage, paths.ToArray(), folderId); var saved = await _files.ImportCompletedAsync(stage);
        Report($"スクリーンショットをライブラリへ保存しました（{saved.Length}件）。");
        return saved.FirstOrDefault();
    }
    private async Task ShowScreenshotToastAsync(string assetId, int seconds)
    {
        try
        {
            var path = await _store.CopyOutAsync(assetId);
            var thumbnail = await Task.Run(() => ScreenshotToastWindow.LoadThumbnail(path));
            if (_disposed) return;
            var toast = new ScreenshotToastWindow(path, thumbnail, TimeSpan.FromSeconds(seconds));
            _toast = toast;
            toast.Closed += (_, _) => { if (ReferenceEquals(_toast, toast)) _toast = null; };
            toast.ShowAtPointer();
        }
        catch (Exception ex) { Report("保存は完了しました。画像付き通知を表示できませんでした: " + ex.Message); }
    }
    private void CloseToast() { _toast?.Dismiss(); _toast = null; }
    public async Task ToggleRecordingAsync(Func<nint, Task<GraphicsCaptureItem?>>? pickForVerify = null, string? folderId = null, bool useCurrentFolder = false)
    {
        if (_disposed) return;
        if (Recording) { await StopRecordingAsync(); return; }
        if (Busy) return; CloseToast(); _busy = true; Report("収録対象の画面またはウィンドウを選択してください。");
        string? stage = null;
        try
        {
            var options = useCurrentFolder ? _preferences with { FolderId = folderId } : _preferences;
            GraphicsCaptureItem? item;
            // The system picker needs an active HWND. A one-pixel native owner gives
            // it focus without constructing or showing the settings window.
            var owner = new Window { Title = "HoverPocket — 画面収録", Width = 1, Height = 1, WindowStartupLocation = WindowStartupLocation.CenterScreen, Background = Brushes.Black, ShowInTaskbar = false, WindowStyle = WindowStyle.None, ResizeMode = ResizeMode.NoResize };
            try
            {
                await _hideShell();
                owner.Show();
                var handle = new WindowInteropHelper(owner).EnsureHandle();
                ExcludeFromCapture(handle);
                RecordingOwnerForVerify = handle;
                owner.Activate();
                Interop.NativeMethods.ActivateWindowForTextInput(handle);
                await Dispatcher.Yield(DispatcherPriority.ApplicationIdle);
                if (pickForVerify is not null) item = await pickForVerify(handle);
                else { var picker = new GraphicsCapturePicker(); WinRT.Interop.InitializeWithWindow.Initialize(picker, handle); item = await picker.PickSingleItemAsync(); }
            }
            finally { owner.Close(); RecordingOwnerForVerify = 0; _restoreShell(); }
            if (item is null) { Report("画面収録をキャンセルしました。"); return; }
            stage = _files.CreateStage(); var path = Path.Combine(stage, $"画面収録 {DateTime.Now:yyyy-MM-dd HH-mm-ss}.mp4");
            using (File.Create(path)) { }
            _recorder = await ScreenRecorder.StartAsync(item, path, options.SystemAudio, options.Microphone);
            _clock.Start();
            _recordingStage = stage;
            _finishRecording = FinishRecordingAsync(_recorder, stage, path, options.FolderId);
            Report("● 収録中。もう一度ショートカットを押すか「停止して保存」を押してください。");
        }
        catch (Exception ex) { if (stage is not null) await AssetRecycle.MoveAsync(stage); Report("収録を開始できません: " + ex.Message); RecordingError?.Invoke(_status); }
        finally { _busy = false; Report(_status); }
    }
    private async Task FinishRecordingAsync(ScreenRecorder recorder, string stage, string path, string? folder)
    {
        await Task.Yield();
        try
        {
            await recorder.Completion;
            recorder.Dispose();
            if (recorder.VideoFrames == 0) throw new IOException("収録できた映像がありません。");
            CaptureFiles.MarkComplete(stage, [path], folder); var saved = await _files.ImportCompletedAsync(stage);
            Report((recorder.StopReason is null ? "" : recorder.StopReason + " ") + $"画面収録をライブラリへ保存しました（{saved.Length}件）。");
        }
        catch (Exception ex) { Report("収録の完了・保存に失敗しました: " + ex.Message + " 保存待ちファイルを保持しています。"); RecordingError?.Invoke(_status); }
        finally { recorder.Dispose(); if (ReferenceEquals(_recorder, recorder)) _recorder = null; _clock.Stop(); _recordingStage = null; _busy = false; Report(_status); }
    }
    public async Task StopRecordingAsync()
    { if (_deviceCapture is not null) await _deviceCapture.StopAsync(); if (_recorder is null) return; _busy = true; _recorder.Stop(); Report("収録を終了し、ライブラリへ保存しています…"); if (_finishRecording is not null) await _finishRecording; }
    public async Task RetryAsync()
    {
        if (Busy || Recording) return;
        _busy = true;
        try
        {
            var result = await _files.RetryPendingAsync();
            Report(result.Failed == 0 ? $"保存待ちの素材を取り込みました（{result.Saved}件）。"
                : $"{result.Saved}件を保存しました。{result.Failed}件の保存待ちを保持しています。{result.Error}");
        }
        catch (Exception ex) { Report(ex.Message); }
        finally { _busy = false; Report(_status); }
    }
    public void OpenLibrary() => _openLibrary();
    public void OpenPendingFolder()
    { var path = Path.Combine(_store.Root, "staging"); Directory.CreateDirectory(path); System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(path) { UseShellExecute = true }); }
    internal void Tick()
    {
        var recorder = _recorder; if (recorder is null) return;
        _window?.Update(_busy, true, recorder.Duration, _status);
        try { if (_recordingStage is not null && new DriveInfo(Path.GetPathRoot(_recordingStage)!).AvailableFreeSpace < 512L * 1024 * 1024) recorder.Stop("空き容量が少なくなったため収録を終了しました。"); }
        catch (IOException) { recorder.Stop("保存先への接続が失われました。"); }
    }
    public void Dispose() { if (_disposed) return; _disposed = true; CloseToast(); _clock.Stop(); _hotkeys.Dispose(); _recorder?.Stop(); _deviceCapture?.Dispose(); _window?.CloseForShutdown(); }
    internal static void ExcludeFromCapture(nint handle) { if (OperatingSystem.IsWindowsVersionAtLeast(10, 0, 19041)) SetWindowDisplayAffinity(handle, 0x11); }
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern bool SetWindowDisplayAffinity(nint hwnd, uint affinity);
}

internal sealed class CaptureWindow : Window
{
    private readonly CaptureController _controller;
    private readonly ComboBox _folder = new() { DisplayMemberPath = "Name", SelectedValuePath = "Id", MinWidth = 280 };
    private readonly CheckBox _system, _microphone;
    private readonly TextBox _shotKey, _recordKey;
    private readonly Slider _toastSeconds;
    private readonly Button _shot, _record, _saveKeys, _retry;
    private readonly TextBlock _status = new() { TextWrapping = TextWrapping.Wrap, Margin = new(0, 14, 0, 5) };
    private readonly StackPanel _settings;
    private bool _foldersLoaded;
    private string? _requestedFolder;
    public CapturePreferences Preferences => new(_shotKey.Text.Trim(), _recordKey.Text.Trim(), _system.IsChecked == true, _microphone.IsChecked == true, _foldersLoaded ? (string.IsNullOrEmpty(_folder.SelectedValue as string) ? null : _folder.SelectedValue as string) : _requestedFolder, ScreenshotToastSeconds: (int)_toastSeconds.Value);
    public CaptureWindow(CaptureController controller, CapturePreferences preferences, string status)
    {
        _controller = controller; _requestedFolder = preferences.FolderId; Title = "撮影・画面収録 — HoverPocket"; Width = 500; Height = 560; MinWidth = 430; MinHeight = 440; WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Width = Math.Min(500, SystemParameters.WorkArea.Width * .9); Height = Math.Min(560, SystemParameters.WorkArea.Height * .9); MinWidth = Math.Min(430, Width); MinHeight = Math.Min(440, Height);
        var stack = new StackPanel { Margin = new(24) }; Content = new ScrollViewer { Content = stack, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        stack.Children.Add(new TextBlock { Text = "撮影して、素材ライブラリへ", FontSize = 23, FontWeight = FontWeights.SemiBold, Margin = new(0, 0, 0, 15) });
        var actions = new WrapPanel(); stack.Children.Add(actions);
        _shot = Button(actions, "スクリーンショット", async () => await controller.ScreenshotAsync());
        _record = Button(actions, "画面収録を開始", async () =>
        {
            try { if (!controller.Recording) controller.SavePreferences(Preferences); await controller.ToggleRecordingAsync(); }
            catch (Exception ex) { Update(false, controller.Recording, TimeSpan.Zero, ex.Message); }
        });
        _settings = new StackPanel(); stack.Children.Add(_settings);
        _settings.Children.Add(new TextBlock { Text = "保存先フォルダ", Margin = new(0, 18, 0, 6) }); _settings.Children.Add(_folder);
        _settings.Children.Add(new TextBlock { Text = "撮影は選択枠のそばで編集できます。✓またはダブルクリックで保存、×でキャンセルします。", Foreground = Brushes.DimGray, TextWrapping = TextWrapping.Wrap, Margin = new(0, 12, 0, 0) });
        _settings.Children.Add(new TextBlock { Text = "スクショ通知の表示時間", Margin = new(0, 14, 0, 6) });
        var toastRow = new DockPanel(); _settings.Children.Add(toastRow);
        var duration = new TextBlock { Width = 80, TextAlignment = TextAlignment.Right, VerticalAlignment = VerticalAlignment.Center };
        DockPanel.SetDock(duration, Dock.Right); toastRow.Children.Add(duration);
        _toastSeconds = new Slider { Minimum = 0, Maximum = 30, TickFrequency = 1, IsSnapToTickEnabled = true, Value = preferences.ScreenshotToastSeconds, ToolTip = "0秒で通知をオフにします" };
        void UpdateDuration() => duration.Text = _toastSeconds.Value == 0 ? "オフ" : $"{_toastSeconds.Value:0}秒";
        _toastSeconds.ValueChanged += (_, _) => UpdateDuration(); UpdateDuration(); toastRow.Children.Add(_toastSeconds);
        _settings.Children.Add(new TextBlock { Text = "画像付き通知をドラッグして、他のアプリへ画像を渡せます。マウスを置いている間は消えません。", Foreground = Brushes.DimGray, TextWrapping = TextWrapping.Wrap, Margin = new(0, 5, 0, 0) });
        var audio = new WrapPanel { Margin = new(0, 15, 0, 8) }; _settings.Children.Add(audio);
        _system = new CheckBox { Content = "PCの再生音", IsChecked = preferences.SystemAudio, Margin = new(0, 0, 20, 0) }; _microphone = new CheckBox { Content = "マイク", IsChecked = preferences.Microphone }; audio.Children.Add(_system); audio.Children.Add(_microphone);
        _settings.Children.Add(new TextBlock { Text = "PCの既定の再生・入力デバイスを使用します。\nマイクが使えない場合は、Windowsのプライバシー設定を確認してください。", Foreground = Brushes.DimGray, TextWrapping = TextWrapping.Wrap });
        _shotKey = Field(_settings, "撮影ショートカット", preferences.ScreenshotKey); _recordKey = Field(_settings, "収録の開始・停止", preferences.RecordingKey);
        _saveKeys = Button(_settings, "設定を保存", () => { try { controller.SavePreferences(Preferences); } catch (Exception ex) { Update(false, controller.Recording, TimeSpan.Zero, ex.Message); } return Task.CompletedTask; });
        var extras = new WrapPanel(); stack.Children.Add(extras); Button(extras, "素材ライブラリを開く", () => { controller.OpenLibrary(); return Task.CompletedTask; });
        _retry = Button(extras, "保存待ちを再試行", controller.RetryAsync);
        Button(extras, "保存待ちフォルダを開く", () => { try { controller.OpenPendingFolder(); } catch (Exception ex) { Update(false, controller.Recording, TimeSpan.Zero, ex.Message); } return Task.CompletedTask; });
        stack.Children.Add(_status); _status.Text = status;
        SourceInitialized += (_, _) => CaptureController.ExcludeFromCapture(new WindowInteropHelper(this).Handle);
    }
    private static TextBox Field(Panel parent, string title, string value)
    { var row = new DockPanel { Margin = new(0, 7, 0, 0) }; row.Children.Add(new TextBlock { Text = title, Width = 160, VerticalAlignment = VerticalAlignment.Center }); var input = new TextBox { Text = value, Padding = new(5) }; row.Children.Add(input); parent.Children.Add(row); return input; }
    private static Button Button(Panel parent, string title, Func<Task> action)
    { var button = new Button { Content = title, Padding = new(10, 7, 10, 7), Margin = new(0, 8, 8, 0) }; button.Click += async (_, _) => await action(); parent.Children.Add(button); return button; }
    public void LoadFolders(Category[] folders)
    {
        _foldersLoaded = true;
        var categories = folders.ToDictionary(item => item.Id);
        string Name(Category category)
        {
            var parts = new List<string> { category.Name }; var visited = new HashSet<string> { category.Id };
            while (category.ParentId is not null && categories.TryGetValue(category.ParentId, out var parent) && visited.Add(parent.Id)) { parts.Insert(0, parent.Name); category = parent; }
            return string.Join(" / ", parts);
        }
        _folder.ItemsSource = new[] { new Category("", "すべての素材（分類なし）", null) }.Concat(folders.Select(item => item with { Name = Name(item) }).OrderBy(item => item.Name)).ToArray(); SelectFolder(_requestedFolder);
    }
    public void SelectFolder(string? selected) { _requestedFolder = selected; if (!_foldersLoaded) return; _folder.SelectedValue = selected ?? ""; if (_folder.SelectedIndex < 0) _folder.SelectedIndex = 0; }
    public void Update(bool busy, bool recording, TimeSpan duration, string status)
    { _settings.IsEnabled = !busy && !recording; _shot.IsEnabled = !busy && !recording; _record.IsEnabled = !busy; _retry.IsEnabled = !busy && !recording; _record.Content = recording ? "■ 停止して保存" : "画面収録を開始"; _status.Text = (recording ? $"● {duration:hh\\:mm\\:ss}  " : "") + status; }
    public void CloseForShutdown() => Close();
}
