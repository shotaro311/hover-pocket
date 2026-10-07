using System.Text.Json;
using HoverPocket.Shell.Bridge;
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
            // This verifier shares the desktop. Real typing must not alter its generated fixture text.
            await web.ExecuteScriptAsync("document.addEventListener('keydown',e=>{if(e.isTrusted){e.preventDefault();e.stopImmediatePropagation();}},true);document.addEventListener('beforeinput',e=>{if(e.isTrusted)e.preventDefault();},true)");
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
            await Until(() => Task.FromResult(bridge.InlineChat.Draft == "未送信の下書き" && bridge.InlineChat.Focused), token);
            Check(harnesses.Count == 0 && !bridge.CurrentSettings.VoiceEnabled, "typed entry works with voice off and starts no runtime until Send");
            controller.SimulatePointerMoveForVerify(30, 400); await Task.Delay(250, token);
            await Until(() => Task.FromResult(!controller.Panel.IsVisible), token);
            VerifyConsole.WriteLine($"MEASURE hover draft: matched={bridge.InlineChat.Draft == "未送信の下書き"}, busy={bridge.InlineChat.Busy}, menu={bridge.InlineChat.MenuOpen}; UI=" + await web.ExecuteScriptAsync("({value:document.querySelector('[data-chat-draft]').value,active:document.activeElement?.tagName,messages:document.querySelector('.hp-chat-messages').textContent})"));
            Check(bridge.InlineChat.Draft == "未送信の下書き", "hover exit hides while editing and preserves draft");
            var entry = controller.Layouts[0].AccessSurface.PhysicalRect;
            controller.SimulatePointerMoveForVerify(entry.Left + entry.Width / 2, entry.Top);
            await Until(() => Task.FromResult(controller.Panel.IsVisible && !controller.Panel.IsAnimating), token);
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
            var replyText = bridge.InlineChat.Snapshot.Messages.Single(message => message.Id == "reply").Text;
            harness.Notify("item/completed", new { threadId = "chat-1", turnId = "turn-1", item = new { type = "agentMessage", id = "reply-final", text = replyText } });
            await Until(async () => await web.ExecuteScriptAsync("document.querySelectorAll('.hp-chat-message[data-role=assistant]').length===1") == "true", token);
            await Task.Delay(100, token);
            Check(await web.ExecuteScriptAsync("document.querySelectorAll('.hp-chat-message[data-role=assistant]').length===1 && __chatInput.value==='次の下書き' && __chatInput.selectionStart===2") == "true", "finalization under another ID keeps one visible reply and the input caret");
            await web.ExecuteScriptAsync("__chatInput.dispatchEvent(new CompositionEvent('compositionend',{bubbles:true}));__chatInput.blur()");
            controller.SimulatePointerMoveForVerify(30, 400);
            await Until(() => Task.FromResult(!controller.Panel.IsVisible), token);
            Check(bridge.InlineChat.Busy, "hover exit hides during response without stopping it");
            controller.SimulatePointerMoveForVerify(entry.Left + entry.Width / 2, entry.Top);
            await Until(() => Task.FromResult(controller.Panel.IsVisible && !controller.Panel.IsAnimating), token);
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
            controller.SimulatePointerMoveForVerify(30, 400);
            await Until(() => Task.FromResult(!controller.Panel.IsVisible), token);
            Check(bridge.InlineChat.Busy && bridge.InlineChat.Draft == "次の下書き", "manual hide keeps conversation, running response and draft");
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
            await web.ExecuteScriptAsync("document.querySelector('[data-chat-sidebar]').click();document.querySelector('.hp-chat-history button').click()");
            await Until(async () => await web.ExecuteScriptAsync("document.querySelector('.hp-chat-messages').textContent.includes('以前の返答') && document.querySelector('[data-chat-draft]').value==='次の下書き'") == "true", token);
            Check(harnesses.Count == 2 && harnesses[1].Requests.Any(r => r.Method == "thread/resume"), "history resumes only the owned conversation and restores its draft");
            await web.ExecuteScriptAsync("const body=document.querySelector('.hp-chat-message span');const range=document.createRange();range.selectNodeContents(body);getSelection().removeAllRanges();getSelection().addRange(range)");
            Check(await web.ExecuteScriptAsync("getSelection().toString()==='以前の返答' && getComputedStyle(document.querySelector('.hp-chat-message')).userSelect==='text'") == "true", "reply text can be selected for copy");
            Check(await web.ExecuteScriptAsync("(()=>{let escaped=0;const spy=()=>escaped++;document.addEventListener('keydown',spy);for(const key of ['Delete',' ','z','f'])document.querySelector('.hp-chat-messages').dispatchEvent(new KeyboardEvent('keydown',{key,ctrlKey:key==='z'||key==='f',bubbles:true,cancelable:true}));document.removeEventListener('keydown',spy);return escaped===0;})()") == "true", "chat keyboard input cannot trigger library trash, undo or preview shortcuts");
            var grip = controller.Panel.ResizeGripForVerify;
            await web.ExecuteScriptAsync("const modelButton=document.querySelector('[data-chat-model]');modelButton.focus();modelButton.dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowDown',bubbles:true,cancelable:true}))");
            await Until(async () => await web.ExecuteScriptAsync("!!document.querySelector('.hp-chat-choice-menu:not([hidden]) [data-choice-value=fixture-model]')") == "true", token);
            await Until(() => Task.FromResult(bridge.InlineChat.MenuOpen), token);
            controller.SimulatePointerMoveForVerify(30, 400); await Task.Delay(500, token);
            Check(controller.Panel.IsVisible, "an open model menu survives pointer exit beyond the panel");
            await ClickChoiceAsync(controller, "fixture-model", token);
            await Until(() => Task.FromResult(bridge.CurrentSettings.ChatModel == "fixture-model"), token);
            await Until(() => Task.FromResult(!controller.Panel.IsVisible && !bridge.InlineChat.MenuOpen), token);
            Check(true, "model selection releases auto-hide even with the selector still focused");
            controller.SimulatePointerMoveForVerify(entry.Left + entry.Width / 2, entry.Top);
            await Until(() => Task.FromResult(controller.Panel.IsVisible && !controller.Panel.IsAnimating), token);
            await web.ExecuteScriptAsync("document.querySelector('[data-chat-effort]').click()");
            await Until(() => Task.FromResult(bridge.InlineChat.MenuOpen), token);
            controller.SimulatePointerMoveForVerify(30, 400); await Task.Delay(500, token);
            Check(controller.Panel.IsVisible, "an open reasoning menu survives pointer exit beyond the panel");
            await ClickChoiceAsync(controller, "high", token);
            await Until(() => Task.FromResult(bridge.CurrentSettings.ChatEffort == "high"), token);
            Check(true, "composer model and effort selectors configure the supported server choices");
            await Until(() => Task.FromResult(!controller.Panel.IsVisible && !bridge.InlineChat.MenuOpen), token);
            controller.SimulatePointerMoveForVerify(entry.Left + entry.Width / 2, entry.Top);
            await Until(() => Task.FromResult(controller.Panel.IsVisible && !controller.Panel.IsAnimating), token);
            Check(await web.ExecuteScriptAsync("document.querySelector('[data-chat-model]').textContent==='Fixture Model' && document.querySelector('[data-chat-effort]').textContent==='推論: 高'") == "true", "native choices remain visible after hover reopen");
            await web.ExecuteScriptAsync("document.querySelector('[data-chat-send]').click()");
            await Until(() => Task.FromResult(harnesses[1].Requests.Any(r => r.Method == "turn/start")), token);
            var selectedTurn = harnesses[1].Requests.Single(r => r.Method == "turn/start").Parameters;
            Check(selectedTurn.GetProperty("model").GetString() == "fixture-model" && selectedTurn.GetProperty("effort").GetString() == "high", "native choices reach the next actual turn request");
            await web.ExecuteScriptAsync("document.querySelector('[data-chat-send]').click()");
            await Until(() => Task.FromResult(!bridge.InlineChat.Busy), token);
            await web.ExecuteScriptAsync("__chatInput.value='次の下書き';__chatInput.dispatchEvent(new Event('input',{bubbles:true}))");
            foreach (var dismiss in new[] { "escape", "outside", "blur", "closed" })
            {
                await web.ExecuteScriptAsync("document.querySelector('[data-chat-effort]').click()");
                await Until(() => Task.FromResult(bridge.InlineChat.MenuOpen), token);
                Check(await web.ExecuteScriptAsync("(()=>{const r=document.querySelector('.hp-chat-choice-menu').getBoundingClientRect();return r.left>=0&&r.top>=0&&r.right<=innerWidth&&r.bottom<=innerHeight;})()") == "true", "choice menu fits the current viewport");
                await web.ExecuteScriptAsync(dismiss switch {
                    "escape" => "document.activeElement.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true,cancelable:true}))",
                    "outside" => "document.querySelector('[data-chat-draft]').dispatchEvent(new PointerEvent('pointerdown',{bubbles:true}))",
                    "blur" => "window.dispatchEvent(new Event('blur'))",
                    _ => "window.__chatTestRequest('chat.hidePanel')"
                });
                await Until(() => Task.FromResult(!bridge.InlineChat.MenuOpen), token);
                if (dismiss != "closed") Check(controller.Panel.IsVisible, "dismissal closes only the menu: " + dismiss);
                controller.SimulatePointerMoveForVerify(30, 400);
                await Until(() => Task.FromResult(!controller.Panel.IsVisible), token);
                Check(bridge.InlineChat.Draft == "次の下書き", "menu dismissal releases hover hiding and preserves draft: " + dismiss);
                controller.SimulatePointerMoveForVerify(entry.Left + entry.Width / 2, entry.Top);
                await Until(() => Task.FromResult(controller.Panel.IsVisible && !controller.Panel.IsAnimating), token);
            }
            foreach (var size in new[] { "small", "extraLarge" })
            {
                await web.ExecuteScriptAsync($"window.__chatTestRequest('settings.setPanelSize',{{panelSize:'{size}'}})");
                await Until(() => Task.FromResult(!controller.Panel.IsAnimating), token); await Task.Delay(180, token);
                await web.ExecuteScriptAsync("document.querySelector('[data-chat-model]').click()");
                await Until(() => Task.FromResult(bridge.InlineChat.MenuOpen), token);
                Check(await web.ExecuteScriptAsync("(()=>{const r=document.querySelector('.hp-chat-choice-menu').getBoundingClientRect();return r.left>=0&&r.top>=0&&r.right<=innerWidth&&r.bottom<=innerHeight;})()") == "true", size + " open model choices fit the real panel viewport");
                if (Environment.GetEnvironmentVariable("HOVERPOCKET_VERIFY_LOG") is { Length: > 0 } menuLog)
                {
                    using var screenshot = File.Create(Path.Combine(Path.GetDirectoryName(menuLog)!, "model-menu-" + size + ".png"));
                    await web.CapturePreviewAsync(CoreWebView2CapturePreviewImageFormat.Png, screenshot);
                }
                await web.ExecuteScriptAsync("document.activeElement.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true,cancelable:true}))");
                await Until(() => Task.FromResult(!bridge.InlineChat.MenuOpen), token);
            }
            var oldWidth = controller.Panel.Width;
            grip.RaiseEvent(new System.Windows.Controls.Primitives.DragStartedEventArgs(0, 0) { RoutedEvent = System.Windows.Controls.Primitives.Thumb.DragStartedEvent });
            grip.RaiseEvent(new System.Windows.Controls.Primitives.DragDeltaEventArgs(-40, -40) { RoutedEvent = System.Windows.Controls.Primitives.Thumb.DragDeltaEvent });
            grip.RaiseEvent(new System.Windows.Controls.Primitives.DragCompletedEventArgs(-40, -40, false) { RoutedEvent = System.Windows.Controls.Primitives.Thumb.DragCompletedEvent });
            await Task.Delay(150, token);
            VerifyConsole.WriteLine($"MEASURE resize: old={oldWidth}, width={controller.Panel.Width}, saved={bridge.CurrentSettings.PanelWidthDips}, visible={controller.Panel.IsVisible}");
            Check(controller.Panel.Width < oldWidth && bridge.CurrentSettings.PanelWidthDips is > 0 && Math.Abs(controller.Panel.Width - bridge.CurrentSettings.PanelWidthDips.Value) < 1, "native resize grip changes and saves panel width");
            controller.SimulatePointerMoveForVerify(30, 400);
            await Until(() => Task.FromResult(!controller.Panel.IsVisible), token);
            controller.SimulatePointerMoveForVerify(entry.Left + entry.Width / 2, entry.Top);
            await Until(() => Task.FromResult(controller.Panel.IsVisible && !controller.Panel.IsAnimating), token);
            Check(Math.Abs(controller.Panel.Width - bridge.CurrentSettings.PanelWidthDips!.Value) < 1, "hover reopen keeps the dragged panel size");
            await web.ExecuteScriptAsync("document.querySelector('[data-chat-draft]').dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true,cancelable:true}))");
            controller.SimulatePointerMoveForVerify(30, 400);
            await Until(() => Task.FromResult(!controller.Panel.IsVisible), token);
            Check(bridge.InlineChat.Draft == "次の下書き" && !bridge.InlineChat.Focused, "Escape hides the panel without losing draft");
            VerifyConsole.WriteLine("PASS inline chat panel: direct entry, IME guard, stream/caret, bounded layout, hover exit/draft/reopen, stop, new/history, voice-off and single runtime");
            await web.ExecuteScriptAsync("window.__chatUx=null;import('/js/inline-chat.verify.js').then(m=>m.verifyChatUx()).then(r=>window.__chatUx=r).catch(e=>window.__chatUx={ok:false,error:String(e)})");
            await Until(async () => await web.ExecuteScriptAsync("window.__chatUx!==null") == "true", token);
            var uxResult = await web.ExecuteScriptAsync("window.__chatUx");
            using var ux = JsonDocument.Parse(uxResult);
            Check(ux.RootElement.GetProperty("ok").GetBoolean(), "error recovery preserves drafts, never resends, and labels reasoning and empty state: " + uxResult);
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
        HoverPocket.Shell.Services.AppDiagnostics.Start(root);
        VerifyConsole.WriteLine("MEASURE diagnostics root: " + root);
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
            await bridge.ReplaceChatForVerifyAsync(new CodexChatCoordinator(async ct =>
            {
                var client = await CodexAppServerClient.StartProcessAsync(identity.Path,
                    ["app-server", "--stdio"], TimeSpan.FromSeconds(25), ct, profile.Environment, profile.Root);
                client.NotificationReceived += (_, notification) =>
                {
                    if (!notification.Method.StartsWith("item/", StringComparison.Ordinal) || notification.Parameters is not { } p) return;
                    p.TryGetProperty("itemId", out var deltaId); p.TryGetProperty("item", out var item);
                    if (item.ValueKind == JsonValueKind.Object && item.GetProperty("type").GetString() != "agentMessage") return;
                    VerifyConsole.WriteLine("MEASURE generated reply event: " + JsonSerializer.Serialize(new {
                        method = notification.Method, itemId = deltaId.ValueKind == JsonValueKind.String ? deltaId.GetString() : null,
                        id = item.ValueKind == JsonValueKind.Object ? item.GetProperty("id").GetString() : null,
                        textLength = item.ValueKind == JsonValueKind.Object ? item.GetProperty("text").GetString()?.Length : null }));
                };
                return client;
            }, tools, new CodexChatHistory(root)));
            await bridge.InlineChat.LoadModelsAsync(token);
            bridge.InlineChat.Configure("gpt-6.1-sol", "medium");
            var web = controller.Panel.WebView!.CoreWebView2;
            await web.ExecuteScriptAsync("window.__chatTestRequest=(method,params)=>import('./js/bridge.js').then(m=>m.request(method,params));window.__chatTestRequest('provider.select',{id:'assets'});document.querySelector('[data-chat]').click()");
            await Until(async () => await web.ExecuteScriptAsync("document.activeElement===document.querySelector('[data-chat-draft]')") == "true", token);
            await web.ExecuteScriptAsync("const input=document.querySelector('[data-chat-draft]');input.value='日本語の通信確認です。「おはようございます」とだけ返してください。ツールは使わないでください。';input.dispatchEvent(new Event('input',{bubbles:true}));document.querySelector('[data-chat-send]').click()");
            while ((bridge.InlineChat.Snapshot.Messages.All(message => message.Role != "assistant") && bridge.InlineChat.Snapshot.ErrorCode is null) || bridge.InlineChat.Busy) await Task.Delay(100, token);
            VerifyConsole.WriteLine("MEASURE inline chat result: " + (bridge.InlineChat.Snapshot.ErrorCode ?? "ok"));
            Check(bridge.InlineChat.Snapshot.ErrorCode is null && bridge.InlineChat.Snapshot.Messages.Any(message => message.Role == "assistant" && message.Text.Trim() == "おはようございます"), "live Codex returned exact Japanese text from the panel composer");
            await Until(async () => await web.ExecuteScriptAsync("Array.from(document.querySelectorAll('.hp-chat-message[data-role=assistant] span')).some(n=>n.textContent.trim()==='おはようございます')") == "true", token);
            Check(!bridge.CurrentSettings.VoiceEnabled && controller.Panel.IsVisible, "live reply stays in the same panel with voice off");
            Check(bridge.InlineChat.Snapshot.Messages.Count(message => message.Role == "assistant") == 1, "live streamed and finalized reply produces one message");
            await web.ExecuteScriptAsync("document.querySelector('[data-chat-new]').click()");
            await Until(() => Task.FromResult(!bridge.InlineChat.Busy && bridge.InlineChat.Snapshot.Messages.Count == 0), token);
            if (Environment.GetEnvironmentVariable("HOVERPOCKET_INLINE_CHAT_ACTIONS_VERIFY") != "1")
            {
            await web.ExecuteScriptAsync("const followup=document.querySelector('[data-chat-draft]');followup.value='付箋を追加して';followup.dispatchEvent(new Event('input',{bubbles:true}));document.querySelector('[data-chat-send]').click()");
            await Until(() => Task.FromResult(bridge.InlineChat.Busy), token);
            while (bridge.InlineChat.Busy) await Task.Delay(100, token);
            var clarificationReplies = bridge.InlineChat.Snapshot.Messages.Where(message => message.Role == "assistant").Select(message => message.Text).ToArray();
            Check(bridge.InlineChat.Snapshot.ErrorCode is null && clarificationReplies.Length > 0 && clarificationReplies.Distinct().Count() == clarificationReplies.Length, "live sticky-note replies contain no duplicate text");
            Check(await web.ExecuteScriptAsync($"document.querySelectorAll('.hp-chat-message[data-role=assistant]').length==={clarificationReplies.Length}") == "true", "live panel matches distinct clarification replies");
            }
            if (Environment.GetEnvironmentVariable("HOVERPOCKET_INLINE_CHAT_ACTIONS_VERIFY") == "1")
            {
                var fixtureFile = Path.Combine(root, "trash-fixture.txt"); await File.WriteAllTextAsync(fixtureFile, "Isolated library action fixture", token);
                var fixtureId = (await bridge.AssetLibrary.ImportAsync(fixtureFile)).AssetId!;
                var fixture = (await bridge.AssetLibrary.GetAsync(fixtureId))!;
                var originalPath = bridge.AssetLibrary.ReadOriginalPath(fixture);
                var settingsDispatcher = new BridgeDispatcher();
                using var settingsAttachment = bridge.Attach(settingsDispatcher, BridgeSurface.Settings);
                var permissionResult = await settingsDispatcher.ProcessRawMessageAsync("{\"id\":\"verify-permission\",\"method\":\"settings.setCodexAllowAllAppActions\",\"params\":{\"enabled\":true}}", token);
                using var permissionJson = JsonDocument.Parse(permissionResult!);
                Check(permissionJson.RootElement.GetProperty("error").ValueKind == JsonValueKind.Null, "settings-only bridge enables automatic app permission");
                await web.ExecuteScriptAsync("window.__chatTestRequest('chat.new',{})");
                await Until(() => Task.FromResult(bridge.CurrentSettings.CodexAllowAllAppActions && bridge.InlineChat.Snapshot.Messages.Count == 0), token);
                bridge.InlineChat.Send("ライブラリの内容をすべてゴミ箱に移してください。これは隔離した検証用ライブラリです。確認は済んでいます。library_trash_allを使って実行してください。");
                await Until(() => Task.FromResult(bridge.InlineChat.Busy), token);
                while (bridge.InlineChat.Busy) await Task.Delay(100, token);
                Check(bridge.InlineChat.Snapshot.ErrorCode is null && (await bridge.AssetLibrary.GetAsync(fixtureId))!.Trashed, "live Codex moves isolated library to trash with automatic app permission");
                Check(File.Exists(originalPath) && (await bridge.AssetLibrary.QueryAsync(new())).Total == 0, "live bulk trash readback retains originals");
            }
            if (Environment.GetEnvironmentVariable("HOVERPOCKET_VERIFY_LOG") is { Length: > 0 } log)
            {
                using var screenshot = File.Create(Path.Combine(Path.GetDirectoryName(log)!, "inline-chat-live.png"));
                await web.CapturePreviewAsync(CoreWebView2CapturePreviewImageFormat.Png, screenshot);
            }
            VerifyConsole.WriteLine("PASS inline-chat-live: composer -> real turn/start -> visible Japanese reply; isolated library/history; existing dedicated login; auth_copy=false; microphone=false");
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
    private static async Task ClickChoiceAsync(HoverShellController controller, string value, CancellationToken token)
    {
        var surface = controller.Panel.WebView!;
        var web = surface.CoreWebView2;
        var raw = await web.ExecuteScriptAsync($"(()=>{{const r=document.querySelector('[data-choice-value={value}]').getBoundingClientRect();return {{x:r.x+r.width/2,y:r.y+r.height/2,scale:innerWidth}};}})()");
        using var coordinates = JsonDocument.Parse(raw);
        var c = coordinates.RootElement;
        var ratio = surface.ActualWidth / c.GetProperty("scale").GetDouble();
        var target = surface.PointToScreen(new System.Windows.Point(c.GetProperty("x").GetDouble()*ratio,c.GetProperty("y").GetDouble()*ratio));
        var previous = System.Windows.Forms.Cursor.Position;
        try
        {
            System.Windows.Forms.Cursor.Position = new((int)target.X,(int)target.Y);
            await Task.Delay(80,token); MouseEvent(2,0,0,0,0); await Task.Delay(40,token); MouseEvent(4,0,0,0,0);
            await Task.Delay(100,token);
            VerifyConsole.WriteLine("MEASURE native choice: " + await web.ExecuteScriptAsync("({model:document.querySelector('[data-chat-model]').textContent,effort:document.querySelector('[data-chat-effort]').textContent,popupHidden:document.querySelector('.hp-chat-choice-menu').hidden})"));
        }
        finally { MouseEvent(4,0,0,0,0); System.Windows.Forms.Cursor.Position=previous; }
    }
    private static async Task Until(Func<Task<bool>> predicate, CancellationToken token, [System.Runtime.CompilerServices.CallerLineNumber] int line = 0)
    {
        var until = DateTime.UtcNow.AddSeconds(8);
        while (!await predicate()) { if (DateTime.UtcNow > until) throw new TimeoutException("Inline chat condition at line " + line); await Task.Delay(25, token); }
    }
    [System.Runtime.InteropServices.DllImport("user32.dll", EntryPoint = "mouse_event")] private static extern void MouseEvent(uint flags, uint dx, uint dy, uint data, nuint extra);
}
