using System.IO;
using HoverPocket.Shell.Configuration;
using HoverPocket.Shell.Verification;

namespace HoverPocket.Shell.Providers.AiLane;

internal sealed class AiLaneVerifier
{
    private readonly List<string> _failures = [];

    public int Run()
    {
        var root = UserSettingsStore.CreateTemporary("AiLaneVerify").RootDirectory;
        var auditLog = new AiLaneAuditLog(root);
        var interpreter = new AiLaneCommandInterpreter(() => new DateTime(2026, 7, 5));
        var controller = new AiLaneController(interpreter, auditLog);

        VerifyRead(controller);
        var approvedActionId = VerifyCreatePending(controller);
        if (approvedActionId is not null)
        {
            VerifyApprove(controller, approvedActionId);
        }

        var rejectedActionId = VerifyCreatePending(controller);
        if (rejectedActionId is not null)
        {
            VerifyReject(controller, rejectedActionId);
        }

        VerifyUnknown(controller);
        VerifyAuditLog(auditLog);

        if (_failures.Count == 0)
        {
            VerifyConsole.WriteLine("PASS ailane verify: read/create/unknown interpretation, approval transitions, audit JSONL");
            VerifyConsole.WriteLine($"auditlog_path={auditLog.LogDirectory}");
            return 0;
        }

        VerifyConsole.WriteLine("FAIL ailane verify:");
        foreach (var failure in _failures)
        {
            VerifyConsole.WriteLine($"- {failure}");
        }

        return 1;
    }

    private void VerifyRead(AiLaneController controller)
    {
        var state = controller.Submit("今日の予定");
        if (state.Status != "complete"
            || state.PendingApproval is not null
            || !state.Message.Contains("Phase 2", StringComparison.Ordinal))
        {
            _failures.Add("read interpretation did not return Phase 2 calendar guidance");
        }
    }

    private string? VerifyCreatePending(AiLaneController controller)
    {
        var state = controller.Submit("明日14時 打ち合わせ");
        var card = state.PendingApproval;
        if (state.Status != "pending_approval" || card is null)
        {
            _failures.Add("create interpretation did not enter pending approval");
            return null;
        }

        var requiredFields = new[] { "title", "start", "end", "allDay", "location", "notes", "calendar" };
        var actualFields = card.Fields.Select(field => field.Key).ToHashSet(StringComparer.Ordinal);
        if (requiredFields.Any(field => !actualFields.Contains(field)))
        {
            _failures.Add("create approval card omitted required fields");
        }

        if (card.Start != "2026-07-06 14:00" || card.End != "2026-07-06 15:00")
        {
            _failures.Add("create approval card did not resolve tomorrow 14:00 deterministically");
        }

        return card.ActionId;
    }

    private void VerifyApprove(AiLaneController controller, string actionId)
    {
        var state = controller.Approve(actionId);
        if (state.Status != "complete"
            || state.PendingApproval is not null
            || !state.Message.Contains("Phase 2", StringComparison.Ordinal))
        {
            _failures.Add("approve transition did not complete without execution");
        }
    }

    private void VerifyReject(AiLaneController controller, string actionId)
    {
        var state = controller.Reject(actionId);
        if (state.Status != "complete"
            || state.PendingApproval is not null
            || !state.Message.Contains("送信していません", StringComparison.Ordinal))
        {
            _failures.Add("reject transition did not clear pending action");
        }
    }

    private void VerifyUnknown(AiLaneController controller)
    {
        var state = controller.Submit("これは何");
        if (state.Status != "error" || state.PendingApproval is not null)
        {
            _failures.Add("unknown input did not enter failure state");
        }
    }

    private void VerifyAuditLog(AiLaneAuditLog auditLog)
    {
        var logFiles = Directory.Exists(auditLog.LogDirectory)
            ? Directory.GetFiles(auditLog.LogDirectory, "*.jsonl")
            : [];
        var lines = logFiles.SelectMany(File.ReadAllLines).ToArray();
        if (lines.Length < 3)
        {
            _failures.Add("audit log did not include approved/rejected/failed entries");
            return;
        }

        var joined = string.Join('\n', lines);
        if (!joined.Contains("\"outcome\":\"approved\"", StringComparison.Ordinal)
            || !joined.Contains("\"outcome\":\"rejected\"", StringComparison.Ordinal)
            || !joined.Contains("\"event\":\"failure\"", StringComparison.Ordinal))
        {
            _failures.Add("audit log missing required decision or failure event");
        }

        if (joined.Contains("打ち合わせ", StringComparison.Ordinal)
            || joined.Contains("今日の予定", StringComparison.Ordinal))
        {
            _failures.Add("audit log included command text or personal content");
        }
    }
}
