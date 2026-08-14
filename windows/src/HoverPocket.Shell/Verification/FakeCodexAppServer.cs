using System.Text;
using System.Text.Json;

namespace HoverPocket.Shell.Verification;

internal static class FakeCodexAppServer
{
    private const string EnableEnvironmentVariable = "HOVERPOCKET_FAKE_CODEX_APP_SERVER";
    private const string SignedOutEnvironmentVariable = "HOVERPOCKET_FAKE_CODEX_SIGNED_OUT";

    public static bool ShouldRun(IReadOnlyList<string> args)
    {
        return string.Equals(
                Environment.GetEnvironmentVariable(EnableEnvironmentVariable),
                "1",
                StringComparison.Ordinal)
            && args.Any(argument =>
                string.Equals(argument, "app-server", StringComparison.OrdinalIgnoreCase));
    }

    public static int Run()
    {
        using var input = new StreamReader(
            Console.OpenStandardInput(),
            new UTF8Encoding(false),
            detectEncodingFromByteOrderMarks: true,
            bufferSize: 4096,
            leaveOpen: true);
        using var output = new StreamWriter(
            Console.OpenStandardOutput(),
            new UTF8Encoding(false),
            bufferSize: 4096,
            leaveOpen: true)
        {
            AutoFlush = true
        };

        var rateLimitAttempts = 0;
        var serverReplyReceived = false;
        var signedOut = string.Equals(
            Environment.GetEnvironmentVariable(SignedOutEnvironmentVariable),
            "1",
            StringComparison.Ordinal);
        string? line;
        while ((line = input.ReadLine()) is not null)
        {
            JsonElement message;
            try
            {
                using var document = JsonDocument.Parse(line);
                message = document.RootElement.Clone();
            }
            catch (JsonException)
            {
                continue;
            }

            var hasMethod = message.TryGetProperty("method", out var methodElement)
                && methodElement.ValueKind == JsonValueKind.String;
            var hasId = message.TryGetProperty("id", out var idElement)
                && idElement.ValueKind is JsonValueKind.String or JsonValueKind.Number;

            if (!hasMethod && hasId)
            {
                if (idElement.ToString() == "900"
                    && message.TryGetProperty("result", out var serverResult)
                    && serverResult.ValueKind == JsonValueKind.Object
                    && serverResult.TryGetProperty("accepted", out var accepted)
                    && accepted.ValueKind == JsonValueKind.True)
                {
                    serverReplyReceived = true;
                }

                continue;
            }

            if (!hasMethod)
            {
                continue;
            }

            var method = methodElement.GetString();
            switch (method)
            {
                case "initialize":
                    Write(output, new
                    {
                        id = idElement.Clone(),
                        result = new
                        {
                            userAgent = "fake-codex",
                            codexHome = "C:\\fake",
                            platformFamily = "windows",
                            platformOs = "windows"
                        }
                    });
                    break;
                case "initialized":
                    break;
                case "account/read":
                    Write(output, new
                    {
                        id = idElement.Clone(),
                        result = new
                        {
                            account = signedOut
                                ? null
                                : (object)new
                                {
                                    type = "chatgpt",
                                    email = (string?)null,
                                    planType = "pro"
                                },
                            requiresOpenaiAuth = true
                        }
                    });
                    break;
                case "thread/realtime/listVoices":
                    Write(output, new
                    {
                        id = idElement.Clone(),
                        result = new
                        {
                            voices = new
                            {
                                defaultV1 = "verse",
                                defaultV2 = "verse",
                                v1 = new[] { "verse" },
                                v2 = new[] { "verse" }
                            }
                        }
                    });
                    break;
                case "thread/start":
                    Write(output, new
                    {
                        id = idElement.Clone(),
                        result = new
                        {
                            thread = new { id = "root-thread" }
                        }
                    });
                    break;
                case "thread/realtime/start":
                    Write(output, new
                    {
                        id = idElement.Clone(),
                        result = new { }
                    });
                    Write(output, new
                    {
                        method = "thread/realtime/started",
                        @params = new
                        {
                            threadId = "root-thread",
                            realtimeSessionId = "fake-realtime",
                            version = "v1"
                        }
                    });
                    Write(output, new
                    {
                        method = "thread/realtime/sdp",
                        @params = new
                        {
                            threadId = "root-thread",
                            sdp = "v=0\r\ns=fake-answer\r\n"
                        }
                    });
                    break;
                case "thread/realtime/stop":
                    Write(output, new
                    {
                        id = idElement.Clone(),
                        result = new { }
                    });
                    Write(output, new
                    {
                        method = "thread/realtime/closed",
                        @params = new
                        {
                            threadId = "root-thread",
                            reason = (string?)null
                        }
                    });
                    break;
                case "fake/emitNotification":
                    Write(output, new
                    {
                        method = "fake/notification",
                        @params = new { ok = true }
                    });
                    Write(output, new
                    {
                        id = idElement.Clone(),
                        result = new { emitted = true }
                    });
                    break;
                case "fake/emitServerRequest":
                    Write(output, new
                    {
                        id = 900,
                        method = "fake/approval",
                        @params = new { action = "test" }
                    });
                    Write(output, new
                    {
                        id = idElement.Clone(),
                        result = new { emitted = true }
                    });
                    break;
                case "fake/checkServerReply":
                    Write(output, new
                    {
                        id = idElement.Clone(),
                        result = new { received = serverReplyReceived }
                    });
                    break;
                case "account/rateLimits/read":
                    rateLimitAttempts++;
                    if (rateLimitAttempts == 1)
                    {
                        Write(output, new
                        {
                            id = idElement.Clone(),
                            error = new
                            {
                                code = -32001,
                                message = "Server overloaded; retry later."
                            }
                        });
                    }
                    else
                    {
                        Write(output, new
                        {
                            id = idElement.Clone(),
                            result = new { attempt = rateLimitAttempts }
                        });
                    }
                    break;
                case "fake/emitMalformed":
                    output.WriteLine("not-json");
                    Write(output, new
                    {
                        id = idElement.Clone(),
                        result = new { emitted = true }
                    });
                    break;
                case "fake/exit":
                    Write(output, new
                    {
                        id = idElement.Clone(),
                        result = new { exiting = true }
                    });
                    return 0;
                default:
                    if (hasId)
                    {
                        Write(output, new
                        {
                            id = idElement.Clone(),
                            error = new
                            {
                                code = -32601,
                                message = $"Unknown fake method: {method}"
                            }
                        });
                    }
                    break;
            }
        }

        return 0;
    }

    private static void Write(StreamWriter output, object value)
    {
        output.WriteLine(JsonSerializer.Serialize(value));
    }
}
