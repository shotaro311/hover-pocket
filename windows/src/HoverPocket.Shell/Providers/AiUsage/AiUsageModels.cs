namespace HoverPocket.Shell.Providers.AiUsage;

internal static class AiUsageServiceIds
{
    public const string Codex = "codex";
    public const string Claude = "claude";
    public const string Gemini = "gemini";
    public const string Muse = "muse";

    public static IReadOnlyList<string> All { get; } = [Codex, Claude, Gemini, Muse];

    public static IReadOnlyList<string> Web { get; } = [Claude, Gemini, Muse];

    public static bool IsKnown(string? id) => id is not null && All.Contains(id, StringComparer.Ordinal);

    public static string DisplayName(string id) => id switch
    {
        Codex => "Codex",
        Claude => "Claude",
        Gemini => "Gemini",
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
}

/// <summary>
/// One usage window. <see cref="Kind"/> is <c>session</c> (a short rolling window such as five hours),
/// <c>weekly</c>, or <c>window</c> for any other duration. <see cref="Model"/> names the model or
/// product a scoped window applies to, for example Claude's separate Fable weekly limit.
/// </summary>
internal sealed record AiUsageWindow(
    string Id,
    string Kind,
    string? Model,
    double UsedPercent,
    DateTimeOffset? ResetsAt,
    int? WindowMinutes);

internal sealed record AiUsageReading(string? Plan, IReadOnlyList<AiUsageWindow> Windows);

internal sealed record AiUsageResult(string Status, AiUsageReading? Reading, string? ErrorCode)
{
    public static AiUsageResult Success(AiUsageReading reading) => new(AiUsageStatus.Ok, reading, null);

    public static AiUsageResult SignedOut() => new(AiUsageStatus.SignedOut, null, null);

    public static AiUsageResult Failure(string code) => new(AiUsageStatus.Error, null, code);
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
    DateTimeOffset? CheckedAt = null)
{
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
                FetchedAt = now,
                ErrorCode = null,
                Stale = false,
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
                ErrorCode = null,
                Stale = false,
                Refreshing = false
            };
        }

        var keepLast = Windows.Count > 0 && FetchedAt is not null;
        return this with
        {
            Status = AiUsageStatus.Error,
            ErrorCode = result.ErrorCode ?? AiUsageErrorCodes.Network,
            Windows = keepLast ? Windows : [],
            Plan = keepLast ? Plan : null,
            Stale = keepLast,
            Refreshing = false
        };
    }
}
