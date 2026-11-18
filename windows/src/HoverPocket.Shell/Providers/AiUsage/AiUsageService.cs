using System.Windows;

namespace HoverPocket.Shell.Providers.AiUsage;

/// <summary>
/// Keeps the latest usage of each AI service and refreshes it on demand: when the panel or the
/// Settings AI section is shown, when the user presses refresh, and right after a sign-in. There is no
/// background polling. Called on the WPF UI thread; the Codex read runs on the thread pool.
/// </summary>
internal sealed class AiUsageService : IDisposable
{
    public static readonly TimeSpan StaleAfter = TimeSpan.FromMinutes(2);
    public static readonly TimeSpan SignedOutRecheckAfter = TimeSpan.FromMinutes(30);

    private readonly string _codexProfileRoot;
    private readonly string _webDataFolder;
    private readonly Func<string, CancellationToken, Task<AiUsageResult>>? _readerOverride;
    private readonly Func<DateTimeOffset> _clock;
    private readonly AiUsageWebReader _webReader = new();
    private readonly Dictionary<string, AiUsageServiceSnapshot> _snapshots = new(StringComparer.Ordinal);
    private readonly Dictionary<string, int> _generations = new(StringComparer.Ordinal);
    private readonly SemaphoreSlim _refreshGate = new(1, 1);
    private readonly Dictionary<string, AiUsageSignInWindow> _signInWindows = new(StringComparer.Ordinal);
    private readonly CancellationTokenSource _lifetime = new();
    private (Task Task, HashSet<string> Services, bool Force, Dictionary<string, int> Generations)? _inflight;
    private bool _disposed;

    public AiUsageService(
        string codexProfileRoot,
        string webDataFolder,
        Func<string, CancellationToken, Task<AiUsageResult>>? readerOverride = null,
        Func<DateTimeOffset>? clock = null)
    {
        _codexProfileRoot = codexProfileRoot;
        _webDataFolder = webDataFolder;
        _readerOverride = readerOverride;
        _clock = clock ?? (() => DateTimeOffset.UtcNow);
        foreach (var id in AiUsageServiceIds.All)
        {
            _snapshots[id] = AiUsageServiceSnapshot.Initial(id);
            _generations[id] = 0;
        }
    }

    public event EventHandler? Changed;

    public AiUsageServiceSnapshot Snapshot(string id)
    {
        lock (_snapshots) return _snapshots[id];
    }

    public object BuildState(IReadOnlyCollection<string> hiddenServices)
    {
        AiUsageServiceSnapshot[] snapshots;
        lock (_snapshots) snapshots = AiUsageServiceIds.All.Select(id => _snapshots[id]).ToArray();
        return new
        {
            refreshing = snapshots.Any(snapshot => snapshot.Refreshing),
            services = snapshots.Select(snapshot => new
            {
                id = snapshot.Id,
                name = AiUsageServiceIds.DisplayName(snapshot.Id),
                visible = !hiddenServices.Contains(snapshot.Id, StringComparer.Ordinal),
                signIn = snapshot.Id == AiUsageServiceIds.Codex ? "codex" : "web",
                status = snapshot.Status,
                plan = snapshot.Plan,
                errorCode = snapshot.ErrorCode,
                stale = snapshot.Stale,
                refreshing = snapshot.Refreshing,
                fetchedAt = snapshot.FetchedAt?.ToString("O"),
                windows = snapshot.Windows.Select(window => new
                {
                    kind = window.Kind,
                    model = window.Model,
                    usedPercent = window.UsedPercent,
                    resetsAt = window.ResetsAt?.ToString("O"),
                    windowMinutes = window.WindowMinutes
                }).ToArray()
            }).ToArray()
        };
    }

    /// <summary>
    /// Refreshes the given services. Without <paramref name="force"/>, services checked within
    /// <see cref="StaleAfter"/> are skipped, and a signed-out service is re-checked only after
    /// <see cref="SignedOutRecheckAfter"/>. A request already covered by a running refresh joins it.
    /// </summary>
    public Task RefreshAsync(IReadOnlyCollection<string> services, bool force, CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        var wanted = services.Where(AiUsageServiceIds.IsKnown).ToHashSet(StringComparer.Ordinal);
        // Join a running refresh only if it covers these services and no sign-in or sign-out happened
        // since it began; otherwise its results would be discarded and nothing would read the new account.
        if (_inflight is { } current && !current.Task.IsCompleted && (current.Force || !force) && wanted.IsSubsetOf(current.Services)
            && wanted.All(id => current.Generations[id] == Generation(id)))
            return current.Task.WaitAsync(cancellationToken);
        var generations = wanted.ToDictionary(id => id, Generation, StringComparer.Ordinal);
        var task = RefreshCoreAsync(wanted, force, cancellationToken);
        _inflight = (task, wanted, force, generations);
        return task;
    }

    private async Task RefreshCoreAsync(HashSet<string> services, bool force, CancellationToken cancellationToken)
    {
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, _lifetime.Token);
        var token = linked.Token;
        await _refreshGate.WaitAsync(token);
        try
        {
            var now = _clock();
            var due = AiUsageServiceIds.All.Where(services.Contains).Where(id =>
            {
                var snapshot = Snapshot(id);
                if (force || snapshot.CheckedAt is not { } checkedAt) return true;
                var maxAge = snapshot.Status == AiUsageStatus.SignedOut ? SignedOutRecheckAfter : StaleAfter;
                return now - checkedAt >= maxAge;
            }).ToArray();
            if (due.Length == 0) return;
            foreach (var id in due) Update(id, snapshot => snapshot with { Refreshing = true });

            var codex = due.Contains(AiUsageServiceIds.Codex)
                ? RunOneAsync(AiUsageServiceIds.Codex, token, () => _readerOverride is { } reader
                    ? reader(AiUsageServiceIds.Codex, token)
                    : Task.Run(() => AiUsageCodexReader.ReadAsync(_codexProfileRoot, token), token))
                : Task.CompletedTask;
            var web = due.Where(id => id != AiUsageServiceIds.Codex).ToArray();
            await Task.WhenAll(codex, RefreshWebAsync(web, token));
        }
        finally
        {
            foreach (var id in AiUsageServiceIds.All)
                if (Snapshot(id).Refreshing) Update(id, snapshot => snapshot with { Refreshing = false });
            _refreshGate.Release();
        }
    }

    private async Task RefreshWebAsync(IReadOnlyList<string> services, CancellationToken token)
    {
        if (services.Count == 0) return;
        if (_readerOverride is { } reader)
        {
            foreach (var id in services) await RunOneAsync(id, token, () => reader(id, token));
            return;
        }
        // WebView2 controllers and their host windows belong to the UI thread.
        if (System.Windows.Application.Current?.Dispatcher is { } dispatcher && !dispatcher.CheckAccess())
        {
            await dispatcher.InvokeAsync(() => RefreshWebAsync(services, token)).Task.Unwrap();
            return;
        }

        // Creating the view is part of the guarded read, so a profile that cannot be opened becomes this
        // service's error and the next service still runs.
        foreach (var id in services)
            await RunOneAsync(id, token, async () =>
            {
                await using var session = await AiUsageWebSession.CreateAsync(_webDataFolder, id);
                return await _webReader.ReadAsync(session, id, token);
            });
    }

    /// <summary>
    /// Reads one service and applies the result unless a sign-in or sign-out happened meanwhile; any
    /// failure becomes an error for that service only, so the other services still refresh.
    /// </summary>
    private async Task RunOneAsync(string id, CancellationToken token, Func<Task<AiUsageResult>> read)
    {
        var generation = Generation(id);
        AiUsageResult result;
        try
        {
            result = await read();
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception exception) when (exception is OperationCanceledException or TimeoutException)
        {
            result = AiUsageResult.Failure(AiUsageErrorCodes.Timeout);
        }
        catch (Exception exception)
        {
            Services.AppDiagnostics.Record("aiUsage.read.failed", exception);
            result = AiUsageResult.Failure(exception is AiUsageParseException or ArgumentException or FormatException
                or System.Text.Json.JsonException
                ? AiUsageErrorCodes.Changed
                : AiUsageErrorCodes.Unavailable);
        }
        Apply(id, result, generation);
    }

    private int Generation(string id)
    {
        lock (_snapshots) return _generations[id];
    }

    private void Apply(string id, AiUsageResult result, int generation)
    {
        var now = _clock();
        lock (_snapshots)
        {
            if (_generations[id] != generation) return;
            _snapshots[id] = _snapshots[id].Apply(result, now);
        }
        RaiseChanged();
    }

    private void Update(string id, Func<AiUsageServiceSnapshot, AiUsageServiceSnapshot> change)
    {
        lock (_snapshots) _snapshots[id] = change(_snapshots[id]);
        RaiseChanged();
    }

    private void RaiseChanged()
    {
        if (!_disposed) Changed?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>
    /// Forgets a service's readings because its account may have changed. Results of reads that started
    /// earlier are discarded, so a previous account's usage never reappears, even as a stale value.
    /// </summary>
    public void BeginAccountChange(string id)
    {
        lock (_snapshots)
        {
            _generations[id]++;
            _snapshots[id] = AiUsageServiceSnapshot.Initial(id);
        }
        RaiseChanged();
    }

    /// <summary>
    /// Opens the sign-in window for a web service and refreshes that service after it closes.
    /// Must be called on the UI thread.
    /// </summary>
    public async Task SignInAsync(string service, Window? owner, bool english, CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (!AiUsageServiceIds.Web.Contains(service, StringComparer.Ordinal))
            throw new ArgumentOutOfRangeException(nameof(service));
        if (_signInWindows.TryGetValue(service, out var existing))
        {
            existing.Activate();
            return;
        }

        var window = new AiUsageSignInWindow(service, _webDataFolder, AiUsageWebReader.SignInUri(service), english);
        if (owner is not null && owner.IsVisible) window.Owner = owner;
        var closed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        window.Closed += (_, _) =>
        {
            _signInWindows.Remove(service);
            closed.TrySetResult();
        };
        _signInWindows[service] = window;
        window.Show();
        window.Activate();
        using (cancellationToken.Register(() => window.Dispatcher.BeginInvoke(window.Close)))
            await closed.Task;
        if (_disposed) return;
        BeginAccountChange(service);
        await RefreshAsync([service], force: true, cancellationToken);
    }

    /// <summary>
    /// Clears the service's own WebView2 profile (cookies, storage, cache) and reads it again, so the
    /// shown state is the read-back result rather than an assumption. Other services are untouched.
    /// </summary>
    public async Task SignOutAsync(string service, CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (!AiUsageServiceIds.Web.Contains(service, StringComparer.Ordinal))
            throw new ArgumentOutOfRangeException(nameof(service));
        // Hide the old account at once, then again after the running refresh has finished and the profile
        // is cleared, so nothing read before the clearing survives, even if the read-back fails.
        BeginAccountChange(service);
        await _refreshGate.WaitAsync(cancellationToken);
        try
        {
            if (_readerOverride is null)
            {
                await using var session = await AiUsageWebSession.CreateAsync(_webDataFolder, service);
                await session.ClearProfileAsync();
            }
            BeginAccountChange(service);
        }
        finally
        {
            _refreshGate.Release();
        }
        await RefreshAsync([service], force: true, cancellationToken);
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        Changed = null;
        _lifetime.Cancel();
        foreach (var window in _signInWindows.Values.ToArray()) window.Close();
        _signInWindows.Clear();
    }
}
