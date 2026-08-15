using System.Text;
using System.Text.Json;

namespace HoverPocket.Shell.Verification;

internal static class FakeCodexAppServer
{
    private const string EnableEnvironmentVariable = "HOVERPOCKET_FAKE_CODEX_APP_SERVER";
    private const string SignedOutEnvironmentVariable = "HOVERPOCKET_FAKE_CODEX_SIGNED_OUT";
    private const string ExpectDynamicToolsEnvironmentVariable = "HOVERPOCKET_FAKE_CODEX_EXPECT_DYNAMIC_TOOLS";
    private const string WebRtcFailureEnvironmentVariable = "HOVERPOCKET_FAKE_CODEX_WEBRTC_FAILURE";

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
        var serverErrorReplyReceived = false;
        var serverOverloadReplyReceived = false;
        var childReadAttempts = 0;
        var threadStartAttempts = 0;
        var realtimeStartAttempts = 0;
        var signedOut = string.Equals(
            Environment.GetEnvironmentVariable(SignedOutEnvironmentVariable),
            "1",
            StringComparison.Ordinal);
        var expectDynamicTools = string.Equals(
            Environment.GetEnvironmentVariable(ExpectDynamicToolsEnvironmentVariable),
            "1",
            StringComparison.Ordinal);
        var failFirstWebRtc = string.Equals(
            Environment.GetEnvironmentVariable(WebRtcFailureEnvironmentVariable),
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
                if (idElement.ToString() == "901"
                    && message.TryGetProperty("error", out var serverError)
                    && serverError.ValueKind == JsonValueKind.Object
                    && serverError.TryGetProperty("code", out var errorCode)
                    && errorCode.GetInt32() == -32601
                    && serverError.TryGetProperty("message", out var errorMessage)
                    && errorMessage.GetString() == "Verifier rejection."
                    && !serverError.TryGetProperty("Code", out _)
                    && !serverError.TryGetProperty("Message", out _)
                    && !serverError.TryGetProperty("Data", out _))
                {
                    serverErrorReplyReceived = true;
                }
                if (idElement.ToString() == "1008"
                    && message.TryGetProperty("error", out var overloadError)
                    && overloadError.ValueKind == JsonValueKind.Object
                    && overloadError.TryGetProperty("code", out var overloadCode)
                    && overloadCode.GetInt32() == -32001)
                {
                    serverOverloadReplyReceived = true;
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
                    if (!HasRefreshTokenFalse(message))
                    {
                        Write(output, new
                        {
                            id = idElement.Clone(),
                            error = new { code = -32602, message = "Expected refreshToken=false." }
                        });
                        break;
                    }
                    if (expectDynamicTools)
                    {
                        Write(output, new
                        {
                            id = 950,
                            method = "item/tool/call",
                            @params = new
                            {
                                arguments = new { },
                                callId = "validation-call",
                                @namespace = (string?)null,
                                threadId = "root-thread",
                                tool = "hoverpocket_verify",
                                turnId = "validation-turn"
                            }
                        });
                    }
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
                    if (!HasEmptyObjectParams(message))
                    {
                        Write(output, new
                        {
                            id = idElement.Clone(),
                            error = new { code = -32602, message = "Expected empty params." }
                        });
                        break;
                    }
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
                {
                    threadStartAttempts++;
                    var hasDynamicTools = message.TryGetProperty("params", out var threadStartParams)
                        && threadStartParams.ValueKind == JsonValueKind.Object
                        && threadStartParams.TryGetProperty("dynamicTools", out var dynamicTools)
                        && dynamicTools.ValueKind == JsonValueKind.Array
                        && dynamicTools.GetArrayLength() > 0;
                    if (expectDynamicTools && !hasDynamicTools)
                    {
                        Write(output, new
                        {
                            id = idElement.Clone(),
                            error = new
                            {
                                code = -32602,
                                message = "Expected allowlisted dynamic tools."
                            }
                        });
                        break;
                    }
                    Write(output, new
                    {
                        id = idElement.Clone(),
                        result = new
                        {
                            thread = new
                            {
                                id = failFirstWebRtc
                                    ? $"root-thread-{threadStartAttempts}"
                                    : "root-thread",
                                sessionId = failFirstWebRtc
                                    ? $"session-{threadStartAttempts}"
                                    : "session-a",
                                createdAt = 1_700_000_000L
                            }
                        }
                    });
                    break;
                }
                case "thread/list":
                {
                    var expectedSources = new[]
                    {
                        "appServer",
                        "subAgent",
                        "subAgentReview",
                        "subAgentCompact",
                        "subAgentThreadSpawn",
                        "subAgentOther"
                    };
                    var validParams = message.TryGetProperty("params", out var listParams)
                        && listParams.ValueKind == JsonValueKind.Object
                        && listParams.TryGetProperty("ancestorThreadId", out var ancestor)
                        && (ancestor.GetString() == "root-thread"
                            || (failFirstWebRtc
                                && ancestor.GetString() is "root-thread-1" or "root-thread-2"))
                        && listParams.TryGetProperty("archived", out var archived)
                        && archived.ValueKind == JsonValueKind.False
                        && listParams.TryGetProperty("sourceKinds", out var sourceKinds)
                        && sourceKinds.ValueKind == JsonValueKind.Array
                        && sourceKinds.EnumerateArray()
                            .Select(value => value.GetString() ?? string.Empty)
                            .SequenceEqual(expectedSources, StringComparer.Ordinal)
                        && listParams.TryGetProperty("limit", out var limit)
                        && limit.TryGetInt32(out var limitValue)
                        && limitValue == 64
                        && listParams.TryGetProperty("sortDirection", out var sortDirection)
                        && sortDirection.GetString() == "asc"
                        && listParams.TryGetProperty("sortKey", out var sortKey)
                        && sortKey.GetString() == "created_at"
                        && listParams.TryGetProperty("useStateDbOnly", out var stateDbOnly)
                        && stateDbOnly.ValueKind == JsonValueKind.True;
                    var hasCursor = listParams.TryGetProperty("cursor", out var cursorValue);
                    var cursor = hasCursor && cursorValue.ValueKind == JsonValueKind.String
                        ? cursorValue.GetString()
                        : null;
                    validParams = validParams
                        && (!hasCursor || cursorValue.ValueKind == JsonValueKind.String)
                        && (cursor is null or "page-2");
                    if (!validParams)
                    {
                        Write(output, new
                        {
                            id = idElement.Clone(),
                            error = new { code = -32602, message = "Expected root-scoped thread list." }
                        });
                        break;
                    }
                    object[] data;
                    string? nextCursor;
                    if (failFirstWebRtc)
                    {
                        data = [];
                        nextCursor = null;
                    }
                    else if (cursor is null)
                    {
                        data =
                        [
                            new
                            {
                                id = "child-a",
                                sessionId = "session-a",
                                parentThreadId = "root-thread",
                                name = "Today Focusを作成",
                                preview = "古い要約",
                                status = new { type = "active", activeFlags = Array.Empty<string>() },
                                createdAt = 1_700_000_010L,
                                updatedAt = 1_700_000_030L
                            },
                            new
                            {
                                id = "grandchild-a",
                                sessionId = "session-a",
                                parentThreadId = "child-a",
                                name = "予定を整理",
                                preview = "検証中",
                                status = new { type = "idle" },
                                createdAt = 1_700_000_020L,
                                updatedAt = 1_700_000_040L
                            },
                            new
                            {
                                id = "foreign-child",
                                sessionId = "session-b",
                                parentThreadId = "root-thread",
                                name = "別root",
                                preview = "表示禁止",
                                status = new { type = "active", activeFlags = Array.Empty<string>() },
                                createdAt = 1_700_000_020L,
                                updatedAt = 1_700_000_050L
                            },
                            new
                            {
                                id = "orphan",
                                sessionId = "session-a",
                                parentThreadId = "other-root",
                                name = "孤立",
                                preview = "表示禁止",
                                status = new { type = "active", activeFlags = Array.Empty<string>() },
                                createdAt = 1_700_000_020L,
                                updatedAt = 1_700_000_060L
                            }
                        ];
                        nextCursor = "page-2";
                    }
                    else
                    {
                        data =
                        [
                            new
                            {
                                id = "current-root",
                                sessionId = "session-a",
                                parentThreadId = "root-thread",
                                name = "予約語に似た子",
                                preview = "衝突なし",
                                status = new { type = "idle" },
                                createdAt = 1_700_000_050L,
                                updatedAt = 1_700_000_070L
                            },
                            new
                            {
                                id = "paged-child",
                                sessionId = "session-a",
                                parentThreadId = "root-thread",
                                name = "2ページ目",
                                preview = "取得中",
                                status = new { type = "active", activeFlags = Array.Empty<string>() },
                                createdAt = 1_700_000_060L,
                                updatedAt = 1_700_000_080L
                            },
                            new
                            {
                                id = "duplicate",
                                sessionId = "session-a",
                                parentThreadId = "root-thread",
                                name = "重複1",
                                preview = "表示禁止",
                                status = new { type = "active", activeFlags = Array.Empty<string>() },
                                createdAt = 1_700_000_060L,
                                updatedAt = 1_700_000_090L
                            },
                            new
                            {
                                id = "duplicate",
                                sessionId = "session-a",
                                parentThreadId = "root-thread",
                                name = "重複2",
                                preview = "表示禁止",
                                status = new { type = "systemError" },
                                createdAt = 1_700_000_060L,
                                updatedAt = 1_700_000_100L
                            },
                            new
                            {
                                id = "duplicate-child",
                                sessionId = "session-a",
                                parentThreadId = "duplicate",
                                name = "重複配下",
                                preview = "表示禁止",
                                status = new { type = "idle" },
                                createdAt = 1_700_000_070L,
                                updatedAt = 1_700_000_110L
                            }
                        ];
                        nextCursor = null;
                    }
                    Write(output, new
                    {
                        id = idElement.Clone(),
                        result = new
                        {
                            data,
                            nextCursor
                        }
                    });
                    break;
                }
                case "thread/read":
                {
                    string? threadId = null;
                    if (message.TryGetProperty("params", out var readParams)
                        && readParams.ValueKind == JsonValueKind.Object
                        && readParams.TryGetProperty("threadId", out var threadIdValue)
                        && threadIdValue.ValueKind == JsonValueKind.String
                        && readParams.TryGetProperty("includeTurns", out var includeTurns)
                        && includeTurns.ValueKind == JsonValueKind.True)
                    {
                        threadId = threadIdValue.GetString();
                    }
                    if (threadId is not ("child-a" or "grandchild-a" or "current-root" or "paged-child"))
                    {
                        Write(output, new
                        {
                            id = idElement.Clone(),
                            error = new { code = -32602, message = "Expected known child thread." }
                        });
                        break;
                    }
                    if (threadId == "child-a" && ++childReadAttempts == 1)
                    {
                        Write(output, new
                        {
                            id = idElement.Clone(),
                            error = new { code = -32000, message = "Retry child read." }
                        });
                        break;
                    }
                    object[] items = threadId switch
                    {
                        "child-a" =>
                        [
                            new
                            {
                                id = "message-1",
                                type = "agentMessage",
                                text = "実装を進めています"
                            }
                        ],
                        "paged-child" =>
                        [
                            new
                            {
                                id = "message-page",
                                type = "agentMessage",
                                text = "2ページ目を取得しました"
                            }
                        ],
                        "current-root" => [],
                        _ =>
                        [
                            new
                            {
                                id = "message-2",
                                type = "userMessage",
                                content = new[]
                                {
                                    new { type = "text", text = "検証が完了しました" }
                                }
                            }
                        ]
                    };
                    Write(output, new
                    {
                        id = idElement.Clone(),
                        result = new
                        {
                            thread = new
                            {
                                id = threadId,
                                sessionId = threadId == "grandchild-a"
                                    ? "session-b"
                                    : "session-a",
                                parentThreadId = threadId == "grandchild-a"
                                    ? "child-a"
                                    : "root-thread",
                                turns = new[]
                                {
                                    new
                                    {
                                        id = "turn-1",
                                        status = "completed",
                                        items
                                    }
                                }
                            }
                        }
                    });
                    break;
                }
                case "thread/realtime/start":
                    if (!HasRealtimeStartV3Contract(message))
                    {
                        Write(output, new
                        {
                            id = idElement.Clone(),
                            error = new
                            {
                                code = -32602,
                                message = "Expected realtime version v3 with includeStartupContext=false."
                            }
                        });
                        break;
                    }
                    realtimeStartAttempts++;
                    if (failFirstWebRtc && realtimeStartAttempts == 1)
                    {
                        Write(output, new
                        {
                            id = idElement.Clone(),
                            error = new { code = -32000, message = "Injected WebRTC failure." }
                        });
                        break;
                    }
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
                            threadId = failFirstWebRtc
                                ? $"root-thread-{threadStartAttempts}"
                                : "root-thread",
                            realtimeSessionId = "fake-realtime",
                            version = "v3"
                        }
                    });
                    Write(output, new
                    {
                        method = "thread/realtime/sdp",
                        @params = new
                        {
                            threadId = failFirstWebRtc
                                ? $"root-thread-{threadStartAttempts}"
                                : "root-thread",
                            sdp = "v=0\r\ns=fake-answer\r\n"
                        }
                    });
                    break;
                case "thread/realtime/stop":
                    var stoppedThreadId = message.GetProperty("params").GetProperty("threadId").GetString();
                    Write(output, new
                    {
                        method = "thread/realtime/closed",
                        @params = new
                        {
                            threadId = stoppedThreadId,
                            reason = "client_requested"
                        }
                    });
                    Write(output, new
                    {
                        id = idElement.Clone(),
                        result = new { }
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
                case "fake/emitErrorServerRequest":
                    Write(output, new
                    {
                        id = 901,
                        method = "fake/reject",
                        @params = new { action = "reject" }
                    });
                    Write(output, new
                    {
                        id = idElement.Clone(),
                        result = new { emitted = true }
                    });
                    break;
                case "fake/checkServerErrorReply":
                    Write(output, new
                    {
                        id = idElement.Clone(),
                        result = new { received = serverErrorReplyReceived }
                    });
                    break;
                case "fake/emitServerRequestBurst":
                    for (var requestId = 1000; requestId <= 1008; requestId++)
                    {
                        Write(output, new
                        {
                            id = requestId,
                            method = "fake/slow",
                            @params = new { requestId }
                        });
                    }
                    Write(output, new
                    {
                        id = idElement.Clone(),
                        result = new { emitted = true }
                    });
                    break;
                case "fake/checkServerOverloadReply":
                    Write(output, new
                    {
                        id = idElement.Clone(),
                        result = new { received = serverOverloadReplyReceived }
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
                case "fake/emitOversized":
                    output.WriteLine(new string('x', 1_048_577));
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

    private static bool HasEmptyObjectParams(JsonElement message)
    {
        return message.TryGetProperty("params", out var parameters)
            && parameters.ValueKind == JsonValueKind.Object
            && !parameters.EnumerateObject().Any();
    }

    private static bool HasRefreshTokenFalse(JsonElement message)
    {
        return message.TryGetProperty("params", out var parameters)
            && parameters.ValueKind == JsonValueKind.Object
            && parameters.TryGetProperty("refreshToken", out var refreshToken)
            && refreshToken.ValueKind == JsonValueKind.False
            && parameters.EnumerateObject().Count() == 1;
    }

    private static bool HasRealtimeStartV3Contract(JsonElement message)
    {
        return message.TryGetProperty("params", out var parameters)
            && parameters.ValueKind == JsonValueKind.Object
            && parameters.TryGetProperty("version", out var version)
            && version.ValueKind == JsonValueKind.String
            && string.Equals(version.GetString(), "v3", StringComparison.Ordinal)
            && parameters.TryGetProperty("includeStartupContext", out var includeStartupContext)
            && includeStartupContext.ValueKind == JsonValueKind.False;
    }

    private static void Write(StreamWriter output, object value)
    {
        output.WriteLine(JsonSerializer.Serialize(value));
    }
}
