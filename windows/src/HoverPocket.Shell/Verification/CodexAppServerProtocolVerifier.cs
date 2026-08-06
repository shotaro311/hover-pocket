using System.Text.Json;
using HoverPocket.Shell.Providers.CodexVoice;

namespace HoverPocket.Shell.Verification;

internal sealed class CodexAppServerProtocolVerifier
{
    private const string FakeServerEnvironmentVariable = "HOVERPOCKET_FAKE_CODEX_APP_SERVER";
    private readonly List<string> _failures = [];

    public async Task<int> RunAsync(CancellationToken cancellationToken = default)
    {
        try
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(TimeSpan.FromSeconds(30));

            await using var client = await StartFakeServerClientAsync(timeout.Token);
            VerifyInitialize(client);
            await VerifyNotificationsAsync(client, timeout.Token);
            await VerifyServerRequestAsync(client, timeout.Token);
            await VerifyOverloadRetryAsync(client, timeout.Token);
            await VerifyMalformedLineIsolationAsync(client, timeout.Token);
            VerifyProtocolCounters(client);
        }
        catch (Exception exception) when (exception is IOException
            or InvalidOperationException
            or TimeoutException
            or OperationCanceledException
            or CodexAppServerRpcException
            or System.ComponentModel.Win32Exception)
        {
            _failures.Add($"protocol verifier threw {exception.GetType().Name}: {exception.Message}");
        }

        if (_failures.Count == 0)
        {
            VerifyConsole.WriteLine("PASS codex-app-server-protocol verify");
            return 0;
        }

        VerifyConsole.WriteLine("FAIL codex-app-server-protocol verify:");
        foreach (var failure in _failures)
        {
            VerifyConsole.WriteLine($"- {failure}");
        }

        return 1;
    }

    private static async Task<CodexAppServerClient> StartFakeServerClientAsync(
        CancellationToken cancellationToken)
    {
        var executablePath = Environment.ProcessPath
            ?? throw new InvalidOperationException("Current executable path is unavailable.");
        var previousValue = Environment.GetEnvironmentVariable(FakeServerEnvironmentVariable);
        Environment.SetEnvironmentVariable(FakeServerEnvironmentVariable, "1");
        try
        {
            return await CodexAppServerClient.StartAsync(
                new CodexAppServerClientOptions
                {
                    ExecutablePath = executablePath,
                    ClientName = "hover_pocket_protocol_verify",
                    ClientTitle = "HoverPocket Protocol Verifier",
                    ClientVersion = "0.0.0",
                    ExperimentalApi = true,
                    RequestTimeout = TimeSpan.FromSeconds(5)
                },
                cancellationToken);
        }
        finally
        {
            Environment.SetEnvironmentVariable(FakeServerEnvironmentVariable, previousValue);
        }
    }

    private void VerifyInitialize(CodexAppServerClient client)
    {
        if (!client.IsInitialized)
        {
            _failures.Add("initialize handshake did not complete");
        }

        if (client.ProcessId <= 0)
        {
            _failures.Add("fake app-server process id was invalid");
        }
    }

    private async Task VerifyNotificationsAsync(
        CodexAppServerClient client,
        CancellationToken cancellationToken)
    {
        var received = new TaskCompletionSource<bool>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        client.NotificationReceived += (_, eventArgs) =>
        {
            if (eventArgs.Method == "fake/notification"
                && eventArgs.Params is { } parameters
                && parameters.TryGetProperty("ok", out var ok)
                && ok.ValueKind == JsonValueKind.True)
            {
                received.TrySetResult(true);
            }
        };
        client.NotificationReceived += (_, _) =>
            throw new InvalidOperationException("intentional verifier handler failure");

        _ = await client.SendRequestAsync(
            "fake/emitNotification",
            cancellationToken: cancellationToken);
        try
        {
            _ = await received.Task.WaitAsync(TimeSpan.FromSeconds(3), cancellationToken);
        }
        catch (TimeoutException)
        {
            _failures.Add("notification was not delivered");
        }

        if (client.NotificationHandlerFailureCount != 1)
        {
            _failures.Add(
                $"notification handler isolation count was {client.NotificationHandlerFailureCount}, expected 1");
        }
    }

    private async Task VerifyServerRequestAsync(
        CodexAppServerClient client,
        CancellationToken cancellationToken)
    {
        var handled = new TaskCompletionSource<bool>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        client.ServerRequestHandler = (request, _) =>
        {
            if (request.Method != "fake/approval")
            {
                return Task.FromResult(
                    CodexAppServerReply.Failure(-32601, $"Unexpected request: {request.Method}"));
            }

            if (request.Params is not { } parameters
                || !parameters.TryGetProperty("action", out var action)
                || action.GetString() != "test")
            {
                return Task.FromResult(
                    CodexAppServerReply.Failure(-32602, "Invalid fake approval params."));
            }

            handled.TrySetResult(true);
            return Task.FromResult(CodexAppServerReply.Success(new { accepted = true }));
        };

        _ = await client.SendRequestAsync(
            "fake/emitServerRequest",
            cancellationToken: cancellationToken);
        try
        {
            _ = await handled.Task.WaitAsync(TimeSpan.FromSeconds(3), cancellationToken);
        }
        catch (TimeoutException)
        {
            _failures.Add("server-to-client request was not dispatched");
            return;
        }

        var replyReceived = false;
        for (var attempt = 0; attempt < 20 && !replyReceived; attempt++)
        {
            var check = await client.SendRequestAsync(
                "fake/checkServerReply",
                cancellationToken: cancellationToken);
            replyReceived = check.TryGetProperty("received", out var received)
                && received.ValueKind == JsonValueKind.True;
            if (!replyReceived)
            {
                await Task.Delay(50, cancellationToken);
            }
        }

        if (!replyReceived)
        {
            _failures.Add("server-to-client request response was not received by fake server");
        }
    }

    private async Task VerifyOverloadRetryAsync(
        CodexAppServerClient client,
        CancellationToken cancellationToken)
    {
        var result = await client.SendIdempotentRequestWithRetryAsync(
            "account/rateLimits/read",
            maxAttempts: 3,
            cancellationToken: cancellationToken);
        if (!result.TryGetProperty("attempt", out var attempt)
            || !attempt.TryGetInt32(out var value)
            || value != 2)
        {
            _failures.Add("retryable -32001 overload was not retried exactly once");
        }
    }

    private async Task VerifyMalformedLineIsolationAsync(
        CodexAppServerClient client,
        CancellationToken cancellationToken)
    {
        var before = client.MalformedStdoutLineCount;
        _ = await client.SendRequestAsync(
            "fake/emitMalformed",
            cancellationToken: cancellationToken);
        if (client.MalformedStdoutLineCount != before + 1)
        {
            _failures.Add("malformed stdout line was not isolated and counted");
        }
    }

    private void VerifyProtocolCounters(CodexAppServerClient client)
    {
        if (client.UnknownResponseCount != 0)
        {
            _failures.Add($"unknown response count was {client.UnknownResponseCount}");
        }

        if (client.UnhandledServerRequestCount != 0)
        {
            _failures.Add($"unhandled server request count was {client.UnhandledServerRequestCount}");
        }
    }
}
