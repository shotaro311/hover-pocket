namespace HoverPocket.Shell.Providers.AiLane;

internal sealed class AiLaneController
{
    private readonly AiLaneCommandInterpreter _interpreter;
    private readonly AiLaneAuditLog _auditLog;
    private AiLaneState _state = AiLaneState.Ready;

    public AiLaneController(AiLaneAuditLog auditLog)
        : this(new AiLaneCommandInterpreter(), auditLog)
    {
    }

    internal AiLaneController(AiLaneCommandInterpreter interpreter, AiLaneAuditLog auditLog)
    {
        _interpreter = interpreter;
        _auditLog = auditLog;
    }

    public AiLaneState CurrentState => _state;

    public AiLaneState Submit(string input)
    {
        var interpretation = _interpreter.Interpret(input);
        _state = interpretation.Kind switch
        {
            AiLaneCommandKind.ReadCalendar => new AiLaneState("complete", interpretation.Message, null),
            AiLaneCommandKind.CreateCalendarEvent when interpretation.ApprovalCard is not null =>
                new AiLaneState("pending_approval", interpretation.Message, interpretation.ApprovalCard),
            _ => Fail("unknown_command")
        };

        return _state;
    }

    public AiLaneState Approve(string actionId)
    {
        var pending = _state.PendingApproval;
        if (pending is null || !string.Equals(pending.ActionId, actionId, StringComparison.Ordinal))
        {
            return Fail("approval_not_found");
        }

        _auditLog.WriteDecision(pending, "approved");
        _state = new AiLaneState("complete", "承認しました。Phase 2 で Calendar に接続されます。", null);
        return _state;
    }

    public AiLaneState Reject(string actionId)
    {
        var pending = _state.PendingApproval;
        if (pending is null || !string.Equals(pending.ActionId, actionId, StringComparison.Ordinal))
        {
            return Fail("approval_not_found");
        }

        _auditLog.WriteDecision(pending, "rejected");
        _state = new AiLaneState("complete", "却下しました。Calendar には送信していません。", null);
        return _state;
    }

    private AiLaneState Fail(string reason)
    {
        _auditLog.WriteFailure(reason);
        return new AiLaneState("error", $"解釈できませんでした: {reason}", null);
    }
}
