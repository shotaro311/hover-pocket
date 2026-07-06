using System.IO;
using System.Windows;
using System.Windows.Controls;
using HoverPocket.Shell.Bridge;
using HoverPocket.Shell.Windows;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;

namespace HoverPocket.Shell.Settings;

internal sealed class SettingsWindow : Window
{
    private const string UiHostName = "settings.hoverpocket.local";
    private const string SettingsUrl = "https://settings.hoverpocket.local/settings/index.html";

    private readonly PanelBridgeController _bridgeController;
    private readonly bool _enableDevTools;
    private readonly Grid _root = new();
    private IDisposable? _bridgeAttachment;
    private WebView2? _webView;
    private Task? _initializationTask;

    public SettingsWindow(PanelBridgeController bridgeController, bool enableDevTools)
    {
        _bridgeController = bridgeController;
        _enableDevTools = enableDevTools;
        Title = "HoverPocket Settings";
        Width = 620;
        Height = 720;
        MinWidth = 520;
        MinHeight = 560;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        ShowInTaskbar = false;
        Content = _root;

        Loaded += (_, _) => _initializationTask ??= InitializeAsync();
        Closed += (_, _) => _bridgeAttachment?.Dispose();
    }

    private async Task InitializeAsync()
    {
        var webView = new WebView2
        {
            CreationProperties = new CoreWebView2CreationProperties
            {
                UserDataFolder = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                    "HoverPocket",
                    "SettingsWebView2")
            },
            DefaultBackgroundColor = System.Drawing.Color.FromArgb(255, 8, 10, 13)
        };

        _webView = webView;
        _root.Children.Add(webView);

        await webView.EnsureCoreWebView2Async();
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
        webView.CoreWebView2.SetVirtualHostNameToFolderMapping(
            UiHostName,
            ResolveUiFolder(),
            CoreWebView2HostResourceAccessKind.DenyCors);

        var dispatcher = new BridgeDispatcher(json =>
        {
            webView.CoreWebView2.PostWebMessageAsJson(json);
            return Task.CompletedTask;
        });
        _bridgeAttachment = _bridgeController.Attach(dispatcher);
        webView.CoreWebView2.WebMessageReceived += async (_, args) =>
        {
            await dispatcher.HandleRawMessageAsync(args.TryGetWebMessageAsString());
        };
        webView.CoreWebView2.Navigate(SettingsUrl);
    }

    private static string ResolveUiFolder()
    {
        var outputUiFolder = Path.Combine(AppContext.BaseDirectory, "ui");
        if (File.Exists(Path.Combine(outputUiFolder, "settings", "index.html")))
        {
            return outputUiFolder;
        }

        var current = new DirectoryInfo(Directory.GetCurrentDirectory());
        while (current is not null)
        {
            var candidate = Path.Combine(current.FullName, "windows", "ui");
            if (File.Exists(Path.Combine(candidate, "settings", "index.html")))
            {
                return candidate;
            }

            current = current.Parent;
        }

        throw new DirectoryNotFoundException("windows/ui/settings static assets were not found.");
    }
}
