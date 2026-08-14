using System.Text.Json;
using HoverPocket.Shell.Providers.CodexVoice;

namespace HoverPocket.Shell.Verification;

internal sealed class CodexAppServerProtocolVerifier
{
    private const string FakeServerEnvironmentVariable = "HOVERPOCKET_FAKE_CODEX_APP_SERVER";
    private readonly List<string> _failures = [];

    public async Task<int> RunAsync(CancellationToken cancellationToken = default)
    {
        VerifyOptionsFailClosed();
        VerifyCommandWrapperStartInfo();
        try
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(TimeSpan.FromSeconds(30));

            await using var client = await StartFakeServerClientAsync(timeout.Token);
            VerifyInitialize(client);
            await VerifyNotificationsAsync(client, timeout.Token);
            await VerifyServerRequestAsync(client, timeout.Token);
            await VerifyServerErrorWireFormatAsync(client, timeout.Token);
            await VerifyServerRequestBoundAsync(client, timeout.Token);
            await VerifyOverloadRetryAsync(client, timeout.Token);
            await VerifyMalformedLineIsolationAsync(client, timeout.Token);
            await VerifyOversizedLineIsolationAsync(client, timeout.Token);
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

    private void VerifyOptionsFailClosed()
    {
        if (new CodexAppServerClientOptions().ExperimentalApi)
        {
            _failures.Add("experimental app-server capability was enabled by default");
        }
    }

    private void VerifyCommandWrapperStartInfo()
    {
        const string commandPath = @"C:\Program Files\Codex\codex.cmd";
        var startInfo = CodexExecutableResolver.CreateAppServerStartInfo(commandPath);
        var expectedProcessor = Path.Combine(Environment.SystemDirectory, "cmd.exe");
        if (!string.Equals(startInfo.FileName, expectedProcessor, StringComparison.OrdinalIgnoreCase))
        {
            _failures.Add("command wrapper did not use the Windows system command processor");
        }

        if (startInfo.ArgumentList.Count != 0
            || startInfo.Arguments != $"/d /s /c \"\"{commandPath}\" app-server --stdio\"")
        {
            _failures.Add("command wrapper quoting did not preserve the Codex path and JSONL pipes");
        }
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
            new { },
            maxAttempts: 3,
            cancellationToken: cancellationToken);
        if (!result.TryGetProperty("attempt", out var attempt)
            || !attempt.TryGetInt32(out var value)
            || value != 2)
        {
            _failures.Add("retryable -32001 overload was not retried exactly once");
        }
    }

    private async Task VerifyServerErrorWireFormatAsync(
        CodexAppServerClient client,
        CancellationToken cancellationToken)
    {
        client.ServerRequestHandler = (request, _) => Task.FromResult(
            request.Method == "fake/reject"
                ? CodexAppServerReply.Failure(-32601, "Verifier rejection.")
                : CodexAppServerReply.Failure(-32601, $"Unexpected request: {request.Method}"));
        _ = await client.SendRequestAsync(
            "fake/emitErrorServerRequest",
            cancellationToken: cancellationToken);

        var received = false;
        for (var attempt = 0; attempt < 20 && !received; attempt++)
        {
            var check = await client.SendRequestAsync(
                "fake/checkServerErrorReply",
                cancellationToken: cancellationToken);
            received = check.TryGetProperty("received", out var value)
                && value.ValueKind == JsonValueKind.True;
            if (!received)
            {
                await Task.Delay(25, cancellationToken);
            }
        }

        if (!received)
        {
            _failures.Add("server request error reply did not use lowercase JSON-RPC field names");
        }
    }

    private async Task VerifyServerRequestBoundAsync(
        CodexAppServerClient client,
        CancellationToken cancellationToken)
    {
        var release = new TaskCompletionSource<bool>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        client.ServerRequestHandler = async (request, token) =>
        {
            if (request.Method != "fake/slow")
            {
                return CodexAppServerReply.Failure(-32601, $"Unexpected request: {request.Method}");
            }
            _ = await release.Task.WaitAsync(token);
            return CodexAppServerReply.Success(new { accepted = true });
        };

        _ = await client.SendRequestAsync(
            "fake/emitServerRequestBurst",
            cancellationToken: cancellationToken);
        var overloaded = false;
        for (var attempt = 0; attempt < 40 && !overloaded; attempt++)
        {
            var check = await client.SendRequestAsync(
                "fake/checkServerOverloadReply",
                cancellationToken: cancellationToken);
            overloaded = check.TryGetProperty("received", out var value)
                && value.ValueKind == JsonValueKind.True;
            if (!overloaded)
            {
                await Task.Delay(25, cancellationToken);
            }
        }
        release.TrySetResult(true);
        if (!overloaded)
        {
            _failures.Add("concurrent server request bound did not fail closed with overload");
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

    private async Task VerifyOversizedLineIsolationAsync(
        CodexAppServerClient client,
        CancellationToken cancellationToken)
    {
        var before = client.MalformedStdoutLineCount;
        _ = await client.SendRequestAsync(
            "fake/emitOversized",
            cancellationToken: cancellationToken);
        if (client.MalformedStdoutLineCount != before + 1)
        {
            _failures.Add("oversized stdout line was not discarded and counted");
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
