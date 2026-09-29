namespace HoverPocket.Shell.PocketApps;

internal sealed record PocketAppStateTransitionLease(
    string AppId,
    string? OperationId,
    bool Saved)
{
    public static PocketAppStateTransitionLease Noop(string appId) => new(appId, null, true);

    public static PocketAppStateTransitionLease Failed(string appId) => new(appId, null, false);
}
