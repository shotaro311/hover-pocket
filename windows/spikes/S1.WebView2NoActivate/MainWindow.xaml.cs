using System.IO;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using Microsoft.Web.WebView2.Wpf;

namespace S1.WebView2NoActivate;

public partial class MainWindow : Window
{
    private readonly DispatcherTimer _hoverPollTimer;
    private readonly OverlayOptions _options;
    private readonly List<string> _processFailures = [];
    private IntPtr _hwnd;
    private bool _isCursorInside;
    private int _webHoverMessages;

    public MainWindow()
        : this(OverlayOptions.Target)
    {
    }

    public MainWindow(OverlayOptions options)
    {
        _options = options;
        InitializeComponent();

        Title = $"S1 WebView2 NOACTIVATE - {options.Name}";
        ShowActivated = !options.UseNoActivate;
        Left = Math.Max(0, (SystemParameters.PrimaryScreenWidth - Width) / 2);
        Top = 24;

        SourceInitialized += OnSourceInitialized;
        SizeChanged += (_, _) => ApplyRoundedRegion();

        _hoverPollTimer = new DispatcherTimer
        {
            Interval = TimeSpan.FromMilliseconds(120),
        };
        _hoverPollTimer.Tick += (_, _) => UpdateHoverStateFromCursor();
        _hoverPollTimer.Start();
    }

    public bool HasNoActivateStyle => (NativeMethods.GetWindowLongPtr(_hwnd, NativeMethods.GWL_EXSTYLE).ToInt64() & NativeMethods.WS_EX_NOACTIVATE) != 0;

    public bool HasToolWindowStyle => (NativeMethods.GetWindowLongPtr(_hwnd, NativeMethods.GWL_EXSTYLE).ToInt64() & NativeMethods.WS_EX_TOOLWINDOW) != 0;

    public bool IsCursorInside => _isCursorInside;

    public int WebHoverMessages => _webHoverMessages;

    public IReadOnlyList<string> ProcessFailures => _processFailures;

    public async Task InitializeWebViewAsync()
    {
        Web.CreationProperties = new CoreWebView2CreationProperties
        {
            AdditionalBrowserArguments = "--disable-gpu",
            UserDataFolder = Path.Combine(Path.GetTempPath(), "HoverPocket.Spikes", "S1", _options.Name),
        };
        await Web.EnsureCoreWebView2Async();
        Web.DefaultBackgroundColor = _options.TransparentBackground
            ? System.Drawing.Color.Transparent
            : System.Drawing.Color.FromArgb(255, 16, 24, 32);
        Web.CoreWebView2.ProcessFailed += (_, args) =>
        {
            _processFailures.Add($"{args.ProcessFailedKind}:{args.Reason}");
        };
        Web.CoreWebView2.Settings.AreDefaultContextMenusEnabled = false;
        Web.CoreWebView2.Settings.AreDevToolsEnabled = true;
        Web.CoreWebView2.WebMessageReceived += (_, args) =>
        {
            if (args.TryGetWebMessageAsString().StartsWith("hover:", StringComparison.Ordinal))
            {
                _webHoverMessages++;
            }
        };
        Web.NavigateToString(OverlayHtml);
    }

    public async Task<string> ReadProbeTextAsync()
    {
        var json = await Web.ExecuteScriptAsync("document.querySelector('[data-probe]').textContent");
        return json.Trim('"');
    }

    private void OnSourceInitialized(object? sender, EventArgs e)
    {
        _hwnd = new WindowInteropHelper(this).Handle;
        HwndSource.FromHwnd(_hwnd)?.AddHook(WndProc);

        var style = NativeMethods.GetWindowLongPtr(_hwnd, NativeMethods.GWL_EXSTYLE).ToInt64();
        if (_options.UseNoActivate)
        {
            style |= NativeMethods.WS_EX_NOACTIVATE | NativeMethods.WS_EX_TOOLWINDOW;
        }

        NativeMethods.SetWindowLongPtr(_hwnd, NativeMethods.GWL_EXSTYLE, new IntPtr(style));
        NativeMethods.SetWindowPos(
            _hwnd,
            NativeMethods.HWND_TOPMOST,
            0,
            0,
            0,
            0,
            NativeMethods.SWP_NOMOVE | NativeMethods.SWP_NOSIZE | NativeMethods.SWP_NOACTIVATE | NativeMethods.SWP_FRAMECHANGED);

        ApplyRoundedRegion();
    }

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (_options.UseNoActivate && msg == NativeMethods.WM_MOUSEACTIVATE)
        {
            handled = true;
            return new IntPtr(NativeMethods.MA_NOACTIVATE);
        }

        return IntPtr.Zero;
    }

    private void ApplyRoundedRegion()
    {
        if (_hwnd == IntPtr.Zero || !_options.UseRoundedRegion)
        {
            return;
        }

        var dpi = VisualTreeHelper.GetDpi(this);
        var width = Math.Max(1, (int)Math.Round(ActualWidth * dpi.DpiScaleX));
        var height = Math.Max(1, (int)Math.Round(ActualHeight * dpi.DpiScaleY));
        var radius = (int)Math.Round(28 * dpi.DpiScaleX);
        var region = NativeMethods.CreateRoundRectRgn(0, 0, width + 1, height + 1, radius, radius);
        NativeMethods.SetWindowRgn(_hwnd, region, true);
    }

    private void UpdateHoverStateFromCursor()
    {
        if (_hwnd == IntPtr.Zero || !NativeMethods.GetCursorPos(out var point))
        {
            return;
        }

        var rect = new NativeMethods.RECT();
        if (!NativeMethods.GetWindowRect(_hwnd, ref rect))
        {
            return;
        }

        const int tolerance = 4;
        _isCursorInside =
            point.X >= rect.Left - tolerance &&
            point.X <= rect.Right + tolerance &&
            point.Y >= rect.Top - tolerance &&
            point.Y <= rect.Bottom + tolerance;
    }

    private const string OverlayHtml = """
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <style>
    html, body {
      margin: 0;
      width: 100%;
      height: 100%;
      overflow: hidden;
      background: transparent;
      font-family: "Segoe UI", system-ui, sans-serif;
      color: #f8fafc;
    }
    .panel {
      box-sizing: border-box;
      width: 100vw;
      height: 100vh;
      border-radius: 28px;
      background: #101820;
      border: 1px solid rgba(255, 255, 255, 0.14);
      box-shadow: 0 18px 60px rgba(0, 0, 0, 0.42);
      padding: 28px;
    }
    .eyebrow { color: #7dd3fc; font-size: 13px; letter-spacing: 0; }
    h1 { font-size: 24px; margin: 10px 0 12px; font-weight: 650; }
    p { color: #cbd5e1; line-height: 1.6; max-width: 520px; }
    .status {
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 10px;
      margin-top: 24px;
    }
    .status div {
      border: 1px solid rgba(255, 255, 255, 0.1);
      border-radius: 10px;
      padding: 12px;
      background: rgba(255, 255, 255, 0.05);
      min-height: 54px;
    }
    strong { display: block; margin-bottom: 5px; color: #f8fafc; }
  </style>
</head>
<body>
  <main class="panel">
    <div class="eyebrow">HoverPocket spike S1</div>
    <h1 data-probe>WebView2 in NOACTIVATE overlay</h1>
    <p>
      This WebView2 is hosted by a borderless WPF topmost window with
      WS_EX_NOACTIVATE and a rounded Win32 region. The WebView background is
      fully transparent; the panel itself is opaque HTML.
    </p>
    <section class="status">
      <div><strong>Background</strong>DefaultBackgroundColor = Transparent</div>
      <div><strong>Hover</strong>DOM mouse enter/leave posts to host</div>
      <div><strong>Shape</strong>Host HWND region clips the corners</div>
      <div><strong>Focus</strong>WM_MOUSEACTIVATE returns MA_NOACTIVATE</div>
    </section>
  </main>
  <script>
    document.addEventListener('mouseenter', () => chrome.webview.postMessage('hover:enter'));
    document.addEventListener('mouseleave', () => chrome.webview.postMessage('hover:leave'));
  </script>
</body>
</html>
""";
}

public sealed record OverlayOptions(string Name, bool UseNoActivate, bool UseRoundedRegion, bool TransparentBackground)
{
    public static OverlayOptions BaselineOpaque { get; } = new("baseline-opaque", UseNoActivate: false, UseRoundedRegion: false, TransparentBackground: false);

    public static OverlayOptions NoActivateOpaque { get; } = new("noactivate-opaque", UseNoActivate: true, UseRoundedRegion: false, TransparentBackground: false);

    public static OverlayOptions Target { get; } = new("noactivate-transparent-rounded", UseNoActivate: true, UseRoundedRegion: true, TransparentBackground: true);
}
