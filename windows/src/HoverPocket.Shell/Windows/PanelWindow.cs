using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
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
    public static readonly TimeSpan ResizeAnimationDuration = TimeSpan.FromMilliseconds(180);
    private static readonly TimeSpan MicrophonePermissionArmDuration = TimeSpan.FromSeconds(8);
    private const string UiHostName = "app.hoverpocket.local";
    private const string UiBaseUrl = "https://app.hoverpocket.local/index.html";
    private const double CornerRadiusDips = 18;

    private readonly PanelBridgeController _bridgeController;
    private readonly HoverPocketApplicationData _applicationData;
    private readonly bool _enableWebView;
    private readonly bool _enableDevTools;
    private readonly Grid _root = new();
    private readonly Border _fallbackVisual;
    private readonly System.Windows.Controls.Image _morphImage = new()
    {
        Stretch = Stretch.Fill,
        Visibility = Visibility.Collapsed,
        IsHitTestVisible = false
    };
    private readonly List<string> _processFailures = [];
    private readonly SemaphoreSlim _snapshotCaptureGate = new(1, 1);
    private int _animationGeneration;
    private int _snapshotRefreshGeneration;
    private bool _isAnimating;
    private bool _morphActive;
    private BitmapSource? _lastSnapshot;
    private WebView2? _webView;
    private Task? _initializationTask;
    private IDisposable? _bridgeAttachment;
    private DateTimeOffset? _microphonePermissionArmedUntil;
    private bool _closed;

    public AnimationDiagnostics LastAnimationDiagnostics { get; private set; } = AnimationDiagnostics.Empty;

    public PanelWindow(
        PanelBridgeController bridgeController,
        HoverPocketApplicationData applicationData,
        bool enableWebView,
        bool enableDevTools)
        : base(allowsTransparency: false)
    {
        _bridgeController = bridgeController;
        _applicationData = applicationData;
        _enableWebView = enableWebView;
        _enableDevTools = enableDevTools;
        if (ShouldExposeToAutomation(applicationData))
        {
            Title = "HoverPocket Voice E2E";
            ShowInTaskbar = true;
        }

        var metrics = PanelSizeCatalog.Get(
            _bridgeController.CurrentSettings.PanelSize,
            _bridgeController.CurrentSettings.EffectiveVoiceLaneLayout);
        Width = metrics.Width;
        Height = metrics.TotalHeight;
        MinWidth = PanelSizeCatalog.Get(PanelSize.Small).Width;
        MinHeight = PanelSizeCatalog.Get(PanelSize.Small).TotalHeight;
        MaxWidth = PanelSizeCatalog.Get(PanelSize.Large).Width;
        MaxHeight = PanelSizeCatalog.Get(
            PanelSize.Large,
            VoiceLaneLayoutState.Expanded).TotalHeight;
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
        _root.Children.Add(_morphImage);
        System.Windows.Controls.Panel.SetZIndex(_morphImage, 2);
        Content = _root;

        SizeChanged += (_, _) =>
        {
            if (!_isAnimating)
            {
                ApplyRoundedRegion();
            }
        };
    }

    public IReadOnlyList<string> ProcessFailures => _processFailures;

    public bool IsAnimating => _isAnimating;

    public bool KeyboardInteractionEnabled => ActivationEnabled;

    public bool ExposesToAutomation => ShouldExposeToAutomation(_applicationData);

    protected override bool ActivatesOnMouseInteraction => true;

    public WebView2? WebView => _webView;

    internal static bool ShouldExposeToAutomation(
        HoverPocketApplicationData applicationData)
    {
        return applicationData.IsIsolatedVoiceE2E;
    }

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        if (ExposesToAutomation)
        {
            NativeMethods.SetToolWindowStyle(Hwnd, enabled: false);
        }
    }

    public void ReleaseBridgeAttachment()
    {
        _bridgeAttachment?.Dispose();
        _bridgeAttachment = null;
    }

    public void PrepareCollapsedState()
    {
        MinWidth = 1;
        MinHeight = 1;
    }

    public void RestorePanelMinimums()
    {
        MinWidth = PanelSizeCatalog.Get(PanelSize.Small).Width;
        MinHeight = PanelSizeCatalog.Get(PanelSize.Small).TotalHeight;
    }

    public async Task EnsureWebViewInitializedAsync()
    {
        if (!_enableWebView || _closed)
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
        var deadline = DateTimeOffset.UtcNow + TimeSpan.FromSeconds(30);
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

        var stepJson = await _webView.ExecuteScriptAsync("window.__hoverPocketVerifyStep");
        var step = JsonSerializer.Deserialize<string?>(stepJson, BridgeJson.Options);
        throw new TimeoutException($"UI verification timed out at step: {step ?? "unknown"}");
    }

    public void ApplyPanelSize(PanelSize panelSize)
    {
        var metrics = PanelSizeCatalog.Get(
            panelSize,
            _bridgeController.CurrentSettings.EffectiveVoiceLaneLayout);
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
            PrepareCollapsedState();
            ApplyPlacement(layout.PanelCollapsed, show: true);
            Opacity = 0;
            from = layout.PanelCollapsed;
        }
        else
        {
            ShowNoActivate();
            from = GetCurrentPlacement(layout.PanelCollapsed);
        }

        if (_lastSnapshot is not null)
        {
            BeginMorph(_lastSnapshot);
        }

        await AnimateToAsync(
            from,
            layout.PanelTarget,
            1,
            generation,
            AnimationDuration,
            MorphDirection.Open);
        if (generation == _animationGeneration)
        {
            ApplyPlacement(layout.PanelTarget, show: true);
            Opacity = 1;
            ResetMorphState();
            ScheduleSnapshotRefresh();
        }
    }

    public Task CloseAsync(DisplaySurfaceLayout layout)
    {
        EndKeyboardInteraction();
        _microphonePermissionArmedUntil = null;
        if (!IsVisible)
        {
            return Task.CompletedTask;
        }

        ++_animationGeneration;
        ++_snapshotRefreshGeneration;
        _isAnimating = false;
        Opacity = 0;
        PrepareCollapsedState();
        Hide();
        ApplyPlacement(layout.PanelCollapsed, show: false);
        ResetMorphState(restoreMinimums: false);
        return Task.CompletedTask;
    }

    public async Task ResizeAsync(WindowPlacement target)
    {
        if (!IsVisible)
        {
            ApplyPlacement(target, show: false);
            return;
        }

        var generation = ++_animationGeneration;
        var from = GetCurrentPlacement(target);
        if (_lastSnapshot is not null)
        {
            BeginMorph(_lastSnapshot);
        }

        await AnimateToAsync(
            from,
            target,
            1,
            generation,
            ResizeAnimationDuration,
            MorphDirection.Resize);
        if (generation == _animationGeneration)
        {
            ApplyPlacement(target, show: true);
            Opacity = 1;
            ResetMorphState();
            ScheduleSnapshotRefresh();
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

    private void BeginMorph(BitmapSource snapshot)
    {
        _morphImage.Source = snapshot;
        _morphImage.Opacity = 1;
        _morphImage.Visibility = Visibility.Visible;
        _morphActive = true;
        if (_webView is not null)
        {
            _webView.Visibility = Visibility.Hidden;
        }

        // Allow the WPF layout to shrink together with the native window rect so the
        // Stretch=Fill snapshot scales down instead of being clipped at the small-panel minimum.
        MinWidth = 1;
        MinHeight = 1;
    }

    private void ResetMorphState(bool restoreMinimums = true)
    {
        _morphActive = false;
        _morphImage.Visibility = Visibility.Collapsed;
        _morphImage.Source = null;
        if (_webView is not null)
        {
            _webView.Visibility = Visibility.Visible;
        }
        if (restoreMinimums)
        {
            RestorePanelMinimums();
        }
    }

    private async Task<BitmapSource?> CaptureWebViewAsync()
    {
        var core = _webView?.CoreWebView2;
        if (core is null)
        {
            return null;
        }

        try
        {
            using var stream = new MemoryStream();
            await core.CapturePreviewAsync(CoreWebView2CapturePreviewImageFormat.Png, stream);
            stream.Position = 0;
            var bitmap = new BitmapImage();
            bitmap.BeginInit();
            bitmap.CacheOption = BitmapCacheOption.OnLoad;
            bitmap.StreamSource = stream;
            bitmap.EndInit();
            bitmap.Freeze();
            return bitmap;
        }
        catch
        {
            return null;
        }
    }

    private void ScheduleSnapshotRefresh()
    {
        if (!IsVisible || _webView?.CoreWebView2 is null)
        {
            return;
        }

        var generation = ++_snapshotRefreshGeneration;
        _ = RefreshSnapshotAsync(generation);
    }

    private async Task RefreshSnapshotAsync(int generation)
    {
        await Task.Delay(120);
        if (generation != _snapshotRefreshGeneration || !IsVisible || _morphActive)
        {
            return;
        }

        await _snapshotCaptureGate.WaitAsync();
        try
        {
            if (generation != _snapshotRefreshGeneration || !IsVisible || _morphActive)
            {
                return;
            }

            var snapshot = await CaptureWebViewAsync();
            if (snapshot is not null
                && generation == _snapshotRefreshGeneration
                && !_morphActive)
            {
                _lastSnapshot = snapshot;
            }
        }
        finally
        {
            _snapshotCaptureGate.Release();
        }
    }

    private async Task AnimateToAsync(
        WindowPlacement from,
        WindowPlacement to,
        double targetOpacity,
        int generation,
        TimeSpan duration,
        MorphDirection direction)
    {
        if (!SystemParameters.ClientAreaAnimation)
        {
            ApplyPlacement(to, show: targetOpacity > 0);
            Opacity = targetOpacity;
            return;
        }

        var startOpacity = Opacity;
        var start = Stopwatch.GetTimestamp();
        var previousFrame = start;
        var frameCount = 0;
        var maxFrameGap = TimeSpan.Zero;
        _isAnimating = true;
        ApplyRoundedRegion(to);
        try
        {
            while (true)
            {
                if (generation != _animationGeneration)
                {
                    return;
                }

                var elapsed = Stopwatch.GetElapsedTime(start);
                var frameGap = Stopwatch.GetElapsedTime(previousFrame);
                previousFrame = Stopwatch.GetTimestamp();
                maxFrameGap = frameGap > maxFrameGap ? frameGap : maxFrameGap;
                frameCount++;
                var progress = Math.Clamp(elapsed.TotalMilliseconds / duration.TotalMilliseconds, 0, 1);
                var eased = EaseOutCubic(progress);
                ApplyPlacement(Interpolate(from, to, eased), show: true);
                Opacity = Interpolate(startOpacity, targetOpacity, eased);
                UpdateMorphCrossfade(direction, progress, targetOpacity);

                if (progress >= 1)
                {
                    return;
                }

                await WaitForNextFrameAsync(previousFrame);
            }
        }
        finally
        {
            if (generation == _animationGeneration)
            {
                LastAnimationDiagnostics = new AnimationDiagnostics(
                    direction.ToString(),
                    frameCount,
                    Stopwatch.GetElapsedTime(start),
                    maxFrameGap);
                _isAnimating = false;
                ApplyRoundedRegion();
            }
        }
    }

    private void UpdateMorphCrossfade(MorphDirection direction, double progress, double targetOpacity)
    {
        if (!_morphActive)
        {
            return;
        }

        if (progress >= 0.72 && _webView is not null)
        {
            _webView.Visibility = Visibility.Visible;
        }

        _morphImage.Opacity = progress < 0.68
            ? 1
            : 1 - SmoothStep((progress - 0.68) / 0.32);
    }

    private static async Task WaitForNextFrameAsync(long previousFrameTimestamp)
    {
        var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        EventHandler? handler = null;
        handler = (_, _) =>
        {
            // WPF may raise multiple Rendering events for one native resize. Limiting
            // placement updates to 200 Hz still covers 144/165 Hz displays without
            // creating a SetWindowPos feedback loop.
            if (Stopwatch.GetElapsedTime(previousFrameTimestamp) < TimeSpan.FromMilliseconds(5))
            {
                return;
            }

            CompositionTarget.Rendering -= handler;
            completion.TrySetResult();
        };
        CompositionTarget.Rendering += handler;
        try
        {
            _ = await Task.WhenAny(completion.Task, Task.Delay(50));
        }
        finally
        {
            CompositionTarget.Rendering -= handler;
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

    private static double SmoothStep(double progress)
    {
        var clamped = Math.Clamp(progress, 0, 1);
        return clamped * clamped * (3 - (2 * clamped));
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
                AdditionalBrowserArguments = DisableGpuRequested() ? "--disable-gpu" : string.Empty,
                UserDataFolder = _applicationData.PanelWebViewDataDirectory
            },
            DefaultBackgroundColor = System.Drawing.Color.Transparent
        };

        _webView = webView;
        _root.Children.Add(webView);
        System.Windows.Controls.Panel.SetZIndex(webView, 1);
        _fallbackVisual.Visibility = Visibility.Collapsed;

        await webView.EnsureCoreWebView2Async();
        if (_closed)
        {
            webView.Dispose();
            return;
        }

        webView.DefaultBackgroundColor = System.Drawing.Color.Transparent;
        webView.CoreWebView2.ProcessFailed += (_, args) =>
        {
            _processFailures.Add($"{args.ProcessFailedKind}:{args.Reason}");
        };
        WebViewSecurityPolicy.ApplyBrowserDebugSettings(webView.CoreWebView2.Settings, _enableDevTools);
        webView.CoreWebView2.NavigationStarting += (_, args) =>
        {
            if (WebViewSecurityPolicy.IsAllowedVirtualHostNavigation(args.Uri, UiHostName))
            {
                return;
            }

            args.Cancel = true;
            WebViewSecurityPolicy.TryOpenExternalBrowser(args.Uri, UiHostName);
        };
        webView.CoreWebView2.NewWindowRequested += (_, args) =>
        {
            args.Handled = true;
            WebViewSecurityPolicy.TryOpenExternalBrowser(args.Uri, UiHostName);
        };
        webView.CoreWebView2.PermissionRequested += (_, args) =>
        {
            args.Handled = true;
            args.SavesInProfile = false;
            var now = DateTimeOffset.UtcNow;
            var allowed = WebViewSecurityPolicy.ShouldAllowMicrophone(
                args.Uri,
                args.PermissionKind,
                args.IsUserInitiated,
                _bridgeController.CurrentSettings.CodexVoiceEnabled,
                IsVisible,
                _microphonePermissionArmedUntil,
                now);
            if (args.PermissionKind == CoreWebView2PermissionKind.Microphone)
            {
                _microphonePermissionArmedUntil = null;
            }

            args.State = allowed
                ? CoreWebView2PermissionState.Allow
                : CoreWebView2PermissionState.Deny;
        };
        webView.CoreWebView2.SetVirtualHostNameToFolderMapping(
            UiHostName,
            uiFolder,
            CoreWebView2HostResourceAccessKind.DenyCors);

        var dispatcher = new BridgeDispatcher(json =>
        {
            webView.CoreWebView2.PostWebMessageAsJson(json);
            ScheduleSnapshotRefresh();
            return Task.CompletedTask;
        });
        _bridgeAttachment = _bridgeController.Attach(dispatcher);
        dispatcher.Register("panel.beginTextInput", (_, _) =>
            Task.FromResult<object?>(BeginKeyboardInteraction()));
        dispatcher.Register("panel.endTextInput", (_, _) =>
            Task.FromResult<object?>(EndKeyboardInteraction()));
        dispatcher.Register("codexVoice.beginMicrophoneRequest", (_, _) =>
            Task.FromResult<object?>(BeginMicrophoneRequest()));
        webView.CoreWebView2.WebMessageReceived += async (_, args) =>
        {
            await dispatcher.HandleRawMessageAsync(args.TryGetWebMessageAsString());
            ScheduleSnapshotRefresh();
        };
        webView.CoreWebView2.Navigate(UiBaseUrl);
    }

    private object BeginKeyboardInteraction()
    {
        var activated = SetActivationEnabled(true);
        _ = _webView?.Focus();
        return KeyboardInteractionState(activated);
    }

    private object BeginMicrophoneRequest()
    {
        var armed = !_closed
            && IsVisible
            && _bridgeController.CurrentSettings.CodexVoiceEnabled;
        _microphonePermissionArmedUntil = armed
            ? DateTimeOffset.UtcNow + MicrophonePermissionArmDuration
            : null;
        if (armed)
        {
            _bridgeController.MarkVoiceMicrophoneRequestStarted();
        }

        return new
        {
            armed,
            expiresInMilliseconds = armed
                ? (int)MicrophonePermissionArmDuration.TotalMilliseconds
                : 0
        };
    }

    private object EndKeyboardInteraction()
    {
        var changed = SetActivationEnabled(false);
        return KeyboardInteractionState(changed);
    }

    private object KeyboardInteractionState(bool activationResult)
    {
        var styles = Hwnd == IntPtr.Zero ? 0 : NativeMethods.GetExtendedStyles(Hwnd);
        return new
        {
            keyboardInteractionEnabled = KeyboardInteractionEnabled,
            noActivateStyle = (styles & NativeMethods.WsExNoActivate) != 0,
            activationResult
        };
    }

    protected override void OnClosed(EventArgs e)
    {
        _closed = true;
        _microphonePermissionArmedUntil = null;
        EndKeyboardInteraction();
        ReleaseBridgeAttachment();
        _webView?.Dispose();
        _webView = null;
        base.OnClosed(e);
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

    private void ApplyRoundedRegion(WindowPlacement placement)
    {
        if (Hwnd == IntPtr.Zero)
        {
            return;
        }

        var dpi = VisualTreeHelper.GetDpi(this);
        var ellipse = Math.Max(1, (int)Math.Round(CornerRadiusDips * 2 * dpi.DpiScaleX));
        NativeMethods.SetRoundedWindowRegion(
            Hwnd,
            Math.Max(1, placement.PhysicalRect.Width),
            Math.Max(1, placement.PhysicalRect.Height),
            ellipse,
            ellipse);
    }

    private static bool DisableGpuRequested()
    {
        return string.Equals(
            Environment.GetEnvironmentVariable("HOVERPOCKET_WEBVIEW_DISABLE_GPU"),
            "1",
            StringComparison.OrdinalIgnoreCase);
    }

    private enum MorphDirection
    {
        Open,
        Resize
    }
}

internal sealed record AnimationDiagnostics(
    string Direction,
    int FrameCount,
    TimeSpan Elapsed,
    TimeSpan MaxFrameGap)
{
    public static AnimationDiagnostics Empty { get; } = new("None", 0, TimeSpan.Zero, TimeSpan.Zero);
}

internal sealed record UiWebVerifyResult(
    bool EchoOk,
    bool ControlsRenderedOk,
    bool ControlsLayoutOk,
    bool ControlsHitAreasOk,
    bool ControlsFallbackLayerOk,
    bool ControlsStableRefreshOk,
    bool ControlsBrightnessResolvedOk,
    bool ControlsMediaActionsOk,
    bool ClipboardStableProviderOk,
    bool ClipboardStableRefreshOk,
    bool ClipboardSplitViewOk,
    bool ClipboardCenteredSplitOk,
    bool ClipboardTabsOk,
    bool ClipboardDeleteActionsOk,
    bool ClipboardNoDragActionOk,
    bool ClipboardNoResolutionOk,
    bool ClipboardPreviewBehaviorOk,
    bool CalculatorHistorySidebarOk,
    bool ProviderIconStableOk,
    bool ProviderDragReorderReadyOk,
    bool TextInputActivationOk,
    bool CalendarMacLayoutOk,
    bool CalendarEditorStableOk,
    bool TimerLayoutOk,
    bool TimerInteractionStableOk,
    bool TimerStopwatchOk,
    bool VoiceCompactOk,
    bool VoiceExpandedOk,
    bool VoiceProviderInvariantOk,
    double VoiceCompactProviderWidth,
    double VoiceCompactProviderHeight,
    double VoiceExpandedProviderWidth,
    double VoiceExpandedProviderHeight,
    bool VoiceExplicitToggleOnlyOk,
    bool VoiceNoFullscreenOk,
    bool TextSizeScaleReadyOk,
    bool ProviderSwitchOk,
    bool SettingsWriteOk,
    string OriginalProvider,
    string SwitchedProvider,
    string OriginalPanelSize,
    string ProbePanelSize);

internal static class WebViewSecurityPolicy
{
    internal const string PanelHostName = "app.hoverpocket.local";
    internal const string SettingsHostName = "settings.hoverpocket.local";

    public static bool IsDebugBuild
    {
        get
        {
#if DEBUG
            return true;
#else
            return false;
#endif
        }
    }

    public static bool ShouldEnableBrowserDebugFeatures(bool devToolsFlag, bool? isDebugBuild = null)
    {
        return devToolsFlag || (isDebugBuild ?? IsDebugBuild);
    }

    public static void ApplyBrowserDebugSettings(CoreWebView2Settings settings, bool devToolsFlag)
    {
        var enabled = ShouldEnableBrowserDebugFeatures(devToolsFlag);
        settings.AreDefaultContextMenusEnabled = enabled;
        settings.AreDevToolsEnabled = enabled;
    }

    public static bool IsAllowedVirtualHostNavigation(string? uri, string hostName)
    {
        return Uri.TryCreate(uri, UriKind.Absolute, out var parsed)
            && parsed.Scheme.Equals(Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase)
            && parsed.Host.Equals(hostName, StringComparison.OrdinalIgnoreCase);
    }

    public static bool ShouldAllowMicrophone(
        string? uri,
        CoreWebView2PermissionKind permissionKind,
        bool isUserInitiated,
        bool featureEnabled,
        bool panelVisible,
        DateTimeOffset? armedUntil,
        DateTimeOffset now)
    {
        return permissionKind == CoreWebView2PermissionKind.Microphone
            && isUserInitiated
            && featureEnabled
            && panelVisible
            && armedUntil is { } deadline
            && deadline >= now
            && Uri.TryCreate(uri, UriKind.Absolute, out var parsed)
            && parsed.Scheme.Equals(Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase)
            && parsed.Host.Equals(PanelHostName, StringComparison.OrdinalIgnoreCase)
            && parsed.IsDefaultPort
            && string.IsNullOrEmpty(parsed.UserInfo);
    }

    public static bool ShouldOpenExternalBrowser(string? uri, string hostName)
    {
        return Uri.TryCreate(uri, UriKind.Absolute, out var parsed)
            && (parsed.Scheme.Equals(Uri.UriSchemeHttp, StringComparison.OrdinalIgnoreCase)
                || parsed.Scheme.Equals(Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase))
            && !IsAllowedVirtualHostNavigation(parsed.AbsoluteUri, hostName);
    }

    public static void TryOpenExternalBrowser(string? uri, string hostName)
    {
        if (!ShouldOpenExternalBrowser(uri, hostName)
            || !Uri.TryCreate(uri, UriKind.Absolute, out var parsed))
        {
            return;
        }

        try
        {
            using var _ = Process.Start(new ProcessStartInfo(parsed.AbsoluteUri)
            {
                UseShellExecute = true
            });
        }
        catch (Exception ex) when (ex is InvalidOperationException or System.ComponentModel.Win32Exception or ArgumentException)
        {
        }
    }
}
