using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace HoverPocket.Shell.Providers.AiLane;

internal sealed class AiLaneAuditLog
{
    private static readonly TimeSpan Retention = TimeSpan.FromDays(90);
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };

    public AiLaneAuditLog(string rootDirectory)
    {
        LogDirectory = Path.Combine(rootDirectory, "auditlog");
        PruneExpiredFiles(DateTimeOffset.UtcNow);
    }

    public string LogDirectory { get; }

    public void WriteDecision(AiLaneApprovalCard card, string decision)
    {
        var now = DateTimeOffset.UtcNow;
        Write(now, new AiLaneAuditEntry(
            now.ToString("O"),
            "approval_decision",
            card.ActionType,
            decision,
            null,
            string.IsNullOrWhiteSpace(card.Calendar) ? null : card.Calendar));
    }

    public void WriteFailure(string reason)
    {
        _ = reason;
        var now = DateTimeOffset.UtcNow;
        Write(now, new AiLaneAuditEntry(
            now.ToString("O"),
            "failure",
            null,
            "failed",
            null,
            null));
    }

    private void Write(DateTimeOffset now, AiLaneAuditEntry entry)
    {
        Directory.CreateDirectory(LogDirectory);
        PruneExpiredFiles(now);
        var path = Path.Combine(LogDirectory, $"ailane-{now:yyyyMMdd}.jsonl");
        File.AppendAllText(path, JsonSerializer.Serialize(entry, JsonOptions) + Environment.NewLine);
    }

    private void PruneExpiredFiles(DateTimeOffset now)
    {
        if (!Directory.Exists(LogDirectory))
        {
            return;
        }

        var cutoffDate = now.UtcDateTime.Date.Subtract(Retention);
        foreach (var path in Directory.GetFiles(LogDirectory, "ailane-*.jsonl"))
        {
            try
            {
                if (IsExpired(path, cutoffDate))
                {
                    File.Delete(path);
                }
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException)
            {
            }
        }
    }

    private static bool IsExpired(string path, DateTime cutoffDate)
    {
        var name = Path.GetFileNameWithoutExtension(path);
        if (name.Length == "ailane-yyyyMMdd".Length
            && DateTime.TryParseExact(
                name["ailane-".Length..],
                "yyyyMMdd",
                provider: null,
                System.Globalization.DateTimeStyles.AssumeUniversal,
                out var fileDate))
        {
            return fileDate.Date < cutoffDate;
        }

        return File.GetLastWriteTimeUtc(path) < cutoffDate;
    }
}

internal sealed record AiLaneAuditEntry(
    string Timestamp,
    string Action,
    string? ActionType,
    string Result,
    string? EventId,
    string? CalendarId);
