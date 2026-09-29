using System.Threading;

namespace HoverPocket.Shell.Services;

internal sealed class SingleInstanceGate : IDisposable
{
    private readonly Mutex _mutex;
    private readonly EventWaitHandle _showPanelEvent;
    private readonly EventWaitHandle? _stopEvent;
    private readonly CancellationTokenSource _cancellation = new();
    private readonly Task _watchTask;
    private bool _disposed;

    private SingleInstanceGate(
        Mutex mutex,
        EventWaitHandle showPanelEvent,
        EventWaitHandle? stopEvent)
    {
        _mutex = mutex;
        _showPanelEvent = showPanelEvent;
        _stopEvent = stopEvent;
        _watchTask = Task.Run(WatchForShowPanelRequests);
    }

    public event EventHandler? ShowPanelRequested;

    public event EventHandler? StopRequested;

    public static bool TryAcquire(SingleInstanceNames names, out SingleInstanceGate? gate)
    {
        var mutex = new Mutex(true, names.MutexName, out var createdNew);
        if (!createdNew)
        {
            NotifyExistingInstance(names);
            mutex.Dispose();
            gate = null;
            return false;
        }

        var showPanelEvent = new EventWaitHandle(false, EventResetMode.AutoReset, names.ShowPanelEventName);
        var stopEvent = names.StopEventName is { Length: > 0 } stopEventName
            ? new EventWaitHandle(false, EventResetMode.AutoReset, stopEventName)
            : null;
        gate = new SingleInstanceGate(mutex, showPanelEvent, stopEvent);
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
        _stopEvent?.Set();

        try
        {
            _watchTask.Wait(TimeSpan.FromMilliseconds(500));
        }
        catch (AggregateException)
        {
        }

        _showPanelEvent.Dispose();
        _stopEvent?.Dispose();
        _mutex.ReleaseMutex();
        _mutex.Dispose();
        _cancellation.Dispose();
    }

    private static void NotifyExistingInstance(SingleInstanceNames names)
    {
        try
        {
            using var showPanelEvent = EventWaitHandle.OpenExisting(names.ShowPanelEventName);
            showPanelEvent.Set();
        }
        catch (WaitHandleCannotBeOpenedException)
        {
        }
    }

    private void WatchForShowPanelRequests()
    {
        var handles = _stopEvent is null
            ? new WaitHandle[] { _showPanelEvent }
            : [_showPanelEvent, _stopEvent];
        while (!_cancellation.IsCancellationRequested)
        {
            var signaled = WaitHandle.WaitAny(handles, TimeSpan.FromMilliseconds(250));
            if (signaled == 0)
            {
                if (!_cancellation.IsCancellationRequested)
                {
                    ShowPanelRequested?.Invoke(this, EventArgs.Empty);
                }
            }
            else if (signaled == 1 && !_cancellation.IsCancellationRequested)
            {
                StopRequested?.Invoke(this, EventArgs.Empty);
            }
        }
    }
}

internal sealed record SingleInstanceNames(
    string MutexName,
    string ShowPanelEventName,
    string? StopEventName = null)
{
    public static SingleInstanceNames Production { get; } = new(
        @"Local\HoverPocket.Windows.Shell.SingleInstance",
        @"Local\HoverPocket.Windows.Shell.ShowPanel");

    public static SingleInstanceNames Verification { get; } = new(
        @"Local\HoverPocket.Windows.Verifier.SingleInstance",
        @"Local\HoverPocket.Windows.Verifier.ShowPanel");

    public static SingleInstanceNames VoiceE2E { get; } = new(
        @"Local\HoverPocket.Windows.VoiceE2E.SingleInstance",
        @"Local\HoverPocket.Windows.VoiceE2E.ShowPanel",
        @"Local\HoverPocket.Windows.VoiceE2E.Stop");
}
