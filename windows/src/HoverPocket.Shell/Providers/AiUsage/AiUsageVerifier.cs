using System.Text.Json;
using System.Text.Json.Nodes;
using System.Windows;
using HoverPocket.Shell.Bridge;
using HoverPocket.Shell.Configuration;
using HoverPocket.Shell.Settings;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;

namespace HoverPocket.Shell.Providers.AiUsage;

/// <summary>
/// <c>--verify ai-usage</c>: parsers against recorded response shapes, snapshot rules, refresh
/// caching, settings persistence, the bridge contract, and the panel and Settings UI rendered in
/// real WebViews with fixed fake readings. No network access.
/// <c>--verify ai-usage-live</c>: reads the real services once with the live profile (Debug aid).
/// </summary>
internal sealed class AiUsageVerifier
{
    private readonly List<string> _failures = [];
    private int _checks;

    private void Check(bool condition, string label)
    {
        _checks++;
        if (!condition) _failures.Add(label);
    }

    public async Task<int> RunAsync(Action<string> log)
    {
        try
        {
            VerifyParsers();
            VerifySnapshots();
            await VerifyServiceAsync();
            await VerifyAntigravityReaderAsync();
            await VerifyInPageFetchAsync();
            VerifySettings();
            await VerifyBridgeAndUiAsync(log);
        }
        catch (Exception exception)
        {
            _failures.Add($"unexpected {exception.GetType().Name}: {exception.Message}");
        }
        if (_failures.Count == 0)
        {
            log($"PASS ai-usage verify: {_checks} checks (parsers, stale/sign-out rules, refresh cache, settings, bridge, panel and Settings UI)");
            return 0;
        }
        log("FAIL ai-usage verify:");
        foreach (var failure in _failures) log($"- {failure}");
        return 1;
    }

    private void VerifyParsers()
    {
        // Shape of claude.ai/api/organizations/{id}/usage on 2026-11-18 (values kept, identifiers removed).
        using (var claude = JsonDocument.Parse("""
            {"five_hour":{"utilization":32,"resets_at":"2026-11-18T02:00:00.126177+00:00"},
             "seven_day":{"utilization":30,"resets_at":"2026-11-23T02:00:00.126198+00:00"},
             "seven_day_opus":null,"extra_usage":{"is_enabled":false,"utilization":0},
             "limits":[
              {"kind":"session","group":"session","percent":32,"severity":"normal","resets_at":"2026-11-18T02:00:00.126177+00:00","scope":null},
              {"kind":"weekly_all","group":"weekly","percent":30,"resets_at":"2026-11-23T02:00:00.126198+00:00","scope":null},
              {"kind":"weekly_scoped","group":"weekly","percent":35,"resets_at":"2026-11-23T02:00:00.126361+00:00",
               "scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":true}]}
            """))
        {
            var reading = AiUsageParsers.ParseClaude(claude.RootElement, "Max 5x");
            Check(reading.Windows.Count == 3, "claude: three windows from limits[]");
            Check(reading.Windows[0] is { Kind: "session", Model: null, UsedPercent: 32, WindowMinutes: 300 }, "claude: five-hour session");
            Check(reading.Windows[1] is { Kind: "weekly", Model: null, UsedPercent: 30 }, "claude: all-model weekly");
            Check(reading.Windows[2] is { Kind: "weekly", Model: "Fable", UsedPercent: 35 }, "claude: Fable weekly kept separate");
            Check(reading.Windows[0].ResetsAt == DateTimeOffset.Parse("2026-11-18T02:00:00.126177+00:00"), "claude: reset instant");
            Check(reading.Plan == "Max 5x", "claude: plan passed through");
        }
        using (var legacy = JsonDocument.Parse("""{"five_hour":{"utilization":12.5,"resets_at":"2026-11-18T02:00:00Z"},"seven_day":{"utilization":140,"resets_at":null},"seven_day_opus":{"utilization":5}}"""))
        {
            var reading = AiUsageParsers.ParseClaude(legacy.RootElement, null);
            Check(reading.Windows.Count == 3 && reading.Windows[2].Model == "Opus", "claude: legacy objects when limits[] is missing");
            Check(reading.Windows[1].UsedPercent == 100 && reading.Windows[1].ResetsAt is null, "claude: over-limit clamps to 100, missing reset stays unknown");
        }
        ExpectParseFailure(() => { using var empty = JsonDocument.Parse("""{"limits":[],"five_hour":null}"""); AiUsageParsers.ParseClaude(empty.RootElement, null); }, "claude: no windows is a parse failure, not 0%");

        using (var organizations = JsonDocument.Parse("""
            [{"uuid":"00000000-0000-4000-8000-000000000001","capabilities":["api"],"rate_limit_tier":"auto_trust_tier_b"},
             {"uuid":"00000000-0000-4000-8000-000000000002","capabilities":["chat","claude_max"],"rate_limit_tier":"default_claude_max_5x"}]
            """))
        {
            var selected = AiUsageParsers.SelectClaudeOrganization(organizations.RootElement);
            Check(selected is { Id: "00000000-0000-4000-8000-000000000002", Plan: "Max 5x" }, "claude: chat organization and Max 5x plan");
        }
        using (var injected = JsonDocument.Parse("""[{"uuid":"../../x","capabilities":["chat"]}]"""))
            Check(AiUsageParsers.SelectClaudeOrganization(injected.RootElement) is null, "claude: organization id must be a UUID before it enters a path");

        // Shape of the Gemini app usage query on 2026-11-18.
        const string gemini = """
            [{"data":{"viewer":{"rpcs":{"getUsageInfo":{"subscriptionTier":"TIER1","pools":[
              {"poolType":"GXU_WEEKLY","percentageUsed":0.25,"gxu":{"windowRefreshesAt":"2026-11-23T05:45:14.306471Z"}},
              {"poolType":"GXU_FIVE_HOURLY","percentageUsed":0.0,"gxu":{"windowRefreshesAt":"2026-11-18T02:45:14.306349Z"}}]}}}}}]
            """;
        var geminiReading = AiUsageParsers.ParseGemini(gemini);
        Check(geminiReading is { Plan: "Pro", Windows.Count: 2 }, "gemini: two pools and plan");
        Check(geminiReading?.Windows[0] is { Kind: "session", UsedPercent: 0 } && geminiReading.Windows[1] is { Kind: "weekly", UsedPercent: 25 },
            "gemini: five-hour first, fraction converted to percent");
        Check(AiUsageParsers.ParseGemini(")]}'\n" + gemini) is { Windows.Count: 2 }, "gemini: XSSI prefix accepted");
        Check(AiUsageParsers.ParseGemini("""[{"data":{"viewer":null}}]""") is null, "gemini: null viewer is signed out");
        ExpectParseFailure(() => AiUsageParsers.ParseGemini("<!doctype html><html></html>"), "gemini: an HTML page is not read as signed out");
        Check(AiUsageParsers.ParseGemini("""[{"data":{"viewer":null},"errors":[{"message":"Internal error encountered."}]}]""") is null,
            "gemini: the signed-out answer seen on 2026-11-18 (viewer null) is signed out");
        ExpectParseFailure(() => AiUsageParsers.ParseGemini("""[{"data":{"viewer":{"rpcs":{"getUsageInfo":{"pools":[{"poolType":"GXU_WEEKLY","percentageUsed":-0.5}]}}}}}]"""),
            "gemini: a negative value is a format change, not 0%");
        ExpectParseFailure(() => AiUsageParsers.ParseGemini("""[{"data":{"viewer":{"rpcs":{}}}}]"""), "gemini: missing pools is a parse failure");

        VerifyAntigravityParser();

        const string muse = "0:{\"a\":\"$@1\",\"f\":\"\",\"b\":\"x\"}\n1:{\"success\":true,\"subscription\":{\"usage\":{\"percentUsed\":9,\"resetsAt\":1763856000},\"tier\":{\"name\":\"Plus\"},\"usageRowValueLabel\":\"9% used\"}}\n";
        var museReading = AiUsageParsers.ParseMuse(muse);
        Check(museReading is { Plan: "Plus", Windows.Count: 1 } && museReading.Windows[0] is { Kind: "weekly", UsedPercent: 9 }
            && museReading.Windows[0].ResetsAt == DateTimeOffset.FromUnixTimeSeconds(1763856000), "muse: weekly percentage, reset, plan");
        ExpectParseFailure(() => AiUsageParsers.ParseMuse("0:{\"success\":false}\n"), "muse: unsuccessful action is a parse failure");

        // account/rateLimits/read from the Codex app-server (schema generated from codex-cli 0.169.0).
        using (var codex = JsonDocument.Parse("""
            {"rateLimits":{"limitId":"codex","primary":{"usedPercent":12,"windowDurationMins":300,"resetsAt":1763434800},"secondary":{"usedPercent":47,"windowDurationMins":10080,"resetsAt":1763856000},"planType":"pro"},
             "rateLimitsByLimitId":{
               "codex_spark":{"limitId":"codex_spark","limitName":"GPT-5.3-Codex-Spark","primary":{"usedPercent":3,"windowDurationMins":300,"resetsAt":1763434800},"secondary":null,"planType":"pro"},
               "codex":{"limitId":"codex","primary":{"usedPercent":12,"windowDurationMins":300,"resetsAt":1763434800},"secondary":{"usedPercent":47,"windowDurationMins":10080,"resetsAt":1763856000},"planType":"pro"}}}
            """))
        using (var account = JsonDocument.Parse("""{"account":{"type":"chatgpt","email":null,"planType":"pro"},"requiresOpenaiAuth":true}"""))
        {
            Check(AiUsageParsers.IsCodexSignedIn(account.RootElement), "codex: ChatGPT account is signed in");
            var reading = AiUsageParsers.ParseCodex(codex.RootElement, account.RootElement);
            Check(reading.Plan == "Pro" && reading.Windows.Count == 3, "codex: plan and three windows");
            Check(reading.Windows[0] is { Kind: "session", Model: null, UsedPercent: 12 } && reading.Windows[1] is { Kind: "weekly", UsedPercent: 47 },
                "codex: ordinary bucket first, labelled by duration");
            Check(reading.Windows[2] is { Kind: "session", Model: "GPT-5.3-Codex-Spark", UsedPercent: 3 }, "codex: model bucket keeps its name");
            Check(reading.Windows[0].ResetsAt == DateTimeOffset.FromUnixTimeSeconds(1763434800), "codex: unix reset");
        }
        // Shape of the live response on 2026-11-18 (balances are made-up values): the only window is
        // weekly and arrives as `primary`; credits sit in the ordinary `rateLimits` view.
        using (var weeklyOnly = JsonDocument.Parse("""
            {"ordinaryUsageAllowed":true,
             "rateLimits":{"limitId":"codex","limitName":null,"primary":{"usedPercent":8,"windowDurationMins":10080,"resetsAt":1795487156},"secondary":null,"planType":"prolite","credits":{"hasCredits":true,"unlimited":false,"balance":"12345.6789"}},
             "rateLimitsByLimitId":{"codex":{"limitId":"codex","limitName":null,"primary":{"usedPercent":8,"windowDurationMins":10080,"resetsAt":1795487156},"secondary":null,"planType":"prolite"}},
             "rateLimitResetCredits":{"availableCount":3,"credits":null},"rateLimitUpsell":null}
            """))
        {
            var reading = AiUsageParsers.ParseCodex(weeklyOnly.RootElement, null);
            Check(reading.Plan == "Pro Lite" && reading.Windows.Count == 1 && reading.Windows[0] is { Kind: "weekly", UsedPercent: 8, WindowMinutes: 10080 },
                "codex: a weekly primary window is labelled weekly, not by position");
            Check(reading.BalanceList is [{ Kind: "codexCredits", Unit: "credits", Amount: 12345.6789m, State: null }],
                "codex: credits read from the ordinary view at full precision, as a credit count");
        }
        string CodexWith(string credits) => "{\"rateLimits\":{\"primary\":{\"usedPercent\":5,\"windowDurationMins\":10080},\"credits\":" + credits + "}}";
        AiUsageReading CodexCreditsCase(string credits) { using var document = JsonDocument.Parse(CodexWith(credits)); return AiUsageParsers.ParseCodex(document.RootElement, null); }
        Check(CodexCreditsCase("""{"hasCredits":true,"unlimited":false,"balance":42.5}""").BalanceList is [{ Amount: 42.5m, State: null }], "codex: a numeric balance is accepted");
        var oddCredits = CodexCreditsCase("""{"hasCredits":true,"unlimited":false,"balance":"lots"}""");
        Check(oddCredits.Windows.Count == 1 && oddCredits.BalanceList is [{ State: "unreadable" }], "codex: an unreadable balance shows as unreadable and keeps the usage windows");
        Check(CodexCreditsCase("""{"hasCredits":true,"unlimited":true,"balance":null}""").BalanceList is [{ State: "unlimited" }], "codex: unlimited credits are shown as unlimited");
        Check(CodexCreditsCase("""{"hasCredits":false,"unlimited":false,"balance":null}""").BalanceList.Count == 0, "codex: no balance provided adds no row");

        // platform.claude.com prepaid/credits, 2026-11-18 shape (made-up purchased amounts, identifiers removed).
        using (var console = JsonDocument.Parse("""
            {"amount":11234,"currency":"USD","balance":{"money":null,"credits":{"amount_minor":11234,"exponent":2}},
             "tranches":[
               {"remaining_amount_minor_units":734,"currency":"USD","expires_at":"2026-12-14T00:00:00Z","remaining":{"money":null,"credits":{"amount_minor":734,"exponent":2}},"program_id":"api_credits","name":null},
               {"remaining_amount_minor_units":500,"currency":"USD","expires_at":"2027-03-01T00:00:00Z","remaining":{"money":null,"credits":{"amount_minor":500,"exponent":2}},"program_id":"api_credits","name":null}],
             "promo_tranches":[{"remaining_amount_minor_units":10000,"currency":"USD","expires_at":"2026-12-12T00:00:00Z","remaining":{"money":null,"credits":{"amount_minor":10000,"exponent":2}},"program_id":"subscription_api_credit","name":"API credit (Max)"}],
             "next_expires_at":"2026-12-12T00:00:00Z"}
            """))
        {
            var balances = AiUsageParsers.ParseClaudeConsoleCredits(console.RootElement).BalanceList;
            Check(balances.Count == 3 && balances[0] is { Kind: "planCredit", Label: "API credit (Max)", Amount: 100.00m, Unit: "usd" }
                && balances[0].ExpiresAt == DateTimeOffset.Parse("2026-12-12T00:00:00Z")
                && balances[1] is { Kind: "purchasedCredit", Amount: 7.34m } && balances[1].ExpiresAt == DateTimeOffset.Parse("2026-12-14T00:00:00Z")
                && balances[2] is { Kind: "purchasedCredit", Amount: 5.00m } && balances[2].ExpiresAt == DateTimeOffset.Parse("2027-03-01T00:00:00Z"),
                "claude api: plan grant apart from purchases, purchases one row per expiry, from minor units");
        }
        using (var empty = JsonDocument.Parse("""{"balance":{"money":null,"credits":{"amount_minor":0,"exponent":2}},"tranches":[],"promo_tranches":[]}"""))
            Check(AiUsageParsers.ParseClaudeConsoleCredits(empty.RootElement).BalanceList is [{ Amount: 0m }], "claude api: empty tranches with a zero total read as a real $0");
        void ConsoleFailure(string json, string label) =>
            ExpectParseFailure(() => { using var document = JsonDocument.Parse(json); AiUsageParsers.ParseClaudeConsoleCredits(document.RootElement); }, label);
        ConsoleFailure("""{"balance":{"credits":{"amount_minor":1500,"exponent":2}},"tranches":[],"promo_tranches":[]}""", "claude api: a positive total without a breakdown is not shown as purchased");
        ConsoleFailure("""{"promo_tranches":[{"remaining":{"credits":{"amount_minor":-5,"exponent":2}}}]}""", "claude api: a negative amount is a format change");
        ConsoleFailure("""{"currency":"USD"}""", "claude api: no balance is a format change, never $0");
        ConsoleFailure("""{"promo_tranches":[{"remaining":{"credits":{"amount_minor":100,"exponent":2}}},{"remaining":{}}]}""", "claude api: an unreadable tranche fails instead of a partial total");
        ConsoleFailure("""{"promo_tranches":[{"remaining":{"credits":{"amount_minor":100}}}]}""", "claude api: a missing exponent is a format change");
        ConsoleFailure("""{"promo_tranches":[{"remaining":{"credits":{"amount_minor":100,"exponent":"2"}}}]}""", "claude api: a non-integer exponent is a format change");
        ConsoleFailure("""{"currency":"EUR","promo_tranches":[{"remaining":{"credits":{"amount_minor":100,"exponent":2}}}]}""", "claude api: a non-USD currency is not shown in dollars");
        ConsoleFailure("""{"promo_tranches":[{"currency":"JPY","remaining":{"credits":{"amount_minor":100,"exponent":0}}}]}""", "claude api: a non-USD tranche is not shown in dollars");
        ConsoleFailure("""{"promo_tranches":{"x":1},"tranches":[{"currency":"USD","remaining":{"credits":{"amount_minor":100,"exponent":2}}}]}""", "claude api: a grant list of the wrong shape is not skipped");
        ConsoleFailure("""{"promo_tranches":[{"remaining":{"credits":{"amount_minor":"100","exponent":2}}}]}""", "claude api: a string amount is a format change");
        ConsoleFailure("""{"promo_tranches":[{"remaining":{"money":{"currency":"EUR","amount_minor":100,"exponent":2}}}]}""", "claude api: a non-USD amount object is not shown in dollars");
        try
        {
            using var stringAmount = JsonDocument.Parse("""{"promo_tranches":[{"remaining":{"credits":{"amount_minor":null,"exponent":2}}}]}""");
            AiUsageParsers.ParseClaudeConsoleCredits(stringAmount.RootElement);
            Check(false, "claude api: a null amount is a parse failure, not another exception");
        }
        catch (AiUsageParseException) { Check(true, "claude api: a null amount is a parse failure, not another exception"); }
        using (var consoleOrgs = JsonDocument.Parse("""
            [{"uuid":"00000000-0000-4000-8000-000000000002","capabilities":["chat","claude_max"]},
             {"uuid":"not-a-uuid","capabilities":["api"]},
             {"uuid":"00000000-0000-4000-8000-000000000001","capabilities":["api","customer_terms:standard"]}]
            """))
            Check(AiUsageParsers.SelectClaudeConsoleOrganization(consoleOrgs.RootElement) is ("00000000-0000-4000-8000-000000000001", false),
                "claude api: the one valid api organization is used, skipping invalid ones and the chat one");
        using (var twoOrgs = JsonDocument.Parse("""
            [{"uuid":"00000000-0000-4000-8000-000000000001","capabilities":["api"]},{"uuid":"00000000-0000-4000-8000-000000000003","capabilities":["api"]}]
            """))
            Check(AiUsageParsers.SelectClaudeConsoleOrganization(twoOrgs.RootElement) is (null, true), "claude api: several api organizations are ambiguous, not guessed");
        using (var sameOrg = JsonDocument.Parse("""
            [{"uuid":"0000000A-0000-4000-8000-000000000001","capabilities":["api"]},{"uuid":"0000000a-0000-4000-8000-000000000001","capabilities":["api"]}]
            """))
            Check(AiUsageParsers.SelectClaudeConsoleOrganization(sameOrg.RootElement) is ({ } _, false), "claude api: the same organization in two letter cases is one organization");
        Check(AiUsageWebReader.Classify(new(403, "basic", "", """{"type":"error","error":{"type":"permission_error"}}""", false)) is { Status: AiUsageStatus.SignedOut },
            "claude api: the organization list's 403 JSON is signed out (the credits call maps 403 to noAccess instead)");

        // colab.research.google.com/tun/m/ccu-info, 2026-11-18 shape (made-up values).
        var colab = AiUsageParsers.ParseColab("""{"currentBalance":87.6543,"consumptionRateHourly":0,"assignmentsCount":0,"eligibleGpus":[],"ineligibleGpus":[],"eligibleTpus":[]}""");
        Check(colab.BalanceList is [{ Kind: "computeUnits", Unit: "units", Amount: 87.6543m, PerHour: 0m }], "colab: compute units and hourly rate at full precision");
        Check(AiUsageParsers.ParseColab(")]}'\n{\"currentBalance\":0.04,\"consumptionRateHourly\":0.004}").BalanceList is [{ Amount: 0.04m, PerHour: 0.004m }],
            "colab: tiny positive values are kept, not rounded to zero (XSSI prefix accepted)");
        Check(AiUsageParsers.ParseColab("""{"currentBalance":3,"consumptionRateHourly":"fast"}""").BalanceList is [{ PerHour: null }], "colab: an odd rate is unknown, not zero");
        Check(AiUsageParsers.ParseColab("""{"currentBalance":1e-30,"consumptionRateHourly":1e-30}""").BalanceList is [{ Amount: > 0m, PerHour: > 0m }],
            "colab: values below decimal precision stay positive"); 
        ExpectParseFailure(() => AiUsageParsers.ParseColab("<!DOCTYPE html><title>Error 401 (Unauthorized)!!1</title>"), "colab: an HTML page is not a balance");
        ExpectParseFailure(() => AiUsageParsers.ParseColab("""{"currentBalance":-1}"""), "colab: a negative balance is a format change");
        using (var signedOut = JsonDocument.Parse("""{"account":null,"requiresOpenaiAuth":true}"""))
            Check(!AiUsageParsers.IsCodexSignedIn(signedOut.RootElement), "codex: missing account is signed out");
        ExpectParseFailure(() => { using var none = JsonDocument.Parse("""{"rateLimits":{"primary":null}}"""); AiUsageParsers.ParseCodex(none.RootElement, null); }, "codex: no windows is a parse failure");
        ExpectParseFailure(() => { using var odd = JsonDocument.Parse("""{"requiresOpenaiAuth":true}"""); AiUsageParsers.IsCodexSignedIn(odd.RootElement); },
            "codex: a missing account field is a format change, not signed out");
        ExpectParseFailure(() => { using var far = JsonDocument.Parse("""{"rateLimits":{"primary":{"usedPercent":5,"windowDurationMins":10080,"resetsAt":99999999999999}}}"""); AiUsageParsers.ParseCodex(far.RootElement, null); },
            "codex: an impossible reset time is a format change");
        ExpectParseFailure(() => AiUsageParsers.ParseMuse("1:{\"success\":true,\"subscription\":{\"usage\":{\"percentUsed\":-3,\"resetsAt\":1763856000}}}\n"),
            "muse: a negative percentage is a format change");

        // Explicit sign-out answers seen on 2026-11-18 versus pages that say nothing about the session.
        Check(AiUsageWebReader.Classify(new(403, "basic", "", """{"type":"error","error":{"type":"permission_error"}}""", false)) is { Status: AiUsageStatus.SignedOut },
            "web: claude.ai 403 JSON is signed out");
        Check(AiUsageWebReader.Classify(new(401, "basic", "", """{"error":"Authentication required"}""", false)) is { Status: AiUsageStatus.SignedOut },
            "web: muse.ai 401 JSON is signed out");
        Check(AiUsageWebReader.Classify(new(403, "basic", "", "<!DOCTYPE html><title>Just a moment</title>", false)) is { ErrorCode: AiUsageErrorCodes.Blocked },
            "web: an HTML 403 (bot check) is an error that keeps the last reading");
        Check(AiUsageWebReader.Classify(new(0, "opaqueredirect", "", "", false)) is { ErrorCode: AiUsageErrorCodes.Blocked }, "web: a redirect is not read as signed out");
        Check(AiUsageWebReader.Classify(new(200, "basic", "", "{", true)) is { ErrorCode: AiUsageErrorCodes.Changed }, "web: a body over the size cap is an error");
        Check(AiUsageWebReader.Classify(new(200, "basic", "", "{}", false)) is null, "web: a complete 200 is parsed");
        Check(AiUsageWebSession.OriginOf("https://claude.ai/api/x") == "https://claude.ai" && AiUsageWebSession.OriginOf("http://claude.ai/") is null,
            "web: origins are HTTPS scheme and host");
        Check(AiUsageWebReader.IsExpectedSignInHost("claude", "claude.ai") && AiUsageWebReader.IsExpectedSignInHost("gemini", "accounts.google.com")
            && !AiUsageWebReader.IsExpectedSignInHost("claude", "claude.ai.example.com"), "sign-in window: expected hosts, look-alikes warned");
    }

    // Shape of the Gemini Peer's GET /history/api/usage on 2026-11-19 (Antigravity CLI 1.5.11).
    internal static string AntigravityAnswer(DateTimeOffset observedAt, string? extra = null, string weeklyFraction = "0.94876695") => $$"""
        {"configuredModel":"gemini-4-hydrogen-high","reasoning":"high","sample":{"version":1,"observedAt":"{{observedAt.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", System.Globalization.CultureInfo.InvariantCulture)}}",
         "model":{"id":"Gemini 4 Hydrogen (High)","name":"Gemini 4 Hydrogen (High)"},"cliVersion":"1.5.11","quotas":[
          {"id":"3p-5h","remainingFraction":0.5,"resetAt":"2026-11-19T08:31:47.000Z"},
          {"id":"3p-weekly","remainingFraction":1,"resetAt":"2026-11-26T03:31:47.000Z"},
          {"id":"gemini-5h","remainingFraction":1,"resetAt":"2026-11-19T08:31:47.000Z"},
          {"id":"gemini-argon-wtu-weekly","remainingFraction":1,"resetAt":"2026-11-26T03:31:47.000Z"},
          {"id":"gemini-weekly","remainingFraction":{{weeklyFraction}},"resetAt":"2026-11-24T23:46:28.000Z"}]},
         "stale":false,"refreshing":false{{extra}}}
        """;

    private void VerifyAntigravityParser()
    {
        var observed = DateTimeOffset.Parse("2026-11-19T03:31:47.307Z");
        var fresh = AiUsageParsers.ParseAntigravity(AntigravityAnswer(observed, ""","lastAttempt":{"at":"2026-11-19T03:31:47.461Z","ok":true}"""), observed.AddMinutes(1));
        Check(fresh is { Status: AiUsageStatus.Ok, Reading: { Plan: "Gemini 4 Hydrogen (High)", Windows.Count: 2 } } && fresh.Reading.ObservedAt == observed,
            "antigravity: fresh reading with the model name and the capture time");
        Check(fresh.Reading?.Windows[0] is { Id: "antigravity:gemini-5h", Kind: "session", UsedPercent: 0, WindowMinutes: 300, Model: null }
            && fresh.Reading.Windows[1] is { Id: "antigravity:gemini-weekly", Kind: "weekly", UsedPercent: 5.1, WindowMinutes: 10080 },
            "antigravity: Gemini five-hour and weekly only, used = 1 − remainingFraction (other quotas ignored)");
        Check(fresh.Reading?.Windows[1].ResetsAt == DateTimeOffset.Parse("2026-11-24T23:46:28Z"), "antigravity: reset instant");

        var old = AiUsageParsers.ParseAntigravity(AntigravityAnswer(observed), observed.AddMinutes(6));
        Check(old is { Status: AiUsageStatus.Error, ErrorCode: AiUsageErrorCodes.Stale, Reading.Windows.Count: 2 },
            "antigravity: a capture older than five minutes is a stale reading, not a success");
        var failedRenewal = AiUsageParsers.ParseAntigravity(AntigravityAnswer(observed, ""","lastAttempt":{"at":"2026-11-19T03:40:00.000Z","ok":false,"error":"x"}"""), observed.AddMinutes(9));
        Check(failedRenewal is { Status: AiUsageStatus.Error, ErrorCode: AiUsageErrorCodes.PeerFailed, Reading: not null },
            "antigravity: a failed peer refresh is reported with the old values");
        var peerSaysStale = AiUsageParsers.ParseAntigravity(AntigravityAnswer(observed).Replace("\"stale\":false", "\"stale\":true"), observed.AddMinutes(1));
        Check(peerSaysStale is { Status: AiUsageStatus.Error, ErrorCode: AiUsageErrorCodes.Stale }, "antigravity: the peer's own stale flag is honoured");
        Check(AiUsageParsers.ParseAntigravity(AntigravityAnswer(observed), observed.AddMinutes(-10)).Status == AiUsageStatus.Error,
            "antigravity: a capture far in the future is not shown as current");

        Check(AiUsageParsers.ParseAntigravity("""{"configuredModel":"gemini-4-hydrogen-high","sample":null,"stale":true,"lastAttempt":null}""", observed)
            is { Status: AiUsageStatus.Error, ErrorCode: AiUsageErrorCodes.NoSnapshot, Reading: null }, "antigravity: no saved reading is its own error, never 0%");
        Check(AiUsageParsers.ParseAntigravity("""{"sample":null,"lastAttempt":{"at":"2026-11-19T03:40:00.000Z","ok":false}}""", observed)
            is { ErrorCode: AiUsageErrorCodes.PeerFailed, Reading: null }, "antigravity: no saved reading after a failed refresh");

        var unknownWeekly = AiUsageParsers.ParseAntigravity(AntigravityAnswer(observed, weeklyFraction: "null"), observed);
        Check(unknownWeekly is { Status: AiUsageStatus.Ok } && unknownWeekly.Reading?.Windows is [{ Kind: "session", State: null }, { Kind: "weekly", State: "unreadable" }]
            && unknownWeekly.Reading.Windows[1].ResetsAt is not null, "antigravity: an unknown fraction is an unreadable row, not 0% and not dropped");
        var unknownBoth = AiUsageParsers.ParseAntigravity(AntigravityAnswer(observed, weeklyFraction: "null").Replace(
            "\"id\":\"gemini-5h\",\"remainingFraction\":1", "\"id\":\"gemini-5h\",\"remainingFraction\":null"), observed);
        Check(unknownBoth is { Status: AiUsageStatus.Error, ErrorCode: AiUsageErrorCodes.NoValues } && unknownBoth.Reading?.Windows is [{ State: "unreadable" }, { State: "unreadable" }],
            "antigravity: with both fractions unknown the rows stay, but the reading is not a success");
        var missingSession = AiUsageParsers.ParseAntigravity(AntigravityAnswer(observed).Replace("\"id\":\"gemini-5h\"", "\"id\":\"gemini-5h-renamed\""), observed);
        Check(missingSession is { Status: AiUsageStatus.Ok } && missingSession.Reading?.Windows is [{ Kind: "session", State: "unreadable", ResetsAt: null }, { Kind: "weekly", State: null }],
            "antigravity: a window missing from the capture is an unreadable row, so it is clear which one was read");
        var renewalFailedFresh = AiUsageParsers.ParseAntigravity(AntigravityAnswer(observed, ""","lastAttempt":{"at":"2026-11-19T03:32:30.000Z","ok":false}"""), observed.AddMinutes(1));
        Check(renewalFailedFresh is { Status: AiUsageStatus.Error, ErrorCode: AiUsageErrorCodes.PeerFailed, Reading: not null },
            "antigravity: a renewal that failed after a recent capture is reported, not shown as updated");
        var failedBefore = AiUsageParsers.ParseAntigravity(AntigravityAnswer(observed, ""","lastAttempt":{"at":"2026-11-19T03:20:00.000Z","ok":false}"""), observed.AddMinutes(1));
        Check(failedBefore.Status == AiUsageStatus.Ok, "antigravity: a failure older than the capture does not taint it");
        ExpectParseFailure(() => AiUsageParsers.ParseAntigravity(AntigravityAnswer(observed, weeklyFraction: "1.5"), observed),
            "antigravity: a fraction above 1 is a format change");
        ExpectParseFailure(() => AiUsageParsers.ParseAntigravity(AntigravityAnswer(observed, weeklyFraction: "-0.1"), observed),
            "antigravity: a negative fraction is a format change");
        ExpectParseFailure(() => AiUsageParsers.ParseAntigravity("""{"sample":{"version":1,"observedAt":"2026-11-19T03:31:47Z","quotas":[{"id":"3p-5h","remainingFraction":1}]}}""", observed),
            "antigravity: no Gemini quota is a parse failure");
        ExpectParseFailure(() => AiUsageParsers.ParseAntigravity("""{"sample":{"version":2,"observedAt":"2026-11-19T03:31:47Z","quotas":[]}}""", observed),
            "antigravity: a new sample version is a format change");
        ExpectParseFailure(() => AiUsageParsers.ParseAntigravity("""{"sample":{"version":1,"quotas":[{"id":"gemini-5h","remainingFraction":1}]}}""", observed),
            "antigravity: a sample without a capture time is not trusted");
        ExpectParseFailure(() => AiUsageParsers.ParseAntigravity("<html></html>", observed), "antigravity: an HTML page is a format change");
    }

    private void ExpectParseFailure(Action action, string label)
    {
        try
        {
            action();
            Check(false, label);
        }
        catch (AiUsageParseException)
        {
            Check(true, label);
        }
    }

    private void VerifySnapshots()
    {
        var now = DateTimeOffset.Parse("2026-11-18T01:00:00Z");
        var reading = new AiUsageReading("Pro", [new AiUsageWindow("w", "weekly", null, 40, now.AddDays(2), 10080)]);
        var ok = AiUsageServiceSnapshot.Initial("claude").Apply(AiUsageResult.Success(reading), now);
        Check(ok is { Status: AiUsageStatus.Ok, Stale: false, Windows.Count: 1 } && ok.FetchedAt == now && ok.CheckedAt == now, "snapshot: success");
        var failed = ok.Apply(AiUsageResult.Failure(AiUsageErrorCodes.Network), now.AddMinutes(5));
        Check(failed is { Status: AiUsageStatus.Error, Stale: true, Windows.Count: 1, ErrorCode: AiUsageErrorCodes.Network } && failed.FetchedAt == now,
            "snapshot: a failed refresh keeps the last reading as stale");
        var firstFailure = AiUsageServiceSnapshot.Initial("muse").Apply(AiUsageResult.Failure(AiUsageErrorCodes.Changed), now);
        Check(firstFailure is { Status: AiUsageStatus.Error, Stale: false, Windows.Count: 0 }, "snapshot: a first failure shows no bars");
        var balanceOk = AiUsageServiceSnapshot.Initial("colab").Apply(AiUsageResult.Success(new AiUsageReading(null, [], [new AiUsageBalance("computeUnits", null, 12.5m, "units", null)])), now);
        var balanceFailed = balanceOk.Apply(AiUsageResult.Failure(AiUsageErrorCodes.Network), now.AddMinutes(5));
        Check(balanceFailed is { Status: AiUsageStatus.Error, Stale: true } && balanceFailed.BalanceList is [{ Amount: 12.5m }],
            "snapshot: a failed balance read keeps the last balance as stale, never 0");
        var signedOut = failed.Apply(AiUsageResult.SignedOut(), now.AddMinutes(6));
        Check(signedOut is { Status: AiUsageStatus.SignedOut, Windows.Count: 0, Plan: null, Stale: false }, "snapshot: sign-out clears old readings");

        // A saved reading (Antigravity through the Gemini Peer) keeps the time it was captured.
        var captured = now.AddMinutes(-3);
        var saved = reading with { ObservedAt = captured };
        var savedOk = AiUsageServiceSnapshot.Initial("antigravity").Apply(AiUsageResult.Success(saved), now);
        Check(savedOk is { Status: AiUsageStatus.Ok, Stale: false } && savedOk.FetchedAt == captured && savedOk.CheckedAt == now,
            "snapshot: a saved reading shows its capture time, not the time it was read");
        var oldFirst = AiUsageServiceSnapshot.Initial("antigravity").Apply(AiUsageResult.StaleReading(saved, AiUsageErrorCodes.Stale), now);
        Check(oldFirst is { Status: AiUsageStatus.Error, Stale: true, Windows.Count: 1, ErrorCode: AiUsageErrorCodes.Stale } && oldFirst.FetchedAt == captured,
            "snapshot: an old saved reading on first read is shown, marked stale with the reason");
        var newer = savedOk.Apply(AiUsageResult.StaleReading(saved with { Plan = "Older", ObservedAt = captured.AddMinutes(-60) }, AiUsageErrorCodes.PeerFailed), now.AddMinutes(10));
        Check(newer is { Status: AiUsageStatus.Error, Stale: true, Plan: "Pro", ErrorCode: AiUsageErrorCodes.PeerFailed } && newer.FetchedAt == captured,
            "snapshot: an older saved reading never replaces a newer one on screen");
    }

    private async Task VerifyServiceAsync()
    {
        var calls = new Dictionary<string, int>();
        var now = DateTimeOffset.Parse("2026-11-18T01:00:00Z");
        var results = new Dictionary<string, AiUsageResult>
        {
            ["codex"] = AiUsageResult.Success(new AiUsageReading("Pro", [new AiUsageWindow("c", "session", null, 10, null, 300)])),
            ["claude"] = AiUsageResult.Success(new AiUsageReading("Max 5x", [new AiUsageWindow("a", "weekly", "Fable", 35, null, 10080)])),
            ["claude-api"] = AiUsageResult.Success(new AiUsageReading(null, [], [new AiUsageBalance("planCredit", "API credit (Max)", 100m, "usd", null)])),
            ["gemini"] = AiUsageResult.SignedOut(),
            ["antigravity"] = AiUsageResult.Success(new AiUsageReading("Gemini 4 Hydrogen (High)", [new AiUsageWindow("g", "weekly", null, 5.1, null, 10080)], ObservedAt: DateTimeOffset.Parse("2026-11-18T00:59:00Z"))),
            ["colab"] = AiUsageResult.SignedOut(),
            ["muse"] = AiUsageResult.Failure(AiUsageErrorCodes.Changed)
        };
        var root = Path.Combine(Path.GetTempPath(), "HoverPocket", "AiUsageVerify", Guid.NewGuid().ToString("N"));
        using var service = new AiUsageService(Path.Combine(root, "codex"), Path.Combine(root, "web"), (id, _) =>
        {
            calls[id] = calls.GetValueOrDefault(id) + 1;
            return Task.FromResult(results[id]);
        }, () => now);
        var changes = 0;
        service.Changed += (_, _) => changes++;
        await service.RefreshAsync(AiUsageServiceIds.All, force: false);
        Check(AiUsageServiceIds.All.All(id => calls.GetValueOrDefault(id) == 1), "service: first refresh reads every service once");
        Check(service.Snapshot("claude").Windows[0].Model == "Fable" && service.Snapshot("gemini").Status == AiUsageStatus.SignedOut
            && service.Snapshot("muse").ErrorCode == AiUsageErrorCodes.Changed && changes >= 8, "service: results applied with change events");
        Check(AiUsageServiceIds.All.All(id => !service.Snapshot(id).Refreshing), "service: refreshing flags cleared");

        now = now.AddMinutes(1);
        await service.RefreshAsync(AiUsageServiceIds.All, force: false);
        Check(AiUsageServiceIds.All.All(id => calls[id] == 1), "service: readings younger than two minutes are reused");
        now = now.AddMinutes(2);
        await service.RefreshAsync(AiUsageServiceIds.All, force: false);
        Check(calls["codex"] == 2 && calls["claude"] == 2 && calls["muse"] == 2 && calls["gemini"] == 1,
            "service: stale readings refresh, a signed-out service waits for sign-in or refresh");
        await service.RefreshAsync(["gemini"], force: true);
        Check(calls["gemini"] == 2 && calls["codex"] == 2, "service: forced refresh reads only the requested service");
        now = now.AddMinutes(31);
        await service.RefreshAsync(["gemini"], force: false);
        Check(calls["gemini"] == 3, "service: a signed-out service is re-checked after 30 minutes");

        // A saved reading shown as current turns old five minutes after its capture, so it is re-read on the
        // next panel open even within two minutes of the last check.
        var peerCalls = 0;
        var peerNow = DateTimeOffset.Parse("2026-11-19T10:04:50Z");
        using (var peerService = new AiUsageService(Path.Combine(root, "codex8"), Path.Combine(root, "web8"), (_, _) =>
        {
            peerCalls++;
            return Task.FromResult(AiUsageResult.Success(new AiUsageReading("Gemini 4 Hydrogen (High)", [
                new AiUsageWindow("antigravity:gemini-5h", "session", null, 0, null, 300, State: "unreadable"),
                new AiUsageWindow("antigravity:gemini-weekly", "weekly", null, 5.1, null, 10080)], ObservedAt: DateTimeOffset.Parse("2026-11-19T10:00:00Z"))));
        }, () => peerNow))
        {
            await peerService.RefreshAsync(["antigravity"], force: false);
            var wire = JsonSerializer.SerializeToNode(peerService.BuildState([]), BridgeJson.Options)!["services"]!.AsArray()
                .Single(node => node!["id"]!.GetValue<string>() == "antigravity")!;
            Check(wire["freshUntil"]?.GetValue<string>() == DateTimeOffset.Parse("2026-11-19T10:05:00Z").ToString("O")
                && wire["windows"]![0]!["usedPercent"] is null && wire["windows"]![0]!["state"]?.GetValue<string>() == "unreadable"
                && wire["windows"]![1]!["usedPercent"]!.GetValue<double>() == 5.1,
                "service: the wire state says when a saved reading turns old, and carries no number for an unreadable row");
            peerNow = peerNow.AddSeconds(20);
            await peerService.RefreshAsync(["antigravity"], force: false);
            Check(peerCalls == 2, "service: a saved reading past its five minutes is re-read on the next panel open");
        }

        // A reading that started before a sign-in or sign-out must not land afterwards.
        var gate = new TaskCompletionSource<AiUsageResult>(TaskCreationOptions.RunContinuationsAsynchronously);
        var slowCalls = 0;
        using (var slow = new AiUsageService(Path.Combine(root, "codex2"), Path.Combine(root, "web2"), (id, _) =>
        {
            slowCalls++;
            return id == "claude" && slowCalls == 1 ? gate.Task : Task.FromResult(AiUsageResult.SignedOut());
        }, () => now))
        {
            var pending = slow.RefreshAsync(["claude"], force: true);
            var joined = slow.RefreshAsync(["claude"], force: true);
            slow.BeginAccountChange("claude");
            gate.SetResult(AiUsageResult.Success(new AiUsageReading("Old", [new AiUsageWindow("w", "weekly", null, 70, null, 10080)])));
            await pending;
            await joined;
            Check(slowCalls == 1, "service: a second refresh press joins the running one");
            Check(slow.Snapshot("claude") is { Status: AiUsageStatus.Idle, Windows.Count: 0, Plan: null },
                "service: a reading from before the account change is discarded");
            await slow.SignOutAsync("claude", CancellationToken.None);
            Check(slow.Snapshot("claude").Status == AiUsageStatus.SignedOut, "service: sign-out shows the read-back state");
        }

        // After an account change, a new refresh reads the new account instead of joining the old one.
        var oldRead = new TaskCompletionSource<AiUsageResult>(TaskCreationOptions.RunContinuationsAsynchronously);
        var swapCalls = 0;
        using (var swap = new AiUsageService(Path.Combine(root, "codex4"), Path.Combine(root, "web4"), (_, _) =>
            ++swapCalls == 1 ? oldRead.Task : Task.FromResult(AiUsageResult.Success(new AiUsageReading("New", [new AiUsageWindow("w", "weekly", null, 5, null, 10080)]))), () => now))
        {
            var before = swap.RefreshAsync(["claude"], force: true);
            swap.BeginAccountChange("claude");
            var after = swap.RefreshAsync(["claude"], force: true);
            oldRead.SetResult(AiUsageResult.Success(new AiUsageReading("Old", [new AiUsageWindow("w", "weekly", null, 70, null, 10080)])));
            await before;
            await after;
            Check(swapCalls == 2 && swap.Snapshot("claude") is { Status: AiUsageStatus.Ok, Plan: "New" },
                "service: after an account change a new refresh reads the new account instead of joining the old one");
        }

        // Sign-out while another refresh still has to read the service, then a failing read-back.
        var claudeBlock = new TaskCompletionSource<AiUsageResult>(TaskCreationOptions.RunContinuationsAsynchronously);
        var museCalls = 0;
        using (var order = new AiUsageService(Path.Combine(root, "codex5"), Path.Combine(root, "web5"), (id, _) =>
            id == "claude" ? claudeBlock.Task
            : ++museCalls == 1 ? Task.FromResult(AiUsageResult.Success(new AiUsageReading("Old", [new AiUsageWindow("w", "weekly", null, 70, null, 10080)])))
            : Task.FromResult(AiUsageResult.Failure(AiUsageErrorCodes.Network)), () => now))
        {
            var running = order.RefreshAsync(["claude", "muse"], force: true);
            var signOut = order.SignOutAsync("muse", CancellationToken.None);
            claudeBlock.SetResult(AiUsageResult.SignedOut());
            await running;
            await signOut;
            Check(museCalls == 2 && order.Snapshot("muse") is { Status: AiUsageStatus.Error, Stale: false, Windows.Count: 0, Plan: null },
                "service: sign-out never leaves the previous account's values, even when the read-back fails");
        }

        // One service failing in an unexpected way must not stop the others.
        using (var throwing = new AiUsageService(Path.Combine(root, "codex3"), Path.Combine(root, "web3"), (id, _) =>
            id == "gemini" ? throw new ArgumentOutOfRangeException("resetsAt") : Task.FromResult(results[id]), () => now))
        {
            await throwing.RefreshAsync(AiUsageServiceIds.All, force: true);
            Check(throwing.Snapshot("gemini") is { Status: AiUsageStatus.Error, ErrorCode: AiUsageErrorCodes.Changed }
                && throwing.Snapshot("claude").Status == AiUsageStatus.Ok && throwing.Snapshot("muse").Status == AiUsageStatus.Error,
                "service: an exception becomes that service's error and the rest still refresh");
        }

        var state = JsonSerializer.SerializeToNode(service.BuildState(["muse"]), BridgeJson.Options)!;
        var services = state["services"]!.AsArray();
        JsonNode Service(string id) => services.Single(node => node!["id"]!.GetValue<string>() == id)!;
        Check(services.Count == 7 && Service("muse")["visible"]!.GetValue<bool>() == false && Service("codex")["signIn"]!.GetValue<string>() == "codex"
            && Service("antigravity")["signIn"]!.GetValue<string>() == "peer" && Service("antigravity")["sharedWith"] is null
            && Service("antigravity")["fetchedAt"]!.GetValue<string>() == DateTimeOffset.Parse("2026-11-18T00:59:00Z").ToString("O")
            && Service("claude")["windows"]![0]!["model"]!.GetValue<string>() == "Fable"
            && Service("colab")["signIn"]!.GetValue<string>() == "shared" && Service("colab")["sharedWith"]!.GetValue<string>() == "gemini"
            && Service("claude-api")["balances"]![0]!["amount"]!.GetValue<decimal>() == 100m, "service: wire state lists all services, balances and the shared sign-in");

        // Gemini's Google sign-in also feeds Colab: signing out of Gemini must drop Colab's balance too.
        var google = new Dictionary<string, int>();
        var geminiRead = new TaskCompletionSource<AiUsageResult>(TaskCreationOptions.RunContinuationsAsynchronously);
        using (var shared = new AiUsageService(Path.Combine(root, "codex6"), Path.Combine(root, "web6"), (id, _) =>
        {
            google[id] = google.GetValueOrDefault(id) + 1;
            if (id == "gemini" && google[id] == 1) return geminiRead.Task;
            return Task.FromResult(google[id] == 1 && id == "colab"
                ? AiUsageResult.Success(new AiUsageReading(null, [], [new AiUsageBalance("computeUnits", null, 87.6m, "units", null)]))
                : AiUsageResult.SignedOut());
        }, () => now))
        {
            // A refresh of both is under way (Gemini first, Colab still queued) when Gemini is signed out.
            var running = shared.RefreshAsync(["gemini", "colab"], force: true);
            var signingOut = false;
            var leaked = false;
            shared.Changed += (_, _) => { if (signingOut && shared.Snapshot("colab").BalanceList.Count > 0) leaked = true; };
            signingOut = true;
            var signOut = shared.SignOutAsync("gemini", CancellationToken.None);
            geminiRead.SetResult(AiUsageResult.Success(new AiUsageReading(null, [new AiUsageWindow("g", "weekly", null, 10, null, 10080)])));
            await running;
            await signOut;
            Check(!leaked, "service: no change notification shows the old Colab balance during a Gemini sign-out");
            Check(google["colab"] == 2 && shared.Snapshot("colab") is { Status: AiUsageStatus.SignedOut, Balances.Count: 0 }
                && shared.Snapshot("gemini").Status == AiUsageStatus.SignedOut,
                "service: signing out of Gemini resets and re-reads Colab"); 
            // Two overlapping sign-outs: cancelling the second must not lift the first one's hold.
            var queued = new TaskCompletionSource<AiUsageResult>(TaskCreationOptions.RunContinuationsAsynchronously);
            using (var overlap = new AiUsageService(Path.Combine(root, "codex7"), Path.Combine(root, "web7"), (id, _) =>
                id == "gemini" ? queued.Task : Task.FromResult(AiUsageResult.Success(new AiUsageReading(null, [], [new AiUsageBalance("computeUnits", null, 5m, "units", null)]))), () => now))
            {
                var stale = false;
                var holding = false;
                overlap.Changed += (_, _) => { if (holding && overlap.Snapshot("colab").BalanceList.Count > 0) stale = true; };
                var refreshing = overlap.RefreshAsync(["gemini", "colab"], force: true);
                holding = true;
                var first = overlap.SignOutAsync("gemini", CancellationToken.None);
                using var cancel = new CancellationTokenSource();
                var second = overlap.SignOutAsync("gemini", cancel.Token);
                cancel.Cancel();
                try { await second; } catch (OperationCanceledException) { }
                queued.SetResult(AiUsageResult.SignedOut());
                await refreshing;
                holding = false;
                await first;
                Check(!stale, "service: a cancelled overlapping sign-out does not lift the other's hold");
            }
            try { await shared.SignOutAsync("colab", CancellationToken.None); Check(false, "service: Colab has no sign-out of its own"); }
            catch (ArgumentOutOfRangeException) { Check(true, "service: Colab has no sign-out of its own"); }
        }
    }

    /// <summary>A response body that ends abruptly after its first bytes, like a connection dropped mid-answer.</summary>
    private sealed class CutOffBody : Stream
    {
        private bool _started;
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override void Flush() { }
        public override int Read(byte[] buffer, int offset, int count) => ReadAsync(buffer.AsMemory(offset, count)).AsTask().GetAwaiter().GetResult();
        public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
        {
            if (_started) throw new HttpIOException(HttpRequestError.ResponseEnded, "cut off");
            _started = true;
            var start = "{\"sample\":"u8;
            start.CopyTo(buffer.Span);
            return ValueTask.FromResult(start.Length);
        }
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }

    private sealed class FakeGeminiPeer(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> respond) : HttpMessageHandler
    {
        public List<(string Method, string Path, string? Origin, string Authority)> Requests { get; } = [];

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Requests.Add((request.Method.Method, request.RequestUri!.AbsolutePath,
                request.Headers.TryGetValues("Origin", out var origin) ? origin.Single() : null, request.RequestUri.Authority));
            return respond(request, cancellationToken);
        }
    }

    /// <summary>
    /// The Antigravity reader against a fake Gemini Peer: when it renews (only stale or forced), the
    /// exact address and Origin it sends, and that every failure keeps the reason instead of 0%.
    /// </summary>
    private async Task VerifyAntigravityReaderAsync()
    {
        var now = DateTimeOffset.Parse("2026-11-19T03:35:00Z");
        var freshAt = now.AddMinutes(-1);
        var oldAt = now.AddMinutes(-30);
        static Task<HttpResponseMessage> Answer(string body, System.Net.HttpStatusCode status = System.Net.HttpStatusCode.OK) =>
            Task.FromResult(new HttpResponseMessage(status) { Content = new StringContent(body, System.Text.Encoding.UTF8, "application/json") });
        async Task<(AiUsageResult Result, FakeGeminiPeer Peer)> Read(bool force, Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> respond)
        {
            var peer = new FakeGeminiPeer(respond);
            using var reader = new AiUsageAntigravityReader(null, peer, () => now);
            return (await reader.ReadAsync(force, CancellationToken.None), peer);
        }
        static bool IsPost(HttpRequestMessage request) => request.Method == HttpMethod.Post;

        var (fresh, freshPeer) = await Read(false, (_, _) => Answer(AntigravityAnswer(freshAt)));
        Check(fresh.Status == AiUsageStatus.Ok && freshPeer.Requests is [("GET", "/history/api/usage", null, "127.0.0.1:17848")],
            "antigravity reader: a fresh saved reading is used without asking the peer to run agy");

        var (renewed, renewedPeer) = await Read(false, (request, _) => Answer(AntigravityAnswer(IsPost(request) ? freshAt : oldAt)));
        Check(renewed is { Status: AiUsageStatus.Ok, Reading.ObservedAt: { } at } && at == freshAt
            && renewedPeer.Requests is [("GET", _, _, _), ("POST", "/history/api/usage/refresh", "http://127.0.0.1:17848", "127.0.0.1:17848")],
            "antigravity reader: a stale reading is renewed with a POST from the peer's own origin");

        var (forced, forcedPeer) = await Read(true, (_, _) => Answer(AntigravityAnswer(freshAt)));
        Check(forced.Status == AiUsageStatus.Ok && forcedPeer.Requests.Count(r => r.Method == "POST") == 1, "antigravity reader: the refresh button always renews");

        var (forcedKept, _) = await Read(true, (request, _) => IsPost(request)
            ? Answer("{}", System.Net.HttpStatusCode.InternalServerError) : Answer(AntigravityAnswer(freshAt)));
        Check(forcedKept is { Status: AiUsageStatus.Error, ErrorCode: AiUsageErrorCodes.Unavailable, Reading.ObservedAt: { } keptAt } && keptAt == freshAt,
            "antigravity reader: a failed refresh-button renewal keeps the saved values but is not shown as updated");

        var (droppedPost, _) = await Read(true, (request, _) => IsPost(request)
            ? throw new HttpRequestException("reset", null, System.Net.HttpStatusCode.OK) : Answer(AntigravityAnswer(freshAt)));
        Check(droppedPost is { Status: AiUsageStatus.Error, ErrorCode: AiUsageErrorCodes.Network, Reading: not null },
            "antigravity reader: a renewal that fails to connect is reported as a connection problem with the saved values");

        var (cutOff, _) = await Read(false, (request, _) => IsPost(request)
            ? Task.FromResult(new HttpResponseMessage(System.Net.HttpStatusCode.OK) { Content = new StreamContent(new CutOffBody()) })
            : Answer(AntigravityAnswer(oldAt)));
        Check(cutOff is { Status: AiUsageStatus.Error, ErrorCode: AiUsageErrorCodes.Network, Reading: not null },
            "antigravity reader: a renewal whose answer is cut off mid-body keeps the saved values with the reason");

        var (renewFailed, _) = await Read(false, (request, _) => IsPost(request)
            ? Answer("{}", System.Net.HttpStatusCode.InternalServerError) : Answer(AntigravityAnswer(oldAt)));
        Check(renewFailed is { Status: AiUsageStatus.Error, ErrorCode: AiUsageErrorCodes.Unavailable, Reading.Windows.Count: 2 },
            "antigravity reader: a failed renewal shows the old values with the reason");

        var (peerFailed, _) = await Read(false, (request, _) => Answer(AntigravityAnswer(oldAt,
            IsPost(request) ? ""","lastAttempt":{"at":"2026-11-19T03:34:59.000Z","ok":false,"error":"x"}""" : "")));
        Check(peerFailed is { Status: AiUsageStatus.Error, ErrorCode: AiUsageErrorCodes.PeerFailed, Reading: not null },
            "antigravity reader: the peer's failed agy read is reported with the old values");

        var (firstCapture, firstPeer) = await Read(false, (request, _) => IsPost(request)
            ? Answer(AntigravityAnswer(freshAt)) : Answer("""{"sample":null,"stale":true,"lastAttempt":null}"""));
        Check(firstCapture.Status == AiUsageStatus.Ok && firstPeer.Requests.Count == 2, "antigravity reader: with no saved reading the peer is asked to read one");

        var (refused, refusedPeer) = await Read(false, (_, _) => Answer("""{"error":"x"}""", System.Net.HttpStatusCode.Forbidden));
        Check(refused is { Status: AiUsageStatus.Error, ErrorCode: AiUsageErrorCodes.Changed, Reading: null } && refusedPeer.Requests.Count == 1,
            "antigravity reader: a refused request is a changed interface and is not retried as a POST");

        var (garbled, garbledPeer) = await Read(false, (_, _) => Answer("<html></html>"));
        Check(garbled is { ErrorCode: AiUsageErrorCodes.Changed, Reading: null } && garbledPeer.Requests.Count == 2,
            "antigravity reader: an unreadable answer is a changed interface, and the peer is still asked to renew");

        var huge = new string(' ', 300 * 1024) + "{}";
        var (oversized, _) = await Read(false, (request, _) => IsPost(request) ? Answer(huge) : Answer(huge));
        Check(oversized is { Status: AiUsageStatus.Error, ErrorCode: AiUsageErrorCodes.Changed, Reading: null }, "antigravity reader: an answer over 256 KiB is refused, not parsed");
        var (oversizedThenOk, _) = await Read(false, (request, _) => IsPost(request) ? Answer(AntigravityAnswer(freshAt)) : Answer(huge));
        Check(oversizedThenOk.Status == AiUsageStatus.Ok, "antigravity reader: after a refused answer a good renewal is used");

        using (var cancel = new CancellationTokenSource())
        {
            var waiting = new FakeGeminiPeer(async (request, token) =>
            {
                if (!IsPost(request)) return await Answer(AntigravityAnswer(oldAt));
                cancel.CancelAfter(100);
                await Task.Delay(Timeout.Infinite, token);
                throw new InvalidOperationException("unreachable");
            });
            using var reader = new AiUsageAntigravityReader(null, waiting, () => now);
            try
            {
                await reader.ReadAsync(false, cancel.Token);
                Check(false, "antigravity reader: closing the app during a renewal cancels it instead of reporting a timeout");
            }
            catch (OperationCanceledException)
            {
                Check(true, "antigravity reader: closing the app during a renewal cancels it instead of reporting a timeout");
            }
        }

        var (hung, hungPeer) = await Read(false, async (_, token) =>
        {
            await Task.Delay(Timeout.Infinite, token);
            throw new InvalidOperationException("unreachable");
        });
        Check(hung is { ErrorCode: AiUsageErrorCodes.Timeout, Reading: null } && hungPeer.Requests.Count == 1,
            "antigravity reader: a hung peer times out once instead of being asked again");

        // Nothing listens on a port that was just released: the real socket path reports a stopped peer.
        var probe = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, 0);
        probe.Start();
        var port = ((System.Net.IPEndPoint)probe.LocalEndpoint).Port;
        probe.Stop();
        using (var reader = new AiUsageAntigravityReader(new Uri($"http://127.0.0.1:{port}"), clock: () => now))
            Check(await reader.ReadAsync(false, CancellationToken.None) is { Status: AiUsageStatus.Error, ErrorCode: AiUsageErrorCodes.PeerMissing, Reading: null },
                "antigravity reader: a stopped Gemini Peer is reported as not running, not 0%");
    }

    /// <summary>
    /// The hidden view's in-page reader against a local HTTPS origin (WebView2 virtual host): repeated
    /// reads in one document, the size cap, the origin lock, and the Muse script evaluated twice.
    /// </summary>
    private async Task VerifyInPageFetchAsync()
    {
        var root = Path.Combine(Path.GetTempPath(), "HoverPocket", "AiUsageFetchVerify", Guid.NewGuid().ToString("N"));
        var site = Path.Combine(root, "site");
        Directory.CreateDirectory(site);
        File.WriteAllText(Path.Combine(site, "robots.txt"), "User-agent: *");
        File.WriteAllText(Path.Combine(site, "a.json"), """{"ok":1}""");
        File.WriteAllText(Path.Combine(site, "big.txt"), new string('x', 300_000));
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(60));
        await using var session = await AiUsageWebSession.CreateAsync(Path.Combine(root, "web"), "verify");
        session.CoreWebView2.SetVirtualHostNameToFolderMapping("ai-usage-verify.example", site, CoreWebView2HostResourceAccessKind.Allow);
        await session.NavigateAsync(new Uri("https://ai-usage-verify.example/robots.txt"), TimeSpan.FromSeconds(20), timeout.Token);
        var first = await session.FetchAsync("/a.json", "GET", null, null, "manual", 1000, TimeSpan.FromSeconds(20), timeout.Token);
        var second = await session.FetchAsync("/a.json", "GET", null, null, "manual", 1000, TimeSpan.FromSeconds(20), timeout.Token);
        Check(first is { Status: 200, Truncated: false } && second is { Status: 200, Body: """{"ok":1}""" }, "in-page fetch: two reads in the same document");
        var big = await session.FetchAsync("/big.txt", "GET", null, null, "manual", 1000, TimeSpan.FromSeconds(20), timeout.Token);
        Check(big is { Status: 200, Truncated: true } && big.Body.Length == 1000, "in-page fetch: the body is cut at the cap and reported");
        var museFirst = await session.EvaluateAsync(AiUsageWebReader.MuseDiscoveryExpression, TimeSpan.FromSeconds(20), timeout.Token);
        var museSecond = await session.EvaluateAsync(AiUsageWebReader.MuseDiscoveryExpression, TimeSpan.FromSeconds(20), timeout.Token);
        Check(museFirst.Contains("network", StringComparison.Ordinal) && museSecond == museFirst,
            "in-page fetch: the Muse script runs twice and refuses a non-muse.ai origin");
        session.CoreWebView2.Navigate("https://example.com/");
        await Task.Delay(800, timeout.Token);
        Check(AiUsageWebSession.OriginOf(session.CoreWebView2.Source) == "https://ai-usage-verify.example", "in-page fetch: navigation to another origin is refused");
        try
        {
            await session.FetchAsync("//example.com/x", "GET", null, null, "manual", 10, TimeSpan.FromSeconds(5), timeout.Token);
            Check(false, "in-page fetch: protocol-relative paths are rejected");
        }
        catch (ArgumentException)
        {
            Check(true, "in-page fetch: protocol-relative paths are rejected");
        }
    }

    private void VerifySettings()
    {
        var providers = ProviderRegistry.CreateDefault();
        Check(providers.Find("ai-usage") is { Icon: "gauge" }, "registry: AI Usage provider");
        var old = new UserSettings
        {
            ProviderOrder = ["controls", "calculator", "calendar", "clipboard", "sticky", "assets", "timer"],
            ProviderVisibility = new(StringComparer.OrdinalIgnoreCase) { ["timer"] = false },
            AiUsageHiddenServices = ["muse", "unknown", "muse", "antigravity"]
        };
        var normalized = UserSettingsStore.Normalize(old, providers.ProviderIds);
        Check(normalized.ProviderOrder[^1] == "ai-usage" && normalized.ProviderVisibility["ai-usage"], "settings: existing users get the new tool at the end, visible");
        Check(normalized.AiUsageHiddenServices.SequenceEqual(["muse", "antigravity"]), "settings: hidden services keep only known ids");
        Check(normalized.AiUsageView == "list" && normalized.AiUsageSort is null
            && normalized.AiUsageServiceOrder.SequenceEqual(AiUsageServiceIds.All), "settings: old settings default to list and the original service order");
        var clone = normalized.Clone();
        clone.AiUsageHiddenServices.Add("codex");
        clone.AiUsageServiceOrder.Remove("codex");
        Check(normalized.AiUsageServiceOrder.SequenceEqual(AiUsageServiceIds.All), "settings: clone copies the service order");
        Check(normalized.AiUsageHiddenServices.Count == 2, "settings: clone copies the hidden list");
        var store = UserSettingsStore.CreateTemporary("AiUsageSettingsVerify");
        normalized.AiUsageServiceOrder = ["muse", "unknown", "muse", "gemini"];
        normalized.AiUsageView = "invalid";
        normalized.AiUsageSort = new AiUsageListSort("session", "invalid");
        store.Save(normalized);
        var loaded = store.Load(providers.ProviderIds);
        Check(loaded.AiUsageHiddenServices.SequenceEqual(["muse", "antigravity"]), "settings: hidden services persist");
        Check(loaded.AiUsageView == "list" && loaded.AiUsageSort is null
            && loaded.AiUsageServiceOrder.SequenceEqual(["muse", "gemini", "codex", "claude", "claude-api", "antigravity", "colab"]),
            "settings: invalid preferences fall back and the saved order keeps hidden services, dropping unknown and duplicate ids");
        loaded.AiUsageView = "meter";
        loaded.AiUsageSort = new AiUsageListSort("other", "desc");
        store.Save(loaded);
        var reopened = new UserSettingsStore(store.RootDirectory).Load(providers.ProviderIds);
        Check(reopened.AiUsageView == "meter" && reopened.AiUsageSort == new AiUsageListSort("other", "desc")
            && reopened.AiUsageServiceOrder.SequenceEqual(loaded.AiUsageServiceOrder), "settings: meter, custom order and list sort survive a new store");
    }

    private async Task VerifyBridgeAndUiAsync(Action<string> log)
    {
        var providers = ProviderRegistry.CreateDefault();
        var store = UserSettingsStore.CreateTemporary("AiUsageBridgeVerify");
        var now = DateTimeOffset.UtcNow;
        var readings = new Dictionary<string, AiUsageResult>
        {
            ["codex"] = AiUsageResult.Success(new AiUsageReading("Pro", [
                new AiUsageWindow("codex:codex:primary", "session", null, 12, now.AddHours(3).AddMinutes(12), 300),
                new AiUsageWindow("codex:codex:secondary", "weekly", null, 47, now.AddDays(4), 10080),
                new AiUsageWindow("codex:spark:primary", "session", "GPT-5.3-Codex-Spark", 3, now.AddHours(2), 300),
                new AiUsageWindow("codex:spark:weekly", "weekly", "GPT-5.3-Codex-Spark", 95, now.AddDays(4), 10080)])),
            ["claude"] = AiUsageResult.Success(new AiUsageReading("Max 5x", [
                new AiUsageWindow("claude:session", "session", null, 32, now.AddMinutes(55), 300),
                new AiUsageWindow("claude:weekly_all", "weekly", null, 30, now.AddDays(5), 10080),
                new AiUsageWindow("claude:weekly_scoped:Fable", "weekly", "Fable", 85, now.AddDays(5), 10080),
                new AiUsageWindow("claude:3day", "session", null, 75, now.AddDays(2), 4320)])),
            ["claude-api"] = AiUsageResult.Success(new AiUsageReading(null, [], [
                new AiUsageBalance("planCredit", "API credit (Max)", 100m, "usd", now.AddDays(24)),
                new AiUsageBalance("purchasedCredit", null, 12.34m, "usd", now.AddDays(26)),
                new AiUsageBalance("purchasedCredit", null, 0.004m, "usd", now.AddDays(90))])),
            ["gemini"] = AiUsageResult.SignedOut(),
            ["antigravity"] = AiUsageResult.Success(new AiUsageReading("Gemini 4 Hydrogen (High)", [
                new AiUsageWindow("antigravity:gemini-5h", "session", null, 0, now.AddHours(4).AddMinutes(30), 300),
                new AiUsageWindow("antigravity:gemini-weekly", "weekly", null, 5.1, now.AddDays(5).AddHours(20), 10080)], ObservedAt: now.AddMinutes(-1))),
            ["colab"] = AiUsageResult.Success(new AiUsageReading(null, [], [new AiUsageBalance("computeUnits", null, 87.6m, "units", null, 0m)])),
            ["muse"] = AiUsageResult.Failure(AiUsageErrorCodes.Changed)
        };
        readings["codex"] = readings["codex"] with
        {
            Reading = readings["codex"].Reading! with { Balances = [
                new AiUsageBalance("codexCredits", null, 12345.68m, "credits", null),
                new AiUsageBalance("codexCredits", null, 0, "credits", null, State: "unlimited"),
                new AiUsageBalance("codexCredits", null, 0, "credits", null, State: "unreadable")] }
        };
        using var controller = new PanelBridgeController(providers, store, store.Load(providers.ProviderIds),
            externalIntegrationsEnabled: false, aiUsageReader: (id, _) => Task.FromResult(readings[id]));
        var panel = new BridgeDispatcher();
        using var panelAttachment = controller.Attach(panel, BridgeSurface.Panel);
        var settingsEvents = new List<string>();
        var settings = new BridgeDispatcher(json => { settingsEvents.Add(json); return Task.CompletedTask; });
        using var settingsAttachment = controller.Attach(settings, BridgeSurface.Settings);

        async Task<JsonNode> Call(BridgeDispatcher dispatcher, string method, object? parameters = null)
        {
            var raw = await dispatcher.ProcessRawMessageAsync(JsonSerializer.Serialize(new { id = "1", method, @params = parameters }));
            return JsonNode.Parse(raw!)!;
        }

        var initial = await Call(panel, "aiUsage.getState", new { refresh = true });
        Check(initial["result"]?["services"]?.AsArray().Count == 7, "bridge: panel reads the usage state");
        using var wait = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        while (controller.AiUsageForVerify!.Snapshot("muse").Status == AiUsageStatus.Idle) await Task.Delay(20, wait.Token);
        Check((await Call(panel, "aiUsage.signIn", new { service = "claude" }))["error"]?["code"]?.GetValue<string>() == "unknown_method",
            "bridge: sign-in is only offered in Settings");
        Check((await Call(settings, "aiUsage.signOut", new { service = "codex" }))["error"] is not null, "bridge: Codex sign-out is refused (shared with chat)");
        Check((await Call(settings, "aiUsage.setVisible", new { service = "../x", visible = false }))["error"] is not null, "bridge: unknown service rejected");
        // Settings not loaded yet: the new page's first app.getState carries the AI category, once.
        Check((await Call(panel, "aiUsage.openSettings"))["result"]?["opened"]?.GetValue<bool>() == true, "bridge: panel can open Settings");
        var broadcast = JsonSerializer.SerializeToNode(controller.BuildState(BridgeSurface.Settings), BridgeJson.Options)!;
        var firstLoad = await Call(settings, "app.getState");
        var secondLoad = await Call(settings, "app.getState");
        Check(broadcast["openSettingsCategory"] is null && firstLoad["result"]?["openSettingsCategory"]?.GetValue<string>() == "ai"
            && secondLoad["result"]?["openSettingsCategory"] is null, "bridge: a newly opened Settings page lands on AI once");
        // Settings already loaded: it is told to switch instead.
        await Call(settings, "app.ready");
        settingsEvents.Clear();
        await Call(panel, "aiUsage.openSettings");
        var focus = settingsEvents.Select(json => JsonNode.Parse(json)!).Where(node => node["event"]?.GetValue<string>() == "settings.focusCategory").ToArray();
        var afterFocus = await Call(settings, "app.getState");
        Check(focus.Length == 1 && focus[0]["payload"]?["category"]?.GetValue<string>() == "ai" && afterFocus["result"]?["openSettingsCategory"] is null,
            "bridge: a loaded Settings page switches to AI without leaving a pending jump");

        settingsEvents.Clear();
        var presentation = await Call(panel, "aiUsage.setPresentation", new { view = "meter", sort = new { column = "weekly", direction = "desc" } });
        var crossSurface = await Call(settings, "aiUsage.getState");
        var published = settingsEvents.Select(json => JsonNode.Parse(json)!).LastOrDefault(node => node["event"]?.GetValue<string>() == "aiUsage.changed");
        Check(presentation["result"]?["view"]?.GetValue<string>() == "meter"
            && crossSurface["result"]?["sort"]?["direction"]?.GetValue<string>() == "desc"
            && published?["payload"]?["view"]?.GetValue<string>() == "meter", "bridge: panel saves presentation and broadcasts it to Settings");
        var restored = await Call(settings, "aiUsage.setPresentation", new { view = "list", order = AiUsageServiceIds.All, sort = (object?)null });
        Check(restored["result"]?["view"]?.GetValue<string>() == "list" && restored["result"]?["sort"] is null
            && (await Call(panel, "aiUsage.getState"))["result"]?["order"]?.AsArray().Count == 7, "bridge: Settings can save order and clear sort");

        await VerifyPanelUiAsync(controller, store, readings, log);

        var hidden = await Call(settings, "aiUsage.setVisible", new { service = "muse", visible = false });
        Check(hidden["result"]?["services"]?.AsArray().Single(node => node!["id"]!.GetValue<string>() == "muse")?["visible"]?.GetValue<bool>() == false
            && controller.CurrentSettings.AiUsageHiddenServices.SequenceEqual(["muse"])
            && store.Load(providers.ProviderIds).AiUsageHiddenServices.SequenceEqual(["muse"]), "bridge: hiding a service is saved");
    }

    private async Task VerifyPanelUiAsync(PanelBridgeController controller, UserSettingsStore store, Dictionary<string, AiUsageResult> readings, Action<string> log)
    {
        var minWidth = PanelSizeCatalog.ResizeLimits(0).MinWidth;
        var window = new Window
        {
            Left = -20000, Top = -20000, Width = minWidth, Height = 520, ShowActivated = false, ShowInTaskbar = false,
            WindowStartupLocation = WindowStartupLocation.Manual, WindowStyle = WindowStyle.None
        };
        var web = new WebView2 { CreationProperties = new CoreWebView2CreationProperties { UserDataFolder = Path.Combine(store.RootDirectory, "PanelWebView") } };
        window.Content = web;
        IDisposable? attachment = null;
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(60));
        try
        {
            window.Show();
            await web.EnsureCoreWebView2Async();
            var dispatcher = new BridgeDispatcher(json => { web.CoreWebView2.PostWebMessageAsJson(json); return Task.CompletedTask; });
            attachment = controller.Attach(dispatcher, BridgeSurface.Panel, () => window);
            web.CoreWebView2.WebMessageReceived += async (_, args) => await dispatcher.HandleRawMessageAsync(args.TryGetWebMessageAsString());
            web.CoreWebView2.SetVirtualHostNameToFolderMapping("app.hoverpocket.local", ResolveUiFolder(), CoreWebView2HostResourceAccessKind.DenyCors);
            web.CoreWebView2.Navigate("https://app.hoverpocket.local/index.html");
            async Task<bool> Js(string expression) => await web.ExecuteScriptAsync(expression) == "true";
            async Task WaitFor(string expression)
            {
                try
                {
                    while (!await Js(expression)) await Task.Delay(100, timeout.Token);
                }
                catch (OperationCanceledException)
                {
                    throw new InvalidOperationException($"AI Usage DOM condition did not appear: {expression}");
                }
            }
            async Task ChangePanelState(string method, object parameters)
            {
                var raw = JsonSerializer.Serialize(new { id = "verify", method, @params = parameters });
                await dispatcher.ProcessRawMessageAsync(raw);
                await dispatcher.PostEventAsync("state.changed", controller.BuildState(BridgeSurface.Panel));
            }
            Task Select(string id) => ChangePanelState("provider.select", new { id });

            await WaitFor("!!document.querySelector('[data-provider-icons] button')");
            await web.ExecuteScriptAsync("""
                window.usageVerify = {
                    all(selector) { return [...document.querySelectorAll(selector)]; },
                    one(selector) { return document.querySelector(selector); },
                    text(selector) { return this.one(selector)?.textContent.trim() ?? ''; },
                    services() { return this.all('.hp-usage-service').map(n => n.dataset.service).join(','); },
                    values(service) { return this.all('[data-service=' + service + '] .hp-usage-value').map(n => n.textContent).join('|'); },
                    sort() { return this.one('.hp-usage-table [aria-sort]'); },
                    fit() {
                        return ['.hp-usage', '.hp-usage-body', '.hp-provider', '.hp-panel'].every(selector => {
                            const n = this.one(selector);
                            return n.scrollWidth <= n.clientWidth;
                        });
                    },
                    resetFits(limit) {
                        const value = limit.querySelector('.hp-usage-value');
                        const reset = limit.querySelector('.hp-usage-reset:not(:empty)');
                        if (!value || !reset) return true;
                        const rect = node => {
                            const text = document.createRange();
                            text.selectNodeContents(node);
                            return text.getBoundingClientRect();
                        };
                        const number = rect(value);
                        const time = rect(reset);
                        const bar = limit.querySelector('.hp-usage-bar').getBoundingClientRect();
                        const cell = limit.getBoundingClientRect();
                        const belowBar = reset.getBoundingClientRect().top >= bar.bottom;
                        return number.left >= cell.left - 0.1 && number.right <= cell.right + 0.1
                            && time.left >= cell.left - 0.1 && time.right <= cell.right + 0.1
                            && getComputedStyle(reset).textOverflow !== 'ellipsis'
                            && (belowBar || time.left - number.right >= 5.9);
                    },
                    reasonFits(service) {
                        const group = this.one('tbody[data-service=' + service + ']');
                        const reason = group?.querySelector('.hp-usage-reason-row .hp-usage-error');
                        if (!reason) return false;
                        const style = getComputedStyle(reason);
                        const session = this.one('[data-sort-column=session]').closest('th');
                        const rect = reason.getBoundingClientRect();
                        const left = session.getBoundingClientRect().left + parseFloat(getComputedStyle(session).paddingLeft);
                        const right = group.getBoundingClientRect().right - parseFloat(getComputedStyle(reason.closest('td')).paddingRight);
                        return !group.querySelector('th .hp-usage-error')
                            && reason.closest('tr') === group.lastElementChild
                            && Math.abs(rect.left - left) < 0.1 && Math.abs(rect.right - right) < 0.1
                            && style.whiteSpace === 'normal' && style.textOverflow === 'clip'
                            && reason.scrollWidth <= reason.clientWidth && reason.scrollHeight <= reason.clientHeight
                            && reason.clientHeight <= 2 * parseFloat(style.lineHeight) + 1;
                    },
                    scrollingList() {
                        const body = this.one('.hp-usage-body');
                        const head = this.one('.hp-usage-table thead');
                        const top = body.scrollTop;
                        try {
                            body.style.maxHeight = '100px';
                            body.scrollTop = head.offsetHeight + 8;
                            const headingStyle = getComputedStyle(head);
                            return body.scrollTop > 0 && body.scrollHeight > body.clientHeight
                                && body.offsetWidth === body.clientWidth && getComputedStyle(body).scrollbarWidth === 'none'
                                && headingStyle.position === 'sticky'
                                && headingStyle.backgroundColor === getComputedStyle(body.closest('.hp-provider')).backgroundColor
                                && Math.abs(head.getBoundingClientRect().top - body.getBoundingClientRect().top) < 1;
                        } finally {
                            body.style.maxHeight = '';
                            body.scrollTop = top;
                        }
                    },
                    haveOpacity(root, selector, expected) {
                        const nodes = [...root.querySelectorAll(selector)];
                        return nodes.length > 0 && nodes.every(node => {
                            let opacity = 1;
                            for (let n = node; n !== root.parentElement; n = n.parentElement) {
                                opacity *= Number(getComputedStyle(n).opacity);
                            }
                            return opacity === expected;
                        });
                    },
                    drag(from, to) {
                        const source = this.one('.hp-usage-service[data-service=' + from + '] .hp-usage-handle');
                        const target = this.one('.hp-usage-service[data-service=' + to + ']');
                        const dataTransfer = new DataTransfer();
                        const drag = (node, type) => node.dispatchEvent(new DragEvent(type, {bubbles:true, cancelable:true, dataTransfer}));
                        drag(source, 'dragstart'); drag(target, 'dragover'); drag(target, 'drop'); drag(source, 'dragend');
                    }
                };
                """);
            const string defaultListOrder = "codex,claude,gemini,antigravity,muse";
            const string listAfterDrag = "claude,codex,gemini,antigravity,muse";
            const string listDragOrder = "claude,codex,claude-api,gemini,antigravity,colab,muse";
            const string meterDragOrder = "muse,claude,codex,claude-api,gemini,antigravity,colab";
            const string listAfterMeterDrag = "muse,claude,codex,gemini,antigravity";
            const string settingsOrder = "claude,muse,codex,claude-api,gemini,antigravity,colab";
            string Ordered(string order) => $"usageVerify.services() === '{order}'";
            await Select("ai-usage");
            await WaitFor($"!!usageVerify.one('.hp-usage-list') && {Ordered(defaultListOrder)} && usageVerify.values('claude') === '68%|70%|15%|25%'");

            Check(await Js("usageVerify.text('.hp-usage-header h2') === 'AI Usage' && usageVerify.one('[data-view=list]').getAttribute('aria-pressed') === 'true'"), "panel UI: title and list default");
            Check(await Js("""
                usageVerify.all('[data-service=claude] .hp-usage-fill').map(n => n.style.width).join('|') === '68%|70%|15%|25%'
                && usageVerify.all('[data-service=claude] .hp-usage-value').map(n => getComputedStyle(n).color).join('|')
                   === 'rgb(95, 208, 138)|rgb(90, 169, 255)|rgb(255, 124, 124)|rgb(245, 195, 91)'
                && usageVerify.all('[data-service=claude] .hp-usage-fill').every(n =>
                    getComputedStyle(n).backgroundColor === getComputedStyle(n.closest('.hp-usage-limit').querySelector('.hp-usage-value')).color)
                """), "panel UI: list numbers and bar widths show remaining quota in all four threshold colors");
            Check(await Js("""
                usageVerify.all('[data-service=claude] [data-column=other] .hp-usage-limit-name').map(n => n.textContent).join('|') === 'Fable|3日'
                && usageVerify.all('[data-service=codex] [data-column=other] .hp-usage-limit-name').map(n => n.title).join('|')
                    === 'GPT-5.3-Codex-Spark 5時間|GPT-5.3-Codex-Spark 1週間'
                && usageVerify.all('[data-service=codex] [data-column=other] .hp-usage-limit-name').every(n => n.textContent === n.title)
                && usageVerify.all('[data-service=codex] [data-column=other] .hp-usage-window-model').some(n =>
                    n.scrollWidth > n.clientWidth && getComputedStyle(n).textOverflow === 'ellipsis')
                && /^0:\d{2}$/.test(usageVerify.text('[data-service=claude] [data-column=session] .hp-usage-reset'))
                && usageVerify.all('[data-service=claude] [data-column=other] .hp-usage-reset').every(n =>
                    /^\d+日(\d+時間)?$/.test(n.textContent) && /\d+\/\d+\(.+\) \d{2}:\d{2}にリセット/.test(n.title))
                """), "panel UI: model-specific and nonstandard limits stack with names, short countdowns and exact reset tooltips");
            Check(await Js("""
                usageVerify.text('[data-service=gemini] .hp-usage-action') === '設定を開く'
                && usageVerify.text('[data-service=gemini]').includes('サインインしていません')
                && !usageVerify.one('[data-service=gemini] .hp-usage-bar')
                && usageVerify.text('[data-service=muse] .hp-usage-error') === '使用状況の応答を読み取れませんでした（サービス側の変更の可能性があります）。'
                && usageVerify.reasonFits('muse')
                && !usageVerify.one('[data-service=muse] .hp-usage-bar')
                """), "panel UI: signed-out and error rows keep their guidance without percentage bars");
            Check(await Js("""
                usageVerify.values('antigravity') === '100%|94.9%'
                && usageVerify.all('.hp-usage-updated').length === 1 && /^\d{2}:\d{2} 更新$/.test(usageVerify.text('.hp-usage-updated'))
                && !/更新|Max 5x|Gemini 4 Hydrogen|経過/.test(usageVerify.text('.hp-usage-body'))
                && !usageVerify.one('.hp-usage-pace, .hp-usage-plan, .hp-usage-model')
                """), "panel UI: Antigravity shows remaining percentages and only the header shows update time");
            const string apiChip = ".hp-usage-chip[data-balance-service=claude-api]";
            Check(await Js($"""
                usageVerify.all('{apiChip}').length === 1
                && usageVerify.text('{apiChip} .hp-usage-balance-amount') === '$112.34'
                && ['API credit (Max)', '$100.00', '$12.34', '<$0.01', 'まで（あと'].every(s => usageVerify.one('{apiChip}').title.includes(s))
                """), "panel UI: Claude API total preserves plan, bought credits, sub-cent precision and expiry in the tooltip");
            Check(await Js("""
                usageVerify.all('.hp-usage-chip[data-balance-service=codex] .hp-usage-balance-amount').map(n => n.textContent).join('|')
                    === '12,345.68|無制限|読み取れません'
                && usageVerify.text('.hp-usage-chip[data-balance-service=colab] .hp-usage-balance-amount') === '87.6'
                && !usageVerify.one('.hp-usage-service[data-service=colab], .hp-usage-service[data-service=claude-api]')
                """), "panel UI: balance-only services appear as chips only, preserving amounts and unavailable/unlimited states");
            Check(await Js("""
                usageVerify.all('.hp-usage-limit').every(limit => usageVerify.resetFits(limit))
                && (() => {
                    const limit = usageVerify.one('[data-service=claude] [data-column=session] .hp-usage-limit');
                    return limit.querySelector('.hp-usage-reset').getBoundingClientRect().bottom
                        <= limit.querySelector('.hp-usage-bar').getBoundingClientRect().top;
                })()
                """), "panel UI: list percentages remain fully visible with at least 6 CSS px before an inline countdown");
            Check(await Js("""
                (() => {
                    const root = document.documentElement;
                    const previous = root.dataset.textSize;
                    try {
                        root.dataset.textSize = 'extraLarge';
                        const limit = usageVerify.one('[data-service=antigravity] [data-column=weekly] .hp-usage-limit');
                        return limit.querySelector('.hp-usage-value').textContent === '94.9%'
                            && limit.querySelector('.hp-usage-reset').getBoundingClientRect().top >= limit.querySelector('.hp-usage-bar').getBoundingClientRect().bottom
                            && usageVerify.all('.hp-usage-limit').every(item => usageVerify.resetFits(item))
                            && usageVerify.reasonFits('muse') && usageVerify.fit();
                    } finally {
                        root.dataset.textSize = previous;
                    }
                })()
                """), "panel UI: crowded countdowns move below the bar and the full error still fits at the largest text size");
            Check(await Js("usageVerify.fit()"), "panel UI: list fits at the minimum panel width");
            Check(await Js("usageVerify.scrollingList()"), "panel UI: the list scrolls without a scrollbar and the opaque column header stays at the top");
            await Capture(web, "panel");
            await web.ExecuteScriptAsync("usageVerify.one('.hp-usage-body').scrollTop = 10000");
            await Task.Delay(150, timeout.Token);
            await Capture(web, "panel-bottom");

            await web.ExecuteScriptAsync("usageVerify.one('[data-sort-column=session]').click()");
            await WaitFor(Ordered("claude,codex,antigravity,gemini,muse"));
            Check(await Js("usageVerify.sort()?.getAttribute('aria-sort') === 'ascending' && !usageVerify.one('.hp-usage-handle')"),
                "panel UI: first session sort is ascending and hides dragging");
            Check(await Js("usageVerify.reasonFits('muse')"), "panel UI: an error without values aligns with the session column even when sorted");
            await web.ExecuteScriptAsync("usageVerify.one('[data-sort-column=session]').click()");
            await WaitFor(Ordered("antigravity,codex,claude,gemini,muse"));
            Check(await Js("usageVerify.sort()?.getAttribute('aria-sort') === 'descending'"), "panel UI: second click is descending; missing rows remain last");
            await web.ExecuteScriptAsync("usageVerify.one('[data-sort-column=other]').click()");
            await WaitFor("usageVerify.sort()?.querySelector('[data-sort-column=other]') !== null && usageVerify.sort()?.getAttribute('aria-sort') === 'ascending'");
            Check(await Js(Ordered(defaultListOrder)), "panel UI: a new sort starts ascending and Other uses the smallest value in the cell");
            await web.ExecuteScriptAsync("usageVerify.one('[data-sort-column=other]').click()");
            await WaitFor(Ordered(listAfterDrag));
            Check(await Js("usageVerify.sort()?.getAttribute('aria-sort') === 'descending'"), "panel UI: Other switches direction and preserves missing-row order");
            await web.ExecuteScriptAsync("usageVerify.one('.hp-usage-sort-reset').click()");
            await WaitFor($"!!usageVerify.one('.hp-usage-handle') && {Ordered(defaultListOrder)}");
            Check(await Js("!usageVerify.sort()"), "panel UI: Back to my order restores the custom order");

            await web.ExecuteScriptAsync("usageVerify.drag('claude','codex')");
            await WaitFor(Ordered(listAfterDrag));
            Check(store.Load(ProviderRegistry.CreateDefault().ProviderIds).AiUsageServiceOrder.SequenceEqual(listDragOrder.Split(',')),
                "panel UI: a list drag saves the new custom order");

            await web.ExecuteScriptAsync("usageVerify.one('[data-sort-column=weekly]').click()");
            await WaitFor("usageVerify.sort()?.querySelector('[data-sort-column=weekly]') != null");
            await web.ExecuteScriptAsync("usageVerify.one('[data-view=meter]').click()");
            await WaitFor($"!!usageVerify.one('.hp-usage-meter-grid') && {Ordered(listDragOrder)}");
            Check(await Js("""
                usageVerify.all('.hp-usage-meter').every(n => {
                    const svg = n.querySelector('svg');
                    const style = getComputedStyle(svg);
                    return n.offsetWidth === 116 && n.offsetHeight === 100
                        && style.width === '116px' && style.height === '100px';
                })
                """), "panel UI: each rendered SVG gauge is 116 × 100 CSS px");
            Check(await Js("""
                usageVerify.all('.hp-usage-meter .hp-usage-limit-name').every(n => n.offsetWidth <= 60)
                && (() => {
                    const model = 'GPT-5.3-Codex-Spark';
                    const gauges = usageVerify.all('[data-service=codex] .hp-usage-meter').filter(n => n.dataset.label.startsWith(model));
                    const durations = ['5時間', '1週間'];
                    return gauges.length === 2 && gauges.every((gauge, i) => {
                        const name = gauge.querySelector('.hp-usage-limit-name');
                        const detail = gauge.querySelector('.hp-usage-meter-detail');
                        const reset = detail?.querySelector('.hp-usage-reset');
                        const title = model + ' ' + durations[i];
                        return name.textContent === model && name.scrollWidth > name.clientWidth
                            && getComputedStyle(name).textOverflow === 'ellipsis'
                            && !!reset?.textContent && !!reset.title
                            && detail.textContent === durations[i] + ' · ' + reset.textContent
                            && detail.getBoundingClientRect().top >= name.getBoundingClientRect().bottom
                            && detail.scrollWidth <= detail.clientWidth && detail.offsetWidth <= gauge.offsetWidth
                            && gauge.title === title && gauge.getAttribute('aria-label').startsWith(title + ' ');
                    });
                })()
                """), "panel UI: long gauge names fit the opening; repeated durations sit beside the countdown below and remain in the full title");
            Check(await Js("""
                usageVerify.all('[data-service=claude] .hp-usage-meter').map(n => n.dataset.label).join('|') === '5時間|1週間|Fable|3日'
                && usageVerify.all('[data-service=claude] .hp-usage-meter-number').map(n => n.textContent).join('|') === '68%|70%|15%|25%'
                && usageVerify.all('[data-service=claude] .hp-usage-meter-value').map(n => n.getAttribute('stroke')).join('|') === '#5fd08a|#5aa9ff|#ff7c7c|#f5c35b'
                && usageVerify.all('[data-service=claude] .hp-usage-meter').every(n => {
                    const path = n.querySelector('.hp-usage-meter-value');
                    const track = n.querySelector('svg path');
                    return Math.abs(path.getTotalLength() / track.getTotalLength() * 100 - parseFloat(n.dataset.percent)) < 0.1
                        && path.getAttribute('stroke-dasharray') === '2.6 1.3'
                        && n.querySelector('.hp-usage-needle') && n.getAttribute('aria-label').includes(n.dataset.percent);
                })
                && !usageVerify.one('.hp-usage-legend')
                """), "panel UI: SVG gauges show the same remaining values and colors, proportional arcs, needles and accessible names");
            Check(await Js("""
                usageVerify.text('[data-service=colab] .hp-usage-balance-amount') === '87.6 CU'
                && usageVerify.text('[data-service=colab] .hp-usage-balance-detail') === 'いまは消費していません'
                && usageVerify.text('[data-service=codex] .hp-usage-balance-amount') === '12,345.68 CR'
                && usageVerify.text('[data-service=claude-api] .hp-usage-balance-amount') === '$112.34'
                && /\d+\/\d+まで/.test(usageVerify.text('[data-service=claude-api] .hp-usage-balance-detail'))
                && !usageVerify.one('[data-service=claude-api] svg, [data-service=colab] svg')
                """), "panel UI: meter balances keep units, expiry and detailed consumption without drawing gauges");
            Check(await Js("usageVerify.fit() && !/更新|Max 5x|Gemini 4 Hydrogen|経過/.test(usageVerify.text('.hp-usage-body'))"),
                "panel UI: fixed-size meters wrap at minimum width and omit the previous card metadata");
            await Capture(web, "panel-meter");

            await web.ExecuteScriptAsync("usageVerify.drag('muse','claude')");
            await WaitFor(Ordered(meterDragOrder));
            await Select("timer");
            await WaitFor("!usageVerify.one('.hp-usage')");
            await Select("ai-usage");
            await WaitFor($"!!usageVerify.one('.hp-usage-meter-grid') && {Ordered(meterDragOrder)}");
            var saved = new UserSettingsStore(store.RootDirectory).Load(ProviderRegistry.CreateDefault().ProviderIds);
            Check(saved.AiUsageView == "meter" && saved.AiUsageSort == new AiUsageListSort("weekly", "asc")
                && saved.AiUsageServiceOrder.SequenceEqual(meterDragOrder.Split(',')), "panel UI: reopen and disk readback preserve meter, sort and drag order");
            await web.ExecuteScriptAsync("usageVerify.one('[data-view=list]').click()");
            await WaitFor("usageVerify.sort()?.querySelector('[data-sort-column=weekly]') != null");
            await web.ExecuteScriptAsync("usageVerify.one('.hp-usage-sort-reset').click()");
            await WaitFor($"!!usageVerify.one('.hp-usage-handle') && {Ordered(listAfterMeterDrag)}");

            var service = controller.AiUsageForVerify!;
            async Task ReadAntigravity(AiUsageResult result, bool newAccount = true)
            {
                readings["antigravity"] = result;
                if (newAccount) service.BeginAccountChange("antigravity");
                await service.RefreshAsync(["antigravity"], force: true);
            }
            const string oldReading = "usageVerify.text('[data-service=antigravity] .hp-usage-old').endsWith('の値')";
            await ReadAntigravity(AiUsageResult.Failure(AiUsageErrorCodes.PeerMissing), newAccount: false);
            await WaitFor(oldReading);
            Check(await Js("""
                usageVerify.text('[data-service=antigravity] .hp-usage-error') === '前回の値を表示中。Gemini Peerを起動すると最新の値を取得できます。'
                && usageVerify.reasonFits('antigravity')
                && /^\d{2}:\d{2} の値$/.test(usageVerify.text('[data-service=antigravity] .hp-usage-old'))
                && (() => {
                    const stamp = usageVerify.one('[data-service=antigravity] .hp-usage-old');
                    return stamp.getBoundingClientRect().top >= stamp.previousElementSibling.getBoundingClientRect().bottom;
                })()
                && usageVerify.values('antigravity') === '100%|94.9%'
                && (() => {
                    const row = usageVerify.one('[data-service=antigravity]');
                    return usageVerify.haveOpacity(row, '.hp-usage-value, .hp-usage-bar', 0.5)
                        && usageVerify.haveOpacity(row, '.hp-usage-service-name, .hp-usage-reset', 1);
                })()
                """), "panel UI: a stopped peer shows the new guidance and dims only the old percentages and bars");
            await web.ExecuteScriptAsync("usageVerify.one('[data-service=antigravity]').scrollIntoView({block:'center'})");
            await Task.Delay(150, timeout.Token);
            await Capture(web, "panel-antigravity-stopped");

            await ReadAntigravity(AiUsageResult.StaleReading(new AiUsageReading("Gemini 4 Hydrogen (High)", [
                new AiUsageWindow("antigravity:gemini-5h", "session", null, 0, DateTimeOffset.UtcNow.AddHours(2), 300, State: "unreadable"),
                new AiUsageWindow("antigravity:gemini-weekly", "weekly", null, 40, DateTimeOffset.UtcNow.AddDays(3), 10080),
                new AiUsageWindow("antigravity:model-5h", "session", "Example Model", 0, DateTimeOffset.UtcNow.AddHours(1), 300, State: "unreadable"),
                new AiUsageWindow("antigravity:model-weekly", "weekly", "Example Model", 27, DateTimeOffset.UtcNow.AddDays(3), 10080)],
                ObservedAt: DateTimeOffset.UtcNow.AddHours(-2)), AiUsageErrorCodes.Stale));
            await WaitFor("usageVerify.values('antigravity') === '60%|73%'");
            Check(await Js(oldReading + """
                 && usageVerify.text('[data-service=antigravity] .hp-usage-error') === '古い値です（読み直せていません）。少し待って更新してください。'
                 && usageVerify.text('[data-service=antigravity] [data-column=session]') === '取得できません'
                 && !usageVerify.one('[data-service=antigravity] [data-column=session] [role=meter]')
                 && usageVerify.haveOpacity(usageVerify.one('[data-service=antigravity]'), '.hp-usage-limit-name, .hp-usage-reset', 1)
                """), "panel UI: stale readings keep their reason and full-opacity window names and countdowns; unreadable windows have no bar");
            await web.ExecuteScriptAsync("usageVerify.one('[data-view=meter]').click()");
            await WaitFor("!!usageVerify.one('[data-service=antigravity] .hp-usage-meter')");
            Check(await Js("""
                (() => {
                    const card = usageVerify.one('[data-service=antigravity]');
                    const gauges = [...card.querySelectorAll('.hp-usage-meter')];
                    const unreadable = gauges.filter(n => n.dataset.percent === '');
                    const opacity = (selector, expected) => usageVerify.haveOpacity(card, selector, expected);
                    return opacity('.hp-usage-meter[data-percent]:not([data-percent=""]) .hp-usage-meter-number, .hp-usage-meter-value', 0.5)
                        && opacity('.hp-usage-limit-name, .hp-usage-meter-detail, .hp-usage-reset, .hp-usage-needle, svg', 1)
                        && unreadable.length === 2
                        && unreadable.every(n => n.querySelector('.hp-usage-meter-number').textContent === '—'
                            && n.getAttribute('aria-label').includes('取得できません') && n.title.includes('取得できません')
                            && !n.querySelector('.hp-usage-unavailable, .hp-usage-meter-value, .hp-usage-needle, .hp-usage-reset'))
                        && !unreadable[0].querySelector('.hp-usage-meter-detail')
                        && unreadable[1].querySelector('.hp-usage-limit-name').textContent === 'Example Model'
                        && unreadable[1].querySelector('.hp-usage-meter-detail').textContent === '5時間'
                        && unreadable[1].getAttribute('aria-label').startsWith('Example Model 5時間 ');
                })()
                """), "panel UI: old gauges dim percentages and value arcs; unreadable gauges keep their hint and show only a repeated duration below the name");
            await web.ExecuteScriptAsync("usageVerify.one('[data-view=list]').click()");
            await WaitFor("!!usageVerify.one('.hp-usage-list')");

            AiUsageResult AntigravityReading(double used, DateTimeOffset observedAt) =>
                AiUsageResult.Success(new AiUsageReading("Gemini 4 Hydrogen (High)", [
                    new AiUsageWindow("antigravity:gemini-weekly", "weekly", null, used, DateTimeOffset.UtcNow.AddDays(3), 10080)], ObservedAt: observedAt));
            await ReadAntigravity(AntigravityReading(7, DateTimeOffset.UtcNow.AddMinutes(-6)));
            await WaitFor("usageVerify.values('antigravity') === '93%'");
            Check(await Js(oldReading + " && usageVerify.text('[data-service=antigravity] .hp-usage-error').startsWith('古い値です')"),
                "panel UI: a snapshot already past freshUntil is immediately shown as old");

            await ReadAntigravity(AntigravityReading(8, DateTimeOffset.UtcNow - AiUsageParsers.AntigravityFreshFor + TimeSpan.FromSeconds(4)), newAccount: false);
            await WaitFor("usageVerify.values('antigravity') === '92%'");
            var shownAsCurrent = await Js("usageVerify.one('[data-service=antigravity]').dataset.status === 'ok' && !usageVerify.one('[data-service=antigravity] .hp-usage-old')");
            var expiryDeadline = DateTimeOffset.UtcNow.AddSeconds(10);
            while (DateTimeOffset.UtcNow < expiryDeadline && !await Js(oldReading)) await Task.Delay(200, timeout.Token);
            Check(shownAsCurrent && await Js(oldReading), "panel UI: open panel turns old at freshUntil without waiting for the 30-second tick");

            await ReadAntigravity(AiUsageResult.StaleReading(new AiUsageReading("Gemini 4 Hydrogen (High)", [
                new AiUsageWindow("antigravity:gemini-5h", "session", null, 0, null, 300, State: "unreadable"),
                new AiUsageWindow("antigravity:gemini-weekly", "weekly", null, 0, null, 10080, State: "unreadable")],
                ObservedAt: DateTimeOffset.UtcNow.AddSeconds(-30)), AiUsageErrorCodes.NoValues));
            await WaitFor("usageVerify.all('[data-service=antigravity] .hp-usage-unavailable').length === 2");
            Check(await Js(oldReading + """
                 && usageVerify.text('[data-service=antigravity] .hp-usage-error') === '記録に利用枠の値がありませんでした。少し待って更新してください。'
                 && !usageVerify.one('[data-service=antigravity] .hp-usage-bar')
                """), "panel UI: a capture with no readable values stays marked old and shows the original reason");
            await ReadAntigravity(AiUsageResult.Failure(AiUsageErrorCodes.NoSnapshot));
            await WaitFor("usageVerify.text('[data-service=antigravity] .hp-usage-error').startsWith('Gemini Peerにまだ')");
            Check(await Js("""
                usageVerify.text('[data-service=antigravity] .hp-usage-error') === 'Gemini Peerにまだ利用枠の記録がありません。少し待って更新してください。'
                && usageVerify.reasonFits('antigravity') && !usageVerify.one('[data-service=antigravity] .hp-usage-bar')
                """), "panel UI: no snapshot draws no bar and keeps the original reason");

            const string peerReason = "usageVerify.text('[data-service=antigravity] .hp-usage-error')";
            await ReadAntigravity(AiUsageResult.Failure(AiUsageErrorCodes.PeerMissing));
            await WaitFor(peerReason + ".includes('Gemini Peerを起動')");
            Check(await Js(peerReason + " === 'Gemini Peerを起動すると最新の値を取得できます。' && usageVerify.reasonFits('antigravity')"),
                "panel UI: PeerMissing with no saved values has the new guidance and no previous-reading prefix");
            await ChangePanelState("settings.setLanguage", new { language = "en" });
            await WaitFor("usageVerify.text('[data-view=list]') === 'List'");
            await WaitFor(peerReason + ".includes('Gemini Peer')");
            Check(await Js(peerReason + " === 'Start Gemini Peer to get the latest values.'"), "panel UI: PeerMissing has the new English guidance");
            await ChangePanelState("settings.setLanguage", new { language = "ja" });
            await WaitFor("usageVerify.text('[data-view=list]') === '一覧'");

            await ReadAntigravity(AntigravityReading(5.1, DateTimeOffset.UtcNow));
            service.BeginAccountChange("colab");
            const string loadingColab = "usageVerify.text('[data-service=colab] .hp-usage-message') === '読み込み中…'";
            await WaitFor(loadingColab);
            Check(await Js(loadingColab + " && !usageVerify.one('.hp-usage-chip[data-balance-service=colab]')"),
                "panel UI: a balance-only service still gets a row while awaiting its first reading");
            await service.RefreshAsync(["colab"], force: true);
            await WaitFor(Ordered(listAfterMeterDrag));
            await VerifySettingsUiAsync(controller, store, log);
            const string listSettingsOrder = "claude,muse,codex,gemini,antigravity";
            await WaitFor(Ordered(listSettingsOrder));
            Check(await Js(Ordered(listSettingsOrder)), "panel UI: Settings moves update the open list");
            await web.ExecuteScriptAsync("usageVerify.one('[data-view=meter]').click()");
            await WaitFor($"!!usageVerify.one('.hp-usage-meter-grid') && {Ordered(settingsOrder)}");
            Check(await Js(Ordered(settingsOrder)), "panel UI: the meter reflects the same Settings order");
            log("PASS ai-usage panel UI rendered in WebView2");
        }
        finally
        {
            attachment?.Dispose();
            window.Close();
            web.Dispose();
        }
    }

    private async Task VerifySettingsUiAsync(PanelBridgeController controller, UserSettingsStore store, Action<string> log)
    {
        var window = new SettingsWindow(controller, false, Path.Combine(store.RootDirectory, "SettingsWebView"), false)
        { Left = -20000, Top = -20000, Width = 940, Height = 900, WindowStartupLocation = WindowStartupLocation.Manual, ShowActivated = false };
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        try
        {
            window.Show();
            while (window.WebViewForVerify?.CoreWebView2 is null
                || await window.WebViewForVerify.ExecuteScriptAsync("document.querySelectorAll('.ai-usage-settings-row').length === 7") != "true")
                await Task.Delay(100, timeout.Token);
            var web = window.WebViewForVerify;
            await web.ExecuteScriptAsync("document.querySelector('[data-category=ai]').click(); document.querySelector('[data-ai-usage-settings]').scrollIntoView({block:'start'})");
            async Task<bool> Js(string expression) => await web.ExecuteScriptAsync(expression) == "true";
            Check(await Js("!document.querySelector('[data-ai-usage-settings]').hidden"), "settings UI: AI usage section under the AI category");
            Check(await Js("document.querySelector('[data-ai-usage-settings] [data-service=claude] .ai-usage-settings-state').textContent === 'サインイン済み · Max 5x'"),
                "settings UI: signed-in state with plan");
            Check(await Js("[...document.querySelectorAll('[data-ai-usage-settings] [data-service=gemini] button')].some(b => b.textContent === 'サインイン')"),
                "settings UI: sign-in button for a signed-out service");
            Check(await Js("document.querySelectorAll('[data-ai-usage-settings] [data-service=codex] button:not([data-move])').length === 0"),
                "settings UI: no sign-in button while Codex is signed in");
            Check(await Js("[...document.querySelectorAll('[data-ai-usage-settings] input[type=checkbox]')].every(i => i.checked)"), "settings UI: all services shown by default");
            Check(await Js("document.querySelectorAll('[data-ai-usage-settings] [data-service=colab] button:not([data-move])').length === 0 && document.querySelector('[data-ai-usage-settings] [data-service=colab]').textContent.includes('Gemini')"),
                "settings UI: Colab uses the Gemini sign-in, with no buttons of its own");
            Check(await Js("[...document.querySelectorAll('[data-ai-usage-settings] [data-service=\"claude-api\"] button')].some(b => b.textContent === 'サインインし直す')"),
                "settings UI: Claude API has its own sign-in");
            Check(await Js("[...document.querySelectorAll('[data-ai-usage-settings] [data-service=gemini] button')].some(b => b.textContent === 'サインアウト')"),
                "settings UI: Gemini offers sign-out while Colab still reads with its Google sign-in");
            Check(await Js("document.querySelectorAll('[data-ai-usage-settings] [data-service=antigravity] button:not([data-move])').length === 0"
                + " && document.querySelector('[data-ai-usage-settings] [data-service=antigravity] .ai-usage-settings-state').textContent === 'Gemini Peerから取得 · Gemini 4 Hydrogen (High)'"
                + " && document.querySelector('[data-ai-usage-settings] [data-service=antigravity]').textContent.includes('サインインは要りません')"),
                "settings UI: Antigravity is read from the Gemini Peer, with no sign-in buttons");
            const string order = "[...document.querySelectorAll('.ai-usage-settings-row')].map(n => n.dataset.service).join(',')";
            Check(await Js(order + " === 'muse,claude,codex,claude-api,gemini,antigravity,colab'"), "settings UI: order matches the panel drag");
            Check(await Js("""
                [...document.querySelectorAll('.ai-usage-settings-row')].every(row => {
                    const toggle = row.querySelector('input[type=checkbox]').getBoundingClientRect();
                    const moves = [...row.querySelectorAll('button[data-move]')];
                    return moves.length === 2 && moves.every((button, index) => {
                        const box = button.getBoundingClientRect();
                        return button.closest('.ai-usage-settings-heading') === row.firstElementChild
                            && !button.closest('.settings-button-row')
                            && button.textContent === ['↑', '↓'][index]
                            && button.getAttribute('aria-label') === ['上へ', '下へ'][index]
                            && button.offsetWidth === 24 && button.offsetHeight === 24
                            && box.right <= toggle.left && box.top < toggle.bottom && box.bottom > toggle.top;
                    });
                })
                """), "settings UI: small named arrow buttons sit beside the switch rather than with sign-in actions");
            var providerIds = ProviderRegistry.CreateDefault().ProviderIds;
            var originalOrder = store.Load(providerIds).AiUsageServiceOrder;
            Check(await Js("""
                (() => {
                    const up = document.querySelector('.ai-usage-settings-row:first-child [data-move=up]');
                    const down = document.querySelector('.ai-usage-settings-row:last-child [data-move=down]');
                    up.click();
                    down.click();
                    return up.disabled && down.disabled
                        && [up, down].every(button => Number(getComputedStyle(button).opacity) < 1);
                })()
                """) && store.Load(providerIds).AiUsageServiceOrder.SequenceEqual(originalOrder),
                "settings UI: end arrows are dimmed, disabled, and clicking them leaves the order unchanged");
            await web.ExecuteScriptAsync("document.querySelector('.ai-usage-settings-row[data-service=codex] [data-move=up]').click()");
            while (!await Js(order + " === 'muse,codex,claude,claude-api,gemini,antigravity,colab'")) await Task.Delay(100, timeout.Token);
            Check(store.Load(providerIds).AiUsageServiceOrder.Take(3).SequenceEqual(["muse", "codex", "claude"]), "settings UI: Move up is saved");
            await web.ExecuteScriptAsync("document.querySelector('.ai-usage-settings-row[data-service=codex] [data-move=down]').click()");
            while (!await Js(order + " === 'muse,claude,codex,claude-api,gemini,antigravity,colab'")) await Task.Delay(100, timeout.Token);
            await web.ExecuteScriptAsync("document.querySelector('.ai-usage-settings-row[data-service=muse] [data-move=down]').click()");
            while (!await Js(order + " === 'claude,muse,codex,claude-api,gemini,antigravity,colab'")) await Task.Delay(100, timeout.Token);
            Check(store.Load(providerIds).AiUsageServiceOrder.Take(3).SequenceEqual(["claude", "muse", "codex"]), "settings UI: Move down is saved");
            await Task.Delay(150, timeout.Token);
            await Capture(web, "settings");
            log("PASS ai-usage Settings UI rendered in WebView2");
        }
        finally
        {
            window.Close();
            window.WebViewForVerify?.Dispose();
        }
    }

    private static async Task Capture(WebView2 web, string name)
    {
        var folder = Environment.GetEnvironmentVariable("HOVERPOCKET_AI_USAGE_SNAPSHOT_DIR");
        if (string.IsNullOrEmpty(folder)) return;
        Directory.CreateDirectory(folder);
        await using var output = File.Create(Path.Combine(folder, $"ai-usage-{name}.png"));
        await web.CoreWebView2.CapturePreviewAsync(CoreWebView2CapturePreviewImageFormat.Png, output);
    }

    private static string ResolveUiFolder()
    {
        var output = Path.Combine(AppContext.BaseDirectory, "ui");
        if (File.Exists(Path.Combine(output, "index.html"))) return output;
        for (var current = new DirectoryInfo(Directory.GetCurrentDirectory()); current is not null; current = current.Parent)
        {
            var candidate = Path.Combine(current.FullName, "windows", "ui");
            if (File.Exists(Path.Combine(candidate, "index.html"))) return candidate;
        }
        throw new DirectoryNotFoundException("ui folder not found");
    }

    /// <summary>
    /// Debug aid: reads the real services once. The web profile lives in a fixed temp folder so a
    /// sign-in survives between runs. <c>HOVERPOCKET_AI_USAGE_SIGNIN=&lt;service[,service]&gt;</c> opens those
    /// sign-in windows first; <c>HOVERPOCKET_AI_USAGE_CODEX_ROOT</c> selects the Codex profile.
    /// Only percentages, reset times and plan names are printed.
    /// </summary>
    public static async Task<int> RunLiveAsync(Action<string> log)
    {
        var root = Path.Combine(Path.GetTempPath(), "HoverPocket", "AiUsageLive");
        var codexRoot = Environment.GetEnvironmentVariable("HOVERPOCKET_AI_USAGE_CODEX_ROOT");
        if (string.IsNullOrWhiteSpace(codexRoot)) codexRoot = Path.Combine(root, "CodexVoice");
        using var service = new AiUsageService(codexRoot, Path.Combine(root, "AiUsageWebView2"));
        using var timeout = new CancellationTokenSource(TimeSpan.FromMinutes(30));
        var smokeFailed = Environment.GetEnvironmentVariable("HOVERPOCKET_AI_USAGE_SIGNIN_SMOKE") == "1"
            && !await SignInWindowSmokeAsync(Path.Combine(root, "AiUsageWebView2"), log, timeout.Token);
        // A comma-separated list opens each sign-in window in turn, e.g. "claude,gemini,muse".
        var signIn = Environment.GetEnvironmentVariable("HOVERPOCKET_AI_USAGE_SIGNIN") ?? string.Empty;
        foreach (var target in signIn.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            if (target != AiUsageServiceIds.Codex)
            {
                await service.SignInAsync(target, null, false, timeout.Token);
                continue;
            }
            // Same flow as Settings > Sign in to ChatGPT: the browser opens OpenAI's login page.
            using var login = new HoverPocket.Shell.Voice.CodexVoiceAccountLogin();
            await login.StartAsync(codexRoot, timeout.Token);
            while (login.Status == "waiting") await Task.Delay(200, timeout.Token);
            log($"codex login: {login.Status}");
        }
        var only = Environment.GetEnvironmentVariable("HOVERPOCKET_AI_USAGE_ONLY");
        IReadOnlyCollection<string> services = string.IsNullOrWhiteSpace(only)
            ? AiUsageServiceIds.All
            : only.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        if (services.Count == 0 || services.Any(id => !AiUsageServiceIds.IsKnown(id)))
        {
            log("FAIL unknown service in HOVERPOCKET_AI_USAGE_ONLY; use " + string.Join(", ", AiUsageServiceIds.All));
            return 2;
        }
        var started = DateTimeOffset.UtcNow;
        var foreground = GetForegroundWindow();
        await service.RefreshAsync(services, force: true, timeout.Token);
        log($"ai-usage live read in {(DateTimeOffset.UtcNow - started).TotalSeconds:F1}s; foreground window unchanged: {GetForegroundWindow() == foreground}");
        log(JsonSerializer.Serialize(service.BuildState([]), new JsonSerializerOptions(BridgeJson.Options) { WriteIndented = true }));
        return smokeFailed || services.Any(id => service.Snapshot(id).Status != AiUsageStatus.Ok) ? 1 : 0;
    }

    /// <summary>Opens each sign-in window off screen without activation and reports where it landed.</summary>
    private static async Task<bool> SignInWindowSmokeAsync(string webFolder, Action<string> log, CancellationToken cancellationToken)
    {
        var passed = true;
        foreach (var service in AiUsageServiceIds.Web)
        {
            var foreground = GetForegroundWindow();
            var window = new AiUsageSignInWindow(service, webFolder, AiUsageWebReader.SignInUri(service), false)
            {
                WindowStartupLocation = WindowStartupLocation.Manual, Left = -20000, Top = -20000, ShowActivated = false, ShowInTaskbar = false
            };
            try
            {
                window.Show();
                var core = await window.Ready.WaitAsync(TimeSpan.FromSeconds(30), cancellationToken);
                await Task.Delay(TimeSpan.FromSeconds(8), cancellationToken);
                var host = Uri.TryCreate(core.Source, UriKind.Absolute, out var uri) ? uri.Host : "(none)";
                var hasPasswordOrEmail = await core.ExecuteScriptAsync("!!document.querySelector('input[type=email],input[type=password],input[name=identifier],input[name=email]')");
                var ok = AiUsageWebReader.IsExpectedSignInHost(service, host) && window.AddressTextForVerify.Contains("https://" + host, StringComparison.Ordinal);
                passed &= ok;
                log($"{(ok ? "PASS" : "FAIL")} sign-in window {service}: host={host} loginField={hasPasswordOrEmail} foregroundUnchanged={GetForegroundWindow() == foreground} address=\"{window.AddressTextForVerify}\"");
            }
            finally
            {
                window.Close();
            }
        }
        return passed;
    }

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();
}
