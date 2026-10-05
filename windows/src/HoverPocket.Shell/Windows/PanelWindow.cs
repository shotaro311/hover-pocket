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
using HoverPocket.Shell.PocketApps;
using HoverPocket.Shell.Voice;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;
using HoverPocket.Shell.Providers.Assets;
using DataFormats = System.Windows.DataFormats;
using DragDropEffects = System.Windows.DragDropEffects;

namespace HoverPocket.Shell.Windows;

internal sealed class PanelWindow : NoActivateWindow
{
    public const double CollapsedWidth = AccessSurfaceWindow.SurfaceWidth;
    public const double CollapsedHeight = AccessSurfaceWindow.SurfaceHeight;
    private const string UiHostName = "app.hoverpocket.local";
    private const string UiBaseUrl = "https://app.hoverpocket.local/index.html";
    private const double CornerRadiusDips = 18;
    private static readonly long MicrophoneGestureLifetimeTicks =
        (long)(Stopwatch.Frequency * 5.0);

    private readonly PanelBridgeController _bridgeController;
    private readonly bool _enableWebView;
    private readonly bool _enableDevTools;
    private readonly bool _externalIntegrationsEnabled;
    private readonly string _webViewDataDirectory;
    private readonly Grid _root = new();
    private readonly Grid _contentHost = new()
    {
        HorizontalAlignment = System.Windows.HorizontalAlignment.Left,
        VerticalAlignment = System.Windows.VerticalAlignment.Top
    };
    private readonly Border _fallbackVisual;
    private readonly TranslateTransform _contentTransform = new();
    private readonly System.Windows.Controls.Image _resizeImage = new()
    {
        Stretch = Stretch.Fill, HorizontalAlignment = System.Windows.HorizontalAlignment.Left,
        VerticalAlignment = System.Windows.VerticalAlignment.Top, IsHitTestVisible = false, Visibility = Visibility.Collapsed
    };
    private readonly Grid _resizeCover = new() { Background = new SolidColorBrush(System.Windows.Media.Color.FromRgb(4, 4, 6)), IsHitTestVisible = false, Visibility = Visibility.Collapsed };
    private ResizeOverlayWindow? _resizeOverlay;
    private WindowPlacement? _resizeImagePlacement;
    private double _resizeImageTop;
    private bool _resizePrepared;
    private long _resizeRevision;
    private WindowPlacement? _pendingResizeTarget;
    private Task? _resizeTask;
    private WindowPlacement? _resizeViewport;
    private readonly TranslateTransform _viewportOffset = new();
    private readonly List<string> _processFailures = [];
    private bool _isAnimating;
    private WebView2CompositionControl? _webView;
    private Task? _initializationTask;
    private IDisposable? _bridgeAttachment;
    private long _microphoneGestureExpiresAt;
    private BridgeDispatcher? _bridgeDispatcher;
    private bool _closed;
    private AssetPaneController? _assetPane;
    public AssetPreviewLayout AssetLayout { get; private set; } = new(false);
    public event Action<AssetPreviewLayout>? AssetLayoutChanged;
    public event Action? AssetOrganizerRequested;
    public event Action? AssetPreviewDismissRequested;
    public event Action<bool>? AssetDragChanged;
    public async Task ReceiveAssetDropAsync(System.Windows.IDataObject data)
    {
        var payload = AssetDropPayload.Capture(data, _bridgeController.AssetLibrary.Root);
        await ReceiveAssetPayloadAsync(payload);
    }
    internal async Task<string> ReceiveAssetPayloadAsync(AssetDropPayload payload, string? folderId = null)
    {
        await EnsureWebViewInitializedAsync();
        if (_assetPane is null) throw new InvalidOperationException("素材ライブラリを開けませんでした。");
        return await _assetPane.ImportPayloadAsync(payload, folderId);
    }
    public void EndAssetPreview() { if (AssetLayout.Active) _assetPane?.EndPreview(); }
    internal string DragTraceForVerify => _assetPane?.DragTraceForVerify ?? "no-pane";
    internal string DragStateForVerify => _assetPane?.DragStateForVerify ?? "no-pane";
    internal bool InternalAssetDragForVerify => _assetPane?.InternalDragForVerify == true;
    public bool AssetBackgrounded { get; private set; }
    public void SetAssetBackgrounded(bool backgrounded)
    {
        AssetBackgrounded = backgrounded && AssetLayout.Active;
        Topmost = !AssetBackgrounded;
        if (Hwnd != IntPtr.Zero) NativeMethods.SetTopmostNoActivate(Hwnd, Topmost);
    }

    protected override void OnDeactivated(EventArgs e)
    {
        base.OnDeactivated(e);
        if (!_closed && !NativeMethods.ForegroundBelongsToCurrentProcess()) DismissAssetPreviewOnFocusLoss();
    }

    internal void DismissAssetPreviewOnFocusLoss()
    {
        if (!AssetLayout.Active || AssetLayout.PinOnly) return;
        Services.AppDiagnostics.Record("asset.preview.focus-lost");
        AssetPreviewDismissRequested?.Invoke();
    }

    public AnimationDiagnostics LastAnimationDiagnostics { get; private set; } = AnimationDiagnostics.Empty;

    public PanelWindow(
        PanelBridgeController bridgeController,
        bool enableWebView,
        bool enableDevTools,
        string webViewDataDirectory,
        bool externalIntegrationsEnabled = true)
        : base(allowsTransparency: false)
    {
        _bridgeController = bridgeController;
        _enableWebView = enableWebView;
        _enableDevTools = enableDevTools;
        _externalIntegrationsEnabled = externalIntegrationsEnabled;
        _webViewDataDirectory = webViewDataDirectory;
        Title = "HoverPocket";

        var metrics = PanelSizeCatalog.Get(_bridgeController.CurrentSettings.PanelSize);
        Width = metrics.Width;
        Height = metrics.TotalHeight
            + _bridgeController.ChatHeight
            + VoicePanelGeometry.Height(_bridgeController.CurrentSettings.PanelSize, _bridgeController.ResolvedVoiceLaneMode);
        _contentHost.Width = Width;
        _contentHost.Height = Height;
        MinWidth = 1;
        MinHeight = 1;
        MaxWidth = double.PositiveInfinity;
        MaxHeight = double.PositiveInfinity;
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
        _root.Children.Add(_contentHost);
        _resizeCover.Children.Add(_resizeImage);
        RenderOptions.SetBitmapScalingMode(_resizeImage, BitmapScalingMode.HighQuality);
        _contentHost.RenderTransform = _contentTransform;
        _contentHost.RenderTransformOrigin = new System.Windows.Point(.5, 0);
        _root.HorizontalAlignment = System.Windows.HorizontalAlignment.Left;
        _root.VerticalAlignment = System.Windows.VerticalAlignment.Top;
        _root.UseLayoutRounding = true;
        Content = _root;
        AllowDrop = true;
        System.Windows.DragEventHandler assetDragOver = (_, args) =>
        {
            if (_assetPane?.HandleInternalDrag(args) == true) return;
            if (!_bridgeController.AssetsVisible) { args.Effects = DragDropEffects.None; args.Handled = true; return; }
            AssetDragChanged?.Invoke(true);
            _ = _bridgeController.BeginAssetDropAsync();
            args.Effects = DragDropEffects.Copy; args.Handled = true;
        };
        PreviewDragEnter += assetDragOver; PreviewDragOver += assetDragOver;
        PreviewDragLeave += (_, _) => { _assetPane?.ClearDragHover(); AssetDragChanged?.Invoke(false); };
        PreviewDrop += async (_, args) =>
        {
            if (_assetPane?.HandleInternalDrag(args, drop: true) == true) return;
            args.Handled = true;
            if (_assetPane is null || !_bridgeController.AssetsVisible) return;
            try
            {
                var payload = AssetDropPayload.Capture(args.Data, _bridgeController.AssetLibrary.Root);
                await _bridgeController.BeginAssetDropAsync();
                await _bridgeController.FinishAssetDropAsync(true);
                await _assetPane.ImportPayloadAsync(payload);
            }
            catch { await _assetPane.ShowDropErrorAsync(); }
            finally { AssetDragChanged?.Invoke(false); }
        };

        SizeChanged += (_, _) =>
        {
            if (!_isAnimating)
            {
                ApplyRoundedRegion();
            }
        };
    }

    public IReadOnlyList<string> ProcessFailures => _processFailures;

    public bool IsAnimating => _isAnimating || _resizePrepared || _resizeTask is { IsCompleted: false };

    public bool KeyboardInteractionEnabled => ActivationEnabled;

    protected override bool ActivatesOnMouseInteraction => true;

    public WebView2CompositionControl? WebView => _webView;

    public void ReleaseBridgeAttachment()
    {
        _assetPane?.Dispose(); _assetPane = null;
        _bridgeAttachment?.Dispose();
        _bridgeAttachment = null;
    }

    public void PrepareCollapsedState()
    {
        MinWidth = 1;
        MinHeight = 1;
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

    public async Task<PocketAppStateTransitionLease> BeginPocketAppStateTransitionAsync(
        string appId,
        CancellationToken cancellationToken = default)
    {
        if (!Dispatcher.CheckAccess())
        {
            return await Dispatcher.InvokeAsync(
                () => BeginPocketAppStateTransitionAsync(appId, cancellationToken)).Task.Unwrap();
        }
        if (_closed || _initializationTask is null)
        {
            return PocketAppStateTransitionLease.Noop(appId);
        }

        await _initializationTask;
        if (_webView?.CoreWebView2 is null)
        {
            return PocketAppStateTransitionLease.Noop(appId);
        }

        var operationId = Guid.NewGuid().ToString("N");
        var operationJson = JsonSerializer.Serialize(operationId, BridgeJson.Options);
        var appIdJson = JsonSerializer.Serialize(appId, BridgeJson.Options);
        var startScript = $$"""
            (() => {
                const operationId = {{operationJson}};
                window.__hoverPocketStateFlushResults ??= Object.create(null);
                window.__hoverPocketStateFlushResults[operationId] = null;
                Promise.resolve(
                    typeof window.__hoverPocketFlushActiveProviderState === "function"
                        ? window.__hoverPocketFlushActiveProviderState({{appIdJson}}, {{operationJson}})
                        : false)
                    .then((saved) => { window.__hoverPocketStateFlushResults[operationId] = saved !== false; })
                    .catch(() => { window.__hoverPocketStateFlushResults[operationId] = false; });
                return true;
            })()
            """;
        try
        {
            _ = await _webView.ExecuteScriptAsync(startScript);
            var deadline = DateTimeOffset.UtcNow + TimeSpan.FromSeconds(5);
            while (DateTimeOffset.UtcNow < deadline)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var result = await _webView.ExecuteScriptAsync(
                    $"window.__hoverPocketStateFlushResults?.[{operationJson}] ?? null");
                if (result.Equals("true", StringComparison.OrdinalIgnoreCase))
                {
                    return new PocketAppStateTransitionLease(appId, operationId, true);
                }
                if (result.Equals("false", StringComparison.OrdinalIgnoreCase))
                {
                    return new PocketAppStateTransitionLease(appId, operationId, false);
                }
                await Task.Delay(50, cancellationToken);
            }
            return new PocketAppStateTransitionLease(appId, operationId, false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            await CompletePocketAppStateTransitionCoreAsync(operationId);
            throw;
        }
        catch
        {
            await CompletePocketAppStateTransitionCoreAsync(operationId);
            return PocketAppStateTransitionLease.Failed(appId);
        }
        finally
        {
            try
            {
                _ = await _webView.ExecuteScriptAsync(
                    $"delete window.__hoverPocketStateFlushResults?.[{operationJson}]");
            }
            catch
            {
            }
        }
    }

    public async Task CompletePocketAppStateTransitionAsync(PocketAppStateTransitionLease lease)
    {
        if (!Dispatcher.CheckAccess())
        {
            await Dispatcher.InvokeAsync(
                () => CompletePocketAppStateTransitionAsync(lease)).Task.Unwrap();
            return;
        }
        if (_closed || _initializationTask is null || lease.OperationId is null)
        {
            return;
        }

        await _initializationTask;
        if (_webView?.CoreWebView2 is null)
        {
            return;
        }

        await CompletePocketAppStateTransitionCoreAsync(lease.OperationId);
    }

    private async Task CompletePocketAppStateTransitionCoreAsync(string operationId)
    {
        if (_webView?.CoreWebView2 is null) { return; }
        var operationJson = JsonSerializer.Serialize(operationId, BridgeJson.Options);
        try
        {
            _ = await _webView.ExecuteScriptAsync(
                $"window.__hoverPocketCompleteActiveProviderStateTransition?.({operationJson})");
        }
        catch
        {
        }
    }

    public async Task<bool> VerifyBackgroundBridgePostAsync()
    {
        if (_bridgeDispatcher is not { } dispatcher || _webView?.CoreWebView2 is null)
        {
            return false;
        }

        await _webView.ExecuteScriptAsync("""
            window.__backgroundBridgeReceived = false;
            window.chrome.webview.addEventListener('message', function probe(event) {
                if (event.data?.event === 'diagnostics.backgroundThread') {
                    window.__backgroundBridgeReceived = event.data.payload?.verified === true;
                    window.chrome.webview.removeEventListener('message', probe);
                }
            });
            """);
        await Task.Run(() => dispatcher.PostEventAsync("diagnostics.backgroundThread", new { verified = true }));
        var deadline = DateTimeOffset.UtcNow + TimeSpan.FromSeconds(3);
        while (DateTimeOffset.UtcNow < deadline)
        {
            if (await _webView.ExecuteScriptAsync("window.__backgroundBridgeReceived === true") == "true")
            {
                return true;
            }

            await Task.Delay(50);
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
        var deadline = DateTimeOffset.UtcNow + TimeSpan.FromSeconds(18);
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

    public Task OpenAsync(DisplaySurfaceLayout layout) =>
        OpenAsync(layout, layout.PanelTarget);

    private readonly LiquidSpring _reveal = new(0);
    private readonly LiquidSpring _attachment = new(0);
    private LiquidSpring _liquidWidth = new(600);
    private LiquidSpring _liquidHeight = new(439);
    private DisplaySurfaceLayout? _liquidLayout;
    private WindowPlacement? _liquidTarget;
    private LiquidPanelShape? _liquidShape;
    private TaskCompletionSource? _transition;
    private long _previousTick;
    private long _transitionStart;
    private int _frameCount;
    private TimeSpan _maximumGap;
    private string _direction = "None";
    private long _liquidRevision;

    public double RevealForVerify => _reveal.Value;
    public LiquidPanelShape? ShapeForVerify => _liquidShape;
    public bool IsOpening => _reveal.Target > 0;
    public WindowPlacement? LiquidTargetForVerify => _liquidTarget;
    private bool MotionReduced => _bridgeController.CurrentSettings.ReduceMotion || !SystemParameters.ClientAreaAnimation;

    public Task OpenAsync(DisplaySurfaceLayout layout, WindowPlacement? target = null)
    {
        _liquidLayout = layout;
        SetLiquidTarget(target ?? layout.PanelTarget, snap: !IsVisible);
        if (!IsVisible) _reveal.Snap(0);
        Opacity = 1;
        // Install the small region before showing the full content host.
        ApplyLiquidSurface();
        ShowNoActivate();
        return RetargetLiquid(1, "Open");
    }

    public Task CloseAsync(DisplaySurfaceLayout layout)
    {
        CancelResizeImage();
        EndKeyboardInteraction();
        return !IsVisible ? Task.CompletedTask : RetargetLiquid(0, "Close");
    }

    public Task ResizeAsync(WindowPlacement target)
    {
        if (_pendingResizeTarget == target) return _resizeTask ?? Task.CompletedTask;
        if (_pendingResizeTarget is not null) CancelResizeImage();
        if (_liquidTarget == target) { CancelResizeImage(); ApplyLiquidSurface(); return _transition?.Task ?? Task.CompletedTask; }
        _pendingResizeTarget = target;
        return _resizeTask = ResizeContentAsync(target, ++_resizeRevision);
    }

    private async Task ResizeContentAsync(WindowPlacement target, long revision)
    {
        try
        {
            if (!_resizePrepared && IsVisible && !MotionReduced && _reveal.Value > .5 && _webView?.CoreWebView2 is not null)
            {
                var snapshot = CaptureDisplayedContent();
                if (_closed || revision != _resizeRevision) return;
                _resizeImage.Source = snapshot;
                _resizeImage.Visibility = Visibility.Visible;
                _resizeCover.Visibility = Visibility.Visible;
                _resizeImagePlacement = _liquidTarget;
                _resizeImageTop = AssetLayout.Fullscreen ? 0 : _liquidLayout?.AccessSurface.DipRect.Height ?? 0;
                await ShowResizeOverlayAsync(revision);
            }
            if (_closed || revision != _resizeRevision) return;
            if (IsVisible && _liquidLayout is { } layout && !MotionReduced)
            {
                _resizeViewport = target;
            }
            SetLiquidTarget(target, snap: !IsVisible);
            if (_resizeImage.Visibility == Visibility.Visible)
            {
                // Keep both the HWND and content pixels stationary. Only the silhouette
                // expands; scaling text on every frame makes it shimmer and jump.
                ApplyLiquidSurface();
                _root.UpdateLayout();
                await _webView!.CoreWebView2.CallDevToolsProtocolMethodAsync("Runtime.evaluate",
                    "{\"expression\":\"new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(()=>resolve(true))))\",\"awaitPromise\":true}").WaitAsync(TimeSpan.FromSeconds(2));
                if (_closed || revision != _resizeRevision) return;
                var destination = await CaptureContentAsync();
                if (_closed || revision != _resizeRevision) return;
                _resizeImage.Source = destination;
                _resizeImagePlacement = target;
                _resizeImageTop = AssetLayout.Fullscreen ? 0 : _liquidLayout?.AccessSurface.DipRect.Height ?? 0;
                ApplyLiquidSurface();
            }
            if (IsVisible) await RetargetLiquid(_reveal.Target, "Resize").WaitAsync(TimeSpan.FromSeconds(3));
        }
        catch (Exception ex) when (ex is InvalidOperationException or System.Runtime.InteropServices.COMException or IOException or TaskCanceledException or TimeoutException or NotSupportedException)
        {
            Services.AppDiagnostics.Record("panel.resize.snapshot.failed", ex);
            if (!_closed && revision == _resizeRevision)
            {
                SetLiquidTarget(target, snap: true);
                CompleteLiquid();
            }
        }
        finally
        {
            if (revision == _resizeRevision)
            {
                _pendingResizeTarget = null;
                _resizePrepared = false;
                _resizeViewport = null;
                // Opacity first: ApplyLiquidSurface restores the live region only for a visible panel.
                Opacity = 1;
                if (!_closed) ApplyLiquidSurface();
                // Hide() is immediate while Opacity applies on WPF's next frame. Keep the
                // matching overlay until the live panel has presented to avoid a blank frame.
                if (!_closed && _resizeOverlay is { IsVisible: true })
                    try { await WaitForRenderedFramesAsync(2); } catch (TimeoutException) { }
            }
            if (revision == _resizeRevision)
            {
                _resizeImage.Visibility = Visibility.Collapsed;
                _resizeImage.Source = null;
                _resizeCover.Visibility = Visibility.Collapsed;
                _resizeImagePlacement = null;
                if (_resizeOverlay is { IsVisible: true }) _resizeOverlay.Hide();
                if (!_closed) ApplyLiquidSurface();
            }
        }
    }

    internal Func<Stream, Task>? CapturePreviewForVerify { get; set; }
    internal bool ResizeOverlayVisibleForVerify => _resizeOverlay?.IsVisible == true;

    private async Task<BitmapSource> CaptureContentAsync()
    {
        var stream = new MemoryStream();
        Task? capture = null;
        try
        {
            capture = CapturePreviewForVerify?.Invoke(stream)
                ?? _webView!.CoreWebView2.CapturePreviewAsync(CoreWebView2CapturePreviewImageFormat.Png, stream);
            await capture.WaitAsync(TimeSpan.FromSeconds(2));
            stream.Position = 0;
            var bitmap = new BitmapImage(); bitmap.BeginInit(); bitmap.CacheOption = BitmapCacheOption.OnLoad;
            bitmap.StreamSource = stream; bitmap.EndInit(); bitmap.Freeze(); return bitmap;
        }
        finally
        {
            // WebView capture cannot be cancelled; a late completion still owns the stream.
            if (capture is { IsCompleted: false }) _ = DisposeCaptureStreamAsync(capture, stream);
            else stream.Dispose();
        }
    }

    private static async Task DisposeCaptureStreamAsync(Task capture, Stream stream)
    {
        try { await capture; }
        catch { /* The resize has already recovered from the timeout. */ }
        finally { stream.Dispose(); }
    }

    private BitmapSource CaptureDisplayedContent()
    {
        var dpi = VisualTreeHelper.GetDpi(_contentHost);
        var width = Math.Max(1, _contentHost.ActualWidth); var height = Math.Max(1, _contentHost.ActualHeight);
        var visual = new DrawingVisual();
        using (var drawing = visual.RenderOpen()) drawing.DrawRectangle(new VisualBrush(_contentHost) { Stretch = Stretch.Fill }, null, new Rect(0, 0, width, height));
        var bitmap = new RenderTargetBitmap((int)Math.Ceiling(width * dpi.DpiScaleX), (int)Math.Ceiling(height * dpi.DpiScaleY), dpi.PixelsPerInchX, dpi.PixelsPerInchY, PixelFormats.Pbgra32);
        bitmap.Render(visual); bitmap.Freeze(); return bitmap;
    }

    private async Task ShowResizeOverlayAsync(long revision)
    {
        _resizeOverlay ??= new ResizeOverlayWindow { Owner = this, Content = _resizeCover };
        _resizeOverlay.EnsureHandle();
        ApplyLiquidSurface();
        _resizeOverlay.ShowNoActivate();
        // Present the old frame before moving the browser's HWND behind it.
        await WaitForRenderedFramesAsync(2);
        if (!_closed && revision == _resizeRevision) { Opacity = 0; NativeMethods.SetEmptyWindowRegion(Hwnd); }
    }

    private static async Task WaitForRenderedFramesAsync(int count)
    {
        var presented = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var frames = 0;
        EventHandler rendered = (_, _) => { if (++frames == count) presented.TrySetResult(); };
        CompositionTarget.Rendering += rendered;
        try { await presented.Task.WaitAsync(TimeSpan.FromMilliseconds(250)); }
        finally { CompositionTarget.Rendering -= rendered; }
    }

    private sealed class ResizeOverlayWindow : NoActivateWindow
    {
        public ResizeOverlayWindow() : base(allowsTransparency: false) { Title = "HoverPocket transition"; MinWidth = MinHeight = 1; }
    }

    internal async Task<long> PrepareContentTransitionAsync()
    {
        var revision = ++_resizeRevision;
        _pendingResizeTarget = null; _resizeTask = null;
        if (_resizeImage.Source is not null) { _resizePrepared = true; return revision; }
        if (!IsVisible || MotionReduced || _reveal.Value <= .5 || _webView?.CoreWebView2 is null) return revision;
        _resizePrepared = true;
        try
        {
            var placement = _liquidTarget;
            var top = AssetLayout.Fullscreen ? 0 : _liquidLayout?.AccessSurface.DipRect.Height ?? 0;
            var snapshot = CaptureDisplayedContent();
            if (_closed || revision != _resizeRevision) return revision;
            _resizeImage.Source = snapshot; _resizeImagePlacement = placement; _resizeImageTop = top;
            _resizeImage.Visibility = _resizeCover.Visibility = Visibility.Visible;
            _resizePrepared = true;
            await ShowResizeOverlayAsync(revision);
        }
        catch (Exception ex) when (ex is InvalidOperationException or System.Runtime.InteropServices.COMException or IOException or NotSupportedException or TimeoutException)
        { Services.AppDiagnostics.Record("panel.resize.prepare.failed", ex); CancelContentTransition(revision); }
        return revision;
    }

    internal void CancelContentTransition(long revision)
    { if (revision == _resizeRevision) { CancelResizeImage(); if (!_closed) ApplyLiquidSurface(); } }

    private void CancelResizeImage()
    {
        ++_resizeRevision; _pendingResizeTarget = null; _resizeTask = null;
        _resizeImage.Visibility = Visibility.Collapsed; _resizeImage.Source = null;
        _resizeCover.Visibility = Visibility.Collapsed; _resizeImagePlacement = null; _resizePrepared = false;
        _resizeViewport = null;
        Opacity = 1;
        // Restore the live region cleared while the overlay was presenting.
        if (!_closed) ApplyLiquidSurface();
        if (_resizeOverlay is { IsVisible: true }) _resizeOverlay.Hide();
    }

    private void SetLiquidTarget(WindowPlacement target, bool snap)
    {
        _liquidTarget = target;
        if (snap)
        {
            _liquidWidth.Snap(target.DipRect.Width);
            _liquidHeight.Snap(target.DipRect.Height);
        }
        else
        {
            _liquidWidth.Target = target.DipRect.Width;
            _liquidHeight.Target = target.DipRect.Height;
        }
        _attachment.Target = PanelAttachment.Resolve(_bridgeController.CurrentSettings) == PanelAttachmentStyle.CoverMenu ? 1 : 0;
        if (snap || MotionReduced) _attachment.Snap(_attachment.Target);
    }

    private Task RetargetLiquid(double target, string direction)
    {
        _liquidRevision++;
        _transition?.TrySetResult();
        var transition = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        _transition = transition;
        _reveal.Target = target;
        _attachment.Target = PanelAttachment.Resolve(_bridgeController.CurrentSettings) == PanelAttachmentStyle.CoverMenu ? 1 : 0;
        _direction = direction;
        _transitionStart = _previousTick = Stopwatch.GetTimestamp();
        _frameCount = 0;
        _maximumGap = TimeSpan.Zero;
        if (MotionReduced)
        {
            _reveal.Snap(target);
            _attachment.Snap(_attachment.Target);
            _liquidWidth.Snap(_liquidWidth.Target);
            _liquidHeight.Snap(_liquidHeight.Target);
            CompleteLiquid();
        }
        else if (!_isAnimating)
        {
            _isAnimating = true;
            CompositionTarget.Rendering += RenderLiquid;
        }
        return transition.Task;
    }

    private void RenderLiquid(object? sender, EventArgs e)
    {
        if (_closed) { StopLiquid(); return; }
        var gap = Stopwatch.GetElapsedTime(_previousTick);
        if (gap.TotalMilliseconds < 5) return;
        _previousTick = Stopwatch.GetTimestamp();
        _maximumGap = gap > _maximumGap ? gap : _maximumGap;
        var dt = Math.Min(1.0 / 30, gap.TotalSeconds);
        _reveal.Step(dt, _reveal.Target > 0 ? .32 : .26);
        _attachment.Step(dt, .28);
        _liquidWidth.Step(dt, .28);
        _liquidHeight.Step(dt, .28);
        _frameCount++;
        if (_reveal.Target == 0 && _reveal.Value <= .012) _reveal.Snap(0);
        if (_reveal.Settled() && _attachment.Settled()
            && _liquidWidth.Settled(.1, .5) && _liquidHeight.Settled(.1, .5))
            CompleteLiquid();
        else ApplyLiquidSurface();
    }

    private void CompleteLiquid()
    {
        var revision = _liquidRevision;
        var transition = _transition;
        _reveal.Snap(_reveal.Target);
        _attachment.Snap(_attachment.Target);
        _liquidWidth.Snap(_liquidWidth.Target);
        _liquidHeight.Snap(_liquidHeight.Target);
        ApplyLiquidSurface();
        // Native placement may pump settings/Voice messages and retarget the spring.
        if (revision != _liquidRevision) return;
        StopLiquid();
        LastAnimationDiagnostics = new AnimationDiagnostics(_direction, _frameCount,
            Stopwatch.GetElapsedTime(_transitionStart), _maximumGap);
        if (_reveal.Target == 0)
        {
            Opacity = 0;
            Hide();
            if (_liquidLayout is { } layout) ApplyPlacement(layout.PanelCollapsed, show: false);
        }
        transition?.TrySetResult();
    }

    private void StopLiquid()
    {
        CompositionTarget.Rendering -= RenderLiquid;
        _isAnimating = false;
    }

    private void ApplyLiquidSurface()
    {
        if (_liquidTarget is not { } target || _liquidLayout is not { } layout) return;
        var w = Math.Max(1, _liquidWidth.Value);
        var h = Math.Max(1, _liquidHeight.Value);
        var scaleX = layout.Monitor.ScaleX;
        var scaleY = layout.Monitor.ScaleY;
        var dip = new Rect(target.DipRect.Left + (target.DipRect.Width - w) / 2, target.DipRect.Top, w, h);
        var placement = new WindowPlacement(dip, new PhysicalRect(
            (int)Math.Round(dip.Left * scaleX), target.PhysicalRect.Top,
            (int)Math.Round(w * scaleX), (int)Math.Round(h * scaleY)));
        var viewport = _resizeViewport ?? placement;
        // WPF moves the HWND in several SetWindowPos steps before the new region below is set.
        // The old region stays in window coordinates, so a presented frame would expose the
        // hidden (Opacity 0, black) panel beside the overlay. Keep it fully clipped while it moves.
        if (_resizeImage.Source is not null && Hwnd != IntPtr.Zero && NativeMethods.TryGetWindowRect(Hwnd, out var current)
            && (current.Left != viewport.PhysicalRect.Left || current.Top != viewport.PhysicalRect.Top
                || current.Width != viewport.PhysicalRect.Width || current.Height != viewport.PhysicalRect.Height))
            NativeMethods.SetEmptyWindowRegion(Hwnd);
        ApplyPlacement(viewport, show: false);
        _root.Width = viewport.DipRect.Width; _root.Height = viewport.DipRect.Height;
        _viewportOffset.X = dip.Left - viewport.DipRect.Left;
        _viewportOffset.Y = dip.Top - viewport.DipRect.Top;
        var contentTop = AssetLayout.Fullscreen ? 0 : layout.AccessSurface.DipRect.Height;
        _liquidShape = LiquidPanelGeometry.Shape(_reveal.Value, w, h,
            layout.AccessSurface.DipRect.Width, contentTop, _attachment.Value);
        var clip = AssetLayout.Fullscreen ? new RectangleGeometry(new Rect(0, 0, w, h)) : _liquidShape.Path;
        _fallbackVisual.Margin = new Thickness(0, contentTop, 0, 0);
        if (_webView is not null)
        {
            _contentHost.Margin = new Thickness(target.DipRect.Left - viewport.DipRect.Left, target.DipRect.Top - viewport.DipRect.Top + contentTop, 0, 0);
            // CompositionControl's capture pool rejects zero-sized content during collapse.
            // Keep content at panel dimensions; only the shared silhouette shrinks.
            // Resize the live WebView once, without transforms that alter its capture bounds.
            // A separate bitmap covers intermediate CompositionControl frames while resizing.
            _contentHost.Width = target.DipRect.Width;
            _contentHost.Height = Math.Max(1, target.DipRect.Height - contentTop);
            if (_resizeImagePlacement is { } imagePlacement)
            {
                _resizeImage.Margin = new Thickness(imagePlacement.DipRect.Left - layout.Monitor.Bounds.Left / scaleX, imagePlacement.DipRect.Top - layout.Monitor.Bounds.Top / scaleY + _resizeImageTop, 0, 0);
                _resizeImage.Width = imagePlacement.DipRect.Width;
                _resizeImage.Height = Math.Max(1, imagePlacement.DipRect.Height - _resizeImageTop);
            }
            _contentHost.Opacity = _liquidShape.ContentOpacity;
            _contentTransform.Y = _liquidShape.ContentOffset;
            _webView.IsHitTestVisible = _reveal.Value >= .88 && _reveal.Target > 0 && _resizeImage.Visibility != Visibility.Visible;
        }
        var nativeClip = clip;
        if (_viewportOffset.X != 0 || _viewportOffset.Y != 0)
        {
            nativeClip = clip.Clone();
            nativeClip.Transform = new TranslateTransform(_viewportOffset.X, _viewportOffset.Y);
        }
        _root.Clip = nativeClip;
        // While the overlay presents the transition, the hidden panel (Opacity 0 renders black)
        // stays fully clipped so no move, resize or first present can show it beside the overlay.
        if (MainHiddenBehindOverlay) NativeMethods.SetEmptyWindowRegion(Hwnd);
        else NativeMethods.SetLiquidWindowRegion(Hwnd, nativeClip, scaleX, scaleY);
        if (_resizeOverlay is not null && _resizeImage.Source is not null)
        {
            var monitor = layout.Monitor.Bounds;
            var overlayBounds = new Rect(monitor.Left / scaleX, monitor.Top / scaleY, monitor.Width / scaleX, monitor.Height / scaleY);
            _resizeOverlay.ApplyPlacement(new(overlayBounds, monitor), show: false);
            var overlayClip = clip.Clone();
            overlayClip.Transform = new TranslateTransform(dip.Left - overlayBounds.Left, dip.Top - overlayBounds.Top);
            _resizeCover.Clip = overlayClip;
            NativeMethods.SetLiquidWindowRegion(_resizeOverlay.Hwnd, overlayClip, scaleX, scaleY);
        }
    }

    public bool ContainsPhysicalPoint(int x, int y, double toleranceDips = 0)
    {
        if (_liquidShape is null || _liquidLayout is null) return false;
        if (AssetLayout.Fullscreen && _reveal.Target > 0 && _liquidTarget is { } fullscreen)
            return fullscreen.PhysicalRect.Contains(x, y);
        var rect = new Rect(Left, Top, Width, Height);
        return _liquidShape.Contains(new System.Windows.Point(x / _liquidLayout.Monitor.ScaleX - rect.Left - _viewportOffset.X,
            y / _liquidLayout.Monitor.ScaleY - rect.Top - _viewportOffset.Y), toleranceDips);
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
        var webView = new PanelWebView
        {
            CreationProperties = new CoreWebView2CreationProperties
            {
                AdditionalBrowserArguments = DisableGpuRequested() ? "--disable-gpu" : string.Empty,
                UserDataFolder = _webViewDataDirectory
            },
            DefaultBackgroundColor = System.Drawing.Color.Transparent
        };

        _webView = webView;
        _contentHost.Margin = new Thickness(0, AccessSurfaceWindow.SurfaceHeight, 0, 0);
        _contentHost.Children.Add(webView);
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
            Services.AppDiagnostics.Record($"webview.failed.{args.ProcessFailedKind}.{args.Reason}");
        };
        WebViewSecurityPolicy.ApplyBrowserDebugSettings(webView.CoreWebView2.Settings, _enableDevTools);
        webView.CoreWebView2.NavigationStarting += (_, args) =>
        {
            Interlocked.Exchange(ref _microphoneGestureExpiresAt, 0);
            if (WebViewSecurityPolicy.IsAllowedVirtualHostNavigation(args.Uri, UiHostName))
            {
                return;
            }

            args.Cancel = true;
            WebViewSecurityPolicy.TryOpenExternalBrowser(
                args.Uri,
                UiHostName,
                _externalIntegrationsEnabled);
        };
        webView.CoreWebView2.NewWindowRequested += (_, args) =>
        {
            args.Handled = true;
            WebViewSecurityPolicy.TryOpenExternalBrowser(
                args.Uri,
                UiHostName,
                _externalIntegrationsEnabled);
        };
        webView.CoreWebView2.PermissionRequested += (_, args) =>
        {
            var gestureActive = PeekVoiceMicrophoneGesture();
            var allow = IsVoiceMicrophonePermissionAllowedForVerify(
                args.Uri,
                args.PermissionKind,
                _bridgeController.CurrentSettings.VoiceEnabled,
                IsVisible && !_closed,
                gestureActive,
                args.IsUserInitiated);
            if (allow)
            {
                allow = ConsumeVoiceMicrophoneGesture();
            }
            args.State = allow
                ? CoreWebView2PermissionState.Allow
                : CoreWebView2PermissionState.Deny;
            args.SavesInProfile = false;
            args.Handled = true;
        };
        webView.CoreWebView2.SetVirtualHostNameToFolderMapping(
            UiHostName,
            uiFolder,
            CoreWebView2HostResourceAccessKind.DenyCors);

        var dispatcher = new BridgeDispatcher(json => PostBridgeJsonAsync(webView, json));
        _bridgeDispatcher = dispatcher;
        _bridgeAttachment = _bridgeController.Attach(
            dispatcher,
            approvalOwner: () => this,
            voiceMicrophoneGesture: RegisterVoiceMicrophoneGesture);
        _assetPane = new AssetPaneController(_bridgeController.AssetLibrary, this, dispatcher, webView.CoreWebView2,
            value => { if (AssetLayout == value) return; AssetLayout = value; if (!value.Active) SetAssetBackgrounded(false); AssetLayoutChanged?.Invoke(value); }, () => _bridgeController.SelectedProviderId,
            _bridgeController.AssetPlayback, () => AssetOrganizerRequested?.Invoke(), (kind, folder) => _bridgeController.AssetCaptureRequested?.Invoke(kind, folder) ?? Task.CompletedTask, webSurface: webView);
        dispatcher.Register("panel.beginTextInput", (_, _) =>
            Task.FromResult<object?>(BeginKeyboardInteraction()));
        dispatcher.Register("panel.endTextInput", (_, _) =>
            Task.FromResult<object?>(EndKeyboardInteraction()));
        webView.CoreWebView2.WebMessageReceived += async (_, args) =>
        {
            await dispatcher.HandleRawMessageAsync(args.TryGetWebMessageAsString());
        };
        webView.CoreWebView2.Navigate(UiBaseUrl);
    }

    private async Task PostBridgeJsonAsync(WebView2CompositionControl webView, string json)
    {
        if (Dispatcher.CheckAccess())
        {
            PostBridgeJson(webView, json);
            return;
        }

        if (Dispatcher.HasShutdownStarted || Dispatcher.HasShutdownFinished)
        {
            return;
        }

        try
        {
            await Dispatcher.InvokeAsync(() => PostBridgeJson(webView, json)).Task;
        }
        catch (InvalidOperationException) when (_closed || Dispatcher.HasShutdownStarted || Dispatcher.HasShutdownFinished)
        {
        }
        catch (TaskCanceledException) when (_closed || Dispatcher.HasShutdownStarted || Dispatcher.HasShutdownFinished)
        {
        }
    }

    private void PostBridgeJson(WebView2CompositionControl webView, string json)
    {
        if (_closed || !ReferenceEquals(_webView, webView) || webView.CoreWebView2 is null)
        {
            return;
        }

        webView.CoreWebView2.PostWebMessageAsJson(json);
    }

    internal object BeginKeyboardInteraction()
    {
        var activated = SetActivationEnabled(true);
        _ = _webView?.Focus();
        return KeyboardInteractionState(activated);
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

    protected override void OnClosing(System.ComponentModel.CancelEventArgs e)
    {
        base.OnClosing(e);
        if (e.Cancel) return;
        _closed = true;
        StopLiquid();
        ReleaseBridgeAttachment();
        _bridgeDispatcher = null;
        // Stop the composition capture before WPF destroys its parent HWND.
        _webView?.Dispose();
        _webView = null;
    }

    protected override void OnClosed(EventArgs e)
    {
        CancelResizeImage();
        _closed = true;
        StopLiquid();
        _transition?.TrySetResult();
        Interlocked.Exchange(ref _microphoneGestureExpiresAt, 0);
        EndKeyboardInteraction();
        ReleaseBridgeAttachment();
        _bridgeDispatcher = null;
        _webView?.Dispose();
        _webView = null;
        base.OnClosed(e);
    }

    private bool RegisterVoiceMicrophoneGesture()
    {
        if (_closed
            || !IsVisible
            || !_bridgeController.CurrentSettings.VoiceEnabled)
        {
            return false;
        }
        Interlocked.Exchange(
            ref _microphoneGestureExpiresAt,
            Stopwatch.GetTimestamp() + MicrophoneGestureLifetimeTicks);
        return true;
    }

    private bool PeekVoiceMicrophoneGesture()
    {
        var expiresAt = Volatile.Read(ref _microphoneGestureExpiresAt);
        return expiresAt > 0 && Stopwatch.GetTimestamp() <= expiresAt;
    }

    private bool ConsumeVoiceMicrophoneGesture()
    {
        var expiresAt = Interlocked.Exchange(ref _microphoneGestureExpiresAt, 0);
        return expiresAt > 0 && Stopwatch.GetTimestamp() <= expiresAt;
    }

    internal static bool IsVoiceMicrophonePermissionAllowedForVerify(
        string? uri,
        CoreWebView2PermissionKind permissionKind,
        bool featureEnabled,
        bool panelVisible,
        bool recentExplicitGesture,
        bool browserUserInitiated)
    {
        if (!featureEnabled
            || !panelVisible
            || !recentExplicitGesture
            || !browserUserInitiated
            || permissionKind != CoreWebView2PermissionKind.Microphone
            || !Uri.TryCreate(uri, UriKind.Absolute, out var parsed))
        {
            return false;
        }
        return parsed.Scheme == Uri.UriSchemeHttps
            && parsed.IsDefaultPort
            && string.IsNullOrEmpty(parsed.UserInfo)
            && string.Equals(parsed.Host, UiHostName, StringComparison.OrdinalIgnoreCase);
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

    private bool MainHiddenBehindOverlay => _resizeImage.Source is not null && Opacity == 0;

    private void ApplyRoundedRegion()
    {
        // During a content transition the HWND is at the arrival viewport and its region is
        // offset (ApplyLiquidSurface owns it). This untranslated shape would expose the panel
        // left of the overlay when SizeChanged fires between the move and the animation.
        if (_resizeImage.Source is not null) return;
        if (_liquidShape is not null && _liquidLayout is not null)
            NativeMethods.SetLiquidWindowRegion(Hwnd, _liquidShape.Path,
                _liquidLayout.Monitor.ScaleX, _liquidLayout.Monitor.ScaleY);
    }

    private static bool DisableGpuRequested()
    {
        return string.Equals(
            Environment.GetEnvironmentVariable("HOVERPOCKET_WEBVIEW_DISABLE_GPU"),
            "1",
            StringComparison.OrdinalIgnoreCase);
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
    bool LegacyAiLaneNotMountedOk,
    bool VoiceDefaultOffOk,
    bool VoiceTeardownVisibleOk,
    bool VoiceLocalizationOk,
    bool VoiceTransportContractOk,
    bool VoiceWebRtcHarnessOk,
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
    bool PocketSurfaceRenderedOk,
    bool PocketSurfaceSelectionOk,
    bool PocketSurfaceDurationOk,
    bool PocketSurfacePurposeOk,
    bool PocketSurfaceStatePersistedOk,
    bool PocketSurfaceStateBoundControlsPersistedOk,
    bool PocketSurfaceFailedStateWriteRetriedOk,
    bool PocketSurfaceWorkflowBlockedOnStateWriteFailureOk,
    bool PocketSurfaceStateWorkflowInputOk,
    bool PocketSurfaceApprovalHostOwnedOk,
    bool PocketSurfaceLayoutMatrixOk,
    bool PocketSurfaceStateTransitionBoundaryOk,
    bool TextSizeScaleReadyOk,
    bool ProviderSwitchOk,
    bool ProviderSwitchCleanupAwaitedOk,
    bool ProviderSwitchBlockedOnSaveFailureOk,
    bool ProviderRerenderCleanupAwaitedOk,
    bool ProviderRerenderBlockedOnSaveFailureOk,
    bool ProviderHostStateFlushOk,
    bool ProviderSurfaceIdentityRemountOk,
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

    public static bool ShouldOpenExternalBrowser(
        string? uri,
        string hostName,
        bool externalIntegrationsEnabled = true)
    {
        return externalIntegrationsEnabled
            && Uri.TryCreate(uri, UriKind.Absolute, out var parsed)
            && (parsed.Scheme.Equals(Uri.UriSchemeHttp, StringComparison.OrdinalIgnoreCase)
                || parsed.Scheme.Equals(Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase))
            && !IsAllowedVirtualHostNavigation(parsed.AbsoluteUri, hostName);
    }

    public static void TryOpenExternalBrowser(
        string? uri,
        string hostName,
        bool externalIntegrationsEnabled = true)
    {
        if (!ShouldOpenExternalBrowser(uri, hostName, externalIntegrationsEnabled)
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
