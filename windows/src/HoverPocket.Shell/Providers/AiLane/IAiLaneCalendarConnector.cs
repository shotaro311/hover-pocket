namespace HoverPocket.Shell.Providers.AiLane;

internal interface IAiLaneCalendarConnector
{
    Task<string> ReadCalendarAsync(DateTimeOffset day, CancellationToken cancellationToken);

    Task<string> CreateCalendarEventAsync(AiLaneApprovalCard card, CancellationToken cancellationToken);
}

internal sealed class UnavailableAiLaneCalendarConnector : IAiLaneCalendarConnector
{
    public Task<string> ReadCalendarAsync(DateTimeOffset day, CancellationToken cancellationToken)
    {
        _ = day;
        cancellationToken.ThrowIfCancellationRequested();
        return Task.FromResult("Google Calendar に接続してください。");
    }

    public Task<string> CreateCalendarEventAsync(AiLaneApprovalCard card, CancellationToken cancellationToken)
    {
        _ = card;
        cancellationToken.ThrowIfCancellationRequested();
        return Task.FromResult("Google Calendar に接続してください。予定は送信していません。");
    }
}
