using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using HoverPocket.Shell.Bridge;
using HoverPocket.Shell.Configuration;
using HoverPocket.Shell.Display;
using HoverPocket.Shell.Interop;
using HoverPocket.Shell.PocketApps;
using HoverPocket.Shell.Voice;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;

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
        HorizontalAlignment = System.Windows.HorizontalAlignment.Center,
        VerticalAlignment = System.Windows.VerticalAlignment.Top
    };
    private readonly Border _fallbackVisual;
    private readonly TranslateTransform _contentTransform = new();
    private readonly List<string> _processFailures = [];
    private bool _isAnimating;
    private WebView2CompositionControl? _webView;
    private Task? _initializationTask;
    private IDisposable? _bridgeAttachment;
    private long _microphoneGestureExpiresAt;
    private BridgeDispatcher? _bridgeDispatcher;
    private bool _closed;

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
            + VoicePanelGeometry.Height(_bridgeController.CurrentSettings.PanelSize, _bridgeController.ResolvedVoiceLaneMode);
        _contentHost.Width = Width;
        _contentHost.Height = Height;
        MinWidth = 1;
        MinHeight = 1;
        MaxWidth = PanelSizeCatalog.Get(PanelSize.ExtraLarge).Width;
        MaxHeight = PanelSizeCatalog.Get(PanelSize.ExtraLarge).TotalHeight
            + VoicePanelGeometry.ExpandedHeight(PanelSize.ExtraLarge) + AccessSurfaceWindow.SurfaceHeight;
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
        _contentHost.RenderTransform = _contentTransform;
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

    protected override bool ActivatesOnMouseInteraction => true;

    public WebView2CompositionControl? WebView => _webView;

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
        EndKeyboardInteraction();
        return !IsVisible ? Task.CompletedTask : RetargetLiquid(0, "Close");
    }

    public Task ResizeAsync(WindowPlacement target)
    {
        SetLiquidTarget(target, snap: !IsVisible);
        return IsVisible ? RetargetLiquid(_reveal.Target, "Resize") : Task.CompletedTask;
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
        ApplyPlacement(placement, show: false);
        var contentTop = layout.AccessSurface.DipRect.Height;
        _liquidShape = LiquidPanelGeometry.Shape(_reveal.Value, w, h,
            layout.AccessSurface.DipRect.Width, contentTop, _attachment.Value);
        _root.Clip = _liquidShape.Path;
        _fallbackVisual.Margin = new Thickness(0, contentTop, 0, 0);
        if (_webView is not null)
        {
            _contentHost.Margin = new Thickness(0, contentTop, 0, 0);
            // CompositionControl's capture pool rejects zero-sized content during collapse.
            // Keep content at panel dimensions; only the shared silhouette shrinks.
            _contentHost.Width = w;
            _contentHost.Height = Math.Max(1, h - contentTop);
            _contentHost.Opacity = _liquidShape.ContentOpacity;
            _contentTransform.Y = _liquidShape.ContentOffset;
            _webView.IsHitTestVisible = _reveal.Value >= .88 && _reveal.Target > 0;
        }
        NativeMethods.SetLiquidWindowRegion(Hwnd, _liquidShape.Path, scaleX, scaleY);
    }

    public bool ContainsPhysicalPoint(int x, int y, double toleranceDips = 0)
    {
        if (_liquidShape is null || _liquidLayout is null) return false;
        var rect = new Rect(Left, Top, Width, Height);
        return _liquidShape.Contains(new System.Windows.Point(x / _liquidLayout.Monitor.ScaleX - rect.Left,
            y / _liquidLayout.Monitor.ScaleY - rect.Top), toleranceDips);
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
        var webView = new WebView2CompositionControl
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

    private object BeginKeyboardInteraction()
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

    protected override void OnClosed(EventArgs e)
    {
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

    private void ApplyRoundedRegion()
    {
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
