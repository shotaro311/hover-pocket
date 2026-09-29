using System.IO;
using System.Windows;
using System.Windows.Controls;
using HoverPocket.Shell.Bridge;
using HoverPocket.Shell.Configuration;
using HoverPocket.Shell.Services;
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
    private readonly bool _externalIntegrationsEnabled;
    private readonly string _webViewDataDirectory;
    private readonly Grid _root = new();
    private IDisposable? _bridgeAttachment;
    private WebView2? _webView;
    private Task? _initializationTask;

    public SettingsWindow(
        PanelBridgeController bridgeController,
        bool enableDevTools,
        string webViewDataDirectory,
        bool externalIntegrationsEnabled = true)
    {
        _bridgeController = bridgeController;
        _enableDevTools = enableDevTools;
        _externalIntegrationsEnabled = externalIntegrationsEnabled;
        _webViewDataDirectory = webViewDataDirectory;
        ApplyLanguage(_bridgeController.CurrentSettings.Language);
        Width = 620;
        Height = 720;
        MinWidth = 520;
        MinHeight = 560;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        ShowInTaskbar = false;
        Content = _root;

        Loaded += (_, _) => _initializationTask ??= InitializeAsync();
        _bridgeController.SettingsChanged += OnSettingsChanged;
        Closed += (_, _) =>
        {
            _bridgeController.SettingsChanged -= OnSettingsChanged;
            _bridgeAttachment?.Dispose();
        };
    }

    private void OnSettingsChanged(object? sender, UserSettings settings)
    {
        _ = sender;
        ApplyLanguage(settings.Language);
    }

    private void ApplyLanguage(AppLanguage language)
    {
        Title = language == AppLanguage.English ? "HoverPocket Settings" : "HoverPocket 設定";
    }

    private async Task InitializeAsync()
    {
        var webView = new WebView2
        {
            CreationProperties = new CoreWebView2CreationProperties
            {
                UserDataFolder = _webViewDataDirectory
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
        webView.CoreWebView2.SetVirtualHostNameToFolderMapping(
            UiHostName,
            ResolveUiFolder(),
            CoreWebView2HostResourceAccessKind.DenyCors);

        var dispatcher = new BridgeDispatcher(json =>
        {
            webView.CoreWebView2.PostWebMessageAsJson(json);
            return Task.CompletedTask;
        });
        _bridgeAttachment = _bridgeController.Attach(
            dispatcher,
            BridgeSurface.Settings,
            () => this,
            voiceOpenAIKeyPrompt: PromptOpenAIRealtimeKey,
            voiceOpenAIKeyDeleteDecision: ConfirmOpenAIRealtimeKeyDeletion,
            codexSandboxExecutablePicker: SelectCodexSandboxExecutable,
            codexSandboxProvisionDecision: ConfirmCodexSandboxProvisioning);
        webView.CoreWebView2.WebMessageReceived += async (_, args) =>
        {
            await dispatcher.HandleRawMessageAsync(args.TryGetWebMessageAsString());
        };
        webView.CoreWebView2.Navigate(SettingsUrl);
    }

    private OpenAIRealtimeApiKey? PromptOpenAIRealtimeKey()
    {
        var english = _bridgeController.CurrentSettings.Language == AppLanguage.English;
        var dialog = new Window
        {
            Owner = this,
            Title = english ? "OpenAI Realtime API key" : "OpenAI Realtime APIキー",
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            WindowStyle = WindowStyle.ToolWindow,
            ResizeMode = ResizeMode.NoResize,
            ShowInTaskbar = false,
            SizeToContent = SizeToContent.WidthAndHeight,
            MinWidth = 460
        };
        var stack = new StackPanel { Margin = new Thickness(24) };
        stack.Children.Add(new TextBlock
        {
            Text = !_externalIntegrationsEnabled
                ? english
                    ? "For this isolated E2E run, the key stays only in process memory. It is never sent to this Settings WebView."
                    : "この隔離E2E実行では、APIキーはプロセス内メモリだけに保持され、この設定WebViewには返されません。"
                : english
                    ? "The key is stored only in Windows Credential Manager. It is never sent to this Settings WebView."
                    : "APIキーはWindows Credential Managerだけに保存され、この設定WebViewには返されません。",
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 0, 0, 12)
        });
        var password = new PasswordBox
        {
            MinWidth = 390,
            MaxLength = 512
        };
        stack.Children.Add(password);
        var actions = new StackPanel
        {
            Orientation = System.Windows.Controls.Orientation.Horizontal,
            HorizontalAlignment = System.Windows.HorizontalAlignment.Right,
            Margin = new Thickness(0, 16, 0, 0)
        };
        var cancel = new System.Windows.Controls.Button
        {
            Content = english ? "Cancel" : "キャンセル",
            IsCancel = true,
            MinWidth = 96,
            Padding = new Thickness(12, 7, 12, 7)
        };
        var save = new System.Windows.Controls.Button
        {
            Content = english ? "Save" : "保存",
            MinWidth = 96,
            Margin = new Thickness(10, 0, 0, 0),
            Padding = new Thickness(12, 7, 12, 7),
            IsDefault = true
        };
        save.Click += (_, _) => dialog.DialogResult = true;
        actions.Children.Add(cancel);
        actions.Children.Add(save);
        stack.Children.Add(actions);
        dialog.Content = stack;
        if (dialog.ShowDialog() != true)
        {
            password.Clear();
            return null;
        }
        try
        {
            return new OpenAIRealtimeApiKey(password.Password);
        }
        catch (InvalidOperationException)
        {
            System.Windows.MessageBox.Show(
                this,
                english ? "The API key format is invalid." : "APIキーの形式が正しくありません。",
                dialog.Title,
                MessageBoxButton.OK,
                MessageBoxImage.Warning);
            return null;
        }
        finally
        {
            password.Clear();
        }
    }

    private bool ConfirmOpenAIRealtimeKeyDeletion()
    {
        var english = _bridgeController.CurrentSettings.Language == AppLanguage.English;
        return System.Windows.MessageBox.Show(
            this,
            !_externalIntegrationsEnabled
                ? english
                    ? "Delete the OpenAI Realtime API key from this isolated E2E process? Voice will stop until a key is configured again."
                    : "この隔離E2EプロセスからOpenAI Realtime APIキーを削除しますか？再設定するまでVoiceは停止します。"
                : english
                    ? "Delete the OpenAI Realtime API key from Windows Credential Manager? Voice will stop until a key is configured again."
                    : "OpenAI Realtime APIキーをWindows Credential Managerから削除しますか？再設定するまでVoiceは停止します。",
            english ? "Delete OpenAI API key" : "OpenAI APIキーを削除",
            MessageBoxButton.YesNo,
            MessageBoxImage.Warning,
            MessageBoxResult.No) == MessageBoxResult.Yes;
    }

    private string? SelectCodexSandboxExecutable()
    {
        var english = _bridgeController.CurrentSettings.Language == AppLanguage.English;
        var dialog = new Microsoft.Win32.OpenFileDialog
        {
            Title = english
                ? "Select the official Codex 0.145.0 executable"
                : "公式Codex 0.145.0の実行ファイルを選択",
            Filter = "Codex executable (codex.exe)|codex.exe",
            CheckFileExists = true,
            CheckPathExists = true,
            Multiselect = false,
            DereferenceLinks = false,
            FileName = "codex.exe"
        };
        return dialog.ShowDialog(this) == true ? dialog.FileName : null;
    }

    private bool ConfirmCodexSandboxProvisioning()
    {
        var english = _bridgeController.CurrentSettings.Language == AppLanguage.English;
        return System.Windows.MessageBox.Show(
            this,
            english
                ? "Set up or repair the dedicated Codex generation sandbox? Windows will show one UAC prompt and Codex will create or refresh two local sandbox accounts. HoverPocket never receives the administrator credential or sandbox passwords. Normal generation will not request elevation."
                : "Codex生成専用sandboxをセットアップ／修復しますか？ WindowsのUACが1回表示され、Codexがローカルsandboxアカウント2つを作成または更新します。HoverPocketは管理者credentialやsandbox passwordを受け取りません。通常の生成時には昇格を要求しません。",
            english ? "Set up Codex generation sandbox" : "Codex生成sandboxを準備",
            MessageBoxButton.YesNo,
            MessageBoxImage.Warning,
            MessageBoxResult.No) == MessageBoxResult.Yes;
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
