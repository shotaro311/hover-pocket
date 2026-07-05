using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using HoverPocket.Shell.Bridge;
using HoverPocket.Shell.Configuration;
using HoverPocket.Shell.Display;
using HoverPocket.Shell.Interop;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;

namespace HoverPocket.Shell.Windows;

internal sealed class PanelWindow : NoActivateWindow
{
    public const double CollapsedWidth = AccessSurfaceWindow.SurfaceWidth;
    public const double CollapsedHeight = AccessSurfaceWindow.SurfaceHeight;
    public static readonly TimeSpan AnimationDuration = TimeSpan.FromMilliseconds(220);
    private const string UiHostName = "app.hoverpocket.local";
    private const string UiBaseUrl = "https://app.hoverpocket.local/index.html";
    private const double CornerRadiusDips = 18;

    private readonly PanelBridgeController _bridgeController;
    private readonly bool _enableWebView;
    private readonly Grid _root = new();
    private readonly Border _fallbackVisual;
    private readonly List<string> _processFailures = [];
    private int _animationGeneration;
    private WebView2? _webView;
    private Task? _initializationTask;

    public PanelWindow(PanelBridgeController bridgeController, bool enableWebView)
        : base(allowsTransparency: false)
    {
        _bridgeController = bridgeController;
        _enableWebView = enableWebView;

        var metrics = PanelSizeCatalog.Get(_bridgeController.CurrentSettings.PanelSize);
        Width = metrics.Width;
        Height = metrics.TotalHeight;
        MinWidth = PanelSizeCatalog.Get(PanelSize.Small).Width;
        MinHeight = PanelSizeCatalog.Get(PanelSize.Small).TotalHeight;
        MaxWidth = PanelSizeCatalog.Get(PanelSize.Large).Width;
        MaxHeight = PanelSizeCatalog.Get(PanelSize.Large).TotalHeight;
        Background = new SolidColorBrush(System.Windows.Media.Color.FromRgb(4, 4, 6));

        _fallbackVisual = new Border
        {
            Background = new SolidColorBrush(System.Windows.Media.Color.FromRgb(5, 5, 7)),
            BorderBrush = new SolidColorBrush(System.Windows.Media.Color.FromArgb(24, 255, 255, 255)),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(CornerRadiusDips),
            SnapsToDevicePixels = true,
            Child = new TextBlock
            {
                Text = enableWebView ? "Loading HoverPocket UI..." : "HoverPocket UI host disabled for this verifier.",
                Foreground = new SolidColorBrush(System.Windows.Media.Color.FromRgb(210, 214, 222)),
                FontFamily = new System.Windows.Media.FontFamily("Segoe UI"),
                FontSize = 13,
                HorizontalAlignment = System.Windows.HorizontalAlignment.Center,
                VerticalAlignment = System.Windows.VerticalAlignment.Center
            }
        };
        _root.Children.Add(_fallbackVisual);
        Content = _root;

        SizeChanged += (_, _) => ApplyRoundedRegion();
    }

    public IReadOnlyList<string> ProcessFailures => _processFailures;

    public WebView2? WebView => _webView;

    public async Task EnsureWebViewInitializedAsync()
    {
        if (!_enableWebView)
        {
            return;
        }

        _initializationTask ??= InitializeWebViewAsync();
        await _initializationTask;
    }

    public async Task<bool> WaitForUiReadyAsync(TimeSpan timeout)
    {
        await EnsureWebViewInitializedAsync();
        if (_webView?.CoreWebView2 is null)
        {
            return false;
        }

        var deadline = DateTimeOffset.UtcNow + timeout;
        while (DateTimeOffset.UtcNow < deadline)
        {
            var resultJson = await _webView.ExecuteScriptAsync("Boolean(window.__hoverPocketReady === true)");
            if (resultJson.Equals("true", StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }

            await Task.Delay(100);
        }

        return false;
    }

    public async Task<UiWebVerifyResult?> RunWebVerifyScriptAsync()
    {
        await EnsureWebViewInitializedAsync();
        if (_webView?.CoreWebView2 is null)
        {
            return null;
        }

        const string startScript = """
            (() => {
                window.__hoverPocketVerifyResult = null;
                window.__hoverPocketVerifyError = null;
                window.__hoverPocketVerify.run()
                    .then((result) => { window.__hoverPocketVerifyResult = result; })
                    .catch((error) => { window.__hoverPocketVerifyError = String(error?.message ?? error); });
                return true;
            })()
            """;

        _ = await _webView.ExecuteScriptAsync(startScript);
        var deadline = DateTimeOffset.UtcNow + TimeSpan.FromSeconds(8);
        while (DateTimeOffset.UtcNow < deadline)
        {
            var errorJson = await _webView.ExecuteScriptAsync("window.__hoverPocketVerifyError");
            var error = JsonSerializer.Deserialize<string?>(errorJson, BridgeJson.Options);
            if (!string.IsNullOrWhiteSpace(error))
            {
                throw new InvalidOperationException($"UI verify script failed: {error}");
            }

            var resultJson = await _webView.ExecuteScriptAsync("window.__hoverPocketVerifyResult");
            if (!resultJson.Equals("null", StringComparison.OrdinalIgnoreCase))
            {
                return JsonSerializer.Deserialize<UiWebVerifyResult>(resultJson, BridgeJson.Options);
            }

            await Task.Delay(100);
        }

        return null;
    }

    public void ApplyPanelSize(PanelSize panelSize)
    {
        var metrics = PanelSizeCatalog.Get(panelSize);
        Width = metrics.Width;
        Height = metrics.TotalHeight;
        ApplyRoundedRegion();
    }

    public async Task OpenAsync(DisplaySurfaceLayout layout)
    {
        var generation = ++_animationGeneration;
        WindowPlacement from;

        if (!IsVisible)
        {
            ApplyPlacement(layout.PanelCollapsed, show: true);
            Opacity = 0;
            from = layout.PanelCollapsed;
        }
        else
        {
            ShowNoActivate();
            from = GetCurrentPlacement(layout.PanelCollapsed);
        }

        await AnimateToAsync(from, layout.PanelTarget, 1, generation);
        if (generation == _animationGeneration)
        {
            ApplyPlacement(layout.PanelTarget, show: true);
            Opacity = 1;
        }
    }

    public async Task CloseAsync(DisplaySurfaceLayout layout)
    {
        if (!IsVisible)
        {
            return;
        }

        var generation = ++_animationGeneration;
        var from = GetCurrentPlacement(layout.PanelTarget);

        await AnimateToAsync(from, layout.PanelCollapsed, 0, generation);
        if (generation == _animationGeneration)
        {
            Hide();
            ApplyPlacement(layout.PanelCollapsed, show: false);
            Opacity = 0;
        }
    }

    private WindowPlacement GetCurrentPlacement(WindowPlacement fallback)
    {
        var dipRect = new Rect(Left, Top, Width, Height);
        if (Hwnd == IntPtr.Zero || !NativeMethods.TryGetWindowRect(Hwnd, out var nativeRect))
        {
            return new WindowPlacement(dipRect, fallback.PhysicalRect);
        }

        return new WindowPlacement(dipRect, PhysicalRect.FromNative(nativeRect));
    }

    private async Task AnimateToAsync(
        WindowPlacement from,
        WindowPlacement to,
        double targetOpacity,
        int generation)
    {
        var startOpacity = Opacity;
        var start = DateTimeOffset.UtcNow;

        while (true)
        {
            if (generation != _animationGeneration)
            {
                return;
            }

            var elapsed = DateTimeOffset.UtcNow - start;
            var progress = Math.Clamp(elapsed.TotalMilliseconds / AnimationDuration.TotalMilliseconds, 0, 1);
            var eased = EaseOutCubic(progress);
            ApplyPlacement(Interpolate(from, to, eased), show: true);
            Opacity = Interpolate(startOpacity, targetOpacity, eased);

            if (progress >= 1)
            {
                return;
            }

            await Task.Delay(16);
        }
    }

    private static WindowPlacement Interpolate(WindowPlacement from, WindowPlacement to, double progress)
    {
        return new WindowPlacement(
            new Rect(
                Interpolate(from.DipRect.Left, to.DipRect.Left, progress),
                Interpolate(from.DipRect.Top, to.DipRect.Top, progress),
                Interpolate(from.DipRect.Width, to.DipRect.Width, progress),
                Interpolate(from.DipRect.Height, to.DipRect.Height, progress)),
            new PhysicalRect(
                Interpolate(from.PhysicalRect.Left, to.PhysicalRect.Left, progress),
                Interpolate(from.PhysicalRect.Top, to.PhysicalRect.Top, progress),
                Interpolate(from.PhysicalRect.Width, to.PhysicalRect.Width, progress),
                Interpolate(from.PhysicalRect.Height, to.PhysicalRect.Height, progress)));
    }

    private static int Interpolate(int from, int to, double progress)
    {
        return (int)Math.Round(Interpolate((double)from, to, progress), MidpointRounding.AwayFromZero);
    }

    private static double Interpolate(double from, double to, double progress)
    {
        return from + ((to - from) * progress);
    }

    private static double EaseOutCubic(double progress)
    {
        var inverse = 1 - progress;
        return 1 - (inverse * inverse * inverse);
    }

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        ApplyRoundedRegion();
    }

    private async Task InitializeWebViewAsync()
    {
        if (_webView is not null)
        {
            return;
        }

        var uiFolder = ResolveUiFolder();
        var webView = new WebView2
        {
            CreationProperties = new CoreWebView2CreationProperties
            {
                AdditionalBrowserArguments = "--disable-gpu",
                UserDataFolder = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                    "HoverPocket",
                    "WebView2")
            },
            DefaultBackgroundColor = System.Drawing.Color.Transparent
        };

        _webView = webView;
        _root.Children.Add(webView);
        System.Windows.Controls.Panel.SetZIndex(webView, 1);
        _fallbackVisual.Visibility = Visibility.Collapsed;

        await webView.EnsureCoreWebView2Async();
        webView.DefaultBackgroundColor = System.Drawing.Color.Transparent;
        webView.CoreWebView2.ProcessFailed += (_, args) =>
        {
            _processFailures.Add($"{args.ProcessFailedKind}:{args.Reason}");
        };
        webView.CoreWebView2.Settings.AreDefaultContextMenusEnabled = false;
        webView.CoreWebView2.Settings.AreDevToolsEnabled = true;
        webView.CoreWebView2.SetVirtualHostNameToFolderMapping(
            UiHostName,
            uiFolder,
            CoreWebView2HostResourceAccessKind.DenyCors);

        var dispatcher = new BridgeDispatcher(json =>
        {
            webView.CoreWebView2.PostWebMessageAsJson(json);
            return Task.CompletedTask;
        });
        _bridgeController.Attach(dispatcher);
        webView.CoreWebView2.WebMessageReceived += async (_, args) =>
        {
            await dispatcher.HandleRawMessageAsync(args.TryGetWebMessageAsString());
        };
        webView.CoreWebView2.Navigate(UiBaseUrl);
    }

    private static string ResolveUiFolder()
    {
        var outputUiFolder = Path.Combine(AppContext.BaseDirectory, "ui");
        if (File.Exists(Path.Combine(outputUiFolder, "index.html")))
        {
            return outputUiFolder;
        }

        var current = new DirectoryInfo(Directory.GetCurrentDirectory());
        while (current is not null)
        {
            var candidate = Path.Combine(current.FullName, "windows", "ui");
            if (File.Exists(Path.Combine(candidate, "index.html")))
            {
                return candidate;
            }

            current = current.Parent;
        }

        throw new DirectoryNotFoundException("windows/ui static assets were not found.");
    }

    private void ApplyRoundedRegion()
    {
        if (Hwnd == IntPtr.Zero)
        {
            return;
        }

        var dpi = VisualTreeHelper.GetDpi(this);
        var width = Math.Max(1, (int)Math.Round(ActualWidth * dpi.DpiScaleX));
        var height = Math.Max(1, (int)Math.Round(ActualHeight * dpi.DpiScaleY));
        var ellipse = Math.Max(1, (int)Math.Round(CornerRadiusDips * 2 * dpi.DpiScaleX));
        NativeMethods.SetRoundedWindowRegion(Hwnd, width, height, ellipse, ellipse);
    }
}

internal sealed record UiWebVerifyResult(
    bool EchoOk,
    bool ProviderSwitchOk,
    bool SettingsWriteOk,
    string OriginalProvider,
    string SwitchedProvider,
    string OriginalPanelSize,
    string ProbePanelSize);
