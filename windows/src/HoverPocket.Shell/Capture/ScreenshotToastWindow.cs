using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using HoverPocket.Shell.Display;
using HoverPocket.Shell.Interop;
using HoverPocket.Shell.Windows;
using Button = System.Windows.Controls.Button;
using Image = System.Windows.Controls.Image;
using Point = System.Windows.Point;
using DataObject = System.Windows.DataObject;
using DataFormats = System.Windows.DataFormats;
using DragDropEffects = System.Windows.DragDropEffects;

namespace HoverPocket.Shell.Capture;

internal sealed class ScreenshotToastWindow : NoActivateWindow
{
    private readonly string _path;
    private readonly TimeSpan _duration;
    private readonly Stopwatch _elapsed = new();
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromMilliseconds(80) };
    private readonly Border _card;
    private readonly Border _progress;
    private readonly TextBlock _hint;
    private Point? _press;
    private bool _dragging, _dismissed, _closed;
    internal bool DraggingForVerify => _dragging;
    internal string CopyPathForVerify => _path;
    internal FrameworkElement CardForVerify => _card;

    internal ScreenshotToastWindow(string path, BitmapSource thumbnail, TimeSpan duration)
    {
        _path = path; _duration = duration;
        Title = "スクリーンショットを保存しました — HoverPocket";
        Width = 300; Height = 244;
        _card = new Border { CornerRadius = new(12), BorderThickness = new(1), BorderBrush = Brush("#424A5A"), Background = Brush("#171B23"), Padding = new(12), Cursor = System.Windows.Input.Cursors.Hand };
        var layout = new Grid(); _card.Child = layout; Content = _card;
        foreach (var height in new[] { GridLength.Auto, new GridLength(1, GridUnitType.Star), GridLength.Auto, GridLength.Auto }) layout.RowDefinitions.Add(new() { Height = height });
        var header = new DockPanel { Margin = new(0, 0, 0, 9) }; layout.Children.Add(header);
        var close = new Button { Content = "×", Width = 24, Height = 24, FontSize = 18, Background = System.Windows.Media.Brushes.Transparent, Foreground = Brush("#ABB5C7"), BorderThickness = new(0), Focusable = false, ToolTip = "通知を閉じる" };
        System.Windows.Automation.AutomationProperties.SetName(close, "通知を閉じる");
        DockPanel.SetDock(close, Dock.Right); header.Children.Add(close); close.Click += (_, _) => Dismiss();
        header.Children.Add(new TextBlock { Text = "✓  スクリーンショットを保存", Foreground = Brush("#DFE8F8"), FontSize = 13, VerticalAlignment = VerticalAlignment.Center });
        var image = new Image { Source = thumbnail, Stretch = Stretch.Uniform, IsHitTestVisible = false };
        var preview = new Border { Background = Brush("#0C0E12"), CornerRadius = new(6), Child = image, Padding = new(3) }; Grid.SetRow(preview, 1); layout.Children.Add(preview);
        _hint = new TextBlock { Text = "ドラッグして他のアプリへ", Foreground = Brush("#A8B7D2"), FontSize = 12, Margin = new(0, 10, 0, 9) }; Grid.SetRow(_hint, 2); layout.Children.Add(_hint);
        var track = new Border { Height = 2, Background = Brush("#313847"), ClipToBounds = true };
        _progress = new Border { Height = 2, Background = Brush("#9BB8F6"), HorizontalAlignment = System.Windows.HorizontalAlignment.Left }; track.Child = _progress; Grid.SetRow(track, 3); layout.Children.Add(track);
        Loaded += (_, _) => { _progress.Width = Math.Max(0, ActualWidth - 26); Resume(); };
        MouseEnter += (_, _) => Pause();
        MouseLeave += (_, _) => Resume();
        _card.MouseLeftButtonDown += (_, e) =>
        {
            if (IsButton(e.OriginalSource as DependencyObject)) return;
            _press = e.GetPosition(_card); Pause(); _card.CaptureMouse(); e.Handled = true;
        };
        _card.MouseLeftButtonUp += (_, _) => { _press = null; _card.ReleaseMouseCapture(); Resume(); };
        _card.LostMouseCapture += (_, _) => { if (!_dragging) { _press = null; Resume(); } };
        _card.MouseMove += (_, e) =>
        {
            if (_press is not { } press || _dragging || e.LeftButton != MouseButtonState.Pressed) return;
            var current = e.GetPosition(_card);
            if (Math.Abs(current.X - press.X) < SystemParameters.MinimumHorizontalDragDistance && Math.Abs(current.Y - press.Y) < SystemParameters.MinimumVerticalDragDistance) return;
            _dragging = true; _press = null; _card.ReleaseMouseCapture(); Pause();
            var effect = DragDropEffects.None;
            try
            {
                if (!File.Exists(_path)) throw new FileNotFoundException();
                // The receiver gets an outbox copy, never the managed library original.
                effect = System.Windows.DragDrop.DoDragDrop(_card, new DataObject(DataFormats.FileDrop, new[] { _path }), DragDropEffects.Copy);
            }
            catch (Exception ex) when (ex is IOException or COMException or InvalidOperationException)
            { _hint.Text = "ドラッグできませんでした。画像は保存済みです。"; }
            finally
            {
                _dragging = false;
                if (_dismissed || effect != DragDropEffects.None) Dismiss(); else Resume();
            }
        };
        _card.QueryContinueDrag += (_, e) => { if (_dismissed) { e.Action = System.Windows.DragAction.Cancel; e.Handled = true; } };
        _timer.Tick += (_, _) =>
        {
            _progress.Width = Math.Max(0, ActualWidth - 26) * Math.Clamp(1 - _elapsed.Elapsed.TotalSeconds / _duration.TotalSeconds, 0, 1);
            if (_elapsed.Elapsed >= _duration) Dismiss();
        };
        Closed += (_, _) => { _closed = true; Pause(); image.Source = null; };
    }
    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        CaptureController.ExcludeFromCapture(Hwnd);
    }
    internal void ShowAtPointer()
    {
        var pointer = System.Windows.Forms.Cursor.Position;
        var monitors = NativeMethods.EnumerateDisplayMonitors();
        var monitor = monitors.FirstOrDefault(m => pointer.X >= m.MonitorBounds.Left && pointer.X < m.MonitorBounds.Right && pointer.Y >= m.MonitorBounds.Top && pointer.Y < m.MonitorBounds.Bottom) ?? monitors.First();
        var sx = monitor.DpiX / 96d; var sy = monitor.DpiY / 96d;
        var work = monitor.WorkArea;
        var width = Math.Min((int)Math.Round(Width * sx), work.Width); var height = Math.Min((int)Math.Round(Height * sy), work.Height);
        var rect = new PhysicalRect(Math.Max(work.Left, work.Right - width - (int)(18 * sx)), Math.Max(work.Top, work.Bottom - height - (int)(18 * sy)), width, height);
        ApplyPlacement(new(new(rect.Left / sx, rect.Top / sy, width / sx, height / sy), rect), show: true);
    }
    internal void Dismiss()
    {
        if (_closed) return;
        _dismissed = true; Pause();
        if (_dragging) Hide(); else Close();
    }
    private void Pause() { _elapsed.Stop(); _timer.Stop(); }
    private void Resume()
    {
        if (_closed || _dismissed || _dragging || _press is not null || IsMouseOver) return;
        _elapsed.Start(); _timer.Start();
    }
    internal static BitmapSource LoadThumbnail(string path)
    {
        using var stream = File.OpenRead(path);
        var frame = BitmapFrame.Create(stream, BitmapCreateOptions.DelayCreation, BitmapCacheOption.None);
        var width = frame.PixelWidth; var height = frame.PixelHeight; stream.Position = 0;
        var bitmap = new BitmapImage(); bitmap.BeginInit(); bitmap.CacheOption = BitmapCacheOption.OnLoad;
        if (width / 600d >= height / 360d) bitmap.DecodePixelWidth = Math.Min(width, 600); else bitmap.DecodePixelHeight = Math.Min(height, 360);
        bitmap.StreamSource = stream; bitmap.EndInit(); bitmap.Freeze(); return bitmap;
    }
    private static SolidColorBrush Brush(string color) => new((System.Windows.Media.Color)System.Windows.Media.ColorConverter.ConvertFromString(color));
    private static bool IsButton(DependencyObject? node)
    {
        while (node is not null) { if (node is Button) return true; node = node is Visual ? VisualTreeHelper.GetParent(node) : LogicalTreeHelper.GetParent(node); }
        return false;
    }
}
