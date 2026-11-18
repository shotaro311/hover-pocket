using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;
using Button = System.Windows.Controls.Button;
using Color = System.Windows.Media.Color;

namespace HoverPocket.Shell.Providers.AiUsage;

/// <summary>
/// A plain browser window on the service's own usage profile where the user signs in themselves.
/// HoverPocket never sees the password; it only reuses the session afterwards. The window always shows
/// the host the page actually belongs to, warns when it is not one the service normally uses, and only
/// allows HTTPS pages.
/// </summary>
internal sealed class AiUsageSignInWindow : Window
{
    private static readonly SolidColorBrush NormalHost = new(Color.FromRgb(155, 166, 181));
    private static readonly SolidColorBrush WarningHost = new(Color.FromRgb(245, 195, 91));

    private readonly string _service;
    private readonly string _userDataFolder;
    private readonly Uri? _startUri;
    private readonly bool _english;
    private readonly WebView2 _webView;
    private readonly TextBlock _address;
    private readonly TaskCompletionSource<CoreWebView2> _ready = new(TaskCreationOptions.RunContinuationsAsynchronously);

    public AiUsageSignInWindow(string service, string userDataFolder, Uri? startUri, bool english, bool popup = false)
    {
        _service = service;
        _userDataFolder = userDataFolder;
        _startUri = startUri;
        _english = english;
        var serviceName = AiUsageServiceIds.DisplayName(service);
        Title = english ? $"Sign in to {serviceName} — HoverPocket" : $"{serviceName}にサインイン — HoverPocket";
        Width = popup ? 520 : 980;
        Height = popup ? 700 : 780;
        MinWidth = 420;
        MinHeight = 480;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Background = new SolidColorBrush(Color.FromRgb(11, 13, 16));

        var root = new DockPanel();
        var bar = new DockPanel { Background = new SolidColorBrush(Color.FromRgb(17, 21, 27)), LastChildFill = true };
        if (!popup)
        {
            var done = new Button
            {
                Content = english ? "Done" : "完了",
                Padding = new Thickness(18, 4, 18, 4),
                Margin = new Thickness(10, 8, 12, 8),
                MinWidth = 88
            };
            done.Click += (_, _) => Close();
            DockPanel.SetDock(done, Dock.Right);
            bar.Children.Add(done);
        }
        var text = new StackPanel { Margin = new Thickness(14, 8, 4, 8), VerticalAlignment = VerticalAlignment.Center };
        if (!popup)
            text.Children.Add(new TextBlock
            {
                Text = english
                    ? $"Sign in to {serviceName} below, then press Done. HoverPocket reads only usage with this sign-in."
                    : $"下の画面で{serviceName}にサインインして、［完了］を押してください。HoverPocketはこのサインインで使用状況だけを読みます。",
                Foreground = new SolidColorBrush(Color.FromRgb(247, 248, 251)),
                TextWrapping = TextWrapping.Wrap
            });
        _address = new TextBlock { Foreground = NormalHost, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 3, 0, 0) };
        text.Children.Add(_address);
        bar.Children.Add(text);
        DockPanel.SetDock(bar, Dock.Top);
        root.Children.Add(bar);

        _webView = new WebView2 { DefaultBackgroundColor = System.Drawing.Color.FromArgb(255, 11, 13, 16) };
        root.Children.Add(_webView);
        Content = root;
        Loaded += async (_, _) => await InitializeAsync();
        Closed += (_, _) =>
        {
            _ready.TrySetCanceled();
            _webView.Dispose();
        };
    }

    internal string AddressTextForVerify => _address.Text;

    /// <summary>Completes once the WebView is ready; canceled if the window closes first.</summary>
    public Task<CoreWebView2> Ready => _ready.Task;

    private async Task InitializeAsync()
    {
        try
        {
            var environment = await AiUsageWebSession.GetEnvironmentAsync(_userDataFolder);
            await _webView.EnsureCoreWebView2Async(environment, AiUsageWebSession.ProfileOptions(environment, AiUsageServiceIds.Profile(_service)));
            var core = _webView.CoreWebView2;
            core.Settings.AreHostObjectsAllowed = false;
            core.Settings.IsWebMessageEnabled = false;
            core.Settings.AreDevToolsEnabled = false;
            core.Settings.IsPasswordAutosaveEnabled = false;
            core.NavigationStarting += (_, args) =>
            {
                // Sign-in pages are HTTPS only; anything else (http, file, custom schemes) is refused.
                if (AiUsageWebSession.OriginOf(args.Uri) is null && args.Uri != "about:blank") args.Cancel = true;
            };
            core.SourceChanged += (_, _) => ShowAddress(core.Source);
            core.NewWindowRequested += OnNewWindowRequested;
            core.WindowCloseRequested += (_, _) => Close();
            _ready.TrySetResult(core);
            if (_startUri is not null) core.Navigate(_startUri.AbsoluteUri);
        }
        catch (Exception exception)
        {
            // Runs from the async Loaded handler, so nothing may escape: a missing runtime, a locked
            // profile folder or a window closed during startup all end the same way.
            Services.AppDiagnostics.Record("aiUsage.signIn.failed", exception);
            _ready.TrySetException(exception);
            if (IsLoaded) Close();
        }
    }

    private void ShowAddress(string source)
    {
        var name = AiUsageServiceIds.DisplayName(_service);
        if (!Uri.TryCreate(source, UriKind.Absolute, out var uri) || uri.Scheme != Uri.UriSchemeHttps)
        {
            // about:blank popups are filled in by the page that opened them; say so instead of showing nothing.
            _address.Foreground = WarningHost;
            _address.Text = _english
                ? $"Connected to {source} (content written by the page that opened this window; check before entering anything)"
                : $"接続先: {source}（開いた元のページが内容を書き込んでいます。入力前に確認してください）";
            return;
        }
        // Authority keeps a non-default port visible, e.g. https://example.com:8443.
        var expected = uri.IsDefaultPort && AiUsageWebReader.IsExpectedSignInHost(_service, uri.Host);
        _address.Foreground = expected ? NormalHost : WarningHost;
        _address.Text = _english
            ? $"Connected to https://{uri.Authority}" + (expected ? string.Empty : $"  (not a usual {name} sign-in site; check before entering anything)")
            : $"接続先: https://{uri.Authority}" + (expected ? string.Empty : $"（{name}の通常のサインイン先ではありません。入力前に確認してください）");
    }

    // Identity providers may open the account chooser as a popup that reports back through
    // window.opener, so popups get a real WebView on the same profile with their own address line.
    private async void OnNewWindowRequested(object? sender, CoreWebView2NewWindowRequestedEventArgs args)
    {
        var deferral = args.GetDeferral();
        AiUsageSignInWindow? popup = null;
        try
        {
            if (AiUsageWebSession.OriginOf(args.Uri) is null && args.Uri != "about:blank")
            {
                args.Handled = true;
                return;
            }
            popup = new AiUsageSignInWindow(_service, _userDataFolder, null, _english, popup: true) { Owner = this };
            popup.Show();
            args.NewWindow = await popup.Ready.WaitAsync(TimeSpan.FromSeconds(30));
            args.Handled = true;
        }
        catch (Exception exception) when (exception is InvalidOperationException
            or System.Runtime.InteropServices.COMException
            or WebView2RuntimeNotFoundException
            or OperationCanceledException
            or TimeoutException)
        {
            args.Handled = true;
            popup?.Close();
        }
        finally
        {
            deferral.Complete();
        }
    }
}
