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
        return new AiUsageReading(plan, Limit(windows));
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
