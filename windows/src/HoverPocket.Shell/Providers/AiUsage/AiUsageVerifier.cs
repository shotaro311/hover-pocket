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
        Check(services.Count == 6 && Service("muse")["visible"]!.GetValue<bool>() == false && Service("codex")["signIn"]!.GetValue<string>() == "codex"
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
            AiUsageHiddenServices = ["muse", "unknown", "muse"]
        };
        var normalized = UserSettingsStore.Normalize(old, providers.ProviderIds);
        Check(normalized.ProviderOrder[^1] == "ai-usage" && normalized.ProviderVisibility["ai-usage"], "settings: existing users get the new tool at the end, visible");
        Check(normalized.AiUsageHiddenServices.SequenceEqual(["muse"]), "settings: hidden services keep only known ids");
        var clone = normalized.Clone();
        clone.AiUsageHiddenServices.Add("codex");
        Check(normalized.AiUsageHiddenServices.Count == 1, "settings: clone copies the hidden list");
        var store = UserSettingsStore.CreateTemporary("AiUsageSettingsVerify");
        store.Save(normalized);
        Check(store.Load(providers.ProviderIds).AiUsageHiddenServices.SequenceEqual(["muse"]), "settings: hidden services persist");
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
                new AiUsageWindow("codex:spark:primary", "session", "GPT-5.3-Codex-Spark", 3, now.AddHours(2), 300)])),
            ["claude"] = AiUsageResult.Success(new AiUsageReading("Max 5x", [
                new AiUsageWindow("claude:session", "session", null, 32, now.AddMinutes(55), 300),
                new AiUsageWindow("claude:weekly_all", "weekly", null, 30, now.AddDays(5), 10080),
                new AiUsageWindow("claude:weekly_scoped:Fable", "weekly", "Fable", 85, now.AddDays(5), 10080)])),
            ["claude-api"] = AiUsageResult.Success(new AiUsageReading(null, [], [
                new AiUsageBalance("planCredit", "API credit (Max)", 100m, "usd", now.AddDays(24)),
                new AiUsageBalance("purchasedCredit", null, 12.34m, "usd", now.AddDays(26)),
                new AiUsageBalance("purchasedCredit", null, 0.004m, "usd", now.AddDays(90))])),
            ["gemini"] = AiUsageResult.SignedOut(),
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
        Check(initial["result"]?["services"]?.AsArray().Count == 6, "bridge: panel reads the usage state");
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

        await VerifyPanelUiAsync(controller, store, log);
        await VerifySettingsUiAsync(controller, store, log);

        var hidden = await Call(settings, "aiUsage.setVisible", new { service = "muse", visible = false });
        Check(hidden["result"]?["services"]?.AsArray().Single(node => node!["id"]!.GetValue<string>() == "muse")?["visible"]?.GetValue<bool>() == false
            && controller.CurrentSettings.AiUsageHiddenServices.SequenceEqual(["muse"])
            && store.Load(providers.ProviderIds).AiUsageHiddenServices.SequenceEqual(["muse"]), "bridge: hiding a service is saved");
    }

    private async Task VerifyPanelUiAsync(PanelBridgeController controller, UserSettingsStore store, Action<string> log)
    {
        var window = new Window
        {
            Left = -20000, Top = -20000, Width = 680, Height = 520, ShowActivated = false, ShowInTaskbar = false,
            WindowStartupLocation = WindowStartupLocation.Manual, WindowStyle = WindowStyle.None
        };
        var web = new WebView2 { CreationProperties = new CoreWebView2CreationProperties { UserDataFolder = Path.Combine(store.RootDirectory, "PanelWebView") } };
        window.Content = web;
        IDisposable? attachment = null;
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        try
        {
            window.Show();
            await web.EnsureCoreWebView2Async();
            var dispatcher = new BridgeDispatcher(json => { web.CoreWebView2.PostWebMessageAsJson(json); return Task.CompletedTask; });
            attachment = controller.Attach(dispatcher, BridgeSurface.Panel, () => window);
            web.CoreWebView2.WebMessageReceived += async (_, args) => await dispatcher.HandleRawMessageAsync(args.TryGetWebMessageAsString());
            web.CoreWebView2.SetVirtualHostNameToFolderMapping("app.hoverpocket.local", ResolveUiFolder(), CoreWebView2HostResourceAccessKind.DenyCors);
            web.CoreWebView2.Navigate("https://app.hoverpocket.local/index.html");
            while (await web.ExecuteScriptAsync("!!document.querySelector('[data-provider-icons] button')") != "true")
                await Task.Delay(100, timeout.Token);
            await dispatcher.ProcessRawMessageAsync("""{"id":"select","method":"provider.select","params":{"id":"ai-usage"}}""");
            await dispatcher.PostEventAsync("state.changed", controller.BuildState(BridgeSurface.Panel));
            while (await web.ExecuteScriptAsync("document.querySelectorAll('.hp-usage-card').length === 6") != "true")
                await Task.Delay(100, timeout.Token);
            async Task<bool> Js(string expression) => await web.ExecuteScriptAsync(expression) == "true";
            Check(await Js("document.querySelector('[data-provider-title]').textContent === 'AI Usage'"), "panel UI: title");
            Check(await Js("[...document.querySelectorAll('[data-service=claude] .hp-usage-label')].map(n => n.textContent).join('|') === '5時間|1週間|Fable · 1週間'"),
                "panel UI: Claude rows are 5-hour, weekly, and Fable weekly");
            Check(await Js("document.querySelectorAll('[data-service=claude] .hp-usage-row')[2].dataset.level === 'warn'"), "panel UI: 85% is highlighted");
            Check(await Js("document.querySelector('[data-service=claude] .hp-usage-plan').textContent === 'Max 5x'"), "panel UI: plan badge");
            Check(await Js("[...document.querySelectorAll('[data-service=codex] .hp-usage-label')].some(n => n.textContent === 'GPT-5.3-Codex-Spark · 5時間')"),
                "panel UI: Codex model bucket");
            Check(await Js("document.querySelector('[data-service=claude] .hp-usage-reset').textContent.includes('分でリセット')"), "panel UI: relative reset under a day");
            Check(await Js("/あと\\d+日(\\d+時間)?でリセット（/.test(document.querySelectorAll('[data-service=claude] .hp-usage-reset')[1].textContent)"),
                "panel UI: weekly reset shows the days left and the date");
            Check(await Js("document.querySelectorAll('[data-service=codex] .hp-usage-pace').length >= 2"), "panel UI: elapsed-time markers");
            Check(await Js("!!document.querySelector('[data-service=gemini] .hp-usage-action') && document.querySelector('[data-service=gemini]').textContent.includes('サインインしていません')"),
                "panel UI: signed-out card points to Settings");
            Check(await Js("document.querySelector('[data-service=muse] .hp-usage-error')?.textContent.includes('読み取れませんでした') && !document.querySelector('[data-service=muse] .hp-usage-row')"),
                "panel UI: error card shows a reason and no 0% bar");
            Check(await Js("document.querySelector('[data-service=\"claude-api\"]').textContent.includes('API credit (Max)') && document.querySelector('[data-service=\"claude-api\"]').textContent.includes('$100.00') && document.querySelector('[data-service=\"claude-api\"]').textContent.includes('$12.34')"),
                "panel UI: Claude API plan grant and purchased credits");
            Check(await Js("[...document.querySelectorAll('[data-service=\"claude-api\"] .hp-usage-value')].some(n => n.textContent === '<$0.01')"),
                "panel UI: a tiny positive credit reads <$0.01, not $0.00");
            Check(await Js("/まで（あと\\d+日）/.test(document.querySelector('[data-service=\"claude-api\"] .hp-usage-balance .hp-usage-reset').textContent)"), "panel UI: credit expiry with days left");
            Check(await Js("document.querySelector('[data-service=colab]').textContent.includes('87.6') && document.querySelector('[data-service=colab]').textContent.includes('いまは消費していません')"),
                "panel UI: Colab compute units and rate");
            Check(await Js("document.querySelector('[data-service=codex] .hp-usage-balance')?.textContent.includes('12,345.68')"), "panel UI: Codex credit count");
            Check(await Js("[...document.querySelectorAll('[data-service=codex] .hp-usage-balance .hp-usage-value')].map(n => n.textContent).join('|') === '12,345.68|無制限|読み取れません'"),
                "panel UI: unlimited and unreadable credits are shown as such, never 0");
            Check(await Js("!document.querySelector('[data-service=colab] .hp-usage-bar') && !document.querySelector('[data-service=\"claude-api\"] .hp-usage-bar')"), "panel UI: balances are amounts, not bars");
            Check(await Js("document.querySelector('.hp-usage').scrollWidth <= document.querySelector('.hp-usage').clientWidth"), "panel UI: no horizontal overflow");
            await Capture(web, "panel");
            await web.ExecuteScriptAsync("document.querySelector('.hp-usage').scrollTop = 10000");
            await Task.Delay(150, timeout.Token);
            await Capture(web, "panel-bottom");
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
                || await window.WebViewForVerify.ExecuteScriptAsync("document.querySelectorAll('.ai-usage-settings-row').length === 6") != "true")
                await Task.Delay(100, timeout.Token);
            var web = window.WebViewForVerify;
            await web.ExecuteScriptAsync("document.querySelector('[data-category=ai]').click(); document.querySelector('[data-ai-usage-settings]').scrollIntoView({block:'start'})");
            async Task<bool> Js(string expression) => await web.ExecuteScriptAsync(expression) == "true";
            Check(await Js("!document.querySelector('[data-ai-usage-settings]').hidden"), "settings UI: AI usage section under the AI category");
            Check(await Js("document.querySelector('[data-ai-usage-settings] [data-service=claude] .ai-usage-settings-state').textContent === 'サインイン済み · Max 5x'"),
                "settings UI: signed-in state with plan");
            Check(await Js("[...document.querySelectorAll('[data-ai-usage-settings] [data-service=gemini] button')].some(b => b.textContent === 'サインイン')"),
                "settings UI: sign-in button for a signed-out service");
            Check(await Js("[...document.querySelectorAll('[data-ai-usage-settings] [data-service=codex] button')].length === 0"),
                "settings UI: no sign-in button while Codex is signed in");
            Check(await Js("[...document.querySelectorAll('[data-ai-usage-settings] input[type=checkbox]')].every(i => i.checked)"), "settings UI: all services shown by default");
            Check(await Js("document.querySelectorAll('[data-ai-usage-settings] [data-service=colab] button').length === 0 && document.querySelector('[data-ai-usage-settings] [data-service=colab]').textContent.includes('Gemini')"),
                "settings UI: Colab uses the Gemini sign-in, with no buttons of its own");
            Check(await Js("[...document.querySelectorAll('[data-ai-usage-settings] [data-service=\"claude-api\"] button')].some(b => b.textContent === 'サインインし直す')"),
                "settings UI: Claude API has its own sign-in");
            Check(await Js("[...document.querySelectorAll('[data-ai-usage-settings] [data-service=gemini] button')].some(b => b.textContent === 'サインアウト')"),
                "settings UI: Gemini offers sign-out while Colab still reads with its Google sign-in");
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
            log("FAIL unknown service in HOVERPOCKET_AI_USAGE_ONLY; use codex, claude, gemini, muse");
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
