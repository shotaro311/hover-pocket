using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;

namespace HoverPocket.Shell.Voice;

internal static class CodexVoiceToolRouteProbe
{
    public static async Task VerifyAsync(CodexExecutableIdentity identity, JsonElement tools, string probeRoot,
        CancellationToken cancellationToken)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(25));
        var token = timeout.Token;
        var profile = CodexVoiceProfile.Prepare(Path.Combine(probeRoot, Guid.NewGuid().ToString("N")));
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start(1);
        var port = ((IPEndPoint)listener.LocalEndpoint).Port;
        using var executableLease = identity.OpenValidated();
        await using var client = await CodexAppServerClient.StartProcessAsync(identity.Path,
            ["-c", "model=\"hoverpocket-route-probe\"", "-c", "model_provider=\"hoverpocket_probe\"",
             "-c", "model_providers.hoverpocket_probe.name=\"HoverPocket local verification\"",
             "-c", $"model_providers.hoverpocket_probe.base_url=\"http://127.0.0.1:{port}/v1\"",
             "-c", "model_providers.hoverpocket_probe.wire_api=\"responses\"",
             "-c", "model_providers.hoverpocket_probe.request_max_retries=0",
             "-c", "model_providers.hoverpocket_probe.stream_max_retries=0",
             "-c", "model_providers.hoverpocket_probe.requires_openai_auth=false",
             "app-server", "--stdio"], TimeSpan.FromSeconds(12), token, profile.Environment, profile.Root);
        client.StartReading();
        await client.InitializeAsync(JsonSerializer.SerializeToElement(new
        {
            clientInfo = new { name = "hoverpocket_voice_probe", version = "1" },
            capabilities = new { experimentalApi = true }
        }), token);
        var thread = await client.SendRequestAsync("thread/start", CodexVoiceProfile.ThreadParameters(tools, profile.Root), token);
        if (thread.GetProperty("modelProvider").GetString() != "hoverpocket_probe")
            throw new CodexAppServerProtocolException("voice_tool_route_mismatch");
        var capture = CaptureAsync(listener, token);
        try
        {
            await client.SendRequestAsync("turn/start", JsonSerializer.SerializeToElement(new
            {
                threadId = thread.GetProperty("thread").GetProperty("id").GetString(),
                input = new[] { new { type = "text", text = "Reply with ok.", textElements = Array.Empty<object>() } }
            }), token);
            var request = await capture;
            if (!MatchesTools(request, tools)) throw new CodexAppServerProtocolException("voice_tool_route_mismatch");
        }
        finally
        {
            timeout.Cancel();
            listener.Stop();
            try { await capture; } catch (Exception) { }
        }
    }

    internal static bool MatchesTools(JsonElement request, JsonElement expected)
    {
        if (!request.TryGetProperty("tools", out var actual) || actual.ValueKind != JsonValueKind.Array
            || expected.ValueKind != JsonValueKind.Array || actual.GetArrayLength() != expected.GetArrayLength()) return false;
        var actualNames = new HashSet<string>(StringComparer.Ordinal);
        foreach (var tool in actual.EnumerateArray())
        {
            if (!tool.TryGetProperty("type", out var type)
                || !tool.TryGetProperty("name", out var name) || name.ValueKind != JsonValueKind.String
                || !actualNames.Add(name.GetString()!)) return false;
            var definition = expected.EnumerateArray().FirstOrDefault(item => item.GetProperty("name").GetString() == name.GetString());
            if (definition.ValueKind == JsonValueKind.Undefined || type.GetString() != definition.GetProperty("type").GetString()) return false;
            if (type.GetString() == "namespace")
            {
                if (!MatchesTools(tool, definition.GetProperty("tools"))) return false;
            }
            else if (type.GetString() != "function" || !tool.TryGetProperty("parameters", out var parameters)
                || !JsonElement.DeepEquals(parameters, definition.GetProperty("inputSchema"))) return false;
        }
        return expected.EnumerateArray().All(item => actualNames.Contains(item.GetProperty("name").GetString()!));
    }

    private static async Task<JsonElement> CaptureAsync(TcpListener listener, CancellationToken token)
    {
        using var connection = await listener.AcceptTcpClientAsync(token);
        await using var stream = connection.GetStream();
        var header = new List<byte>();
        var single = new byte[1];
        while (true)
        {
            await stream.ReadExactlyAsync(single, token);
            header.Add(single[0]);
            if (header.Count > 32768) throw new CodexAppServerProtocolException("voice_probe_request_invalid");
            if (header.Count >= 4 && header[^4] == 13 && header[^3] == 10 && header[^2] == 13 && header[^1] == 10) break;
        }
        var lines = Encoding.ASCII.GetString(header.ToArray()).Split("\r\n");
        if (lines[0] != "POST /v1/responses HTTP/1.1") throw new CodexAppServerProtocolException("voice_probe_request_invalid");
        var length = 0;
        foreach (var line in lines.Skip(1))
            if (line.StartsWith("Content-Length:", StringComparison.OrdinalIgnoreCase))
                _ = int.TryParse(line[15..].Trim(), out length);
        if (length <= 0 || length > 2 * 1024 * 1024) throw new CodexAppServerProtocolException("voice_probe_request_invalid");
        var body = new byte[length];
        await stream.ReadExactlyAsync(body, token);
        using var document = JsonDocument.Parse(body);
        const string response = "event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"hp-local-probe\",\"object\":\"response\",\"status\":\"completed\",\"output\":[],\"usage\":{\"input_tokens\":0,\"output_tokens\":0,\"total_tokens\":0}}}\n\n";
        var payload = Encoding.UTF8.GetBytes($"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {Encoding.UTF8.GetByteCount(response)}\r\nConnection: close\r\n\r\n{response}");
        await stream.WriteAsync(payload, token);
        return document.RootElement.Clone();
    }
}
