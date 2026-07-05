using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;
using System.IO;
using System.Text.Json;
using System.Windows;

namespace S3.WebView2Camera;

public partial class MainWindow : Window
{
    private readonly TaskCompletionSource<PageReadyInfo> _ready = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly List<string> _processFailures = [];
    private TaskCompletionSource<CameraProbeResult>? _cameraProbe;
    private TaskCompletionSource<bool>? _stopProbe;
    private int _cameraPermissionRequests;

    public MainWindow()
    {
        InitializeComponent();
    }

    public int CameraPermissionRequests => _cameraPermissionRequests;

    public IReadOnlyList<string> ProcessFailures => _processFailures;

    public async Task InitializeWebViewAsync()
    {
        Web.CreationProperties = new CoreWebView2CreationProperties
        {
            AdditionalBrowserArguments = "--disable-gpu",
            UserDataFolder = Path.Combine(Path.GetTempPath(), "HoverPocket.Spikes", "S3CameraWebView2"),
        };
        await Web.EnsureCoreWebView2Async();
        Web.CoreWebView2.PermissionRequested += OnPermissionRequested;
        Web.CoreWebView2.ProcessFailed += (_, args) =>
        {
            _processFailures.Add($"{args.ProcessFailedKind}:{args.Reason}");
        };
        Web.CoreWebView2.WebMessageReceived += OnWebMessageReceived;
        Web.CoreWebView2.Settings.AreDefaultContextMenusEnabled = false;

        var appFolder = PrepareAppFolder();
        Web.CoreWebView2.SetVirtualHostNameToFolderMapping(
            "hoverpocket-camera-spike.local",
            appFolder,
            CoreWebView2HostResourceAccessKind.Allow);
        Web.Source = new Uri("https://hoverpocket-camera-spike.local/index.html");
    }

    public Task<PageReadyInfo> WaitForReadyAsync(TimeSpan timeout)
    {
        return WithTimeout(_ready.Task, timeout, new PageReadyInfo(false, false, "timeout"));
    }

    public async Task<CameraProbeResult> StartCameraProbeAsync(TimeSpan timeout)
    {
        _cameraProbe = new TaskCompletionSource<CameraProbeResult>(TaskCreationOptions.RunContinuationsAsynchronously);
        await Web.ExecuteScriptAsync("window.hoverPocketStartCamera()");
        return await WithTimeout(_cameraProbe.Task, timeout, new CameraProbeResult("timeout", null, null));
    }

    public async Task<bool> StopCameraProbeAsync(TimeSpan timeout)
    {
        _stopProbe = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        await Web.ExecuteScriptAsync("window.hoverPocketStopCamera()");
        return await WithTimeout(_stopProbe.Task, timeout, false);
    }

    protected override void OnClosed(EventArgs e)
    {
        try
        {
            _ = Web.ExecuteScriptAsync("window.hoverPocketStopCamera && window.hoverPocketStopCamera()");
        }
        catch
        {
            // Closing the WebView can race with script execution in this spike.
        }

        base.OnClosed(e);
    }

    private void OnPermissionRequested(object? sender, CoreWebView2PermissionRequestedEventArgs e)
    {
        if (e.PermissionKind == CoreWebView2PermissionKind.Camera)
        {
            _cameraPermissionRequests++;
            e.SavesInProfile = false;
            e.State = CoreWebView2PermissionState.Allow;
            e.Handled = true;
            return;
        }

        e.SavesInProfile = false;
        e.State = CoreWebView2PermissionState.Default;
    }

    private void OnWebMessageReceived(object? sender, CoreWebView2WebMessageReceivedEventArgs e)
    {
        using var document = JsonDocument.Parse(e.WebMessageAsJson);
        var root = document.RootElement;
        var kind = root.GetProperty("kind").GetString();

        if (kind == "ready")
        {
            _ready.TrySetResult(new PageReadyInfo(
                root.GetProperty("secureContext").GetBoolean(),
                root.GetProperty("hasMediaDevices").GetBoolean(),
                root.GetProperty("href").GetString() ?? string.Empty));
            return;
        }

        if (kind == "started")
        {
            _cameraProbe?.TrySetResult(new CameraProbeResult(
                "started",
                root.GetProperty("trackCount").GetInt32().ToString(),
                root.GetProperty("transform").GetString()));
            return;
        }

        if (kind == "error")
        {
            _cameraProbe?.TrySetResult(new CameraProbeResult(
                "error",
                root.GetProperty("name").GetString(),
                root.GetProperty("message").GetString()));
            return;
        }

        if (kind == "stopped")
        {
            _stopProbe?.TrySetResult(true);
        }
    }

    private static string PrepareAppFolder()
    {
        var directory = Path.Combine(Path.GetTempPath(), "HoverPocket.Spikes", "S3Camera");
        Directory.CreateDirectory(directory);
        File.WriteAllText(Path.Combine(directory, "index.html"), Html);
        return directory;
    }

    private static async Task<T> WithTimeout<T>(Task<T> task, TimeSpan timeout, T fallback)
    {
        var completed = await Task.WhenAny(task, Task.Delay(timeout));
        return completed == task ? await task : fallback;
    }

    private const string Html = """
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <style>
    html, body {
      margin: 0;
      width: 100%;
      height: 100%;
      background: #0f172a;
      color: #f8fafc;
      font-family: "Segoe UI", system-ui, sans-serif;
    }
    main { display: grid; grid-template-columns: 1.2fr 0.8fr; gap: 18px; padding: 20px; box-sizing: border-box; height: 100%; }
    .video-shell { border-radius: 18px; overflow: hidden; background: #020617; border: 1px solid rgba(255,255,255,.12); }
    video { width: 100%; height: 100%; object-fit: cover; transform: scaleX(-1); background: #020617; }
    aside { display: flex; flex-direction: column; gap: 12px; }
    button { height: 36px; border: 0; border-radius: 8px; background: #38bdf8; color: #082f49; font-weight: 650; }
    pre { white-space: pre-wrap; background: rgba(255,255,255,.06); border-radius: 8px; padding: 12px; min-height: 120px; }
  </style>
</head>
<body>
  <main>
    <div class="video-shell"><video id="mirror" autoplay playsinline muted></video></div>
    <aside>
      <h1>WebView2 getUserMedia camera</h1>
      <button onclick="hoverPocketStartCamera()">Start camera</button>
      <button onclick="hoverPocketStopCamera()">Stop camera</button>
      <pre id="status">initializing</pre>
    </aside>
  </main>
  <script>
    const video = document.getElementById('mirror');
    const status = document.getElementById('status');
    let stream = null;

    function post(message) {
      chrome.webview.postMessage(message);
    }

    function write(message) {
      status.textContent = message;
    }

    window.hoverPocketStartCamera = async function () {
      try {
        write('requesting camera...');
        stream = await navigator.mediaDevices.getUserMedia({ video: true, audio: false });
        video.srcObject = stream;
        await video.play();
        const transform = getComputedStyle(video).transform;
        write(`camera started\ntracks=${stream.getVideoTracks().length}\ntransform=${transform}`);
        post({ kind: 'started', trackCount: stream.getVideoTracks().length, transform });
      } catch (error) {
        write(`camera error\n${error.name}\n${error.message}`);
        post({ kind: 'error', name: error.name, message: error.message });
      }
    };

    window.hoverPocketStopCamera = function () {
      if (stream) {
        for (const track of stream.getTracks()) {
          track.stop();
        }
      }
      stream = null;
      video.srcObject = null;
      write('camera stopped');
      post({ kind: 'stopped' });
    };

    post({
      kind: 'ready',
      secureContext: window.isSecureContext,
      hasMediaDevices: !!(navigator.mediaDevices && navigator.mediaDevices.getUserMedia),
      href: location.href
    });
  </script>
</body>
</html>
""";
}
