using System.Runtime.InteropServices;
using System.Windows.Interop;
using System.Windows.Threading;

namespace HoverPocket.Shell.Providers.Clipboard;

internal interface IClipboardMonitor : IDisposable
{
    event EventHandler? ClipboardUpdated;

    bool IsListening { get; }

    void Start();

    void Stop();
}

internal sealed partial class ClipboardNativeListener : IClipboardMonitor
{
    private readonly Dispatcher _dispatcher;
    private HwndSource? _source;
    private bool _disposed;

    public ClipboardNativeListener(Dispatcher dispatcher)
    {
        _dispatcher = dispatcher;
    }

    public event EventHandler? ClipboardUpdated;

    public bool IsListening { get; private set; }

    public void Start()
    {
        if (_disposed)
        {
            return;
        }

        if (!_dispatcher.CheckAccess())
        {
            _dispatcher.Invoke(Start);
            return;
        }

        if (IsListening)
        {
            return;
        }

        var parameters = new HwndSourceParameters("HoverPocketClipboardListener")
        {
            Width = 0,
            Height = 0,
            WindowStyle = 0
        };
        _source = new HwndSource(parameters);
        _source.AddHook(WndProc);
        if (!NativeMethods.AddClipboardFormatListener(_source.Handle))
        {
            var error = Marshal.GetLastPInvokeError();
            _source.Dispose();
            _source = null;
            throw new InvalidOperationException($"AddClipboardFormatListener failed: {error}");
        }

        IsListening = true;
    }

    public void Stop()
    {
        if (!_dispatcher.CheckAccess())
        {
            _dispatcher.Invoke(Stop);
            return;
        }

        if (_source is not null)
        {
            if (IsListening)
            {
                _ = NativeMethods.RemoveClipboardFormatListener(_source.Handle);
            }

            _source.RemoveHook(WndProc);
            _source.Dispose();
            _source = null;
        }

        IsListening = false;
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        Stop();
    }

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        _ = hwnd;
        _ = wParam;
        _ = lParam;
        if (msg == NativeMethods.WmClipboardUpdate)
        {
            ClipboardUpdated?.Invoke(this, EventArgs.Empty);
            handled = false;
        }

        return IntPtr.Zero;
    }

    private static partial class NativeMethods
    {
        public const int WmClipboardUpdate = 0x031D;

        [LibraryImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static partial bool AddClipboardFormatListener(IntPtr hwnd);

        [LibraryImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static partial bool RemoveClipboardFormatListener(IntPtr hwnd);
    }
}
