using System.Text.Json;
using HoverPocket.Shell.Voice;
using HoverPocket.Shell.Windows;
using Microsoft.Web.WebView2.Core;

namespace HoverPocket.Shell.Verification;

internal static class InlineChatPanelVerifier
{
    internal static async Task<int> RunAsync(HoverShellController controller)
    {
        var harnesses = new List<CodexChatVerifier.Harness>();
        var bridge = controller.PanelBridgeController;
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(60));
        var token = timeout.Token;
        try
        {
            var fixture = Path.Combine(bridge.AssetLibrary.Root, "inline-chat-fixture");
            await bridge.ReplaceChatForVerifyAsync(new CodexChatCoordinator(_ =>
            {
                var harness = new CodexChatVerifier.Harness(); harnesses.Add(harness); return Task.FromResult(harness.Client());
            }, new CodexChatVerifier.TestTools(), new CodexChatHistory(fixture)));
            var web = controller.Panel.WebView!.CoreWebView2;
            await web.ExecuteScriptAsync("window.__chatTestRequest=(method,params)=>import('./js/bridge.js').then(m=>m.request(method,params));document.querySelector('[data-chat]').click()");
            await web.ExecuteScriptAsync("window.__chatTestRequest('provider.select',{id:'assets'})");
            await Until(async () => await web.ExecuteScriptAsync("document.activeElement===document.querySelector('[data-chat-draft]')") == "true", token);
            var priorPointer = System.Windows.Forms.Cursor.Position;
            var positionJson = await web.ExecuteScriptAsync("(()=>{const r=document.querySelector('[data-chat-draft]').getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2};})()");
            using (var position = JsonDocument.Parse(positionJson))
            {
                var point = controller.Panel.WebView.PointToScreen(new System.Windows.Point(position.RootElement.GetProperty("x").GetDouble(), position.RootElement.GetProperty("y").GetDouble()));
                try { System.Windows.Forms.Cursor.Position = new((int)point.X, (int)point.Y); MouseEvent(2, 0, 0, 0, 0); await Task.Delay(50, token); MouseEvent(4, 0, 0, 0, 0); }
                finally { MouseEvent(4, 0, 0, 0, 0); System.Windows.Forms.Cursor.Position = priorPointer; }
            }
            await web.ExecuteScriptAsync("document.querySelector('[data-chat-draft]').value='未送信の下書き';document.querySelector('[data-chat-draft]').dispatchEvent(new Event('input',{bubbles:true}))");
            await Task.Delay(250, token);
            VerifyConsole.WriteLine($"MEASURE draft host: matched={bridge.InlineChat.Draft == "未送信の下書き"}, focus={bridge.InlineChat.Focused}; UI=" + await web.ExecuteScriptAsync("({value:document.querySelector('[data-chat-draft]').value,active:document.activeElement?.tagName,status:document.querySelector('.hp-chat-status').textContent})"));
            await Until(() => Task.FromResult(bridge.InlineChat.Draft == "未送信の下書き" && bridge.KeepPanelForChat), token);
            Check(harnesses.Count == 0 && !bridge.CurrentSettings.VoiceEnabled, "typed entry works with voice off and starts no runtime until Send");
            controller.SimulatePointerMoveForVerify(30, 400); await Task.Delay(250, token);
            Check(controller.Panel.IsVisible, "focused text input prevents hover auto-hide");
            await web.ExecuteScriptAsync("window.__chatInput=document.querySelector('[data-chat-draft]');__chatInput.dispatchEvent(new CompositionEvent('compositionstart',{bubbles:true}));__chatInput.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',isComposing:true,bubbles:true}));__chatInput.dispatchEvent(new CompositionEvent('compositionend',{bubbles:true}));__chatInput.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true}))");
            await Task.Delay(160, token);
            await web.ExecuteScriptAsync("__chatInput.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',shiftKey:true,bubbles:true}))");
            Check(harnesses.Count == 0, "IME confirm, trailing Enter and Shift+Enter never submit");
            await web.ExecuteScriptAsync("__chatInput.value='生成した確認用メッセージ';__chatInput.dispatchEvent(new Event('input',{bubbles:true}));__chatInput.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true}));__chatInput.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',repeat:true,bubbles:true}))");
            await Until(() => Task.FromResult(harnesses.Count == 1 && harnesses[0].TurnStarted), token);
            var harness = harnesses[0];
            Check(harness.Requests.Count(r => r.Method == "turn/start") == 1, "Enter sends once through the existing runtime");
            await web.ExecuteScriptAsync("__chatInput.value='次の下書き';__chatInput.dispatchEvent(new Event('input',{bubbles:true}));__chatInput.setSelectionRange(2,2);__chatInput.dispatchEvent(new CompositionEvent('compositionstart',{bubbles:true}))");
            harness.Notify("item/agentMessage/delta", new { threadId = "chat-1", turnId = "turn-1", itemId = "reply", delta = "<b>生成した返信</b>\n" + new string('あ', 800) });
            await Until(async () => await web.ExecuteScriptAsync("document.querySelector('.hp-chat-messages').textContent.includes('生成した返信')") == "true", token);
            Check(await web.ExecuteScriptAsync("__chatInput===document.querySelector('[data-chat-draft]') && __chatInput.value==='次の下書き' && __chatInput.selectionStart===2 && !document.querySelector('.hp-chat-messages b')") == "true", "stream preserves input node, composition/caret and renders replies as selectable plain text");
            await web.ExecuteScriptAsync("__chatInput.dispatchEvent(new CompositionEvent('compositionend',{bubbles:true}));__chatInput.blur()");
            await Task.Delay(250, token); Check(controller.Panel.IsVisible, "responding prevents hover auto-hide after input blur");
            foreach (var size in new[] { "small", "extraLarge" })
            {
                await web.ExecuteScriptAsync($"window.__chatTestRequest('settings.setPanelSize',{{panelSize:'{size}'}})");
                await Until(() => Task.FromResult(!controller.Panel.IsAnimating), token); await Task.Delay(180, token);
                Check(await web.ExecuteScriptAsync("(()=>{const input=document.querySelector('[data-chat-draft]').getBoundingClientRect(),send=document.querySelector('[data-chat-send]').getBoundingClientRect(),m=document.querySelector('.hp-chat-messages');return input.top>=0&&input.bottom<=innerHeight&&send.right<=innerWidth&&m.clientHeight>40&&m.scrollHeight>m.clientHeight&&getComputedStyle(m).overflowY==='auto';})()") == "true", size + " composer/stop fit viewport and long replies scroll internally");
                if (Environment.GetEnvironmentVariable("HOVERPOCKET_VERIFY_LOG") is { Length: > 0 } log)
                {
                    using var screenshot = File.Create(Path.Combine(Path.GetDirectoryName(log)!, "inline-chat-" + size + ".png"));
                    await web.CapturePreviewAsync(CoreWebView2CapturePreviewImageFormat.Png, screenshot);
                }
            }
            await web.ExecuteScriptAsync("document.querySelector('[data-chat-hide]').click()");
            await Until(() => Task.FromResult(!controller.Panel.IsVisible), token);
            Check(bridge.InlineChat.Busy && bridge.InlineChat.Draft == "次の下書き", "manual hide keeps conversation, running response and draft");
            var entry = controller.Layouts[0].AccessSurface.PhysicalRect;
            controller.SimulatePointerMoveForVerify(entry.Left + entry.Width / 2, entry.Top);
            await Until(() => Task.FromResult(controller.Panel.IsVisible && !controller.Panel.IsAnimating), token);
            await web.ExecuteScriptAsync("document.querySelector('[data-chat]').click()");
            await Until(() => Task.FromResult(bridge.InlineChat.Focused), token);
            await Until(async () => await web.ExecuteScriptAsync("document.querySelector('[data-chat-draft]').value==='次の下書き'") == "true", token);
            Check(bridge.InlineChat.Busy, "hover reopens the manually hidden panel during a response");
            await web.ExecuteScriptAsync("document.querySelector('[data-chat-send]').click()");
            await Until(() => Task.FromResult(!bridge.InlineChat.Busy), token);
            Check(harness.Requests.Count(r => r.Method == "turn/interrupt") == 1 && bridge.InlineChat.Draft == "次の下書き", "Stop interrupts the same response once and preserves follow-up draft");
            await web.ExecuteScriptAsync("document.querySelector('[data-chat-new]').click()");
            await Until(() => Task.FromResult(!bridge.InlineChat.Busy && bridge.InlineChat.Snapshot.ThreadId is null && bridge.InlineChat.Draft == ""), token);
            await Until(async () => await web.ExecuteScriptAsync("document.querySelector('[data-chat-draft]').value==='' && !document.querySelector('.hp-chat-message')") == "true", token);
            await web.ExecuteScriptAsync("const history=document.querySelector('[data-chat-history]');history.value='chat-1';history.dispatchEvent(new Event('change',{bubbles:true}))");
            await Until(async () => await web.ExecuteScriptAsync("document.querySelector('.hp-chat-messages').textContent.includes('以前の返答') && document.querySelector('[data-chat-draft]').value==='次の下書き'") == "true", token);
            Check(harnesses.Count == 2 && harnesses[1].Requests.Any(r => r.Method == "thread/resume"), "history resumes only the owned conversation and restores its draft");
            await web.ExecuteScriptAsync("const body=document.querySelector('.hp-chat-message span');const range=document.createRange();range.selectNodeContents(body);getSelection().removeAllRanges();getSelection().addRange(range)");
            Check(await web.ExecuteScriptAsync("getSelection().toString()==='以前の返答' && getComputedStyle(document.querySelector('.hp-chat-message')).userSelect==='text'") == "true", "reply text can be selected for copy");
            Check(await web.ExecuteScriptAsync("(()=>{let escaped=0;const spy=()=>escaped++;document.addEventListener('keydown',spy);for(const key of ['Delete',' ','z','f'])document.querySelector('.hp-chat-messages').dispatchEvent(new KeyboardEvent('keydown',{key,ctrlKey:key==='z'||key==='f',bubbles:true,cancelable:true}));document.removeEventListener('keydown',spy);return escaped===0;})()") == "true", "chat keyboard input cannot trigger library trash, undo or preview shortcuts");
            await web.ExecuteScriptAsync("document.querySelector('[data-chat-draft]').dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true,cancelable:true}))");
            controller.SimulatePointerMoveForVerify(30, 400);
            await Until(() => Task.FromResult(!controller.Panel.IsVisible), token);
            Check(bridge.InlineChat.Draft == "次の下書き" && !bridge.InlineChat.Focused, "Escape hides the panel without losing draft");
            VerifyConsole.WriteLine("PASS inline chat panel: direct entry, IME guard, stream/caret, bounded layout, pin/hide/reopen, stop, new/history, voice-off and single runtime");
            return 0;
        }
        catch (Exception ex) { VerifyConsole.WriteLine("FAIL inline chat panel: " + ex); return 1; }
        finally { await bridge.InlineChat.DisposeAsync(); }
    }

    internal static async Task<int> RunLiveAsync(HoverShellController controller)
    {
        var bridge = controller.PanelBridgeController;
        var root = Path.Combine(bridge.AssetLibrary.Root, "inline-chat-live");
        Directory.CreateDirectory(root);
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(100));
        var token = timeout.Token;
        try
        {
            var profileRoot = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "HoverPocket", "CodexVoice");
            if (!File.Exists(Path.Combine(profileRoot, "auth.json"))) throw new InvalidOperationException("dedicated_app_login_required");
            var identity = CodexExecutableResolver.Resolve() ?? throw new InvalidOperationException("codex_missing");
            var tools = bridge.ChatToolsForVerify;
            await CodexVoiceToolRouteProbe.VerifyAsync(identity, tools.Definitions, Path.Combine(root, "route"), token);
            VerifyConsole.WriteLine($"PASS inline chat: live installed model route exactly matches the app's current grants; tools={tools.Definitions.GetArrayLength()}");
            var profile = CodexVoiceProfile.Prepare(profileRoot, reuseExistingLogin: false);
            await bridge.ReplaceChatForVerifyAsync(new CodexChatCoordinator(ct => CodexAppServerClient.StartProcessAsync(identity.Path,
                ["app-server", "--stdio"], TimeSpan.FromSeconds(25), ct, profile.Environment, root), tools, new CodexChatHistory(root)));
            var web = controller.Panel.WebView!.CoreWebView2;
            await web.ExecuteScriptAsync("window.__chatTestRequest=(method,params)=>import('./js/bridge.js').then(m=>m.request(method,params));window.__chatTestRequest('provider.select',{id:'assets'});document.querySelector('[data-chat]').click()");
            await Until(async () => await web.ExecuteScriptAsync("document.activeElement===document.querySelector('[data-chat-draft]')") == "true", token);
            await web.ExecuteScriptAsync("const input=document.querySelector('[data-chat-draft]');input.value='計算の確認です。3+4の答えを数字1文字だけで返してください。ツールは使わないでください。';input.dispatchEvent(new Event('input',{bubbles:true}));document.querySelector('[data-chat-send]').click()");
            while (bridge.InlineChat.Snapshot.Messages.All(message => message.Role != "assistant") || bridge.InlineChat.Busy) await Task.Delay(100, token);
            Check(bridge.InlineChat.Snapshot.ErrorCode is null && bridge.InlineChat.Snapshot.Messages.Any(message => message.Role == "assistant" && message.Text.Trim() == "7"), "live Codex returned 7 from the panel composer");
            await Until(async () => await web.ExecuteScriptAsync("Array.from(document.querySelectorAll('.hp-chat-message[data-role=assistant] span')).some(n=>n.textContent.trim()==='7')") == "true", token);
            Check(!bridge.CurrentSettings.VoiceEnabled && controller.Panel.IsVisible, "live reply stays in the same panel with voice off");
            if (Environment.GetEnvironmentVariable("HOVERPOCKET_VERIFY_LOG") is { Length: > 0 } log)
            {
                using var screenshot = File.Create(Path.Combine(Path.GetDirectoryName(log)!, "inline-chat-live.png"));
                await web.CapturePreviewAsync(CoreWebView2CapturePreviewImageFormat.Png, screenshot);
            }
            VerifyConsole.WriteLine("PASS inline-chat-live: composer -> real turn/start -> visible reply 7; isolated library/history; existing dedicated login; auth_copy=false; microphone=false");
            return 0;
        }
        catch (Exception exception)
        {
            VerifyConsole.WriteLine("FAIL inline-chat-live: " + exception.GetType().Name + " " + VoiceTextSafety.SanitizeErrorCode(exception.Message));
            return 1;
        }
        finally { await bridge.InlineChat.DisposeAsync(); }
    }
    private static void Check(bool ok, string name) { if (!ok) throw new InvalidOperationException(name); VerifyConsole.WriteLine("PASS inline chat: " + name); }
    private static async Task Until(Func<Task<bool>> predicate, CancellationToken token, [System.Runtime.CompilerServices.CallerLineNumber] int line = 0)
    {
        var until = DateTime.UtcNow.AddSeconds(8);
        while (!await predicate()) { if (DateTime.UtcNow > until) throw new TimeoutException("Inline chat condition at line " + line); await Task.Delay(25, token); }
    }
    [System.Runtime.InteropServices.DllImport("user32.dll", EntryPoint = "mouse_event")] private static extern void MouseEvent(uint flags, uint dx, uint dy, uint data, nuint extra);
}
