using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Ink;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using Button = System.Windows.Controls.Button;
using CheckBox = System.Windows.Controls.CheckBox;
using ComboBox = System.Windows.Controls.ComboBox;
using Panel = System.Windows.Controls.Panel;
using TextBox = System.Windows.Controls.TextBox;
using Rectangle = System.Windows.Shapes.Rectangle;
using Image = System.Windows.Controls.Image;
using Brushes = System.Windows.Media.Brushes;
using Color = System.Windows.Media.Color;
using ColorConverter = System.Windows.Media.ColorConverter;
using Cursors = System.Windows.Input.Cursors;
using Point = System.Windows.Point;

namespace HoverPocket.Shell.Capture;

internal sealed class ScreenshotEditorView : System.Windows.Controls.UserControl
{
    private readonly BitmapSource _original;
    private readonly InkCanvas _ink = new() { Background = Brushes.Transparent };
    private readonly Grid _canvas = new();
    private readonly Stack<Snapshot> _undo = new(), _redo = new();
    private readonly CheckBox _keepOriginal = new() { Content = "元画像も保存", Foreground = Brushes.White, VerticalAlignment = VerticalAlignment.Center, Margin = new(8) };
    private readonly TextBlock _status = new() { Margin = new(12, 5, 12, 5), Foreground = Brushes.LightGray };
    private string _tool = "ペン";
    private Color _color = Colors.Coral;
    private readonly Dictionary<string, Button> _tools = new();
    private readonly List<Button> _swatches = new();
    private Button? _undoButton, _redoButton;
    private readonly Slider _width = new() { Minimum = 2, Maximum = 16, Value = 4, Width = 90, Margin = new(8), VerticalAlignment = VerticalAlignment.Center };
    private Point? _start;
    private FrameworkElement? _draft;
    private Snapshot? _beforeGesture;
    private bool _restoring;
    private string Tool => _tool;
    private Color InkColor => _color;
    public event Action<EditedScreenshot?>? Finished;
    public Func<EditedScreenshot, Task>? SaveAsync { get; set; }
    private bool _saving;
    private bool _captureOverlay;
    private StrokeCollection? _captureClickStrokes;
    private UIElement[] _captureClickElements = [];
    private Snapshot[] _captureClickRedo = [];
    private int _captureClickUndoCount;
    private bool _saveAfterDoubleClick;
    internal string StatusForVerify => _status.Text;
    public FrameworkElement? FloatingToolbar { get; private set; }
    internal bool IsSaving => _saving;
    internal InkCanvas InkSurfaceForVerify => _ink;
    public void Cancel() { if (!_saving) Finished?.Invoke(null); }
    private sealed record ColorChoice(string Name, string Value) { public override string ToString() => Name; }
    private sealed record Element(string Kind, double X, double Y, double Width, double Height, string Color, double Thickness, string Text = "");
    private sealed record Snapshot(StrokeCollection Strokes, Element[] Elements);

    public ScreenshotEditorView(BitmapSource original, bool existingAsset = false, bool compact = false, bool captureOverlay = false)
    {
        _original = original;
        Background = Brush("#101218"); Foreground = Brush("#E8ECF5");
        FontFamily = new System.Windows.Media.FontFamily("Yu Gothic UI"); FontSize = 13; UseLayoutRounding = true;
        Focusable = true;
        Resources.MergedDictionaries.Add(new ResourceDictionary { Source = new Uri("/HoverPocket.Shell;component/Capture/EditorTheme.xaml", UriKind.Relative) });
        _captureOverlay = captureOverlay;
        _canvas.Width = original.PixelWidth; _canvas.Height = original.PixelHeight;
        _canvas.Children.Add(new Image { Source = original, Stretch = Stretch.Fill }); _canvas.Children.Add(_ink);
        if (captureOverlay) BuildCaptureUi();
        else
        {
        var root = new Grid(); Content = root;
        foreach (var height in new[] { new GridLength(compact ? 52 : 76), compact ? GridLength.Auto : new GridLength(64), new GridLength(1, GridUnitType.Star), new GridLength(compact ? 26 : 50) }) root.RowDefinitions.Add(new() { Height = height });
        var header = new DockPanel { Margin = new(22, 10, 22, 10) }; root.Children.Add(header);
        var commands = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center }; DockPanel.SetDock(commands, Dock.Right); header.Children.Add(commands);
        AddButton(commands, "キャンセル", Cancel);
        var save = AddButton(commands, existingAsset ? "編集したコピーを保存" : "ライブラリへ保存", Save); save.Background = Brush("#9DBAFF"); save.Foreground = Brush("#111B31"); save.FontWeight = FontWeights.SemiBold; save.BorderBrush = Brushes.Transparent;
        var heading = new StackPanel { VerticalAlignment = VerticalAlignment.Center }; header.Children.Add(heading);
        heading.Children.Add(new TextBlock { Text = "画像を編集", FontSize = compact ? 16 : 23, FontWeight = FontWeights.SemiBold });
        heading.Children.Add(new TextBlock { Text = $"HOVERPOCKET   /   {original.PixelWidth:N0} × {original.PixelHeight:N0} px", FontSize = 10, Foreground = Brush("#8C98AE"), Margin = new(0, 4, 0, 0) });
        Panel options = compact ? new WrapPanel { Margin = new(12, 0, 12, 4) } : new DockPanel { Margin = new(20, 0, 20, 0), LastChildFill = false }; Grid.SetRow(options, 1); root.Children.Add(options);
        var history = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center }; DockPanel.SetDock(history, Dock.Right); options.Children.Add(history);
        _undoButton = AddButton(history, "↶", Undo); _undoButton.ToolTip = "元に戻す  Ctrl+Z";
        _redoButton = AddButton(history, "↷", Redo); _redoButton.ToolTip = "やり直す  Ctrl+Y";
        var colors = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center }; options.Children.Add(colors);
        colors.Children.Add(new TextBlock { Text = "色", Foreground = Brush("#8C98AE"), VerticalAlignment = VerticalAlignment.Center, Margin = new(0, 0, 10, 0) });
        foreach (var choice in new[] { new ColorChoice("コーラル", "#FF756F"), new("ブルー", "#86ADFF"), new("イエロー", "#F5CF6B"), new("ミント", "#74D7B8"), new("白", "#FFFFFF"), new("黒", "#15171E") })
        {
            var color = (Color)ColorConverter.ConvertFromString(choice.Value);
            var swatch = AddButton(colors, "", () => { _color = color; ConfigureTool(); }); swatch.ToolTip = choice.Name; swatch.Width = 28; swatch.Height = 28; swatch.Padding = new(0); swatch.Background = new SolidColorBrush(color); swatch.Tag = color; _swatches.Add(swatch);
        }
        _color = (Color)_swatches[0].Tag;
        var weight = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center, Margin = new(18, 0, 0, 0) }; options.Children.Add(weight);
        weight.Children.Add(new TextBlock { Text = "太さ", Foreground = Brush("#8C98AE"), VerticalAlignment = VerticalAlignment.Center }); weight.Children.Add(_width);
        var widthLabel = new TextBlock { Text = "4 px", Width = 37, Foreground = Brush("#B8C1D3"), VerticalAlignment = VerticalAlignment.Center }; weight.Children.Add(widthLabel);
        _width.IsSnapToTickEnabled = true; _width.TickFrequency = 1; _width.ValueChanged += (_, _) => { widthLabel.Text = $"{_width.Value:0} px"; ConfigureTool(); };
        var workspace = new Grid { Margin = new(16, 0, 16, 0) }; workspace.ColumnDefinitions.Add(new() { Width = new(compact ? 100 : 142) }); workspace.ColumnDefinitions.Add(new()); Grid.SetRow(workspace, 2); root.Children.Add(workspace);
        var rail = new StackPanel { Margin = new(0, 4, 12, 0) }; workspace.Children.Add(rail);
        foreach (var (name, glyph) in new[] { ("ペン", "✎"), ("テキスト", "A"), ("四角", "□"), ("楕円", "○"), ("矢印", "↗"), ("選択・移動", "✥"), ("消しゴム", "⌫") })
        {
            var tool = AddButton(rail, glyph + "   " + name, () => { _tool = name; ConfigureTool(); }); tool.HorizontalContentAlignment = System.Windows.HorizontalAlignment.Left; tool.Margin = new(0, 0, 0, 6); _tools.Add(name, tool);
        }
        var remove = AddButton(rail, "選択を削除", DeleteSelection); remove.Foreground = Brush("#E7A6A9"); remove.Margin = new(0, 14, 0, 0);
        var view = new Viewbox { Stretch = Stretch.Uniform, Child = _canvas, Margin = new(compact ? 8 : 24), StretchDirection = StretchDirection.DownOnly };
        var canvasSurface = new Border { Background = Brush("#1B1F29"), BorderBrush = Brush("#303746"), BorderThickness = new(1), CornerRadius = new(14), Child = view }; Grid.SetColumn(canvasSurface, 1); workspace.Children.Add(canvasSurface);
        var footer = new DockPanel { Margin = new(20, 0, 20, 0) }; Grid.SetRow(footer, 3); root.Children.Add(footer);
        _keepOriginal.IsChecked = true; _keepOriginal.Visibility = existingAsset ? Visibility.Collapsed : Visibility.Visible; DockPanel.SetDock(_keepOriginal, Dock.Right); footer.Children.Add(_keepOriginal);
        _status.Margin = new(0); _status.VerticalAlignment = VerticalAlignment.Center; _status.TextTrimming = TextTrimming.CharacterEllipsis; _status.Foreground = Brush("#8C98AE"); _status.FontSize = 11; footer.Children.Add(_status);
        _status.Text = existingAsset ? "原本を残して、編集した画像を追加します。" : "ペンで描く · テキストを置く · 図形をドラッグ · Ctrl+Zで戻す";
        if (compact)
        {
            foreach (Button command in commands.Children) command.Padding = new(8, 4, 8, 4);
            foreach (var tool in _tools.Values) { tool.FontSize = 11; tool.Padding = new(5, 7, 5, 7); }
            heading.Children.RemoveAt(1);
        }
        }
        _ink.PreviewMouseLeftButtonDown += (sender, args) => Edit(() =>
        {
            if (_captureOverlay && !InsideTextInput(args.OriginalSource as DependencyObject))
            {
                if (args.ClickCount == 2) { _saveAfterDoubleClick = true; args.Handled = true; return; }
                _captureClickStrokes = _ink.Strokes.Clone(); _captureClickElements = _ink.Children.Cast<UIElement>().ToArray();
                _captureClickUndoCount = _undo.Count; _captureClickRedo = _redo.ToArray();
            }
            BeginGesture(sender, args);
        }); _ink.PreviewMouseMove += (sender, args) => Edit(() => MoveGesture(sender, args)); _ink.PreviewMouseLeftButtonUp += (sender, args) => Edit(() =>
        {
            EndGesture(sender, args);
            if (!_saveAfterDoubleClick) return;
            _saveAfterDoubleClick = false;
            // Let InkCanvas finish its live stroke before restoring and exporting.
            Dispatcher.BeginInvoke(new Action(() => Edit(() =>
            {
                _ink.EditingMode = InkCanvasEditingMode.None;
                // Keep existing text controls intact so saving cannot reflow their glyphs.
                if (_captureClickStrokes is not null) _ink.Strokes = _captureClickStrokes;
                foreach (var child in _ink.Children.Cast<UIElement>().Except(_captureClickElements).ToArray()) _ink.Children.Remove(child);
                while (_undo.Count > _captureClickUndoCount) _undo.Pop();
                _redo.Clear(); foreach (var snapshot in _captureClickRedo.Reverse()) _redo.Push(snapshot);
                _beforeGesture = null; _draft = null; _start = null; _ink.ReleaseMouseCapture(); Save();
            })), System.Windows.Threading.DispatcherPriority.Background);
        });
        _ink.StrokeCollected += (_, args) => { if (_restoring) return; var prior = SnapshotNow(); prior.Strokes.RemoveAt(prior.Strokes.Count - 1); Push(prior); };
        _ink.StrokeErasing += (_, _) => { if (!_restoring) Push(SnapshotNow()); };
        _ink.SelectionMoving += (_, _) => { if (_beforeGesture is null) _beforeGesture = SnapshotNow(); };
        _ink.SelectionResizing += (_, _) => { if (_beforeGesture is null) _beforeGesture = SnapshotNow(); };
        _ink.SelectionMoved += (_, _) => CommitSelection(); _ink.SelectionResized += (_, _) => CommitSelection();
        PreviewKeyDown += (_, args) =>
        {
            if (args.Key == Key.Escape) { Cancel(); args.Handled = true; }
            else if (args.OriginalSource is not TextBox && Keyboard.Modifiers == ModifierKeys.Control && args.Key == Key.Z) { Undo(); args.Handled = true; }
            else if (args.OriginalSource is not TextBox && Keyboard.Modifiers == ModifierKeys.Control && args.Key == Key.Y) { Redo(); args.Handled = true; }
            else if (args.OriginalSource is not TextBox && args.Key == Key.Delete) { DeleteSelection(); args.Handled = true; }
        };
        ConfigureTool();
    }
    private static bool InsideTextInput(DependencyObject? source)
    {
        while (source is not null) { if (source is TextBox) return true; source = source is Visual ? VisualTreeHelper.GetParent(source) : LogicalTreeHelper.GetParent(source); }
        return false;
    }
    private void BuildCaptureUi()
    {
        Background = Brushes.Transparent; _tool = "選択・移動";
        Content = new Viewbox { Stretch = Stretch.Fill, Child = _canvas };
        var panel = new StackPanel();
        var bar = new Border { Background = Brush("#F51B1E26"), BorderBrush = Brush("#505867"), BorderThickness = new(1), CornerRadius = new(9), Padding = new(5), Child = panel, Cursor = Cursors.Arrow };
        bar.Resources.MergedDictionaries.Add(new ResourceDictionary { Source = new Uri("/HoverPocket.Shell;component/Capture/EditorTheme.xaml", UriKind.Relative) });
        FloatingToolbar = bar;
        var tools = new WrapPanel(); panel.Children.Add(tools);
        Button Icon(Panel row, string glyph, string name, Action action)
        {
            var b = AddButton(row, glyph, action); b.ToolTip = name; b.Tag = name;
            System.Windows.Automation.AutomationProperties.SetName(b, name);
            b.Width = 34; b.Height = 34; b.Padding = new(0); b.Margin = new(2); b.FontSize = 21;
            return b;
        }
        foreach (var (name, glyph) in new[] { ("四角", "□"), ("楕円", "○"), ("矢印", "↗"), ("ペン", "✎"), ("テキスト", "T"), ("選択・移動", "✥"), ("消しゴム", "⌫") })
            _tools.Add(name, Icon(tools, glyph, name, () => { _tool = name; ConfigureTool(); }));
        var options = new WrapPanel { Visibility = Visibility.Collapsed };
        var colorToggle = Icon(tools, "●", "色・線の太さ", () => options.Visibility = options.Visibility == Visibility.Visible ? Visibility.Collapsed : Visibility.Visible);
        colorToggle.Foreground = new SolidColorBrush(_color);
        _undoButton = Icon(tools, "↶", "元に戻す  Ctrl+Z", Undo); _redoButton = Icon(tools, "↷", "やり直す  Ctrl+Y", Redo);
        var cancel = Icon(tools, "×", "キャンセル  Esc", Cancel); cancel.Foreground = Brush("#FF7D8B");
        var save = Icon(tools, "✓", "保存  Enter / ダブルクリック", Save); save.Foreground = Brush("#84E3AA");
        panel.Children.Add(options);
        foreach (var value in new[] { "#FF756F", "#86ADFF", "#F5CF6B", "#74D7B8", "#FFFFFF", "#15171E" })
        {
            var color = (Color)ColorConverter.ConvertFromString(value);
            var swatch = Icon(options, "", value, () => { _color = color; colorToggle.Foreground = new SolidColorBrush(color); ConfigureTool(); });
            swatch.Width = swatch.Height = 25; swatch.Background = new SolidColorBrush(color); swatch.Tag = color; _swatches.Add(swatch);
        }
        options.Children.Add(_width); _width.ValueChanged += (_, _) => ConfigureTool();
        _keepOriginal.IsChecked = false; options.Children.Add(_keepOriginal);
        _status.Visibility = Visibility.Collapsed; _status.TextWrapping = TextWrapping.Wrap; _status.MaxWidth = 420; panel.Children.Add(_status);
    }
    private static SolidColorBrush Brush(string value) => new((Color)ColorConverter.ConvertFromString(value));
    private Button AddButton(Panel target, string title, Action action)
    { var button = new Button { Content = title }; button.Click += (_, _) => Edit(action); target.Children.Add(button); return button; }
    private void Edit(Action action)
    {
        try { action(); }
        catch (Exception ex) when (ex is InvalidOperationException or ArgumentException or System.Runtime.InteropServices.ExternalException)
        { Services.AppDiagnostics.Record("editor.operation.failed", ex); _status.Text = "操作を完了できませんでした。編集内容は保持されています。"; }
    }
    private void ConfigureTool()
    {
        _ink.EditingMode = Tool switch { "ペン" => InkCanvasEditingMode.Ink, "消しゴム" => InkCanvasEditingMode.EraseByStroke, "選択・移動" => InkCanvasEditingMode.Select, _ => InkCanvasEditingMode.None };
        _ink.DefaultDrawingAttributes = new DrawingAttributes { Color = InkColor, Width = _width.Value, Height = _width.Value, FitToCurve = true, IgnorePressure = false };
        foreach (var (name, button) in _tools) { button.Background = Brush(name == Tool ? "#293D65" : "#1B1F29"); button.BorderBrush = Brush(name == Tool ? "#779BE5" : "#303746"); }
        foreach (var swatch in _swatches) { swatch.BorderThickness = new((Color)swatch.Tag == InkColor ? 3 : 1); swatch.BorderBrush = (Color)swatch.Tag == InkColor ? Brush("#C5D5FF") : Brush("#596173"); }
        UpdateHistory();
    }
    private void UpdateHistory() { if (_undoButton is not null) _undoButton.IsEnabled = _undo.Count > 0; if (_redoButton is not null) _redoButton.IsEnabled = _redo.Count > 0; }
    private void BeginGesture(object sender, MouseButtonEventArgs args)
    {
        if (Tool is "ペン" or "消しゴム" or "選択・移動" || args.OriginalSource is TextBox) return;
        _beforeGesture = SnapshotNow(); _start = args.GetPosition(_ink);
        if (Tool == "テキスト")
        {
            var text = new TextBox { Text = "", Width = Math.Min(320, Math.Max(70, _canvas.Width - _start.Value.X)), MinHeight = 40, FontSize = 28, Foreground = new SolidColorBrush(InkColor), Background = Brushes.Transparent, BorderThickness = new(0), AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, Tag = "text" };
            InkCanvas.SetLeft(text, _start.Value.X); InkCanvas.SetTop(text, _start.Value.Y); _ink.Children.Add(text); Push(_beforeGesture); _beforeGesture = null; _start = null;
            text.GotKeyboardFocus += (_, _) => { if (!_restoring) _beforeGesture = SnapshotNow(); };
            text.LostKeyboardFocus += (_, _) => CommitSelection();
            text.Focus(); args.Handled = true; return;
        }
        _draft = Tool == "矢印" ? new Polyline { Stroke = new SolidColorBrush(InkColor), StrokeThickness = _width.Value, Tag = "arrow" }
            : Tool == "楕円" ? new Ellipse { Stroke = new SolidColorBrush(InkColor), StrokeThickness = _width.Value, Tag = "ellipse" }
            : new Rectangle { Stroke = new SolidColorBrush(InkColor), StrokeThickness = _width.Value, Tag = "rectangle" };
        _ink.Children.Add(_draft); _ink.CaptureMouse(); args.Handled = true;
    }
    private void MoveGesture(object sender, System.Windows.Input.MouseEventArgs args)
    {
        if (_draft is null || _start is null) return;
        var point = args.GetPosition(_ink); point.X = Math.Clamp(point.X, 0, _canvas.Width); point.Y = Math.Clamp(point.Y, 0, _canvas.Height);
        if (_draft is Polyline arrow)
        {
            var start = _start.Value; var vector = start - point; if (vector.Length < 1) return; vector.Normalize();
            var tip = point + vector * 22; var side = new Vector(-vector.Y, vector.X) * 10;
            arrow.Points = new([start, point, tip + side, point, tip - side]);
        }
        else
        {
            InkCanvas.SetLeft(_draft, Math.Min(point.X, _start.Value.X)); InkCanvas.SetTop(_draft, Math.Min(point.Y, _start.Value.Y));
            _draft.Width = Math.Abs(point.X - _start.Value.X); _draft.Height = Math.Abs(point.Y - _start.Value.Y);
        }
    }
    private void EndGesture(object sender, MouseButtonEventArgs args)
    { if (_draft is null) return; if (_beforeGesture is not null) Push(_beforeGesture); _draft = null; _start = null; _beforeGesture = null; _ink.ReleaseMouseCapture(); args.Handled = true; }
    private void CommitSelection() { if (_beforeGesture is not null) Push(_beforeGesture); _beforeGesture = null; }
    private void Push(Snapshot prior) { _undo.Push(prior); _redo.Clear(); UpdateHistory(); }
    private Snapshot SnapshotNow() => new(_ink.Strokes.Clone(), _ink.Children.Cast<FrameworkElement>().Select(ReadElement).ToArray());
    private static double Position(double value) => double.IsNaN(value) ? 0 : value;
    private static Element ReadElement(FrameworkElement item)
    {
        var color = ((item is TextBox text ? text.Foreground : ((Shape)item).Stroke) as SolidColorBrush)?.Color.ToString() ?? "#FFFF5252";
        if (item is Polyline arrow) return new("arrow", Position(InkCanvas.GetLeft(item)), Position(InkCanvas.GetTop(item)), 0, 0, color, arrow.StrokeThickness, string.Join(';', arrow.Points.Select(p => $"{p.X.ToString(System.Globalization.CultureInfo.InvariantCulture)},{p.Y.ToString(System.Globalization.CultureInfo.InvariantCulture)}")));
        return new((string)item.Tag, Position(InkCanvas.GetLeft(item)), Position(InkCanvas.GetTop(item)), double.IsNaN(item.Width) ? item.ActualWidth : item.Width,
            item is TextBox ? Math.Max(40, item.ActualHeight) : item.Height, color, item is Shape shape ? shape.StrokeThickness : ((TextBox)item).FontSize, (item as TextBox)?.Text ?? "");
    }
    private void Restore(Snapshot snapshot)
    {
        _restoring = true; _beforeGesture = null; _ink.Children.Clear(); _ink.Strokes = snapshot.Strokes.Clone();
        foreach (var item in snapshot.Elements)
        {
            var brush = new SolidColorBrush((Color)ColorConverter.ConvertFromString(item.Color)); FrameworkElement child;
            if (item.Kind == "text")
            {
                var text = new TextBox { Text = item.Text, Width = item.Width, MinHeight = 40, FontSize = item.Thickness, Foreground = brush, Background = Brushes.Transparent, BorderThickness = new(0), AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, Tag = "text" };
                text.GotKeyboardFocus += (_, _) => { if (!_restoring) _beforeGesture = SnapshotNow(); }; text.LostKeyboardFocus += (_, _) => CommitSelection(); child = text;
            }
            else if (item.Kind == "arrow") child = new Polyline { Points = PointCollection.Parse(item.Text.Replace(';', ' ')), Stroke = brush, StrokeThickness = item.Thickness, Tag = "arrow" };
            else { Shape shape = item.Kind == "ellipse" ? new Ellipse() : new Rectangle(); shape.Width = item.Width; shape.Height = item.Height; shape.Stroke = brush; shape.StrokeThickness = item.Thickness; shape.Tag = item.Kind; child = shape; }
            InkCanvas.SetLeft(child, item.X); InkCanvas.SetTop(child, item.Y); _ink.Children.Add(child);
        }
        _restoring = false; UpdateHistory();
    }
    internal void Undo() { CommitSelection(); if (_undo.TryPop(out var prior)) { _redo.Push(SnapshotNow()); Restore(prior); } }
    internal void Redo() { if (_redo.TryPop(out var next)) { _undo.Push(SnapshotNow()); Restore(next); } }
    private void DeleteSelection()
    { if (_ink.GetSelectedElements().Count == 0 && _ink.GetSelectedStrokes().Count == 0) return; Push(SnapshotNow()); foreach (var child in _ink.GetSelectedElements().ToArray()) _ink.Children.Remove(child); foreach (var stroke in _ink.GetSelectedStrokes().ToArray()) _ink.Strokes.Remove(stroke); }
    internal BitmapSource RenderImage()
    {
        Keyboard.ClearFocus(); _ink.Select(new StrokeCollection(), Array.Empty<UIElement>());
        _canvas.Measure(new(_canvas.Width, _canvas.Height)); _canvas.Arrange(new(0, 0, _canvas.Width, _canvas.Height)); _canvas.UpdateLayout();
        var image = new RenderTargetBitmap(_original.PixelWidth, _original.PixelHeight, 96, 96, PixelFormats.Pbgra32); image.Render(_canvas); image.Freeze(); return image;
    }
    internal async void Save()
    {
        if (_saving) return;
        _saving = true; if (FloatingToolbar is not null) FloatingToolbar.IsEnabled = false;
        try
        {
            // Capture enabled text styling before disabling interaction during persistence.
            var result = new EditedScreenshot(RenderImage(), _keepOriginal.IsChecked == true);
            IsEnabled = false;
            if (SaveAsync is not null) await SaveAsync(result);
            Finished?.Invoke(result);
        }
        catch (Exception ex) when (ex is InvalidOperationException or ArgumentException or IOException or UnauthorizedAccessException or System.Runtime.InteropServices.ExternalException or Microsoft.Data.Sqlite.SqliteException)
        {
            Services.AppDiagnostics.Record("editor.save.failed", ex);
            _status.Visibility = Visibility.Visible;
            _status.Text = "保存できませんでした。編集内容は残っています。保存先の空き容量などを確認して、もう一度保存してください。";
        }
        finally { _saving = false; IsEnabled = true; if (FloatingToolbar is not null) FloatingToolbar.IsEnabled = true; if (_captureOverlay) ConfigureTool(); if (IsVisible) Focus(); }
    }
    internal void AddAnnotationsForVerify()
    {
        Push(SnapshotNow()); _ink.Strokes.Add(new Stroke(new StylusPointCollection([new StylusPoint(5, 5), new StylusPoint(80, 60)]), new DrawingAttributes { Color = Colors.Red, Width = 5, Height = 5 }));
        var shape = new Rectangle { Width = 40, Height = 30, Stroke = Brushes.Blue, StrokeThickness = 4, Tag = "rectangle" }; InkCanvas.SetLeft(shape, 30); InkCanvas.SetTop(shape, 20); _ink.Children.Add(shape);
        var text = new TextBox { Text = "注釈", Width = 90, MinHeight = 28, FontSize = 20, Foreground = Brushes.Black, Background = Brushes.Transparent, BorderThickness = new(0), Tag = "text" }; InkCanvas.SetLeft(text, 10); InkCanvas.SetTop(text, 60); _ink.Children.Add(text);
        var ellipse = new Ellipse { Width = 40, Height = 30, Stroke = Brushes.Green, StrokeThickness = 3, Tag = "ellipse" }; InkCanvas.SetLeft(ellipse, 90); InkCanvas.SetTop(ellipse, 10); _ink.Children.Add(ellipse);
        _ink.Children.Add(new Polyline { Points = new([new Point(95, 70), new Point(140, 90), new Point(125, 85)]), Stroke = Brushes.DarkOrange, StrokeThickness = 3, Tag = "arrow" });
    }
}
