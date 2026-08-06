using System.Text;
using System.Text.Json;
using HoverPocket.Shell.Providers.CodexVoice;

namespace HoverPocket.Shell.Verification;

internal sealed class CodexAppServerProtocolVerifier
{
    private readonly List<string> _failures = [];

    public async Task<int> RunAsync(CancellationToken cancellationToken = default)
    {
        var root = Path.Combine(
            Path.GetTempPath(),
            "HoverPocket",
            "CodexAppServerProtocolVerify",
            Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        var fakeServerPath = Path.Combine(root, "fake-codex.ps1");
        File.WriteAllText(fakeServerPath, FakeServerScript, new UTF8Encoding(false));

        try
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(TimeSpan.FromSeconds(30));

            await using var client = await CodexAppServerClient.StartAsync(
                new CodexAppServerClientOptions
                {
                    ExecutablePath = fakeServerPath,
                    ClientName = "hover_pocket_protocol_verify",
                    ClientTitle = "HoverPocket Protocol Verifier",
                    ClientVersion = "0.0.0",
                    ExperimentalApi = true,
                    RequestTimeout = TimeSpan.FromSeconds(5)
                },
                timeout.Token);

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
        finally
        {
            try
            {
                Directory.Delete(root, recursive: true);
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
            }
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

    private const string FakeServerScript = """
        $ErrorActionPreference = "Stop"
        $rateLimitAttempts = 0
        $serverReplyReceived = $false

        function Send-Json {
            param([object]$Value)
            $json = $Value | ConvertTo-Json -Depth 20 -Compress
            [Console]::Out.WriteLine($json)
            [Console]::Out.Flush()
        }

        while ($true) {
            $line = [Console]::In.ReadLine()
            if ($null -eq $line) {
                break
            }

            try {
                $message = $line | ConvertFrom-Json -ErrorAction Stop
            }
            catch {
                continue
            }

            $hasMethod = $null -ne $message.PSObject.Properties["method"]
            $hasId = $null -ne $message.PSObject.Properties["id"]
            if (-not $hasMethod -and $hasId) {
                if ([string]$message.id -eq "900"
                    -and $null -ne $message.PSObject.Properties["result"]
                    -and $message.result.accepted -eq $true) {
                    $serverReplyReceived = $true
                }
                continue
            }

            $method = [string]$message.method
            switch ($method) {
                "initialize" {
                    Send-Json @{
                        id = $message.id
                        result = @{
                            userAgent = "fake-codex"
                            codexHome = "C:\fake"
                            platformFamily = "windows"
                            platformOs = "windows"
                        }
                    }
                }
                "initialized" {
                }
                "fake/emitNotification" {
                    Send-Json @{
                        method = "fake/notification"
                        params = @{ ok = $true }
                    }
                    Send-Json @{ id = $message.id; result = @{ emitted = $true } }
                }
                "fake/emitServerRequest" {
                    Send-Json @{
                        id = 900
                        method = "fake/approval"
                        params = @{ action = "test" }
                    }
                    Send-Json @{ id = $message.id; result = @{ emitted = $true } }
                }
                "fake/checkServerReply" {
                    Send-Json @{
                        id = $message.id
                        result = @{ received = $serverReplyReceived }
                    }
                }
                "account/rateLimits/read" {
                    $rateLimitAttempts++
                    if ($rateLimitAttempts -eq 1) {
                        Send-Json @{
                            id = $message.id
                            error = @{
                                code = -32001
                                message = "Server overloaded; retry later."
                            }
                        }
                    }
                    else {
                        Send-Json @{
                            id = $message.id
                            result = @{ attempt = $rateLimitAttempts }
                        }
                    }
                }
                "fake/emitMalformed" {
                    [Console]::Out.WriteLine("not-json")
                    [Console]::Out.Flush()
                    Send-Json @{ id = $message.id; result = @{ emitted = $true } }
                }
                default {
                    if ($hasId) {
                        Send-Json @{
                            id = $message.id
                            error = @{
                                code = -32601
                                message = "Unknown fake method: $method"
                            }
                        }
                    }
                }
            }
        }
        """;
}
