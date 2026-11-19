namespace HoverPocket.Shell.Providers.AiUsage;

internal static class AiUsageServiceIds
{
    public const string Codex = "codex";
    public const string Claude = "claude";
    public const string ClaudeApi = "claude-api";
    public const string Gemini = "gemini";
    /// <summary>Antigravity CLI (agy) limits, read from the local Gemini Peer; separate from the Gemini app's.</summary>
    public const string Antigravity = "antigravity";
    public const string Colab = "colab";
    public const string Muse = "muse";

    public static IReadOnlyList<string> All { get; } = [Codex, Claude, ClaudeApi, Gemini, Antigravity, Colab, Muse];

    /// <summary>Services read through a hidden WebView2 (everything except Codex).</summary>
    public static IReadOnlyList<string> Web { get; } = [Claude, ClaudeApi, Gemini, Colab, Muse];

    /// <summary>Services with their own sign-in window. Colab uses Gemini's Google sign-in.</summary>
    public static IReadOnlyList<string> SignIn { get; } = [Claude, ClaudeApi, Gemini, Muse];

    public static bool IsKnown(string? id) => id is not null && All.Contains(id, StringComparer.Ordinal);

    /// <summary>The WebView2 profile holding the service's sign-in.</summary>
    public static string Profile(string id) => id == Colab ? Gemini : id;

    /// <summary>Services whose readings belong to the same sign-in and must be reset together.</summary>
    public static IReadOnlyList<string> SharingSignIn(string id) => Profile(id) == Gemini ? [Gemini, Colab] : [id];

    public static string DisplayName(string id) => id switch
    {
        Codex => "Codex",
        Claude => "Claude",
        ClaudeApi => "Claude API",
        Gemini => "Gemini",
        Antigravity => "Antigravity",
        Colab => "Colab",
        Muse => "Muse",
        _ => id
    };
}

internal static class AiUsageStatus
{
    public const string Idle = "idle";
    public const string Ok = "ok";
    public const string SignedOut = "signedOut";
    public const string Error = "error";
}

internal static class AiUsageErrorCodes
{
    public const string Network = "network";
    public const string Changed = "changed";
    public const string Timeout = "timeout";
    public const string CodexMissing = "codexMissing";
    public const string Blocked = "blocked";
    public const string Unavailable = "unavailable";
    /// <summary>Signed in, but the account may not read this data (for example Console billing).</summary>
    public const string NoAccess = "noAccess";
    /// <summary>More than one account could be meant; nothing is shown rather than a guess.</summary>
    public const string Ambiguous = "ambiguous";
    /// <summary>The local Gemini Peer did not answer (not running).</summary>
    public const string PeerMissing = "peerMissing";
    /// <summary>The Gemini Peer tried to re-read Antigravity's limits and failed (agy sign-in or status line setup).</summary>
    public const string PeerFailed = "peerFailed";
    /// <summary>The saved reading is old and was not re-read this time.</summary>
    public const string Stale = "stale";
    /// <summary>The Gemini Peer has no saved reading yet.</summary>
    public const string NoSnapshot = "noSnapshot";
    /// <summary>A reading arrived, but none of its windows has a value.</summary>
    public const string NoValues = "noValues";
}

/// <summary>
/// One usage window. <see cref="Kind"/> is <c>session</c> (a short rolling window such as five hours),
/// <c>weekly</c>, or <c>window</c> for any other duration. <see cref="Model"/> names the model or
/// product a scoped window applies to, for example Claude's separate Fable weekly limit.
/// <see cref="State"/> is <c>unreadable</c> for a window the service reports without a value; its
/// <see cref="UsedPercent"/> is then meaningless and is never sent to the panel.
/// </summary>
internal sealed record AiUsageWindow(
    string Id,
    string Kind,
    string? Model,
    double UsedPercent,
    DateTimeOffset? ResetsAt,
    int? WindowMinutes,
    string? State = null);

/// <summary>
/// A balance rather than a limit: Claude Console API credits (<c>usd</c>, the plan's monthly grant and
/// purchased credits on separate rows, one per expiry), Codex credits (<c>credits</c>), or Colab compute
/// units (<c>units</c>, with the current hourly consumption, <c>null</c> when unknown). Amounts keep full
/// precision; the panel decides how to show tiny values. <see cref="State"/> is <c>unlimited</c> or
/// <c>unreadable</c> when there is no amount to show.
/// </summary>
internal sealed record AiUsageBalance(
    string Kind,
    string? Label,
    decimal Amount,
    string Unit,
    DateTimeOffset? ExpiresAt,
    decimal? PerHour = null,
    string? State = null);

/// <summary>
/// <see cref="ObservedAt"/> is when the values were true, for a source that hands over a saved reading
/// (Antigravity through the Gemini Peer); <c>null</c> means "read just now".
/// </summary>
internal sealed record AiUsageReading(
    string? Plan,
    IReadOnlyList<AiUsageWindow> Windows,
    IReadOnlyList<AiUsageBalance>? Balances = null,
    DateTimeOffset? ObservedAt = null)
{
    public IReadOnlyList<AiUsageBalance> BalanceList => Balances ?? [];
}

internal sealed record AiUsageResult(string Status, AiUsageReading? Reading, string? ErrorCode)
{
    public static AiUsageResult Success(AiUsageReading reading) => new(AiUsageStatus.Ok, reading, null);

    public static AiUsageResult SignedOut() => new(AiUsageStatus.SignedOut, null, null);

    public static AiUsageResult Failure(string code) => new(AiUsageStatus.Error, null, code);

    /// <summary>An old saved reading that could not be renewed: shown marked stale with the reason.</summary>
    public static AiUsageResult StaleReading(AiUsageReading reading, string code) => new(AiUsageStatus.Error, reading, code);
}

internal sealed class AiUsageParseException(string message) : Exception(message);

internal sealed record AiUsageServiceSnapshot(
    string Id,
    string Status,
    string? Plan,
    IReadOnlyList<AiUsageWindow> Windows,
    DateTimeOffset? FetchedAt,
    string? ErrorCode,
    bool Stale,
    bool Refreshing,
    DateTimeOffset? CheckedAt = null,
    IReadOnlyList<AiUsageBalance>? Balances = null)
{
    public IReadOnlyList<AiUsageBalance> BalanceList => Balances ?? [];

    public static AiUsageServiceSnapshot Initial(string id) =>
        new(id, AiUsageStatus.Idle, null, [], null, null, false, false);

    /// <summary>
    /// Applies a new result. A failed refresh keeps the last good windows and marks them stale, so a
    /// transient error never reads as 0% used.
    /// </summary>
    public AiUsageServiceSnapshot Apply(AiUsageResult result, DateTimeOffset now) =>
        ApplyResult(result, now) with { CheckedAt = now };

    private AiUsageServiceSnapshot ApplyResult(AiUsageResult result, DateTimeOffset now)
    {
        if (result.Status == AiUsageStatus.Ok && result.Reading is { } reading)
        {
            return this with
            {
                Status = AiUsageStatus.Ok,
                Plan = reading.Plan,
                Windows = reading.Windows,
                Balances = reading.BalanceList,
                FetchedAt = reading.ObservedAt ?? now,
                ErrorCode = null,
                Stale = false,
                Refreshing = false
            };
        }

        // An old saved reading is shown as stale with the reason, unless what is shown already is newer.
        if (result.Status == AiUsageStatus.Error && result.Reading is { } old
            && (FetchedAt is not { } shown || Windows.Count + BalanceList.Count == 0 || (old.ObservedAt ?? now) > shown))
        {
            return this with
            {
                Status = AiUsageStatus.Error,
                Plan = old.Plan,
                Windows = old.Windows,
                Balances = old.BalanceList,
                FetchedAt = old.ObservedAt ?? now,
                ErrorCode = result.ErrorCode ?? AiUsageErrorCodes.Stale,
                Stale = true,
                Refreshing = false
            };
        }

        if (result.Status == AiUsageStatus.SignedOut)
        {
            return this with
            {
                Status = AiUsageStatus.SignedOut,
                Plan = null,
                Windows = [],
                Balances = [],
                ErrorCode = null,
                Stale = false,
                Refreshing = false
            };
        }

        // A failed read keeps the last good values marked stale; it never turns into 0% or a $0 balance.
        var keepLast = (Windows.Count > 0 || BalanceList.Count > 0) && FetchedAt is not null;
        return this with
        {
            Status = AiUsageStatus.Error,
            ErrorCode = result.ErrorCode ?? AiUsageErrorCodes.Network,
            Windows = keepLast ? Windows : [],
            Balances = keepLast ? BalanceList : [],
            Plan = keepLast ? Plan : null,
            Stale = keepLast,
            Refreshing = false
        };
    }
}
