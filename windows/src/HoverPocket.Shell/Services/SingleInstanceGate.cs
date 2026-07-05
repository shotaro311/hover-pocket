using System.Threading;

namespace HoverPocket.Shell.Services;

internal sealed class SingleInstanceGate : IDisposable
{
    private const string MutexName = @"Local\HoverPocket.Windows.Shell.SingleInstance";
    private const string ShowPanelEventName = @"Local\HoverPocket.Windows.Shell.ShowPanel";

    private readonly Mutex _mutex;
    private readonly EventWaitHandle _showPanelEvent;
    private readonly CancellationTokenSource _cancellation = new();
    private readonly Task _watchTask;
    private bool _disposed;

    private SingleInstanceGate(Mutex mutex, EventWaitHandle showPanelEvent)
    {
        _mutex = mutex;
        _showPanelEvent = showPanelEvent;
        _watchTask = Task.Run(WatchForShowPanelRequests);
    }

    public event EventHandler? ShowPanelRequested;

    public static bool TryAcquire(out SingleInstanceGate? gate)
    {
        var mutex = new Mutex(true, MutexName, out var createdNew);
        if (!createdNew)
        {
            NotifyExistingInstance();
            mutex.Dispose();
            gate = null;
            return false;
        }

        var showPanelEvent = new EventWaitHandle(false, EventResetMode.AutoReset, ShowPanelEventName);
        gate = new SingleInstanceGate(mutex, showPanelEvent);
        return true;
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _cancellation.Cancel();
        _showPanelEvent.Set();

        try
        {
            _watchTask.Wait(TimeSpan.FromMilliseconds(500));
        }
        catch (AggregateException)
        {
        }

        _showPanelEvent.Dispose();
        _mutex.ReleaseMutex();
        _mutex.Dispose();
        _cancellation.Dispose();
    }

    private static void NotifyExistingInstance()
    {
        try
        {
            using var showPanelEvent = EventWaitHandle.OpenExisting(ShowPanelEventName);
            showPanelEvent.Set();
        }
        catch (WaitHandleCannotBeOpenedException)
        {
        }
    }

    private void WatchForShowPanelRequests()
    {
        while (!_cancellation.IsCancellationRequested)
        {
            if (_showPanelEvent.WaitOne(TimeSpan.FromMilliseconds(250)))
            {
                if (!_cancellation.IsCancellationRequested)
                {
                    ShowPanelRequested?.Invoke(this, EventArgs.Empty);
                }
            }
        }
    }
}
