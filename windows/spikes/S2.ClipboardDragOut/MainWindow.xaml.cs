using System.Collections.ObjectModel;
using System.Collections.Specialized;
using System.IO;
using System.Security.Cryptography;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace S2.ClipboardDragOut;

public partial class MainWindow : Window
{
    private readonly ObservableCollection<ClipboardHistoryItem> _history = [];
    private IntPtr _hwnd;

    public MainWindow()
    {
        InitializeComponent();

        HistoryList.ItemsSource = _history;
        StatusText.Text = "Listening with AddClipboardFormatListener. Copy text or images, then drag the latest item to another app.";
        SourceInitialized += OnSourceInitialized;
        Closed += OnClosed;

        SeedTextButton.Click += (_, _) => WithClipboardRetry(() => Clipboard.SetText($"HoverPocket S2 text {DateTimeOffset.Now:HH:mm:ss}", TextDataFormat.UnicodeText));
        SeedImageButton.Click += (_, _) => WithClipboardRetry(() => Clipboard.SetImage(CreateProbeBitmap()));
        // NOTE: Click (mouse-up) 起点だと DoDragDrop 開始時点でボタンが離れており、
        // OLE の QueryContinueDrag が即 Drop 判定するため実ドラッグが成立しない。
        // 標準パターンどおり mouse-down 起点で開始する(architect fix, 2026-07-05)。
        DragLatestButton.PreviewMouseLeftButtonDown += (_, e) =>
        {
            DragLatestItem();
            e.Handled = true;
        };
        ClearButton.Click += (_, _) => _history.Clear();
    }

    public IReadOnlyList<ClipboardHistoryItem> History => _history;

    public Task<bool> WaitForItemAsync(Func<ClipboardHistoryItem, bool> predicate, TimeSpan timeout)
    {
        var started = DateTimeOffset.UtcNow;
        var completion = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);

        var timer = new System.Windows.Threading.DispatcherTimer
        {
            Interval = TimeSpan.FromMilliseconds(50),
        };
        timer.Tick += (_, _) =>
        {
            if (_history.Any(predicate))
            {
                timer.Stop();
                completion.TrySetResult(true);
                return;
            }

            if (DateTimeOffset.UtcNow - started > timeout)
            {
                timer.Stop();
                completion.TrySetResult(false);
            }
        };
        timer.Start();
        return completion.Task;
    }

    public void CaptureClipboardSnapshot(string source)
    {
        WithClipboardRetry(() =>
        {
            if (Clipboard.ContainsText(TextDataFormat.UnicodeText))
            {
                var text = Clipboard.GetText(TextDataFormat.UnicodeText);
                if (!string.IsNullOrWhiteSpace(text))
                {
                    AddTextItem(text, source);
                }
            }

            if (Clipboard.ContainsImage())
            {
                var image = Clipboard.GetImage();
                if (image is not null)
                {
                    AddImageItem(image, source);
                }
            }
        });
    }

    public DataObject BuildDragDataObject(ClipboardHistoryItem item)
    {
        var data = new DataObject();

        if (item.Kind == ClipboardItemKind.Text && item.Text is not null)
        {
            data.SetText(item.Text, TextDataFormat.UnicodeText);
            data.SetData(DataFormats.UnicodeText, item.Text);
            return data;
        }

        if (item.Kind == ClipboardItemKind.Image && item.Image is not null && item.PngPath is not null)
        {
            data.SetImage(item.Image);
            data.SetData(DataFormats.Bitmap, item.Image);
            var files = new StringCollection { item.PngPath };
            data.SetFileDropList(files);
            return data;
        }

        throw new InvalidOperationException("Unsupported clipboard item.");
    }

    public static BitmapSource CreateProbeBitmap()
    {
        const int width = 48;
        const int height = 48;
        var pixels = new byte[width * height * 4];
        for (var y = 0; y < height; y++)
        {
            for (var x = 0; x < width; x++)
            {
                var offset = (y * width + x) * 4;
                pixels[offset] = (byte)(x * 5);
                pixels[offset + 1] = (byte)(y * 5);
                pixels[offset + 2] = 220;
                pixels[offset + 3] = 255;
            }
        }

        var bitmap = BitmapSource.Create(width, height, 96, 96, PixelFormats.Bgra32, null, pixels, width * 4);
        bitmap.Freeze();
        return bitmap;
    }

    private void OnSourceInitialized(object? sender, EventArgs e)
    {
        _hwnd = new WindowInteropHelper(this).Handle;
        HwndSource.FromHwnd(_hwnd)?.AddHook(WndProc);
        if (!NativeMethods.AddClipboardFormatListener(_hwnd))
        {
            StatusText.Text = $"AddClipboardFormatListener failed: {NativeMethods.GetLastError()}";
        }
    }

    private void OnClosed(object? sender, EventArgs e)
    {
        if (_hwnd != IntPtr.Zero)
        {
            NativeMethods.RemoveClipboardFormatListener(_hwnd);
        }
    }

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == NativeMethods.WM_CLIPBOARDUPDATE)
        {
            Dispatcher.InvokeAsync(() => CaptureClipboardSnapshot("WM_CLIPBOARDUPDATE"));
            handled = false;
        }

        return IntPtr.Zero;
    }

    private void AddTextItem(string text, string source)
    {
        var hash = Convert.ToHexString(SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(text)));
        if (_history.Any(item => item.Hash == hash))
        {
            return;
        }

        _history.Insert(0, ClipboardHistoryItem.TextItem(text, hash, source));
        Trim(30, ClipboardItemKind.Text);
        StatusText.Text = $"Text captured via {source}: {text.Length} chars";
    }

    private void AddImageItem(BitmapSource image, string source)
    {
        var pngBytes = EncodePng(image);
        var hash = Convert.ToHexString(SHA256.HashData(pngBytes));
        if (_history.Any(item => item.Hash == hash))
        {
            return;
        }

        var directory = Path.Combine(Path.GetTempPath(), "HoverPocket.Spikes", "S2");
        Directory.CreateDirectory(directory);
        var pngPath = Path.Combine(directory, $"{hash[..16]}.png");
        File.WriteAllBytes(pngPath, pngBytes);

        _history.Insert(0, ClipboardHistoryItem.ImageItem(image, pngBytes, pngPath, hash, source));
        Trim(20, ClipboardItemKind.Image);
        StatusText.Text = $"Image captured via {source}: {pngBytes.Length} PNG bytes";
    }

    private static byte[] EncodePng(BitmapSource image)
    {
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(image));
        using var stream = new MemoryStream();
        encoder.Save(stream);
        return stream.ToArray();
    }

    private void DragLatestItem()
    {
        var item = _history.FirstOrDefault();
        if (item is null)
        {
            StatusText.Text = "No item to drag. Seed or copy text/image first.";
            return;
        }

        var data = BuildDragDataObject(item);
        StatusText.Text = $"Starting drag for {item.Kind}. Move to Notepad, Explorer, or another target.";
        DragDrop.DoDragDrop(this, data, DragDropEffects.Copy);
    }

    private void Trim(int maxCount, ClipboardItemKind kind)
    {
        var extra = _history.Where(item => item.Kind == kind).Skip(maxCount).ToList();
        foreach (var item in extra)
        {
            _history.Remove(item);
        }
    }

    private static void WithClipboardRetry(Action action)
    {
        Exception? last = null;
        for (var attempt = 0; attempt < 8; attempt++)
        {
            try
            {
                action();
                return;
            }
            catch (Exception ex) when (ex is System.Runtime.InteropServices.COMException or InvalidOperationException)
            {
                last = ex;
                Thread.Sleep(80);
            }
        }

        throw new InvalidOperationException("Clipboard operation failed after retries.", last);
    }
}
