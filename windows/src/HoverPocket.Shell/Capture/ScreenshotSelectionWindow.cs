using System.Runtime.InteropServices;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Point = System.Windows.Point;
using Image = System.Windows.Controls.Image;
using Brushes = System.Windows.Media.Brushes;
using Color = System.Windows.Media.Color;
using Cursors = System.Windows.Input.Cursors;
using TextBox = System.Windows.Controls.TextBox;
using Panel = System.Windows.Controls.Panel;
using Size = System.Windows.Size;
using DrawingRect = System.Drawing.Rectangle;

namespace HoverPocket.Shell.Capture;

internal sealed class ScreenshotSelectionWindow : Window
{
    private readonly BitmapSource _screen;
    private readonly bool _selectionOnly;
    private readonly DrawingRect _bounds;
    private readonly DrawingRect[] _windows;
    private readonly Canvas _overlay = new() { Background = Brushes.Transparent };
    private readonly System.Windows.Shapes.Path _shade = new() { Fill = new SolidColorBrush(Color.FromArgb(110, 0, 0, 0)), IsHitTestVisible = false };
    private readonly System.Windows.Shapes.Rectangle _selection = new() { Stroke = Brushes.DeepSkyBlue, StrokeThickness = 2, IsHitTestVisible = false };
    private readonly TextBlock _label = new() { Foreground = Brushes.White, Background = Brushes.Black, Padding = new(6, 3, 6, 3), IsHitTestVisible = false };
    private readonly TextBlock _hint = new() { Text = "ホバーでウィンドウを選択  •  クリックで確定 / ドラッグで範囲指定  •  Escでキャンセル", Foreground = Brushes.White, Background = Brushes.Black, FontSize = 14, Padding = new(12), IsHitTestVisible = false };
    private Point? _start;
    private Int32Rect _region;
    private Rect _monitor;
    private ScreenshotEditorView? _editor;
    private readonly Func<BitmapSource, EditedScreenshot, Task>? _save;
    public BitmapSource? Result { get; private set; }
    public Exception? Error { get; private set; }
    internal ScreenshotEditorView? EditorForVerify => _editor;
    internal Int32Rect Region => _region;
    internal DrawingRect[] WindowsForVerify => _windows;

    public ScreenshotSelectionWindow(BitmapSource screenshot, DrawingRect bounds, Func<BitmapSource, EditedScreenshot, Task>? save = null, bool selectionOnly = false)
    {
        _selectionOnly = selectionOnly;
        _screen = screenshot; _bounds = bounds; _save = save; _windows = ReadWindows(bounds);
        WindowStyle = WindowStyle.None; ResizeMode = ResizeMode.NoResize; Topmost = true; ShowInTaskbar = false;
        Title = "撮影・編集 — HoverPocket"; Background = Brushes.Black; Cursor = Cursors.Cross;
        var grid = new Grid(); grid.Children.Add(new Image { Source = screenshot, Stretch = Stretch.Fill });
        _overlay.Children.Add(_shade); _overlay.Children.Add(_selection); _overlay.Children.Add(_label); _overlay.Children.Add(_hint);
        grid.Children.Add(_overlay); Content = grid;
        SourceInitialized += (_, _) => PlaceWindow();
        Loaded += (_, _) => { PlaceWindow(); Activate(); Focus(); Hover(Mouse.GetPosition(_overlay)); };
        SizeChanged += (_, _) => { if (ActualWidth > 0 && ActualHeight > 0) { DrawSelection(); LayoutEditor(); } };
        _overlay.MouseLeftButtonDown += (_, args) =>
        {
            if (_editor is not null) return;
            _start = args.GetPosition(_overlay); _overlay.CaptureMouse(); args.Handled = true;
        };
        _overlay.MouseMove += (_, args) =>
        {
            if (_editor is not null) return;
            var point = args.GetPosition(_overlay);
            if (_start is null) Hover(point);
            else if ((point - _start.Value).Length >= 3) { _region = Pixels(new Rect(_start.Value, point)); DrawSelection(); }
        };
        _overlay.MouseLeftButtonUp += (_, args) =>
        {
            if (_start is null || _editor is not null) return;
            var point = args.GetPosition(_overlay); var rect = new Rect(_start.Value, point);
            _start = null; _overlay.ReleaseMouseCapture(); args.Handled = true;
            if (rect.Width >= 3 && rect.Height >= 3) _region = Pixels(rect);
            CompleteSelection(_region);
        };
        KeyDown += (_, args) =>
        {
            if (args.OriginalSource is TextBox) return;
            if (args.Key == Key.Escape) { if (_editor?.IsSaving != true) Close(); args.Handled = true; }
            else if (args.Key == Key.Enter) { if (_editor is null) CompleteSelection(_region); else _editor.Save(); args.Handled = true; }
        };
        Closing += (_, args) => { if (_editor?.IsSaving == true) args.Cancel = true; };
    }
    private void PlaceWindow() => SetWindowPos(new WindowInteropHelper(this).Handle, new nint(-1), _bounds.Left, _bounds.Top, _bounds.Width, _bounds.Height, 0x0040);
    private Int32Rect Pixels(Rect rect)
    {
        var left = Math.Clamp((int)Math.Floor(rect.Left / ActualWidth * _screen.PixelWidth), 0, _screen.PixelWidth - 1);
        var top = Math.Clamp((int)Math.Floor(rect.Top / ActualHeight * _screen.PixelHeight), 0, _screen.PixelHeight - 1);
        var right = Math.Clamp((int)Math.Ceiling(rect.Right / ActualWidth * _screen.PixelWidth), left + 1, _screen.PixelWidth);
        var bottom = Math.Clamp((int)Math.Ceiling(rect.Bottom / ActualHeight * _screen.PixelHeight), top + 1, _screen.PixelHeight);
        return new(left, top, right - left, bottom - top);
    }
    private Rect Display(Int32Rect rect) => new(rect.X * ActualWidth / _screen.PixelWidth, rect.Y * ActualHeight / _screen.PixelHeight, rect.Width * ActualWidth / _screen.PixelWidth, rect.Height * ActualHeight / _screen.PixelHeight);
    internal void Hover(Point point)
    {
        if (_editor is not null || ActualWidth <= 0 || ActualHeight <= 0) return;
        var physical = new System.Drawing.Point(_bounds.Left + (int)(point.X / ActualWidth * _bounds.Width), _bounds.Top + (int)(point.Y / ActualHeight * _bounds.Height));
        var monitor = DrawingRect.Intersect(_bounds, System.Windows.Forms.Screen.FromPoint(physical).Bounds);
        if (monitor.IsEmpty) monitor = _bounds;
        var target = TargetAt(physical, _windows, monitor);
        _region = FromPhysical(target); _monitor = Display(FromPhysical(monitor)); DrawSelection();
    }
    internal static DrawingRect TargetAt(System.Drawing.Point point, IEnumerable<DrawingRect> windows, DrawingRect monitor) => windows.FirstOrDefault(rect => rect.Contains(point)) is { Width: > 0 } window ? window : monitor;
    private Int32Rect FromPhysical(DrawingRect rect) => new(
        (int)Math.Round((rect.Left - _bounds.Left) * (double)_screen.PixelWidth / _bounds.Width),
        (int)Math.Round((rect.Top - _bounds.Top) * (double)_screen.PixelHeight / _bounds.Height),
        Math.Max(1, (int)Math.Round(rect.Width * (double)_screen.PixelWidth / _bounds.Width)),
        Math.Max(1, (int)Math.Round(rect.Height * (double)_screen.PixelHeight / _bounds.Height)));
    private void DrawSelection()
    {
        if (ActualWidth <= 0 || ActualHeight <= 0) return;
        var rect = Display(_region);
        var geometry = new GeometryGroup { FillRule = FillRule.EvenOdd };
        geometry.Children.Add(new RectangleGeometry(new Rect(0, 0, ActualWidth, ActualHeight))); geometry.Children.Add(new RectangleGeometry(rect)); _shade.Data = geometry;
        Canvas.SetLeft(_selection, rect.Left); Canvas.SetTop(_selection, rect.Top); _selection.Width = rect.Width; _selection.Height = rect.Height;
        _label.Text = $"{_region.Width} × {_region.Height}"; Canvas.SetLeft(_label, rect.Left + 3); Canvas.SetTop(_label, Math.Max(0, rect.Top - 27));
        Canvas.SetLeft(_hint, 16); Canvas.SetTop(_hint, 12);
    }
    internal void CompleteSelection(Int32Rect? rect)
    {
        if (_editor is not null) return;
        try
        {
            _region = rect ?? new(0, 0, _screen.PixelWidth, _screen.PixelHeight);
            var original = _region == new Int32Rect(0, 0, _screen.PixelWidth, _screen.PixelHeight) ? _screen : Crop(_screen, _region);
            if (_selectionOnly) { Result = original; DialogResult = true; return; }
            _editor = new ScreenshotEditorView(original, captureOverlay: true);
            _editor.SaveAsync = result => _save?.Invoke(original, result) ?? Task.CompletedTask;
            _editor.Finished += result => { if (result is not null) Result = result.Image; Dispatcher.BeginInvoke(new Action(Close)); };
            _hint.Visibility = Visibility.Collapsed;
            _overlay.Children.Add(_editor); _overlay.Children.Add(_editor.FloatingToolbar!);
            Panel.SetZIndex(_selection, 2); Panel.SetZIndex(_label, 2); Panel.SetZIndex(_editor.FloatingToolbar!, 3);
            _editor.FloatingToolbar!.SizeChanged += (_, _) => LayoutEditor();
            DrawSelection(); LayoutEditor(); _editor.Focus();
        }
        catch (Exception ex) when (ex is InvalidOperationException or ArgumentException or ExternalException)
        { Error = ex; Result = null; Close(); }
    }
    private void LayoutEditor()
    {
        if (_editor is null) return;
        var rect = Display(_region); _editor.Width = rect.Width; _editor.Height = rect.Height; Canvas.SetLeft(_editor, rect.Left); Canvas.SetTop(_editor, rect.Top);
        var monitor = _monitor.Width > 0 ? _monitor : new Rect(0, 0, ActualWidth, ActualHeight);
        var bar = _editor.FloatingToolbar!; bar.MaxWidth = Math.Max(80, monitor.Width - 16); bar.Measure(new Size(bar.MaxWidth, double.PositiveInfinity));
        var width = bar.DesiredSize.Width; var height = bar.DesiredSize.Height;
        var x = Math.Clamp(rect.Right - width, monitor.Left + 8, Math.Max(monitor.Left + 8, monitor.Right - width - 8));
        var y = rect.Bottom + 8;
        if (y + height > monitor.Bottom - 8) y = rect.Top - height - 8;
        if (y < monitor.Top + 8) y = monitor.Bottom - height - 8;
        Canvas.SetLeft(bar, x); Canvas.SetTop(bar, Math.Max(monitor.Top + 8, y));
    }
    private static DrawingRect[] ReadWindows(DrawingRect desktop)
    {
        var result = new List<DrawingRect>();
        EnumWindows((hwnd, _) =>
        {
            if (!IsWindowVisible(hwnd) || IsIconic(hwnd)) return true;
            if (DwmGetWindowAttribute(hwnd, 14, out int cloaked, sizeof(int)) == 0 && cloaked != 0) return true;
            var name = new StringBuilder(128); GetClassName(hwnd, name, name.Capacity);
            if (name.ToString() is "Progman" or "WorkerW" or "Shell_TrayWnd" or "Shell_SecondaryTrayWnd") return true;
            if (DwmGetWindowAttribute(hwnd, 9, out NativeRect frame, Marshal.SizeOf<NativeRect>()) != 0 && !GetWindowRect(hwnd, out frame)) return true;
            var rect = DrawingRect.Intersect(desktop, DrawingRect.FromLTRB(frame.Left, frame.Top, frame.Right, frame.Bottom));
            if (rect.Width >= 16 && rect.Height >= 16) result.Add(rect);
            return true;
        }, 0);
        return result.ToArray();
    }
    internal static BitmapSource Crop(BitmapSource bitmap, Int32Rect rect) { var result = new CroppedBitmap(bitmap, rect); result.Freeze(); return result; }
    internal static BitmapSource CaptureDesktop(System.Drawing.Rectangle bounds)
    {
        if (bounds.Width <= 0 || bounds.Height <= 0) throw new ArgumentException("撮影できる画面がありません。", nameof(bounds));
        if ((long)bounds.Width * bounds.Height > 64_000_000) throw new NotSupportedException("画面全体が大きすぎます。画面の構成を小さくして撮影してください。");
        using var bitmap = new System.Drawing.Bitmap(bounds.Width, bounds.Height, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        using (var graphics = System.Drawing.Graphics.FromImage(bitmap)) graphics.CopyFromScreen(bounds.Location, System.Drawing.Point.Empty, bounds.Size, System.Drawing.CopyPixelOperation.SourceCopy);
        var pixels = bitmap.LockBits(new System.Drawing.Rectangle(0, 0, bounds.Width, bounds.Height),
            System.Drawing.Imaging.ImageLockMode.ReadOnly, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        try
        {
            // Copy raw pixels: even a frozen decoder frame retains its thread-affine BitmapDecoder.
            // Bgr32 makes the desktop opaque; GDI screen-copy alpha bytes are not meaningful.
            var image = BitmapSource.Create(bounds.Width, bounds.Height, 96, 96, PixelFormats.Bgr32, null,
                pixels.Scan0, checked(pixels.Stride * pixels.Height), pixels.Stride);
            image.Freeze();
            return image;
        }
        finally { bitmap.UnlockBits(pixels); }
    }

    [StructLayout(LayoutKind.Sequential)] private struct NativeRect { public int Left, Top, Right, Bottom; }
    private delegate bool EnumWindowCallback(nint hwnd, nint data);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowCallback callback, nint data);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(nint hwnd);
    [DllImport("user32.dll")] private static extern bool IsIconic(nint hwnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(nint hwnd, StringBuilder name, int count);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(nint hwnd, out NativeRect rect);
    [DllImport("dwmapi.dll")] private static extern int DwmGetWindowAttribute(nint hwnd, int attribute, out NativeRect value, int size);
    [DllImport("dwmapi.dll")] private static extern int DwmGetWindowAttribute(nint hwnd, int attribute, out int value, int size);
    [DllImport("user32.dll")] private static extern bool SetWindowPos(nint hwnd, nint after, int x, int y, int width, int height, uint flags);
}
