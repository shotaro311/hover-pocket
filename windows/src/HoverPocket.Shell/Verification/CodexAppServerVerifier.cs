using System.Text.Json;
using HoverPocket.Shell.Providers.CodexVoice;

namespace HoverPocket.Shell.Verification;

internal sealed class CodexAppServerVerifier
{
    public async Task<int> RunAsync(CancellationToken cancellationToken = default)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(35));

        try
        {
            await using var client = await CodexAppServerClient.StartAsync(
                new CodexAppServerClientOptions
                {
                    ClientName = "hover_pocket",
                    ClientTitle = "HoverPocket Phase 0 Verifier",
                    ClientVersion = "0.0.0",
                    ExperimentalApi = true,
                    RequestTimeout = TimeSpan.FromSeconds(12)
                },
                timeout.Token);

            VerifyConsole.WriteLine("codex_app_server_initialize=ok");
            VerifyConsole.WriteLine($"codex_executable={client.ExecutablePath}");
            VerifyConsole.WriteLine($"codex_process_id={client.ProcessId}");

            var account = await ProbeAsync(
                client,
                "account/read",
                new { refreshToken = false },
                timeout.Token);
            var rateLimits = await ProbeAsync(
                client,
                "account/rateLimits/read",
                null,
                timeout.Token);
            var voices = await ProbeAsync(
                client,
                "thread/realtime/listVoices",
                new { },
                timeout.Token);

            VerifyConsole.WriteLine($"account_read={account.Status}");
            VerifyConsole.WriteLine($"rate_limits_read={rateLimits.Status}");
            VerifyConsole.WriteLine($"realtime_list_voices={voices.Status}");
            if (voices.Result is { } voicesResult)
            {
                var count = TryCountArray(voicesResult);
                VerifyConsole.WriteLine($"realtime_voice_count={(count?.ToString() ?? "unknown")}");
            }

            VerifyConsole.WriteLine($"protocol_malformed_stdout_lines={client.MalformedStdoutLineCount}");
            VerifyConsole.WriteLine($"protocol_unknown_responses={client.UnknownResponseCount}");
            VerifyConsole.WriteLine($"app_server_stderr_tail_count={client.StderrTail.Count}");

            var passed = account.Succeeded
                && rateLimits.Succeeded
                && voices.Succeeded
                && client.MalformedStdoutLineCount == 0
                && client.UnknownResponseCount == 0;
            VerifyConsole.WriteLine(passed
                ? "PASS codex-app-server verify"
                : "FAIL codex-app-server verify");
            return passed ? 0 : 1;
        }
        catch (FileNotFoundException exception)
        {
            VerifyConsole.WriteLine($"codex_app_server_initialize=failed:{exception.GetType().Name}");
            VerifyConsole.WriteLine("FAIL codex-app-server verify");
            return 1;
        }
        catch (OperationCanceledException) when (timeout.IsCancellationRequested)
        {
            VerifyConsole.WriteLine("codex_app_server_initialize=failed:timeout");
            VerifyConsole.WriteLine("FAIL codex-app-server verify");
            return 1;
        }
        catch (Exception exception) when (exception is IOException
            or InvalidOperationException
            or TimeoutException
            or CodexAppServerRpcException
            or System.ComponentModel.Win32Exception)
        {
            VerifyConsole.WriteLine($"codex_app_server_initialize=failed:{exception.GetType().Name}");
            if (exception is CodexAppServerRpcException rpcException)
            {
                VerifyConsole.WriteLine($"codex_app_server_rpc_code={rpcException.Code}");
            }

            VerifyConsole.WriteLine("FAIL codex-app-server verify");
            return 1;
        }
    }

    private static async Task<ProbeResult> ProbeAsync(
        CodexAppServerClient client,
        string method,
        object? parameters,
        CancellationToken cancellationToken)
    {
        try
        {
            var result = await client.SendRequestAsync(method, parameters, cancellationToken);
            return new ProbeResult("ok", true, result);
        }
        catch (CodexAppServerRpcException exception)
        {
            var status = exception.IsRetryableOverload
                ? $"rpc_error:{exception.Code}:retryable"
                : $"rpc_error:{exception.Code}";
            return new ProbeResult(status, false, null);
        }
        catch (TimeoutException)
        {
            return new ProbeResult("timeout", false, null);
        }
    }

    private static int? TryCountArray(JsonElement result)
    {
        if (result.ValueKind == JsonValueKind.Array)
        {
            return result.GetArrayLength();
        }

        if (result.ValueKind != JsonValueKind.Object)
        {
            return null;
        }

        foreach (var propertyName in new[] { "voices", "data" })
        {
            if (result.TryGetProperty(propertyName, out var value)
                && value.ValueKind == JsonValueKind.Array)
            {
                return value.GetArrayLength();
            }
        }

        return null;
    }

    private sealed record ProbeResult(
        string Status,
        bool Succeeded,
        JsonElement? Result);
}
