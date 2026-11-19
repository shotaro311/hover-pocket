using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace HoverPocket.Shell.Providers.AiUsage;

/// <summary>
/// Turns each service's raw usage response into windows. The responses are undocumented web
/// payloads, so every field is read defensively and an unexpected shape fails with
/// <see cref="AiUsageParseException"/> instead of producing a misleading 0%.
/// Field names follow live responses checked on 2026-11-18 and the MIT-licensed CodexBar
/// providers (github.com/steipete/CodexBar).
/// </summary>
internal static partial class AiUsageParsers
{
    private const int SessionMinutes = 300;
    private const int WeekMinutes = 7 * 24 * 60;
    private const int MaxWindows = 12;
    private const int MaxLabelLength = 40;

    public static AiUsageReading ParseCodex(JsonElement rateLimitsResponse, JsonElement? accountResponse)
    {
        if (rateLimitsResponse.ValueKind != JsonValueKind.Object)
            throw new AiUsageParseException("codex response is not an object");

        var buckets = new List<(string Key, JsonElement Snapshot)>();
        if (rateLimitsResponse.TryGetProperty("rateLimitsByLimitId", out var byId) && byId.ValueKind == JsonValueKind.Object)
        {
            foreach (var bucket in byId.EnumerateObject())
                if (bucket.Value.ValueKind == JsonValueKind.Object)
                    buckets.Add((bucket.Name, bucket.Value));
        }
        if (buckets.Count == 0 && rateLimitsResponse.TryGetProperty("rateLimits", out var single) && single.ValueKind == JsonValueKind.Object)
            buckets.Add((ReadString(single, "limitId") ?? "codex", single));
        if (buckets.Count == 0)
            throw new AiUsageParseException("codex response has no rate limits");

        // The ordinary Codex bucket first, then model-specific buckets in a stable order.
        buckets.Sort((left, right) =>
        {
            var leftMain = IsCodexMainBucket(left.Key) ? 0 : 1;
            var rightMain = IsCodexMainBucket(right.Key) ? 0 : 1;
            return leftMain != rightMain ? leftMain.CompareTo(rightMain) : string.CompareOrdinal(left.Key, right.Key);
        });

        var windows = new List<AiUsageWindow>();
        string? plan = null;
        foreach (var (key, snapshot) in buckets)
        {
            plan ??= CodexPlanName(ReadString(snapshot, "planType"));
            var model = IsCodexMainBucket(key) ? null : Clean(ReadString(snapshot, "limitName") ?? key);
            AddCodexWindow(windows, key, "primary", snapshot, model, fallbackKind: "session");
            AddCodexWindow(windows, key, "secondary", snapshot, model, fallbackKind: "weekly");
        }

        if (plan is null && accountResponse is { ValueKind: JsonValueKind.Object } account
            && account.TryGetProperty("account", out var accountValue) && accountValue.ValueKind == JsonValueKind.Object)
            plan = CodexPlanName(ReadString(accountValue, "planType"));

        if (windows.Count == 0)
            throw new AiUsageParseException("codex response has no usage windows");
        // Credits belong to the ordinary allowance: read them from the single-bucket view `rateLimits`,
        // or from the `codex` bucket when only the multi-bucket view is present.
        var ordinary = rateLimitsResponse.TryGetProperty("rateLimits", out var view) && view.ValueKind == JsonValueKind.Object
            ? view
            : buckets.FirstOrDefault(bucket => IsCodexMainBucket(bucket.Key)).Snapshot;
        return new AiUsageReading(plan, Limit(windows), CodexCredits(ordinary));
    }

    /// <summary>
    /// Codex credits extend usage after the plan's limits; the balance is a credit count, not dollars
    /// (learn.chatgpt.com/docs/pricing). No balance means no row; an unreadable balance is shown as
    /// unreadable on its own row and never stops the usage windows.
    /// </summary>
    private static IReadOnlyList<AiUsageBalance> CodexCredits(JsonElement snapshot)
    {
        if (snapshot.ValueKind != JsonValueKind.Object || !snapshot.TryGetProperty("credits", out var credits)
            || credits.ValueKind == JsonValueKind.Null) return [];
        AiUsageBalance Unreadable() => new("codexCredits", null, 0, "credits", null, State: "unreadable");
        if (credits.ValueKind != JsonValueKind.Object) return [Unreadable()];
        if (credits.TryGetProperty("unlimited", out var unlimited) && unlimited.ValueKind == JsonValueKind.True)
            return [new AiUsageBalance("codexCredits", null, 0, "credits", null, State: "unlimited")];
        if (!credits.TryGetProperty("balance", out var balance) || balance.ValueKind == JsonValueKind.Null) return [];
        decimal? value = balance.ValueKind switch
        {
            JsonValueKind.String when decimal.TryParse(balance.GetString(), NumberStyles.Float, CultureInfo.InvariantCulture, out var parsed) => parsed,
            JsonValueKind.Number when balance.TryGetDecimal(out var number) => number,
            _ => null
        };
        return value is { } amount and >= 0 and <= 1_000_000_000m
            ? [new AiUsageBalance("codexCredits", null, amount, "credits", null)]
            : [Unreadable()];
    }

    /// <summary><c>account: null</c> means signed out; a missing or odd <c>account</c> is a format change.</summary>
    public static bool IsCodexSignedIn(JsonElement accountResponse)
    {
        if (accountResponse.ValueKind != JsonValueKind.Object || !accountResponse.TryGetProperty("account", out var account))
            throw new AiUsageParseException("codex account response has no account field");
        return account.ValueKind switch
        {
            JsonValueKind.Object => true,
            JsonValueKind.Null => false,
            _ => throw new AiUsageParseException("codex account has an unexpected type")
        };
    }

    private static bool IsCodexMainBucket(string key) => string.Equals(key, "codex", StringComparison.OrdinalIgnoreCase);

    private static void AddCodexWindow(
        List<AiUsageWindow> windows,
        string bucket,
        string position,
        JsonElement snapshot,
        string? model,
        string fallbackKind)
    {
        if (!snapshot.TryGetProperty(position, out var window) || window.ValueKind != JsonValueKind.Object) return;
        if (ReadNumber(window, "usedPercent") is not { } used) return;
        var minutes = ReadInt(window, "windowDurationMins");
        var kind = minutes is { } value ? KindForMinutes(value) : fallbackKind;
        DateTimeOffset? resetsAt = ReadInt64(window, "resetsAt") is { } seconds ? FromUnixSeconds(seconds) : null;
        windows.Add(new AiUsageWindow($"codex:{bucket}:{position}", kind, model, ClampPercent(used), resetsAt,
            minutes ?? (kind == "session" ? SessionMinutes : kind == "weekly" ? WeekMinutes : null)));
    }

    private static string? CodexPlanName(string? planType) => planType switch
    {
        null or "" or "unknown" => null,
        "free" => "Free",
        "go" => "Go",
        "plus" => "Plus",
        "pro" => "Pro",
        "prolite" => "Pro Lite",
        "promax" => "Pro Max",
        "team" => "Team",
        "business" => "Business",
        "enterprise" => "Enterprise",
        "edu" => "Edu",
        _ => Clean(planType)
    };

    /// <summary>
    /// Parses <c>GET claude.ai/api/organizations/{id}/usage</c>. The <c>limits</c> array carries the
    /// five-hour session, the all-model weekly limit, and each model-scoped weekly limit (Fable on
    /// 2026-11-18); older payloads only have the <c>five_hour</c> / <c>seven_day*</c> objects.
    /// </summary>
    public static AiUsageReading ParseClaude(JsonElement usage, string? plan)
    {
        if (usage.ValueKind != JsonValueKind.Object)
            throw new AiUsageParseException("claude usage is not an object");

        var windows = new List<AiUsageWindow>();
        if (usage.TryGetProperty("limits", out var limits) && limits.ValueKind == JsonValueKind.Array)
        {
            var index = 0;
            foreach (var entry in limits.EnumerateArray())
            {
                index++;
                if (entry.ValueKind != JsonValueKind.Object || ReadNumber(entry, "percent") is not { } percent) continue;
                var kind = ReadString(entry, "kind");
                var group = ReadString(entry, "group");
                string? model = null;
                if (entry.TryGetProperty("scope", out var scope) && scope.ValueKind == JsonValueKind.Object
                    && scope.TryGetProperty("model", out var scopeModel) && scopeModel.ValueKind == JsonValueKind.Object)
                    model = Clean(ReadString(scopeModel, "display_name") ?? ReadString(scopeModel, "id"));
                var windowKind = kind == "session" || group == "session" ? "session"
                    : kind is "weekly_all" or "weekly_scoped" || group == "weekly" ? "weekly"
                    : null;
                if (windowKind is null) continue;
                if (kind == "weekly_scoped" && model is null) model = "Model";
                windows.Add(new AiUsageWindow($"claude:{kind ?? group}:{model ?? index.ToString(CultureInfo.InvariantCulture)}",
                    windowKind, model, ClampPercent(percent), ReadTime(entry, "resets_at"),
                    windowKind == "session" ? SessionMinutes : WeekMinutes));
            }
        }

        if (windows.Count == 0)
        {
            AddClaudeLegacy(windows, usage, "five_hour", "session", null);
            AddClaudeLegacy(windows, usage, "seven_day", "weekly", null);
            AddClaudeLegacy(windows, usage, "seven_day_opus", "weekly", "Opus");
            AddClaudeLegacy(windows, usage, "seven_day_sonnet", "weekly", "Sonnet");
        }

        if (windows.Count == 0)
            throw new AiUsageParseException("claude usage has no windows");
        return new AiUsageReading(plan, Limit(windows));
    }

    private static void AddClaudeLegacy(List<AiUsageWindow> windows, JsonElement usage, string key, string kind, string? model)
    {
        if (!usage.TryGetProperty(key, out var value) || value.ValueKind != JsonValueKind.Object) return;
        if (ReadNumber(value, "utilization") is not { } used) return;
        windows.Add(new AiUsageWindow($"claude:{key}", kind, model, ClampPercent(used), ReadTime(value, "resets_at"),
            kind == "session" ? SessionMinutes : WeekMinutes));
    }

    /// <summary>Selects the organization that has the consumer chat subscription.</summary>
    public static (string Id, string? Plan)? SelectClaudeOrganization(JsonElement organizations)
    {
        if (organizations.ValueKind != JsonValueKind.Array) return null;
        JsonElement? chosen = null;
        foreach (var organization in organizations.EnumerateArray())
        {
            if (organization.ValueKind != JsonValueKind.Object) continue;
            if (HasCapability(organization, "chat")) { chosen = organization; break; }
            chosen ??= HasCapability(organization, "api") ? null : organization;
        }
        if (chosen is not { } selected) return null;
        var id = ReadString(selected, "uuid");
        if (id is null || !ClaudeOrganizationIdPattern().IsMatch(id)) return null;

        var tier = ReadString(selected, "rate_limit_tier") ?? string.Empty;
        string? plan = tier.Contains("max_20x", StringComparison.OrdinalIgnoreCase) ? "Max 20x"
            : tier.Contains("max_5x", StringComparison.OrdinalIgnoreCase) ? "Max 5x"
            : HasCapability(selected, "claude_max") ? "Max"
            : HasCapability(selected, "claude_pro") ? "Pro"
            : null;
        return (id, plan);
    }

    /// <summary>
    /// The Claude Console organization: the only valid one with the <c>api</c> capability. With several,
    /// the plan's organization cannot be told apart, so the result is ambiguous instead of a guess.
    /// </summary>
    public static (string? Id, bool Ambiguous) SelectClaudeConsoleOrganization(JsonElement organizations)
    {
        if (organizations.ValueKind != JsonValueKind.Array) return (null, false);
        var candidates = organizations.EnumerateArray()
            .Where(organization => organization.ValueKind == JsonValueKind.Object && HasCapability(organization, "api"))
            .Select(organization => ReadString(organization, "uuid"))
            .Where(id => id is not null && ClaudeOrganizationIdPattern().IsMatch(id))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();
        return candidates.Length switch
        {
            1 => (candidates[0], false),
            0 => (null, false),
            _ => (null, true)
        };
    }

    /// <summary>
    /// Parses <c>GET platform.claude.com/api/organizations/{id}/prepaid/credits</c> (2026-11-18 shape).
    /// <c>promo_tranches</c> are grants such as the Max plan's monthly "API credit (Max)"; <c>tranches</c>
    /// are purchased credits, shown one row per expiry so each amount keeps its own date. Amounts are
    /// minor units with an explicit exponent in US dollars; anything else, or a tranche that cannot be
    /// read, is a format change. Only empty tranche lists with an explicit zero total read as $0.
    /// </summary>
    public static AiUsageReading ParseClaudeConsoleCredits(JsonElement credits)
    {
        if (credits.ValueKind != JsonValueKind.Object) throw new AiUsageParseException("console credits is not an object");
        RequireUsd(credits);
        var balances = new List<AiUsageBalance>();
        var tranchesSeen = 0;
        if (TrancheList(credits, "promo_tranches") is { } promo)
            foreach (var tranche in promo.EnumerateArray())
            {
                tranchesSeen++;
                var grant = ReadTranche(tranche);
                balances.Add(new AiUsageBalance("planCredit", Clean(ReadString(tranche, "name")), grant.Amount, "usd", grant.ExpiresAt));
            }
        var purchased = new SortedDictionary<DateTimeOffset, decimal>();
        decimal purchasedWithoutExpiry = 0;
        var hasPurchasedWithoutExpiry = false;
        if (TrancheList(credits, "tranches") is { } tranches)
            foreach (var tranche in tranches.EnumerateArray())
            {
                tranchesSeen++;
                var paid = ReadTranche(tranche);
                if (paid.ExpiresAt is { } expires) purchased[expires] = purchased.GetValueOrDefault(expires) + paid.Amount;
                else { purchasedWithoutExpiry += paid.Amount; hasPurchasedWithoutExpiry = true; }
            }
        foreach (var (expires, amount) in purchased)
            balances.Add(new AiUsageBalance("purchasedCredit", null, amount, "usd", expires));
        if (hasPurchasedWithoutExpiry) balances.Add(new AiUsageBalance("purchasedCredit", null, purchasedWithoutExpiry, "usd", null));
        if (tranchesSeen == 0)
        {
            // Without tranches the breakdown is unknown; only a total of exactly zero is shown.
            if (!credits.TryGetProperty("balance", out var total) || ReadMinorAmount(total) is not { } amount)
                throw new AiUsageParseException("console credits has no balance");
            if (amount != 0) throw new AiUsageParseException("console credits breakdown missing");
            balances.Add(new AiUsageBalance("purchasedCredit", null, 0, "usd", null));
        }
        return new AiUsageReading(null, [], balances);
    }

    // A tranche list that is present must be an array (or null); any other shape is a format change,
    // never a silently skipped half of the balance.
    private static JsonElement? TrancheList(JsonElement credits, string name)
    {
        if (!credits.TryGetProperty(name, out var list) || list.ValueKind == JsonValueKind.Null) return null;
        return list.ValueKind == JsonValueKind.Array ? list : throw new AiUsageParseException(name + " is not a list");
    }

    private static void RequireUsd(JsonElement element)
    {
        if (element.TryGetProperty("currency", out var currency) && !(currency.ValueKind == JsonValueKind.String && currency.GetString() == "USD"))
            throw new AiUsageParseException("credit currency is not USD");
    }

    private static (decimal Amount, DateTimeOffset? ExpiresAt) ReadTranche(JsonElement tranche)
    {
        if (tranche.ValueKind != JsonValueKind.Object) throw new AiUsageParseException("credit tranche is not an object");
        RequireUsd(tranche);
        decimal? amount = tranche.TryGetProperty("remaining", out var remaining) ? ReadMinorAmount(remaining) : null;
        // `remaining_amount_minor_units` is cents only alongside an explicit USD currency.
        if (amount is null && ReadInt64(tranche, "remaining_amount_minor_units") is { } minor && ReadString(tranche, "currency") == "USD")
            amount = CheckedAmount(minor, 2);
        return amount is { } value
            ? (value, ReadTime(tranche, "expires_at"))
            : throw new AiUsageParseException("credit tranche has no remaining amount");
    }

    // { "credits": { "amount_minor": 10000, "exponent": 2 } } or { "money": { ... } } → 100.00
    private static decimal? ReadMinorAmount(JsonElement holder)
    {
        if (holder.ValueKind != JsonValueKind.Object) return null;
        foreach (var name in new[] { "credits", "money" })
        {
            if (!holder.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.Object) continue;
            RequireUsd(value);
            if (!value.TryGetProperty("amount_minor", out var minorValue) || minorValue.ValueKind != JsonValueKind.Number
                || !minorValue.TryGetInt64(out var minor)
                || !value.TryGetProperty("exponent", out var exponentValue) || exponentValue.ValueKind != JsonValueKind.Number
                || !exponentValue.TryGetInt32(out var exponent))
                throw new AiUsageParseException("credit amount needs an integer amount_minor and exponent");
            return CheckedAmount(minor, exponent);
        }
        return null;
    }

    private static decimal CheckedAmount(long minor, int exponent) =>
        minor >= 0 && exponent is >= 0 and <= 6 && minor < 1_000_000_000_000
            ? minor / (decimal)Math.Pow(10, exponent)
            : throw new AiUsageParseException("credit amount out of range");

    /// <summary>
    /// Parses <c>GET colab.research.google.com/tun/m/ccu-info?authuser=0</c> (2026-11-18 shape):
    /// <c>currentBalance</c> compute units and <c>consumptionRateHourly</c>. <c>authuser=0</c> is the
    /// first Google account signed in to the profile.
    /// </summary>
    public static AiUsageReading ParseColab(string body)
    {
        var text = body.TrimStart();
        if (text.StartsWith(")]}'", StringComparison.Ordinal)) text = text[4..];
        if (text.TrimStart().StartsWith('<')) throw new AiUsageParseException("colab returned an HTML page");
        JsonDocument document;
        try { document = JsonDocument.Parse(text); }
        catch (JsonException) { throw new AiUsageParseException("colab response is not JSON"); }
        using (document)
        {
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object || ReadNumber(root, "currentBalance") is not { } balance
                || !double.IsFinite(balance) || balance is < 0 or > 1_000_000)
                throw new AiUsageParseException("colab response has no balance");
            // Unknown or odd rates stay null ("rate unknown"), which the panel keeps apart from a real 0.
            decimal? perHour = ReadNumber(root, "consumptionRateHourly") is { } rate && double.IsFinite(rate) && rate is >= 0 and < 10_000
                ? KeepPositive(rate)
                : null;
            return new AiUsageReading(null, [], [new AiUsageBalance("computeUnits", null, KeepPositive(balance), "units", null, perHour)]);
        }
    }

    // decimal cannot hold values below 1e-28; such a positive value must not become zero.
    private static decimal KeepPositive(double value)
    {
        var converted = (decimal)value;
        return value > 0 && converted == 0 ? 0.0000000001m : converted;
    }

    private static bool HasCapability(JsonElement organization, string capability) =>
        organization.TryGetProperty("capabilities", out var capabilities)
        && capabilities.ValueKind == JsonValueKind.Array
        && capabilities.EnumerateArray().Any(value => value.ValueKind == JsonValueKind.String && value.GetString() == capability);

    /// <summary>
    /// Parses the Gemini app's usage query. Returns <c>null</c> when Google reports no signed-in viewer.
    /// <c>percentageUsed</c> is read as a fraction (0.25 = 25%), following CodexBar; on 2026-11-18 only
    /// 0.0 had been observed, so the unit is provisional until a non-zero value is compared with the
    /// Gemini usage page.
    /// </summary>
    public static AiUsageReading? ParseGemini(string body)
    {
        var text = body.TrimStart();
        if (text.StartsWith(")]}'", StringComparison.Ordinal)) text = text[4..];
        if (text.TrimStart().StartsWith('<')) throw new AiUsageParseException("gemini returned an HTML page");
        JsonDocument document;
        try { document = JsonDocument.Parse(text); }
        catch (JsonException) { throw new AiUsageParseException("gemini response is not JSON"); }
        using (document)
        {
            var results = document.RootElement.ValueKind == JsonValueKind.Array
                ? document.RootElement.EnumerateArray().ToArray()
                : [document.RootElement];
            foreach (var result in results)
            {
                if (result.ValueKind != JsonValueKind.Object || !result.TryGetProperty("data", out var data)
                    || data.ValueKind != JsonValueKind.Object || !data.TryGetProperty("viewer", out var viewer)) continue;
                if (viewer.ValueKind == JsonValueKind.Null) return null;
                if (viewer.ValueKind != JsonValueKind.Object || !viewer.TryGetProperty("rpcs", out var rpcs)
                    || rpcs.ValueKind != JsonValueKind.Object || !rpcs.TryGetProperty("getUsageInfo", out var info)
                    || info.ValueKind != JsonValueKind.Object || !info.TryGetProperty("pools", out var pools)
                    || pools.ValueKind != JsonValueKind.Array)
                    throw new AiUsageParseException("gemini response has no usage pools");

                var windows = new List<AiUsageWindow>();
                AddGeminiPool(windows, pools, "GXU_FIVE_HOURLY", "session", SessionMinutes);
                AddGeminiPool(windows, pools, "GXU_WEEKLY", "weekly", WeekMinutes);
                if (windows.Count == 0) throw new AiUsageParseException("gemini response has no known pools");
                var plan = ReadString(info, "subscriptionTier") switch
                {
                    "TIER1" => "Pro",
                    _ => null
                };
                return new AiUsageReading(plan, windows);
            }
        }
        throw new AiUsageParseException("gemini response has no viewer");
    }

    private static void AddGeminiPool(List<AiUsageWindow> windows, JsonElement pools, string poolType, string kind, int minutes)
    {
        foreach (var pool in pools.EnumerateArray())
        {
            if (pool.ValueKind != JsonValueKind.Object || ReadString(pool, "poolType") != poolType) continue;
            if (ReadNumber(pool, "percentageUsed") is not { } fraction) return;
            DateTimeOffset? resetsAt = pool.TryGetProperty("gxu", out var gxu) && gxu.ValueKind == JsonValueKind.Object
                ? ReadTime(gxu, "windowRefreshesAt")
                : null;
            windows.Add(new AiUsageWindow($"gemini:{poolType}", kind, null, ClampPercent(fraction * 100), resetsAt, minutes));
            return;
        }
    }

    /// <summary>A Gemini Peer reading older than this is stale, matching the peer's own five-minute rule.</summary>
    public static readonly TimeSpan AntigravityFreshFor = TimeSpan.FromMinutes(5);

    /// <summary>
    /// Parses the Gemini Peer's <c>/history/api/usage</c> answer: the Antigravity CLI quota panel saved by
    /// the peer (codex-peer-gemini-windows docs/gemini-usage.md, collector schema version 1). Only the
    /// Gemini model quotas are shown: <c>gemini-5h</c> and <c>gemini-weekly</c>. Used = 1 − remainingFraction;
    /// a null fraction (the collector's "unknown") is an unreadable row, never 0%. The values carry the
    /// time they were captured. An old capture, or one the peer failed to renew afterwards, comes back as
    /// a stale reading with the reason (the peer's free-text error is not used).
    /// </summary>
    public static AiUsageResult ParseAntigravity(string body, DateTimeOffset now)
    {
        JsonDocument document;
        try { document = JsonDocument.Parse(body); }
        catch (JsonException) { throw new AiUsageParseException("gemini peer answer is not JSON"); }
        using (document)
        {
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object) throw new AiUsageParseException("gemini peer answer is not an object");
            var refreshFailed = root.TryGetProperty("lastAttempt", out var attempt) && attempt.ValueKind == JsonValueKind.Object
                && attempt.TryGetProperty("ok", out var ok) && ok.ValueKind == JsonValueKind.False;
            DateTimeOffset? failedAt = null;
            if (refreshFailed)
            {
                try { failedAt = ReadTime(attempt, "at"); }
                catch (AiUsageParseException) { failedAt = null; }
            }
            if (!root.TryGetProperty("sample", out var sample) || sample.ValueKind == JsonValueKind.Null)
                return AiUsageResult.Failure(refreshFailed ? AiUsageErrorCodes.PeerFailed : AiUsageErrorCodes.NoSnapshot);
            if (sample.ValueKind != JsonValueKind.Object) throw new AiUsageParseException("gemini peer sample is not an object");
            if (ReadNumber(sample, "version") is { } version && version != 1) throw new AiUsageParseException("gemini peer sample version changed");
            if (ReadTime(sample, "observedAt") is not { } observedAt) throw new AiUsageParseException("gemini peer sample has no capture time");
            if (!sample.TryGetProperty("quotas", out var quotas) || quotas.ValueKind != JsonValueKind.Array)
                throw new AiUsageParseException("gemini peer sample has no quotas");

            var session = AntigravityQuota(quotas, "gemini-5h", "session", SessionMinutes);
            var weekly = AntigravityQuota(quotas, "gemini-weekly", "weekly", WeekMinutes);
            if (session is null && weekly is null) throw new AiUsageParseException("gemini peer sample has no Gemini quotas");
            // One window missing from the capture is shown as unreadable, so it is clear which one was read.
            List<AiUsageWindow> windows =
            [
                session ?? new AiUsageWindow("antigravity:gemini-5h", "session", null, 0, null, SessionMinutes, State: "unreadable"),
                weekly ?? new AiUsageWindow("antigravity:gemini-weekly", "weekly", null, 0, null, WeekMinutes, State: "unreadable")
            ];
            string? model = null;
            if (sample.TryGetProperty("model", out var modelInfo) && modelInfo.ValueKind == JsonValueKind.Object)
                model = Clean(ReadString(modelInfo, "name")) ?? Clean(ReadString(modelInfo, "id"));

            var reading = new AiUsageReading(model, windows, ObservedAt: observedAt);
            var age = now - observedAt;
            var stale = (root.TryGetProperty("stale", out var staleFlag) && staleFlag.ValueKind == JsonValueKind.True)
                || age > AntigravityFreshFor || age < -TimeSpan.FromMinutes(2);
            // A renewal that failed after this capture means the values could not be confirmed just now.
            var renewalFailed = refreshFailed && (failedAt is not { } at || at >= observedAt);
            if (renewalFailed) return AiUsageResult.StaleReading(reading, AiUsageErrorCodes.PeerFailed);
            if (stale) return AiUsageResult.StaleReading(reading, AiUsageErrorCodes.Stale);
            // A capture without a single value is not a successful reading, even when it is recent.
            if (windows.All(window => window.State == "unreadable")) return AiUsageResult.StaleReading(reading, AiUsageErrorCodes.NoValues);
            return AiUsageResult.Success(reading);
        }
    }

    private static AiUsageWindow? AntigravityQuota(JsonElement quotas, string id, string kind, int minutes)
    {
        foreach (var quota in quotas.EnumerateArray())
        {
            if (quota.ValueKind != JsonValueKind.Object || ReadString(quota, "id") != id) continue;
            var resetsAt = ReadTime(quota, "resetAt");
            if (!quota.TryGetProperty("remainingFraction", out var value) || value.ValueKind == JsonValueKind.Null)
                return new AiUsageWindow($"antigravity:{id}", kind, null, 0, resetsAt, minutes, State: "unreadable");
            if (value.ValueKind != JsonValueKind.Number || !value.TryGetDouble(out var remaining) || !double.IsFinite(remaining)
                || remaining is < 0 or > 1)
                throw new AiUsageParseException("remaining fraction out of range");
            return new AiUsageWindow($"antigravity:{id}", kind, null, ClampPercent((1 - remaining) * 100), resetsAt, minutes);
        }
        return null;
    }

    /// <summary>
    /// Parses the React flight rows returned by muse.ai's settings server action. The subscription is
    /// the row that carries <c>"success": true</c>. Muse only reports a weekly percentage.
    /// </summary>
    public static AiUsageReading ParseMuse(string body)
    {
        JsonElement? subscription = null;
        var documents = new List<JsonDocument>();
        try
        {
            foreach (var line in body.Split('\n'))
            {
                var match = MuseFlightRowPattern().Match(line.TrimEnd('\r'));
                if (!match.Success) continue;
                JsonDocument row;
                try { row = JsonDocument.Parse(match.Groups[1].Value); }
                catch (JsonException) { continue; }
                documents.Add(row);
                if (row.RootElement.TryGetProperty("success", out var success) && success.ValueKind == JsonValueKind.True
                    && row.RootElement.TryGetProperty("subscription", out var value) && value.ValueKind == JsonValueKind.Object)
                    subscription = value;
            }
            if (subscription is not { } sub || !sub.TryGetProperty("usage", out var usage) || usage.ValueKind != JsonValueKind.Object
                || ReadNumber(usage, "percentUsed") is not { } percent)
                throw new AiUsageParseException("muse response has no usage");
            DateTimeOffset? resetsAt = ReadNumber(usage, "resetsAt") is { } seconds
                ? FromUnixSeconds(double.IsFinite(seconds) && Math.Abs(seconds) < long.MaxValue ? (long)seconds : -1)
                : null;
            string? plan = null;
            if (sub.TryGetProperty("tier", out var tier) && tier.ValueKind == JsonValueKind.Object)
                plan = Clean(ReadString(tier, "name"));
            return new AiUsageReading(plan, [new AiUsageWindow("muse:weekly", "weekly", null, ClampPercent(percent), resetsAt, WeekMinutes)]);
        }
        finally
        {
            foreach (var document in documents) document.Dispose();
        }
    }

    private static string KindForMinutes(long minutes) => minutes switch
    {
        SessionMinutes => "session",
        WeekMinutes => "weekly",
        _ => "window"
    };

    private static IReadOnlyList<AiUsageWindow> Limit(List<AiUsageWindow> windows) =>
        windows.Count > MaxWindows ? windows.Take(MaxWindows).ToArray() : windows.ToArray();

    // Over-limit readings above 100% are plausible and shown as 100%; negative or absurd values are a
    // format change, never a 0% reading.
    private static double ClampPercent(double value) =>
        double.IsFinite(value) && value is >= 0 and <= 1000
            ? Math.Round(Math.Min(value, 100), 1)
            : throw new AiUsageParseException("percent out of range");

    // Reset instants must be real dates; anything outside 2000–2200 is treated as a format change.
    private static DateTimeOffset FromUnixSeconds(long seconds) =>
        seconds is > 946_684_800 and < 7_258_118_400
            ? DateTimeOffset.FromUnixTimeSeconds(seconds)
            : throw new AiUsageParseException("reset time out of range");

    private static string? Clean(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return null;
        var cleaned = new string(value.Where(character => !char.IsControl(character)).ToArray()).Trim();
        if (cleaned.Length == 0) return null;
        return cleaned.Length > MaxLabelLength ? cleaned[..MaxLabelLength] : cleaned;
    }

    private static string? ReadString(JsonElement element, string name) =>
        element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;

    private static double? ReadNumber(JsonElement element, string name) =>
        element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.Number && value.TryGetDouble(out var number)
            ? number
            : null;

    private static int? ReadInt(JsonElement element, string name) =>
        element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out var number)
            ? number
            : null;

    private static long? ReadInt64(JsonElement element, string name) =>
        element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out var number)
            ? number
            : null;

    // A missing reset time stays unknown; a present one must be a real date between 2000 and 2200.
    private static DateTimeOffset? ReadTime(JsonElement element, string name)
    {
        if (ReadString(element, name) is not { } text) return null;
        if (!DateTimeOffset.TryParse(text, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var value))
            throw new AiUsageParseException("reset time is not a date");
        var utc = value.ToUniversalTime();
        return utc.Year is >= 2000 and < 2200 ? utc : throw new AiUsageParseException("reset time out of range");
    }

    [GeneratedRegex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")]
    private static partial Regex ClaudeOrganizationIdPattern();

    [GeneratedRegex("^[0-9a-f]+:(\\{.*\\})\\s*$")]
    private static partial Regex MuseFlightRowPattern();
}
