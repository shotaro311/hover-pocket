namespace HoverPocket.Assets;

// One sequential loop; cancellation drains the current pass before releasing resources.
public sealed class AssetSyncRunner : IAsyncDisposable
{
    private readonly CancellationTokenSource _stop = new();
    private readonly Task _loop;
    public AssetSyncRunner(AssetStore store, TimeSpan? interval = null)
    {
        _loop = Task.Run(async () =>
        {
            using var timer = new PeriodicTimer(interval ?? TimeSpan.FromSeconds(3));
            try
            {
                do
                {
                    try { await store.SyncOnceAsync(_stop.Token, onlyWhenEnabled: true).ConfigureAwait(false); }
                    catch (OperationCanceledException) when (_stop.IsCancellationRequested) { break; }
                    catch (Exception ex) when (ex is InvalidOperationException or IOException or InvalidDataException or UnauthorizedAccessException or Microsoft.Data.Sqlite.SqliteException)
                    { System.Diagnostics.Trace.WriteLine("Asset sync paused: " + ex.GetType().Name); }
                } while (await timer.WaitForNextTickAsync(_stop.Token).ConfigureAwait(false));
            }
            catch (OperationCanceledException) when (_stop.IsCancellationRequested) { }
        });
    }
    public async ValueTask DisposeAsync()
    {
        await _stop.CancelAsync().ConfigureAwait(false);
        await _loop.ConfigureAwait(false);
        _stop.Dispose();
    }
}
