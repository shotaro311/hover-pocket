using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using HoverPocket.Shell.Voice;
using Button = System.Windows.Controls.Button;
using TextBox = System.Windows.Controls.TextBox;
using ComboBox = System.Windows.Controls.ComboBox;
using Color = System.Windows.Media.Color;
using Brushes = System.Windows.Media.Brushes;
using Orientation = System.Windows.Controls.Orientation;

namespace HoverPocket.Shell.Windows;

internal sealed class CodexChatWindow : Window
{
    private readonly CodexChatCoordinator _chat;
    private readonly bool _english;
    private readonly Func<CancellationToken, Task> _login;
    private readonly CancellationTokenSource _lifetime = new();
    private readonly TextBox _draft = new() { AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 86, MaxHeight = 200, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, MaxLength = 16000 };
    private readonly StackPanel _messages = new();
    private readonly Dictionary<string, TextBox> _messageViews = new();
    private readonly ScrollViewer _scroll = new() { VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    private readonly ComboBox _history = new() { Width = 140, Margin = new Thickness(4) };
    private readonly TextBlock _status = new() { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(4, 8, 4, 8) };
    private readonly Button _send;
    private readonly Button _stop;
    private readonly Button _new;
    private readonly Button _loginButton;
    private readonly Dictionary<string, string> _drafts = new();
    private string _displayThread = "";
    private bool _rendering;
    private bool _closing;
    private bool _closed;
    private bool _allowClose;
    private bool _composing;
    internal TextBox DraftForVerify => _draft;
    internal Button SendForVerify => _send;
    internal Button DictationForVerify { get; }
    internal bool ClosedForVerify => _closed;

    public CodexChatWindow(CodexChatCoordinator chat, bool english, Func<CancellationToken, Task> login)
    {
        _chat = chat; _english = english; _login = login;
        Title = "HoverPocket · Codex";
        Width = 640; Height = 700; MinWidth = 460; MinHeight = 420;
        Background = new SolidColorBrush(Color.FromRgb(25, 27, 33)); Foreground = Brushes.WhiteSmoke;
        _draft.Background = new SolidColorBrush(Color.FromRgb(34, 38, 46));
        _draft.Foreground = Foreground; _draft.CaretBrush = Foreground;
        _draft.Padding = new Thickness(10); _draft.FontSize = 14;
        _draft.BorderBrush = new SolidColorBrush(Color.FromRgb(72, 77, 88));
        _history.Foreground = Brushes.Black;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        var layout = new DockPanel { Margin = new Thickness(18) };
        var top = new StackPanel { Orientation = Orientation.Horizontal };
        _new = MakeButton(L("新しいチャット", "New chat"), async () => await SelectAsync(null));
        _loginButton = MakeButton(L("ログイン", "Sign in"), LoginAsync);
        top.Children.Add(_new);
        top.Children.Add(new TextBlock { Text = L("履歴", "History"), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(6, 0, 0, 0) });
        top.Children.Add(_history); top.Children.Add(_loginButton);
        DockPanel.SetDock(top, Dock.Top); layout.Children.Add(top);
        var bottom = new StackPanel();
        bottom.Children.Add(_status); bottom.Children.Add(_draft);
        var actions = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = System.Windows.HorizontalAlignment.Right };
        DictationForVerify = MakeButton(L("音声入力（未対応）", "Dictation unavailable"), () => Task.CompletedTask);
        DictationForVerify.IsEnabled = false;
        DictationForVerify.ToolTip = L("現在のCodexでは、ChatGPTログインで文字起こし専用の接続を利用できません。音声対話はパネルの会話ボタンから使えます。", "This Codex version does not support transcription-only input with ChatGPT sign-in. Voice conversation is available from the panel.");
        ToolTipService.SetShowOnDisabled(DictationForVerify, true);
        _stop = MakeButton(L("停止", "Stop"), () => _chat.StopAsync());
        _send = MakeButton(L("送信", "Send"), SendAsync);
        actions.Children.Add(DictationForVerify); actions.Children.Add(_stop); actions.Children.Add(_send);
        bottom.Children.Add(actions);
        bottom.Children.Add(new TextBlock { Text = L("Ctrl+Enterで送信 · Enterで改行 · 操作は確認後に実行", "Ctrl+Enter to send · Enter for a new line · Actions require confirmation"), FontSize = 11, Foreground = Brushes.LightGray, Margin = new Thickness(4) });
        DockPanel.SetDock(bottom, Dock.Bottom); layout.Children.Add(bottom);
        _scroll.Content = _messages; layout.Children.Add(_scroll); Content = layout;
        _draft.TextChanged += (_, _) => _send.IsEnabled = !_chat.Snapshot.Busy && !string.IsNullOrWhiteSpace(_draft.Text);
        TextCompositionManager.AddPreviewTextInputStartHandler(_draft, (_, _) => _composing = true);
        TextCompositionManager.AddPreviewTextInputHandler(_draft, (_, _) => _composing = false);
        _draft.PreviewKeyDown += async (_, e) =>
        {
            if (!_composing && e.Key == Key.Enter && Keyboard.Modifiers == ModifierKeys.Control)
            { e.Handled = true; await SendAsync(); }
        };
        _history.SelectionChanged += async (_, _) =>
        { if (!_rendering && _history.SelectedItem is CodexChatHistoryEntry entry) await SelectAsync(entry.ThreadId); };
        _chat.Changed += OnChanged;
        Closing += OnClosing;
        Closed += (_, _) => _closed = true;
        Loaded += (_, _) => { Render(_chat.Snapshot); _draft.Focus(); };
    }

    private string L(string ja, string en) => _english ? en : ja;
    private Button MakeButton(string label, Func<Task> action)
    {
        var button = new Button { Content = label, Padding = new Thickness(10, 6, 10, 6), Margin = new Thickness(4),
            Background = new SolidColorBrush(Color.FromRgb(53, 57, 65)), Foreground = Brushes.WhiteSmoke,
            BorderBrush = new SolidColorBrush(Color.FromRgb(80, 84, 97)), FontSize = 13 };
        button.Template = (ControlTemplate)System.Windows.Markup.XamlReader.Parse("""
            <ControlTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" TargetType="Button">
              <Border x:Name="frame" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="4" Padding="{TemplateBinding Padding}">
                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" />
              </Border>
              <ControlTemplate.Triggers>
                <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="frame" Property="Background" Value="#484d58" /></Trigger>
                <Trigger Property="IsEnabled" Value="False"><Setter TargetName="frame" Property="Opacity" Value="0.6" /></Trigger>
              </ControlTemplate.Triggers>
            </ControlTemplate>
            """);
        System.Windows.Automation.AutomationProperties.SetName(button, label);
        button.Click += async (_, _) => { try { await action(); } catch (Exception) { _status.Text = L("操作できませんでした。下書きは残しています。", "The request failed. Your draft is kept."); } };
        return button;
    }

    private async Task SendAsync()
    {
        if (_chat.Snapshot.Busy || string.IsNullOrWhiteSpace(_draft.Text)) return;
        var text = _draft.Text;
        _draft.Clear();
        await _chat.SendAsync(text, _lifetime.Token);
        if (_chat.Snapshot.ErrorCode is not null && string.IsNullOrEmpty(_draft.Text)) _draft.Text = text;
    }

    private async Task SelectAsync(string? id)
    {
        _drafts[_displayThread] = _draft.Text;
        await _chat.SelectAsync(id, _lifetime.Token);
        _displayThread = _chat.Snapshot.ThreadId ?? "";
        _draft.Text = _drafts.GetValueOrDefault(_displayThread, "");
    }

    private async Task LoginAsync()
    {
        _loginButton.IsEnabled = false;
        try { await _login(_lifetime.Token); _status.Text = L("ログインが完了しました。送信できます。", "Signed in. You can send your message."); }
        finally { _loginButton.IsEnabled = true; }
    }

    private void OnChanged(object? sender, CodexChatSnapshot snapshot)
    {
        if (!_closed && !Dispatcher.HasShutdownStarted) _ = Dispatcher.InvokeAsync(() => Render(snapshot));
    }

    private void Render(CodexChatSnapshot snapshot)
    {
        if (_closed) return;
        _rendering = true;
        try
        {
            if (snapshot.ThreadId is not null) _displayThread = snapshot.ThreadId;
            var atBottom = _scroll.ScrollableHeight - _scroll.VerticalOffset < 36;
            var ids = snapshot.Messages.Select(m => m.Id).ToHashSet();
            foreach (var id in _messageViews.Keys.Where(id => !ids.Contains(id)).ToArray()) _messageViews.Remove(id);
            var structureChanged = _messages.Children.Count != snapshot.Messages.Count
                || snapshot.Messages.Where((m, i) => i < _messages.Children.Count && (_messages.Children[i] as TextBox)?.Tag as string != m.Id).Any();
            if (structureChanged) _messages.Children.Clear();
            foreach (var message in snapshot.Messages)
            {
                if (!_messageViews.TryGetValue(message.Id, out var box))
                {
                    box = new TextBox { Tag = message.Id, IsReadOnly = true, TextWrapping = TextWrapping.Wrap, BorderThickness = new Thickness(0),
                        Background = Brushes.Transparent, Foreground = Foreground, Margin = new Thickness(4, 8, 4, 12), FontSize = 14 };
                    _messageViews.Add(message.Id, box);
                }
                var text = (message.Role == "user" ? L("あなた", "You") : "Codex") + "\n" + message.Text;
                if (box.Text != text) box.Text = text;
                if (structureChanged) _messages.Children.Add(box);
            }
            if (atBottom) _scroll.ScrollToEnd();
            _stop.IsEnabled = snapshot.Busy; _new.IsEnabled = !snapshot.Busy; _history.IsEnabled = !snapshot.Busy;
            _send.IsEnabled = !snapshot.Busy && !string.IsNullOrWhiteSpace(_draft.Text);
            _loginButton.IsEnabled = !snapshot.Busy;
            _status.Text = snapshot.ErrorCode switch
            {
                "chat_sign_in_required" => L("ログインしてから送信してください。", "Sign in before sending."),
                "chat_stopped" => L("停止しました。実行済みの操作と途中までの返答は残ります。", "Stopped. Completed actions and the partial response are kept."),
                "chat_tools_changed_start_new" => L("操作権限が変わりました。新しいチャットを開いてください。", "Capabilities changed. Start a new chat."),
                null => snapshot.Busy ? L("返答中…", "Responding…") : L("送信するまでAIへの依頼や操作は始まりません。", "Nothing is sent or executed until you press Send."),
                _ => L("接続または応答を確認できませんでした。実行済みの操作は取り消されません。", "The connection or response could not be confirmed. Completed actions are not undone.")
            };
            if (!snapshot.Busy)
            {
                _history.ItemsSource = _chat.History;
                _history.SelectedItem = _history.Items.Cast<CodexChatHistoryEntry>().FirstOrDefault(e => e.ThreadId == snapshot.ThreadId);
            }
        }
        catch (IOException) { _status.Text = L("履歴を読み込めませんでした。", "History could not be loaded."); }
        finally { _rendering = false; }
    }

    private async void OnClosing(object? sender, CancelEventArgs e)
    {
        if (_closed || _allowClose) return;
        e.Cancel = true;
        if (_closing) return;
        _closing = true; IsEnabled = false;
        _lifetime.Cancel();
        await System.Windows.Threading.Dispatcher.Yield();
        await _chat.DisposeAsync();
        _chat.Changed -= OnChanged;
        if (!_closed) { _allowClose = true; Close(); }
    }
}
