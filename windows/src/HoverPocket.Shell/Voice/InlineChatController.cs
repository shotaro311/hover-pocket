using System.Windows.Threading;

namespace HoverPocket.Shell.Voice;

internal sealed class InlineChatController : IAsyncDisposable
{
    private readonly CodexChatCoordinator _chat;
    private readonly Func<CancellationToken, Task> _login;
    private readonly Dispatcher _dispatcher;
    private readonly CancellationTokenSource _lifetime = new();
    private readonly Dictionary<string, string> _drafts = [];
    private string _draftKey = "";
    private string? _error;
    private bool _pending, _disposed;
    private bool _creatingThread;
    private int _draftVersion;
    private CancellationTokenSource? _operationCancellation;
    private Task _operation = Task.CompletedTask;

    internal InlineChatController(CodexChatCoordinator chat, Func<CancellationToken, Task> login)
    {
        _chat = chat; _login = login; _dispatcher = Dispatcher.CurrentDispatcher;
        _chat.Changed += OnChanged;
    }
    internal event Action? Changed;
    internal event Action? LayoutChanged;
    internal bool Expanded { get; private set; }
    internal bool Focused { get; set; }
    internal bool Busy => _pending || _chat.Snapshot.Busy;
    internal bool KeepOpen => Focused || Busy;
    internal string Draft => _drafts.GetValueOrDefault(_draftKey, "");
    internal CodexChatSnapshot Snapshot => _chat.Snapshot;
    internal Task OperationForVerify => _operation;

    internal object State()
    {
        var snapshot = _chat.Snapshot;
        IReadOnlyList<CodexChatHistoryEntry> history;
        try { history = _chat.History; }
        catch (IOException) { history = []; _error = "chat_history_failed"; }
        return new { threadId = snapshot.ThreadId, busy = Busy, errorCode = _error ?? snapshot.ErrorCode,
            draft = Draft, draftVersion = _draftVersion, expanded = Expanded, messages = snapshot.Messages, history };
    }
    internal void SetDraft(string text)
    {
        if (text.Length > 16000) throw new ArgumentException("chat_text_invalid");
        _drafts[_draftKey] = text;
    }
    internal void SetExpanded(bool expanded)
    {
        if (Expanded == expanded) return;
        Expanded = expanded; LayoutChanged?.Invoke(); Changed?.Invoke();
    }
    internal void Send(string text)
    {
        if (Busy || _disposed) throw new InvalidOperationException("chat_busy");
        if (string.IsNullOrWhiteSpace(text) || text.Length > 16000) throw new ArgumentException("chat_text_invalid");
        SetDraft(""); SetExpanded(true);
        _creatingThread = _chat.Snapshot.ThreadId is null;
        var before = _chat.Snapshot.Messages.Select(message => message.Id).ToHashSet();
        Run(async token =>
        {
            await _chat.SendAsync(text, token);
            // A rejected connection has not accepted a user message. Keep its draft for retry.
            if (!_chat.Snapshot.Messages.Any(message => message.Role == "user" && !before.Contains(message.Id)) && Draft.Length == 0)
                SetDraft(text);
        });
    }
    internal void Select(string? id)
    {
        if (Busy || _disposed) throw new InvalidOperationException("chat_busy");
        SetExpanded(true);
        Run(async token =>
        {
            await _chat.SelectAsync(id, token);
            if (_chat.Snapshot.ErrorCode is null)
            {
                _draftKey = _chat.Snapshot.ThreadId ?? "";
                if (id is null) _drafts[_draftKey] = "";
                _draftVersion++;
            }
        });
    }
    internal void Login()
    {
        if (Busy || _disposed) throw new InvalidOperationException("chat_busy");
        Run(_login);
    }
    internal async Task StopAsync()
    {
        await _chat.StopAsync();
        _operationCancellation?.Cancel();
        await _operation;
    }
    private void Run(Func<CancellationToken, Task> action)
    {
        _pending = true; _error = null; Changed?.Invoke();
        _operationCancellation = CancellationTokenSource.CreateLinkedTokenSource(_lifetime.Token);
        _operation = RunAsync(action, _operationCancellation);
    }
    private async Task RunAsync(Func<CancellationToken, Task> action, CancellationTokenSource cancellation)
    {
        try { await action(cancellation.Token); }
        catch (OperationCanceledException) { _error = "chat_stopped"; }
        catch (Exception) { _error = "chat_request_failed"; }
        finally { _pending = false; _creatingThread = false; _operationCancellation = null; cancellation.Dispose(); if (!_disposed) Changed?.Invoke(); }
    }
    private void OnChanged(object? sender, CodexChatSnapshot snapshot)
    {
        void Apply()
        {
            if (_disposed) return;
            // Creating the first turn gives an unsent follow-up draft its permanent conversation key.
            if (_creatingThread && snapshot.ThreadId is { } id)
            {
                _drafts[id] = Draft;
                if (_draftKey.Length == 0) _drafts.Remove("");
                _draftKey = id;
                _creatingThread = false;
            }
            Changed?.Invoke();
        }
        if (_dispatcher.CheckAccess()) Apply(); else _dispatcher.BeginInvoke(Apply);
    }
    public async ValueTask DisposeAsync()
    {
        if (_disposed) return;
        _disposed = true; _chat.Changed -= OnChanged; _lifetime.Cancel();
        await _chat.DisposeAsync();
        await _operation;
        _lifetime.Dispose();
    }
}
