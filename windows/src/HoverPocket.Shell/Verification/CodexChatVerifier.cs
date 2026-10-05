using System.Collections.Concurrent;
using System.Text;
using System.Text.Json;
using System.Threading.Channels;
using HoverPocket.Shell.Voice;
using HoverPocket.Shell.Windows;

namespace HoverPocket.Shell.Verification;

internal static class CodexChatVerifier
{
    public static Task<int> RunPanelAsync(HoverShellController controller) => InlineChatPanelVerifier.RunAsync(controller);

    public static async Task<int> RunAsync()
    {
        try
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(40));
            var token = timeout.Token;
            var root = Path.Combine(Path.GetTempPath(), "HoverPocket-ChatVerify-" + Guid.NewGuid().ToString("N"));
            var history = new CodexChatHistory(root);
            var tools = new TestTools();
            var harnesses = new List<Harness>();
            await using var chat = new CodexChatCoordinator(_ =>
            {
                var harness = new Harness(); harnesses.Add(harness); return Task.FromResult(harness.Client());
            }, tools, history);
            Check(harnesses.Count == 0 && chat.Snapshot.Messages.Count == 0, "idle starts no server");
            var sending = chat.SendAsync("ライブラリを検索して", token);
            await Until(() => harnesses.Count > 0 && harnesses[0].TurnStarted, token);
            var h = harnesses[0];
            Check(h.Requests.Single(r => r.Method == "thread/start").Parameters.GetProperty("ephemeral").GetBoolean() == false, "history owned by app server");
            Check(h.Requests.Single(r => r.Method == "turn/start").Parameters.GetProperty("input")[0].GetProperty("text").GetString() == "ライブラリを検索して", "explicit exact text send");
            h.Notify("item/agentMessage/delta", new { threadId = "foreign", turnId = "turn-1", itemId = "a", delta = "unwanted" });
            h.Notify("item/agentMessage/delta", new { threadId = "chat-1", turnId = "old-turn", itemId = "a", delta = "unwanted" });
            h.Notify("item/agentMessage/delta", new { threadId = "chat-1", turnId = "turn-1", itemId = "answer", delta = "結果" });
            await Until(() => chat.Snapshot.Messages.Any(m => m.Text == "結果"), token);
            Check(!chat.Snapshot.Messages.Any(m => m.Text.Contains("unwanted")), "foreign and stale stream ignored");
            h.Call(701, "item/tool/call", new { threadId = "foreign", turnId = "turn-1", tool = "library_search", callId = "bad", arguments = new { } });
            h.Call(702, "exec/command", new { threadId = "chat-1", turnId = "turn-1" });
            h.Call(703, "item/tool/call", new { threadId = "chat-1", turnId = "turn-1", tool = "library_search", callId = "good", arguments = new { } });
            await Until(() => h.Responses.Count == 3, token);
            Check(tools.Calls == 1 && h.Responses.Count(r => r.TryGetProperty("error", out _)) == 2, "root/turn/tool fences");
            h.Notify("item/completed", new { threadId = "chat-1", turnId = "turn-1", item = new { type = "agentMessage", id = "answer", text = "結果です" } });
            h.Complete("completed"); await sending;
            Check(chat.Snapshot.Messages.Single(m => m.Id == "answer").Text == "結果です" && !chat.Snapshot.Busy, "stream final replaces delta once");
            Check(history.Read().Count == 1 && !File.ReadAllText(Path.Combine(root, "chat-history.json")).Contains("ライブラリ"), "index stores no transcript");
            var corruptRoot = Path.Combine(root, "corrupt"); Directory.CreateDirectory(corruptRoot);
            File.WriteAllText(Path.Combine(corruptRoot, "chat-history.json"), "[{\"ThreadId\":\"ok\",\"ToolDigest\":null}]");
            try { new CodexChatHistory(corruptRoot).Read(); throw new InvalidOperationException("corrupt history accepted"); }
            catch (IOException) { Check(true, "corrupt history fails safely"); }
            await chat.SelectAsync("chat-1", token);
            Check(chat.Snapshot.Messages.Any(m => m.Text == "以前の返答"), "history resume renders saved messages");
            h = harnesses[1];
            sending = chat.SendAsync("長い依頼", token); await Until(() => h.TurnStarted, token);
            h.Call(704, "item/tool/call", new { threadId = "chat-1", turnId = "turn-1", tool = "library_search", callId = "waiting", arguments = new { wait = true } });
            await Until(() => tools.Calls == 2, token);
            await chat.StopAsync(); await sending;
            Check(tools.Cancelled && h.Requests.Any(r => r.Method == "turn/interrupt") && chat.Snapshot.ErrorCode == "chat_stopped", "stop cancels pending approval and interrupts turn");
            var before = tools.Calls;
            h.Call(705, "item/tool/call", new { threadId = "chat-1", turnId = "turn-1", tool = "library_search", callId = "late", arguments = new { } });
            await Until(() => h.Responses.Any(r => r.GetProperty("id").GetInt32() == 705), token);
            Check(before == tools.Calls, "late tool cannot act after stop");
            await chat.SelectAsync(null, token);
            Check(chat.Snapshot.ThreadId is null && chat.Snapshot.Messages.Count == 0, "new chat clears view");
            history.Add(new("changed-tools", DateTimeOffset.UtcNow, new string('0', 64)));
            await chat.SelectAsync("changed-tools", token);
            Check(chat.Snapshot.ErrorCode == "chat_tools_changed_start_new" && harnesses.Count == 2, "changed capability grants require a new thread");
            await chat.SelectAsync("not-owned", token);
            Check(chat.Snapshot.ErrorCode == "chat_history_failed", "unowned history rejected");
            await chat.SelectAsync(null, token);
            var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            await using (var pending = new CodexChatCoordinator(async ct =>
            {
                started.SetResult(); await Task.Delay(Timeout.Infinite, ct); throw new InvalidOperationException();
            }, tools, new CodexChatHistory(Path.Combine(root, "pending"))))
            {
                var task = pending.SendAsync("接続中の取り消し", token); await started.Task;
                await pending.StopAsync(); await task;
                Check(!pending.Snapshot.Busy && pending.Snapshot.ErrorCode == "chat_stopped" && pending.Snapshot.Messages.Count == 0, "stop during connection sends no turn");
            }
            await using (var inline = new InlineChatController(chat, _ => Task.CompletedTask))
            {
                inline.SetDraft("未送信の下書き");
                inline.Focused = true;
                Check(harnesses.Count == 2 && inline.Draft == "未送信の下書き" && inline.KeepOpen, "inline draft pins panel without starting AI or microphone");
                inline.Focused = false;
                Check(!inline.KeepOpen && inline.Draft == "未送信の下書き", "manual hide preserves draft without keeping panel open");
            }
            await using (var failed = new InlineChatController(new CodexChatCoordinator(_ => Task.FromException<CodexAppServerClient>(new IOException("generated connection failure")),
                tools, new CodexChatHistory(Path.Combine(root, "failed"))), _ => Task.CompletedTask))
            {
                failed.Send("接続できなかった下書き"); await failed.OperationForVerify;
                Check(!failed.Busy && failed.Draft == "接続できなかった下書き" && failed.Snapshot.Messages.Count == 0 && failed.Snapshot.ErrorCode is not null,
                    "failed connection restores the unsent draft without a phantom user message");
            }
            VerifyConsole.WriteLine("PASS chat verify: explicit send, stream/final, owned history, cancellation, root/turn fences, late-tool denial, inline draft and cleanup");
            return 0;
        }
        catch (Exception exception) { VerifyConsole.WriteLine("FAIL chat verify: " + exception.GetType().Name + " " + exception.Message); return 1; }
    }

    private static void Check(bool condition, string name)
    { if (!condition) throw new InvalidOperationException(name); VerifyConsole.WriteLine("PASS chat: " + name); }
    private static async Task Until(Func<bool> ready, CancellationToken token)
    { while (!ready()) await Task.Delay(10, token); }

    internal sealed class TestTools : ICodexVoiceDynamicToolRuntime
    {
        public int Calls; public bool Cancelled;
        public JsonElement Definitions => JsonSerializer.SerializeToElement(new[] { new { type = "function", name = "library_search", description = "Search", inputSchema = new { type = "object", properties = new { } } } });
        public async Task<CodexVoiceDynamicToolResponse> ExecuteAsync(JsonElement? parameters, string expectedThreadId, CancellationToken token)
        {
            Interlocked.Increment(ref Calls);
            if (parameters!.Value.GetProperty("arguments").TryGetProperty("wait", out _))
            { try { await Task.Delay(Timeout.Infinite, token); } catch (OperationCanceledException) { Cancelled = true; return new(false, "cancelled"); } }
            return new(true, "{\"ok\":true}");
        }
    }

    internal sealed class Harness
    {
        private readonly Reader _reader = new();
        internal ConcurrentQueue<(string Method, JsonElement Parameters)> Requests { get; } = new();
        internal ConcurrentQueue<JsonElement> Responses { get; } = new();
        internal volatile bool TurnStarted;
        public CodexAppServerClient Client() => CodexAppServerClient.AttachForTesting(_reader, new Writer(Receive), TimeSpan.FromSeconds(3), () => { _reader.Close(); return ValueTask.CompletedTask; });
        public void Notify(string method, object parameters) => Push(new { method, @params = parameters });
        public void Call(int id, string method, object parameters) => Push(new { id, method, @params = parameters });
        public void Complete(string status) => Notify("turn/completed", new { threadId = "chat-1", turn = new { id = "turn-1", status } });
        private void Push(object value) => _reader.Push(JsonSerializer.Serialize(value));
        private void Receive(string line)
        {
            using var doc = JsonDocument.Parse(line); var r = doc.RootElement;
            if (!r.TryGetProperty("method", out var method)) { Responses.Enqueue(r.Clone()); return; }
            if (!r.TryGetProperty("id", out var id)) return;
            var name = method.GetString()!; var p = r.GetProperty("params"); Requests.Enqueue((name, p.Clone()));
            object result = name switch
            {
                "account/read" => new { account = new { type = "chatgpt" }, requiresOpenaiAuth = true },
                "thread/start" => new { thread = new { id = "chat-1" } },
                "turn/start" => new { turn = new { id = "turn-1", status = "inProgress" } },
                "thread/resume" => new { thread = new { id = "chat-1", turns = new[] { new { items = new[] { new { type = "agentMessage", id = "saved", text = "以前の返答" } } } } } },
                _ => new { }
            };
            if (name == "turn/start") Notify("turn/started", new { threadId = "chat-1", turn = new { id = "turn-1" } });
            Push(new { id = id.GetInt64(), result });
            if (name == "turn/start") TurnStarted = true;
            if (name == "turn/interrupt") Complete("interrupted");
        }
        private sealed class Writer(Action<string> receive) : TextWriter
        {
            public override Encoding Encoding => Encoding.UTF8;
            public override Task WriteLineAsync(ReadOnlyMemory<char> value, CancellationToken cancellationToken = default) { receive(value.ToString()); return Task.CompletedTask; }
            public override Task FlushAsync(CancellationToken cancellationToken) => Task.CompletedTask;
        }
        private sealed class Reader : TextReader
        {
            private readonly Channel<char> _channel = Channel.CreateUnbounded<char>();
            public void Push(string line) { foreach (var c in line + "\n") _channel.Writer.TryWrite(c); }
            public override void Close() => _channel.Writer.TryComplete();
            public override async ValueTask<int> ReadAsync(Memory<char> buffer, CancellationToken cancellationToken = default)
            {
                if (!await _channel.Reader.WaitToReadAsync(cancellationToken)) return 0;
                var i = 0;
                while (i < buffer.Length && _channel.Reader.TryRead(out var c)) buffer.Span[i++] = c;
                return i;
            }
        }
    }
}
