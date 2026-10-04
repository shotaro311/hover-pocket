using System.Runtime.InteropServices;
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

namespace HoverPocket.Shell.Capture;

internal sealed class ScreenshotSelectionWindow : Window
{
    private readonly BitmapSource _screen;
    private readonly Canvas _overlay = new();
    private readonly System.Windows.Shapes.Rectangle _selection = new() { Stroke = Brushes.DeepSkyBlue, StrokeThickness = 2, Fill = new SolidColorBrush(Color.FromArgb(35, 0, 180, 255)) };
    private Point? _start;
    public BitmapSource? Result { get; private set; }
    public Exception? Error { get; private set; }
    public ScreenshotSelectionWindow(BitmapSource screenshot, System.Drawing.Rectangle bounds)
    {
        _screen = screenshot; WindowStyle = WindowStyle.None; ResizeMode = ResizeMode.NoResize; Topmost = true; ShowInTaskbar = false;
        Title = "範囲を選択 — HoverPocket"; Background = Brushes.Black; Cursor = System.Windows.Input.Cursors.Cross;
        var grid = new Grid(); grid.Children.Add(new Image { Source = screenshot, Stretch = Stretch.Fill });
        _overlay.Background = new SolidColorBrush(Color.FromArgb(40, 0, 0, 0)); _overlay.Children.Add(_selection);
        _overlay.Children.Add(new TextBlock { Text = "ドラッグで範囲を選択  •  Enterで画面全体  •  Escでキャンセル", Foreground = Brushes.White, Background = Brushes.Black, FontSize = 20, Padding = new(15) });
        grid.Children.Add(_overlay); Content = grid;
        SourceInitialized += (_, _) => SetWindowPos(new WindowInteropHelper(this).Handle, new nint(-1), bounds.Left, bounds.Top, bounds.Width, bounds.Height, 0x0040);
        Loaded += (_, _) => { SetWindowPos(new WindowInteropHelper(this).Handle, new nint(-1), bounds.Left, bounds.Top, bounds.Width, bounds.Height, 0x0040); Activate(); Focus(); };
        MouseLeftButtonDown += (_, args) => { _start = args.GetPosition(_overlay); _overlay.CaptureMouse(); };
        MouseMove += (_, args) => { if (_start is null) return; var rect = new Rect(_start.Value, args.GetPosition(_overlay)); Canvas.SetLeft(_selection, rect.Left); Canvas.SetTop(_selection, rect.Top); _selection.Width = rect.Width; _selection.Height = rect.Height; };
        MouseLeftButtonUp += (_, args) =>
        {
            if (_start is null) return; var rect = new Rect(_start.Value, args.GetPosition(_overlay)); _start = null; _overlay.ReleaseMouseCapture();
            if (rect.Width < 3 || rect.Height < 3) return;
            var left = Math.Clamp((int)(rect.Left / ActualWidth * screenshot.PixelWidth), 0, screenshot.PixelWidth - 1);
            var top = Math.Clamp((int)(rect.Top / ActualHeight * screenshot.PixelHeight), 0, screenshot.PixelHeight - 1);
            var width = Math.Clamp((int)Math.Ceiling(rect.Width / ActualWidth * screenshot.PixelWidth), 1, screenshot.PixelWidth - left);
            var height = Math.Clamp((int)Math.Ceiling(rect.Height / ActualHeight * screenshot.PixelHeight), 1, screenshot.PixelHeight - top);
            CompleteSelection(new(left, top, width, height));
        };
        KeyDown += (_, args) => { if (args.Key == Key.Escape) Close(); else if (args.Key == Key.Enter) CompleteSelection(null); };
    }
    internal void CompleteSelection(Int32Rect? rect)
    {
        // Input callbacks run in ShowDialog's nested dispatcher. Its caller cannot catch their exceptions.
        try { Result = rect is { } region ? Crop(_screen, region) : _screen; }
        catch (Exception ex) when (ex is InvalidOperationException or ArgumentException or ExternalException)
        { Error = ex; Result = null; }
        DialogResult = Result is not null;
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
    [DllImport("user32.dll")] private static extern bool SetWindowPos(nint hwnd, nint after, int x, int y, int width, int height, uint flags);
}
