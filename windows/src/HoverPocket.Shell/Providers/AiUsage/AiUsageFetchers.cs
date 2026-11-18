using System.Text.Json;
using System.Text.RegularExpressions;
using HoverPocket.Shell.Voice;

namespace HoverPocket.Shell.Providers.AiUsage;

/// <summary>Reads Codex limits through the HoverPocket chat profile, which holds the chat's ChatGPT sign-in.</summary>
internal static class AiUsageCodexReader
{
    public static async Task<AiUsageResult> ReadAsync(string profileRoot, CancellationToken cancellationToken)
    {
        var identity = CodexExecutableResolver.Resolve();
        if (identity is null) return AiUsageResult.Failure(AiUsageErrorCodes.CodexMissing);
        try
        {
            var profile = CodexVoiceProfile.Prepare(profileRoot);
            using var executableLease = identity.OpenValidated();
            await using var client = await CodexAppServerClient.StartProcessAsync(identity.Path, ["app-server", "--stdio"],
                TimeSpan.FromSeconds(20), cancellationToken, profile.Environment, profile.Root);
            client.StartReading();
            await client.InitializeAsync(JsonSerializer.SerializeToElement(new
            {
                clientInfo = new { name = "hoverpocket_usage", version = "1" },
                capabilities = new { experimentalApi = true }
            }), cancellationToken);
            var account = await client.SendRequestAsync("account/read",
                JsonSerializer.SerializeToElement(new { refreshToken = false }), cancellationToken);
            if (!AiUsageParsers.IsCodexSignedIn(account)) return AiUsageResult.SignedOut();
            var limits = await client.SendRequestAsync("account/rateLimits/read",
                JsonSerializer.SerializeToElement(new { excludeResetCreditDetails = true }), cancellationToken);
            return AiUsageResult.Success(AiUsageParsers.ParseCodex(limits, account));
        }
        catch (AiUsageParseException)
        {
            return AiUsageResult.Failure(AiUsageErrorCodes.Changed);
        }
        catch (CodexAppServerProtocolException exception) when (exception.Code == "request_timeout")
        {
            return AiUsageResult.Failure(AiUsageErrorCodes.Timeout);
        }
        catch (CodexAppServerProtocolException)
        {
            return AiUsageResult.Failure(AiUsageErrorCodes.Unavailable);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException
            or System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            return AiUsageResult.Failure(AiUsageErrorCodes.Unavailable);
        }
    }
}

/// <summary>
/// Reads Claude, Gemini and Muse usage inside each site's origin through <see cref="AiUsageWebSession"/>.
/// Only fixed paths are requested and every response is parsed in C#; nothing from these pages
/// reaches the HoverPocket bridge except the normalized windows.
/// A service is "signed out" only when it says so explicitly (401/403 with a JSON error, or Gemini's
/// null viewer). Challenge pages, redirects and other surprises are errors that keep the last reading.
/// </summary>
internal sealed partial class AiUsageWebReader
{
    private static readonly TimeSpan NavigationTimeout = TimeSpan.FromSeconds(25);
    private static readonly TimeSpan FetchTimeout = TimeSpan.FromSeconds(25);
    private static readonly TimeSpan DiscoveryTimeout = TimeSpan.FromSeconds(60);
    private const int MaxBodyChars = 1_048_576;

    private string? _museActionId;

    public static Uri SignInUri(string service) => service switch
    {
        AiUsageServiceIds.Claude => new Uri("https://claude.ai/login"),
        // Straight to the Google account chooser; it returns to the usage page after sign-in.
        AiUsageServiceIds.Gemini => new Uri("https://accounts.google.com/ServiceLogin?continue=https%3A%2F%2Fgemini.google.com%2Fusage"),
        AiUsageServiceIds.Muse => new Uri("https://muse.ai/"),
        _ => throw new ArgumentOutOfRangeException(nameof(service))
    };

    /// <summary>Hosts a sign-in normally passes through; any other host is shown with a warning, not blocked.</summary>
    public static bool IsExpectedSignInHost(string service, string host)
    {
        host = host.ToLowerInvariant();
        static bool Under(string host, string domain) => host == domain || host.EndsWith("." + domain, StringComparison.Ordinal);
        if (host is "accounts.google.com" or "appleid.apple.com" or "login.microsoftonline.com" or "login.live.com") return true;
        return service switch
        {
            AiUsageServiceIds.Claude => Under(host, "claude.ai") || Under(host, "anthropic.com") || Under(host, "claude.com"),
            AiUsageServiceIds.Gemini => Under(host, "google.com") || Under(host, "gemini.google.com"),
            AiUsageServiceIds.Muse => Under(host, "muse.ai"),
            _ => false
        };
    }

    public async Task<AiUsageResult> ReadAsync(AiUsageWebSession session, string service, CancellationToken cancellationToken)
    {
        try
        {
            return service switch
            {
                AiUsageServiceIds.Claude => await ReadClaudeAsync(session, cancellationToken),
                AiUsageServiceIds.Gemini => await ReadGeminiAsync(session, cancellationToken),
                AiUsageServiceIds.Muse => await ReadMuseAsync(session, cancellationToken),
                _ => AiUsageResult.Failure(AiUsageErrorCodes.Unavailable)
            };
        }
        catch (AiUsageParseException)
        {
            return AiUsageResult.Failure(AiUsageErrorCodes.Changed);
        }
        catch (AiUsageFetchException exception)
        {
            return AiUsageResult.Failure(exception.Code);
        }
        catch (TimeoutException)
        {
            return AiUsageResult.Failure(AiUsageErrorCodes.Timeout);
        }
        catch (JsonException)
        {
            return AiUsageResult.Failure(AiUsageErrorCodes.Changed);
        }
        catch (System.Runtime.InteropServices.COMException)
        {
            return AiUsageResult.Failure(AiUsageErrorCodes.Network);
        }
    }

    private static async Task<AiUsageResult> ReadClaudeAsync(AiUsageWebSession session, CancellationToken cancellationToken)
    {
        await session.NavigateAsync(new Uri("https://claude.ai/robots.txt"), NavigationTimeout, cancellationToken);
        var organizations = await GetJsonAsync(session, "/api/organizations", cancellationToken);
        if (Classify(organizations) is { } early) return early;
        (string Id, string? Plan)? selected;
        using (var document = JsonDocument.Parse(organizations.Body))
            selected = AiUsageParsers.SelectClaudeOrganization(document.RootElement);
        if (selected is not { } organization) return AiUsageResult.Failure(AiUsageErrorCodes.Unavailable);

        var usage = await GetJsonAsync(session, $"/api/organizations/{organization.Id}/usage", cancellationToken);
        if (Classify(usage) is { } late) return late;
        using var usageDocument = JsonDocument.Parse(usage.Body);
        return AiUsageResult.Success(AiUsageParsers.ParseClaude(usageDocument.RootElement, organization.Plan));
    }

    /// <summary>
    /// Returns the result for any response that is not a complete, non-HTML 200, or <c>null</c> to go on
    /// parsing. Only a JSON error object on 401/403 means signed out (claude.ai answers
    /// <c>{"type":"error","error":{...}}</c>, muse.ai <c>{"error":"Authentication required"}</c>); HTML,
    /// plain text, redirects and cut-off bodies say nothing about the session and become errors that keep
    /// the last reading.
    /// </summary>
    internal static AiUsageResult? Classify(AiUsageFetchResponse response)
    {
        if (response.Truncated) return AiUsageResult.Failure(AiUsageErrorCodes.Changed);
        if (response.Type == "opaqueredirect") return AiUsageResult.Failure(AiUsageErrorCodes.Blocked);
        if (response.Status is 401 or 403)
            return IsJsonError(response.Body) ? AiUsageResult.SignedOut() : AiUsageResult.Failure(AiUsageErrorCodes.Blocked);
        if (response.Status == 429 || response.Status >= 500) return AiUsageResult.Failure(AiUsageErrorCodes.Unavailable);
        if (response.Status != 200) return AiUsageResult.Failure(AiUsageErrorCodes.Unavailable);
        if (response.Body.TrimStart().StartsWith('<')) return AiUsageResult.Failure(AiUsageErrorCodes.Blocked);
        return null;
    }

    private static bool IsJsonError(string body)
    {
        try
        {
            using var document = JsonDocument.Parse(body);
            return document.RootElement.ValueKind == JsonValueKind.Object
                && document.RootElement.TryGetProperty("error", out var error)
                && error.ValueKind is JsonValueKind.Object or JsonValueKind.String;
        }
        catch (JsonException)
        {
            return false;
        }
    }

    private static async Task<AiUsageResult> ReadGeminiAsync(AiUsageWebSession session, CancellationToken cancellationToken)
    {
        await session.NavigateAsync(new Uri("https://gemini.google.com/robots.txt"), NavigationTimeout, cancellationToken);
        // UsagePageQuery of the Gemini app's usage page, as identified by CodexBar's gemini-web provider.
        const string signature = "2/dWbCvkVB0X16r9NPnxifeOAAqdCqMf0xeWvau9yPy7g=";
        var variables = JsonSerializer.Serialize(new
        {
            g1Request = new { entrypoints = new[] { "GEMINI_USAGE_SETTINGS_UPGRADE_BANNER" } },
            workspaceRequest = new { recommendationsForSurfaceRequests = Array.Empty<object>() }
        });
        var path = "/_/BardChatUi/graphql/schemas/GEMINI_WEB_GRAPHQL/executeQuery?query_signature="
            + Uri.EscapeDataString(signature) + "&variables=" + Uri.EscapeDataString(variables);
        var response = await GetJsonAsync(session, path, cancellationToken);
        if (Classify(response) is { } early) return early;
        if (response.Body.TrimStart().StartsWith('<')) return AiUsageResult.Failure(AiUsageErrorCodes.Blocked);
        // Signed out, Google answers 200 with `"viewer": null` (checked 2026-11-18).
        return AiUsageParsers.ParseGemini(response.Body) is { } reading
            ? AiUsageResult.Success(reading)
            : AiUsageResult.SignedOut();
    }

    private async Task<AiUsageResult> ReadMuseAsync(AiUsageWebSession session, CancellationToken cancellationToken)
    {
        await session.NavigateAsync(new Uri("https://muse.ai/robots.txt"), NavigationTimeout, cancellationToken);
        // Signed out, muse.ai serves a public landing page at "/" but answers 401
        // {"error":"Authentication required"} for /settings (checked 2026-11-18).
        var gate = await session.FetchAsync("/settings", "GET", new Dictionary<string, string> { ["Accept"] = "text/html" },
            null, "manual", 4096, FetchTimeout, cancellationToken);
        if (gate.Status != 200 && Classify(gate) is { } gateResult) return gateResult;
        if (_museActionId is { } cached)
        {
            var response = await PostMuseAsync(session, cached, cancellationToken);
            if (response.Status is not (400 or 404 or 409)) return MuseResult(response);
            _museActionId = null;
        }

        // muse.ai has no usage API. The settings dialog calls a Next.js server action whose ID changes
        // on every deploy, so it is rediscovered from the page's script chunks.
        var discovered = await session.EvaluateAsync(MuseDiscoveryExpression, DiscoveryTimeout, cancellationToken);
        using (var document = JsonDocument.Parse(discovered))
        {
            var root = document.RootElement;
            if (root.TryGetProperty("signedOut", out var signedOut) && signedOut.ValueKind == JsonValueKind.True)
                return AiUsageResult.SignedOut();
            if (!root.TryGetProperty("id", out var id) || id.ValueKind != JsonValueKind.String
                || id.GetString() is not { } actionId || !MuseActionIdPattern().IsMatch(actionId))
                return AiUsageResult.Failure(root.TryGetProperty("error", out var error) && error.ValueKind == JsonValueKind.String
                    && error.GetString() is AiUsageErrorCodes.Network or AiUsageErrorCodes.Blocked
                    ? error.GetString()!
                    : AiUsageErrorCodes.Changed);
            _museActionId = actionId;
        }

        var fresh = await PostMuseAsync(session, _museActionId, cancellationToken);
        if (fresh.Status is 400 or 404 or 409)
        {
            _museActionId = null;
            return AiUsageResult.Failure(AiUsageErrorCodes.Changed);
        }
        return MuseResult(fresh);
    }

    private static AiUsageResult MuseResult(AiUsageFetchResponse response) =>
        Classify(response) ?? AiUsageResult.Success(AiUsageParsers.ParseMuse(response.Body));

    private static Task<AiUsageFetchResponse> PostMuseAsync(AiUsageWebSession session, string actionId, CancellationToken cancellationToken) =>
        session.FetchAsync("/", "POST", new Dictionary<string, string>
        {
            ["Accept"] = "text/x-component",
            ["Next-Action"] = actionId,
            ["Content-Type"] = "text/plain;charset=UTF-8"
        }, "[{\"includeAgreement\":true}]", "manual", MaxBodyChars, FetchTimeout, cancellationToken);

    private static Task<AiUsageFetchResponse> GetJsonAsync(AiUsageWebSession session, string path, CancellationToken cancellationToken) =>
        session.FetchAsync(path, "GET", new Dictionary<string, string> { ["Accept"] = "application/json" },
            null, "manual", MaxBodyChars, FetchTimeout, cancellationToken);

    // Adapted from CodexBar's museai provider (MIT, github.com/steipete/CodexBar). The app chunk preloads
    // settings through `e.A(<module>).then(({preload…Settings…` and the loader lists that module's files,
    // one of which holds `createServerReference("<id>", …, "fetchSubscriptionAction")`.
    // Since 2026-11 the chunks live under `static/immutable/chunks/` (108 page chunks on 2026-11-18).
    // Every request stays on muse.ai. The page HTML is read up to 4M characters, and all script chunks
    // together, settings chunks included, up to 16M characters: each batch of four splits what is left.
    internal static string MuseDiscoveryExpression =>
        MuseDiscoveryScript.Replace("/*READ_CAPPED*/", AiUsageWebSession.ReadCappedScript, StringComparison.Ordinal);

    private const string MuseDiscoveryScript = """
        (async () => {
          /*READ_CAPPED*/
          if (location.origin !== "https://muse.ai") return JSON.stringify({ error: "network" });
          const chunkPaths = (text) => [...new Set((text.match(/static\/(?:immutable\/)?chunks\/[\w~.-]+\.js/g) ?? []).map((p) => `/_next/${p}`))];
          let budget = 16 * 1024 * 1024;
          const fetchChunks = async (paths) => {
            const cap = Math.min(4 * 1024 * 1024, Math.floor(budget / Math.max(1, paths.length)));
            if (cap < 1024) { budget = 0; return []; }
            const bodies = await Promise.all(paths.map((p) =>
              fetch(p, { credentials: "omit", mode: "same-origin" })
                .then((r) => (r.ok ? readCapped(r, cap) : { text: "", truncated: false }))
                .catch(() => ({ text: "", truncated: false }))));
            budget -= bodies.reduce((sum, b) => sum + b.text.length, 0);
            return bodies.map((b) => (b.truncated ? "" : b.text));
          };
          let page;
          try { page = await fetch("/", { credentials: "include", mode: "same-origin", redirect: "manual", headers: { Accept: "text/html" } }); }
          catch { return JSON.stringify({ error: "network" }); }
          if (page.type === "opaqueredirect") return JSON.stringify({ error: "blocked" });
          if (page.status === 401 || page.status === 403) {
            const answer = await readCapped(page, 4096);
            try {
              const json = JSON.parse(answer.text);
              if (json && typeof json === "object" && "error" in json) return JSON.stringify({ signedOut: true });
            } catch { }
            return JSON.stringify({ error: "blocked" });
          }
          if (page.status !== 200) return JSON.stringify({ error: "network" });
          const html = await readCapped(page, 4 * 1024 * 1024);
          if (html.truncated) return JSON.stringify({ error: "changed" });
          const paths = chunkPaths(html.text).slice(0, 160);
          let text = "";
          for (let i = 0; i < paths.length && budget > 0; i += 4) {
            text += "\n" + (await fetchChunks(paths.slice(i, i + 4))).join("\n");
            const module = /\.A\((\d+)\)\.then\(\(\{[^}]*Settings/.exec(text)?.[1];
            const loader = module && new RegExp(`[,{\\[]${module},\\w+=>\\{\\w+\\.v\\(\\w+=>Promise\\.all\\(\\[([^\\]]*)`).exec(text);
            if (!loader) continue;
            const settingsPaths = chunkPaths(loader[1]).slice(0, 32);
            for (let j = 0; j < settingsPaths.length && budget > 0; j += 4) {
              for (const body of await fetchChunks(settingsPaths.slice(j, j + 4))) {
                const id = /"([0-9a-f]{40,})",[^"]{0,200}"fetchSubscriptionAction"/.exec(body)?.[1];
                if (id) return JSON.stringify({ id });
              }
            }
            break;
          }
          return JSON.stringify({ error: "changed" });
        })()
        """;

    [GeneratedRegex("^[0-9a-f]{40,128}$")]
    private static partial Regex MuseActionIdPattern();
}
