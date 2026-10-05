using System.Diagnostics;
using System.Text.Json;

namespace HoverPocket.Shell.Voice;

internal sealed class CodexVoiceAccountLogin : IDisposable
{
    private CancellationTokenSource? _lifetime;
    private Task? _completion;
    public string Status { get; private set; } = "idle";
    public event EventHandler? Changed;

    public async Task StartAsync(string root, CancellationToken cancellationToken)
    {
        if (_lifetime is not null) return;
        var identity = CodexExecutableResolver.Resolve()
            ?? throw new CodexAppServerProtocolException("codex_executable_missing");
        var profile = CodexVoiceProfile.Prepare(root);
        var lifetime = new CancellationTokenSource(TimeSpan.FromMinutes(3));
        _lifetime = lifetime;
        CodexAppServerClient? client = null;
        try
        {
            using var executableLease = identity.OpenValidated();
            using var start = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, lifetime.Token);
            client = await CodexAppServerClient.StartProcessAsync(identity.Path, ["app-server", "--stdio"],
                TimeSpan.FromSeconds(20), start.Token, profile.Environment, profile.Root);
            var completed = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
            string? loginId = null;
            client.NotificationReceived += (_, notification) =>
            {
                if (notification.Method == "account/login/completed" && notification.Parameters is { } value
                    && value.TryGetProperty("loginId", out var id) && id.GetString() == loginId
                    && value.TryGetProperty("success", out var success))
                    completed.TrySetResult(success.ValueKind == JsonValueKind.True);
            };
            client.Disconnected += (_, _) => completed.TrySetResult(false);
            client.StartReading();
            await client.InitializeAsync(JsonSerializer.SerializeToElement(new {
                clientInfo = new { name = "hoverpocket_voice_login", version = "1" }, capabilities = new { experimentalApi = true }
            }), start.Token);
            var result = await client.SendRequestAsync("account/login/start", JsonSerializer.SerializeToElement(new { type = "chatgpt" }), start.Token);
            loginId = result.GetProperty("loginId").GetString();
            if (string.IsNullOrEmpty(loginId) || !Uri.TryCreate(result.GetProperty("authUrl").GetString(), UriKind.Absolute, out var uri)
                || uri.Scheme != "https" || uri.Host != "auth.openai.com" || !string.IsNullOrEmpty(uri.UserInfo))
                throw new CodexAppServerProtocolException("voice_login_response_invalid");
            Process.Start(new ProcessStartInfo(uri.AbsoluteUri) { UseShellExecute = true });
            Status = "waiting";
            Changed?.Invoke(this, EventArgs.Empty);
            _completion = CompleteAsync(client, completed.Task, lifetime);
            client = null;
        }
        catch
        {
            if (client is not null) await client.DisposeAsync();
            _lifetime = null;
            lifetime.Dispose();
            Status = "failed";
            Changed?.Invoke(this, EventArgs.Empty);
            throw;
        }
    }

    private async Task CompleteAsync(CodexAppServerClient client, Task<bool> completed, CancellationTokenSource lifetime)
    {
        try { Status = await completed.WaitAsync(lifetime.Token) ? "succeeded" : "failed"; }
        catch (OperationCanceledException) { Status = "cancelled"; }
        finally
        {
            await client.DisposeAsync();
            _lifetime = null;
            lifetime.Dispose();
            Changed?.Invoke(this, EventArgs.Empty);
        }
    }

    public void Cancel() => _lifetime?.Cancel();
    public void Dispose() { Changed = null; Cancel(); }
}
