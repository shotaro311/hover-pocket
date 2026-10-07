using System.Text.Json;
using HoverPocket.Shell.Voice;

namespace HoverPocket.Shell.Bridge;

internal sealed partial class PanelBridgeController
{
    private InlineChatController? _inlineChat;
    internal InlineChatController InlineChat => _inlineChat ??= AttachChat(CreateChatCoordinator());
    internal bool KeepPanelForChat => _inlineChat?.KeepOpen == true;
    internal double ChatHeight => _inlineChat?.Expanded == true ? 300 : 126;
    internal event Action? ChatLayoutChanged;
    internal ICodexVoiceDynamicToolRuntime ChatToolsForVerify => _chatTools;
    private InlineChatController AttachChat(CodexChatCoordinator coordinator)
    {
        coordinator.RestoreOptions(CurrentSettings.ChatModel, CurrentSettings.ChatEffort);
        var chat = new InlineChatController(coordinator, LoginChatAsync);
        chat.Changed += () => _ = PostPanelEventOnUiThreadAsync("chat.stateChanged", chat.State());
        chat.LayoutChanged += () => { ChatLayoutChanged?.Invoke(); _ = PostStateEventOnUiThreadAsync("state.changed"); };
        return chat;
    }
    internal async Task ReplaceChatForVerifyAsync(CodexChatCoordinator coordinator)
    {
        if (_inlineChat is not null) await _inlineChat.DisposeAsync();
        _inlineChat = AttachChat(coordinator);
    }
    private void RegisterChat(Action<string, Func<JsonElement?, CancellationToken, Task<object?>>> register)
    {
        register("chat.models", async (_, token) => { await InlineChat.LoadModelsAsync(token); return InlineChat.State(); });
        register("chat.configure", (p, _) => { var model = ReadRequiredString(p, "model"); var effort = ReadRequiredString(p, "effort"); InlineChat.Configure(model, effort); var updated = CurrentSettings.Clone(); updated.ChatModel = model; updated.ChatEffort = effort; SaveSettings(updated); return Task.FromResult<object?>(InlineChat.State()); });
        register("chat.getState", (_, _) => Task.FromResult<object?>(InlineChat.State()));
        register("chat.draft", (p, _) => { InlineChat.SetDraft(ReadRequiredString(p, "text")); return Task.FromResult<object?>(new { ok = true }); });
        register("chat.menu", (p, _) => { InlineChat.MenuOpen = ReadRequiredBool(p, "open"); return Task.FromResult<object?>(new { ok = true }); });
        register("chat.focus", (p, _) => { InlineChat.Focused = ReadRequiredBool(p, "focused"); return Task.FromResult<object?>(new { ok = true }); });
        register("chat.expand", (p, _) => { InlineChat.SetExpanded(ReadRequiredBool(p, "expanded")); return Task.FromResult<object?>(InlineChat.State()); });
        register("chat.send", (p, _) => { InlineChat.Send(ReadRequiredString(p, "text")); return Task.FromResult<object?>(InlineChat.State()); });
        register("chat.stop", async (_, _) => { await InlineChat.StopAsync(); return InlineChat.State(); });
        register("chat.new", (_, _) => { InlineChat.Select(null); return Task.FromResult<object?>(InlineChat.State()); });
        register("chat.select", (p, _) => { InlineChat.Select(ReadRequiredString(p, "threadId")); return Task.FromResult<object?>(InlineChat.State()); });
        register("chat.login", (_, _) => { InlineChat.Login(); return Task.FromResult<object?>(InlineChat.State()); });
        register("chat.open", async (_, _) => { if (ChatRequested is not null) await ChatRequested(); await PostPanelEventOnUiThreadAsync("chat.focusInput", new { }); return new { ok = true }; });
        register("chat.hidePanel", (_, _) => { InlineChat.Focused = false; PanelCloseRequested?.Invoke(this, EventArgs.Empty); return Task.FromResult<object?>(new { ok = true }); });
    }
}
