namespace HoverPocket.Shell.Providers.AiLane;

internal sealed class AiLaneController
{
    private readonly AiLaneCommandInterpreter _interpreter;
    private readonly AiLaneAuditLog _auditLog;
    private readonly IAiLaneCalendarConnector _calendarConnector;
    private AiLaneState _state = AiLaneState.Ready;

    public AiLaneController(AiLaneAuditLog auditLog, IAiLaneCalendarConnector? calendarConnector = null)
        : this(new AiLaneCommandInterpreter(), auditLog, calendarConnector)
    {
    }

    internal AiLaneController(
        AiLaneCommandInterpreter interpreter,
        AiLaneAuditLog auditLog,
        IAiLaneCalendarConnector? calendarConnector = null)
    {
        _interpreter = interpreter;
        _auditLog = auditLog;
        _calendarConnector = calendarConnector ?? new UnavailableAiLaneCalendarConnector();
    }

    public AiLaneState CurrentState => _state;

    public AiLaneState Submit(string input)
    {
        return SubmitAsync(input).GetAwaiter().GetResult();
    }

    public async Task<AiLaneState> SubmitAsync(string input, CancellationToken cancellationToken = default)
    {
        var interpretation = _interpreter.Interpret(input);
        _state = interpretation.Kind switch
        {
            AiLaneCommandKind.ReadCalendar => new AiLaneState(
                "complete",
                await ReadCalendarAsync(interpretation.ReadDate ?? DateTimeOffset.Now, cancellationToken),
                null),
            AiLaneCommandKind.CreateCalendarEvent when interpretation.ApprovalCard is not null =>
                new AiLaneState("pending_approval", interpretation.Message, interpretation.ApprovalCard),
            _ => Fail("unknown_command")
        };

        return _state;
    }

    public AiLaneState Approve(string actionId)
    {
        return ApproveAsync(actionId).GetAwaiter().GetResult();
    }

    public async Task<AiLaneState> ApproveAsync(string actionId, CancellationToken cancellationToken = default)
    {
        var pending = _state.PendingApproval;
        if (pending is null || !string.Equals(pending.ActionId, actionId, StringComparison.Ordinal))
        {
            return Fail("approval_not_found");
        }

        _auditLog.WriteDecision(pending, "approved");
        _state = new AiLaneState(
            "complete",
            await CreateCalendarEventAsync(pending, cancellationToken),
            null);
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

    private async Task<string> ReadCalendarAsync(DateTimeOffset day, CancellationToken cancellationToken)
    {
        try
        {
            return await _calendarConnector.ReadCalendarAsync(day, cancellationToken);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            return $"{ex.Message} Calendar provider で接続してください。";
        }
    }

    private async Task<string> CreateCalendarEventAsync(AiLaneApprovalCard card, CancellationToken cancellationToken)
    {
        try
        {
            return await _calendarConnector.CreateCalendarEventAsync(card, cancellationToken);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            return $"{ex.Message} 予定は送信していません。";
        }
    }
}
