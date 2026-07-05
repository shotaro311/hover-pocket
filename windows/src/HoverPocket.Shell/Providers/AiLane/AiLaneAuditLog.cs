using System.IO;
using System.Text.Json;

namespace HoverPocket.Shell.Providers.AiLane;

internal sealed class AiLaneAuditLog
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase
    };

    public AiLaneAuditLog(string rootDirectory)
    {
        LogDirectory = Path.Combine(rootDirectory, "auditlog");
    }

    public string LogDirectory { get; }

    public void WriteDecision(AiLaneApprovalCard card, string decision)
    {
        Write(new AiLaneAuditEntry(
            DateTimeOffset.UtcNow.ToString("O"),
            "approval_decision",
            card.ActionId,
            card.ActionType,
            decision,
            null,
            card.Fields.Select(field => field.Key).ToArray()));
    }

    public void WriteFailure(string reason)
    {
        Write(new AiLaneAuditEntry(
            DateTimeOffset.UtcNow.ToString("O"),
            "failure",
            null,
            null,
            "failed",
            reason,
            []));
    }

    private void Write(AiLaneAuditEntry entry)
    {
        Directory.CreateDirectory(LogDirectory);
        var path = Path.Combine(LogDirectory, $"ailane-{DateTimeOffset.UtcNow:yyyyMMdd}.jsonl");
        File.AppendAllText(path, JsonSerializer.Serialize(entry, JsonOptions) + Environment.NewLine);
    }
}

internal sealed record AiLaneAuditEntry(
    string TimestampUtc,
    string Event,
    string? ActionId,
    string? ActionType,
    string Outcome,
    string? Reason,
    IReadOnlyList<string> FieldKeys);
