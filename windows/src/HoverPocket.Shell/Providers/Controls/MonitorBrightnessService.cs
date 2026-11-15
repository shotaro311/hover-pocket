using System.Collections.Concurrent;
using System.Diagnostics;
using System.Management;
using System.Runtime.InteropServices;
using Microsoft.Win32;
using HoverPocket.Shell.Display;
using HoverPocket.Shell.Services;

namespace HoverPocket.Shell.Providers.Controls;

internal sealed record BrightnessTiming(
    TimeSpan CommandSpacing,
    TimeSpan ReadbackDelay,
    TimeSpan ReadbackRetryDelay,
    int ReadbackRetries,
    TimeSpan TransientRetryDelay,
    TimeSpan WriteTimeout,
    TimeSpan MonitorGateTimeout)
{
    // Measured on the development PC: a VCP 0x10 read takes about 63ms and a write is readable after 125-140ms.
    public static BrightnessTiming Default { get; } = new(
        TimeSpan.FromMilliseconds(60),
        TimeSpan.FromMilliseconds(100),
        TimeSpan.FromMilliseconds(150),
        2,
        TimeSpan.FromMilliseconds(55),
        TimeSpan.FromSeconds(4),
        TimeSpan.FromSeconds(3));
}

// DDC/CI work is serialized per physical monitor, never across monitors, so a slow or absent monitor
// cannot delay brightness changes on another one. Capability strings are not queried: they took
// 1.5-1.9s per monitor and are unnecessary for VCP 0x10.
internal sealed class MonitorBrightnessService : IMonitorBrightnessService, IDisposable
{
    internal const int ReadbackTolerance = 3;
    private const string DetectingError = "Brightness detection is still running.";
    private const uint ErrorGraphicsI2CTransmittingData = 0xC0262582;
    private const uint ErrorGraphicsI2CReceivingData = 0xC0262583;
    private const uint ErrorGraphicsDdcInvalidMessageCommand = 0xC0262589;
    private const uint ErrorGraphicsDdcInvalidMessageLength = 0xC026258A;
    private const uint ErrorGraphicsDdcInvalidMessageChecksum = 0xC026258B;
    private static readonly TimeSpan CacheLifetime = TimeSpan.FromSeconds(15);
    private static readonly TimeSpan InitialReadWait = TimeSpan.FromMilliseconds(180);
    private static readonly TimeSpan WmiWriteTimeout = TimeSpan.FromMilliseconds(2500);
    private readonly IDdcPlatform _platform;
    private readonly bool _includeWmi;
    private readonly BrightnessTiming _timing;
    private readonly DisplayLayoutService _displays = new();
    private readonly object _readSync = new();
    private readonly object _registrySync = new();
    private readonly SemaphoreSlim _discoveryGate = new(1, 1);
    private readonly SemaphoreSlim _wmiWriteGate = new(1, 1);
    private readonly ConcurrentDictionary<string, MonitorGate> _gates = new(StringComparer.OrdinalIgnoreCase);
    private readonly ConcurrentDictionary<string, long> _writeSequences = new(StringComparer.OrdinalIgnoreCase);
    private Task<IReadOnlyList<DisplayBrightnessState>>? _activeRead;
    private IReadOnlyList<DisplayBrightnessState>? _lastSnapshot;
    private DateTimeOffset _lastSnapshotAt;
    private DdcRegistry? _registry;
    private int _readGeneration;
    private int _activeWrites;
    private volatile bool _topologyDirty;
    private volatile bool _skipPrimary;
    private readonly bool _listening;
    private bool _disposed;

    public MonitorBrightnessService()
        : this(new NativeDdcPlatform(), includeWmi: true, BrightnessTiming.Default, listenForSystemEvents: true)
    {
    }

    internal MonitorBrightnessService(
        IDdcPlatform platform,
        bool includeWmi,
        BrightnessTiming timing,
        bool listenForSystemEvents)
    {
        _platform = platform;
        _includeWmi = includeWmi;
        _timing = timing;
        if (listenForSystemEvents)
        {
            SystemEvents.DisplaySettingsChanged += OnDisplaySettingsChanged;
            SystemEvents.PowerModeChanged += OnPowerModeChanged;
            _listening = true;
        }
    }

    public event EventHandler<IReadOnlyList<DisplayBrightnessState>>? StateChanged;

    public async Task<IReadOnlyList<DisplayBrightnessState>> ReadAsync(CancellationToken cancellationToken)
    {
        ThrowIfDisposed();
        Task<IReadOnlyList<DisplayBrightnessState>> readTask;
        lock (_readSync)
        {
            if (Volatile.Read(ref _activeWrites) > 0 && _lastSnapshot is not null)
            {
                return _lastSnapshot;
            }

            if (_lastSnapshot is not null
                && DateTimeOffset.UtcNow - _lastSnapshotAt <= CacheLifetime)
            {
                return _lastSnapshot;
            }

            if (_activeRead is null || _activeRead.IsCompleted)
            {
                _activeRead = StartRead();
            }

            readTask = _activeRead;
        }

        try
        {
            var snapshot = await readTask.WaitAsync(InitialReadWait, cancellationToken);
            StoreSnapshot(snapshot);
            return snapshot;
        }
        catch (TimeoutException)
        {
            return LastSnapshot() ?? FallbackStates(DetectingError);
        }
        catch (Exception ex) when (ex is ManagementException or COMException)
        {
            return LastSnapshot() ?? FallbackStates("Display brightness is unavailable.");
        }
    }

    public async Task<IReadOnlyList<DisplayBrightnessState>> SetBrightnessAsync(
        string displayId,
        int value,
        CancellationToken cancellationToken)
    {
        ThrowIfDisposed();
        var normalized = Math.Clamp(value, 0, 100);
        if (displayId.StartsWith("wmi:", StringComparison.OrdinalIgnoreCase))
        {
            return await SetWmiAsync(displayId, normalized, cancellationToken);
        }

        if (!displayId.StartsWith("ddc:", StringComparison.OrdinalIgnoreCase))
        {
            var rejected = Annotate(displayId, normalized, WriteResult.Failed("unknown-id", "unknown"));
            RecordFailure("unknown-id", "unknown");
            StoreSnapshot(rejected);
            return rejected;
        }

        var sequence = _writeSequences.AddOrUpdate(displayId, 1, (_, previous) => previous + 1);
        var operation = Task.Run(() => WriteDdc(displayId, normalized), CancellationToken.None);
        WriteResult result;
        try
        {
            result = await operation.WaitAsync(_timing.WriteTimeout, cancellationToken);
        }
        catch (TimeoutException)
        {
            var model = FindEndpoint(displayId)?.Model ?? "unknown";
            RecordFailure("timeout", model);
            result = WriteResult.TimedOut(model);
            // The command keeps its monitor gate until it really finishes, so the next write cannot race
            // with it. Publish the late result so the panel does not keep showing the timeout.
            _ = operation.ContinueWith(
                completed =>
                {
                    if (_disposed
                        || !_writeSequences.TryGetValue(displayId, out var latest)
                        || latest != sequence)
                    {
                        return;
                    }

                    var late = Annotate(displayId, normalized, completed.Result);
                    StoreSnapshot(late);
                    StateChanged?.Invoke(this, late);
                },
                CancellationToken.None,
                TaskContinuationOptions.OnlyOnRanToCompletion,
                TaskScheduler.Default);
        }

        var annotated = Annotate(displayId, normalized, result);
        StoreSnapshot(annotated);
        return annotated;
    }

    internal async Task<DisplayBrightnessState?> ReadTargetFreshAsync(
        string displayId,
        CancellationToken cancellationToken)
    {
        ThrowIfDisposed();
        var readTask = Task.Run(() =>
        {
            if (displayId.StartsWith("ddc:", StringComparison.OrdinalIgnoreCase))
            {
                var endpoint = FindEndpoint(displayId);
                if (endpoint is null)
                {
                    return null;
                }

                var gate = Gate(displayId);
                if (!gate.Semaphore.Wait(_timing.MonitorGateTimeout))
                {
                    return null;
                }

                try
                {
                    if (endpoint.Retired)
                    {
                        endpoint = FindEndpoint(displayId);
                        if (endpoint is null || endpoint.Retired)
                        {
                            return null;
                        }
                    }

                    return TryReadBrightness(endpoint, gate, endpoint.UseHighLevel)
                        ? endpoint.State()
                        : endpoint.State("DDC/CI brightness read failed.");
                }
                finally
                {
                    gate.Semaphore.Release();
                }
            }

            if (!displayId.StartsWith("wmi:", StringComparison.OrdinalIgnoreCase)
                || !int.TryParse(displayId.AsSpan("wmi:".Length), out var targetIndex))
            {
                return null;
            }

            var wmi = ReadWmiBrightness();
            var target = wmi.FirstOrDefault(candidate => candidate.Index == targetIndex);
            var previous = LastSnapshot()?.FirstOrDefault(display =>
                string.Equals(display.Id, displayId, StringComparison.OrdinalIgnoreCase));
            return target is null
                ? null
                : new DisplayBrightnessState(displayId, previous?.Name ?? "Built-in display", true, target.Value, IsPrimary: previous?.IsPrimary);
        }, CancellationToken.None);
        return await readTask.WaitAsync(_timing.WriteTimeout, cancellationToken);
    }

    internal static bool WriteMatches(bool accepted, DisplayBrightnessState? fresh, int requested) =>
        accepted
        && fresh is { Supported: true, Value: int observed }
        && string.IsNullOrWhiteSpace(fresh.Error)
        && Math.Abs(observed - requested) <= ReadbackTolerance;

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        if (_listening)
        {
            SystemEvents.DisplaySettingsChanged -= OnDisplaySettingsChanged;
            SystemEvents.PowerModeChanged -= OnPowerModeChanged;
        }

        DdcRegistry? registry;
        lock (_registrySync)
        {
            registry = _registry;
            _registry = null;
        }

        if (registry is not null)
        {
            Retire(registry);
        }
    }

    private void OnDisplaySettingsChanged(object? sender, EventArgs e) => InvalidateTopology();

    private void OnPowerModeChanged(object? sender, PowerModeChangedEventArgs e)
    {
        if (e.Mode == PowerModes.Resume)
        {
            InvalidateTopology();
        }
    }

    internal void InvalidateTopology()
    {
        _topologyDirty = true;
        lock (_readSync)
        {
            _lastSnapshotAt = DateTimeOffset.MinValue;
        }
    }

    private Task<IReadOnlyList<DisplayBrightnessState>> StartRead()
    {
        var generation = ++_readGeneration;
        var task = Task.Run<IReadOnlyList<DisplayBrightnessState>>(Read, CancellationToken.None);
        _ = task.ContinueWith(
            completed =>
            {
                lock (_readSync)
                {
                    if (generation == _readGeneration)
                    {
                        _lastSnapshot = completed.Result;
                        _lastSnapshotAt = DateTimeOffset.UtcNow;
                    }
                }

                StateChanged?.Invoke(this, completed.Result);
            },
            CancellationToken.None,
            TaskContinuationOptions.OnlyOnRanToCompletion | TaskContinuationOptions.ExecuteSynchronously,
            TaskScheduler.Default);
        return task;
    }

    private IReadOnlyList<DisplayBrightnessState> Read()
    {
        var result = new List<DisplayBrightnessState>();
        if (_includeWmi)
        {
            var displayLayout = _displays.EnumerateMonitors();
            var wmi = ReadWmiBrightness();
            foreach (var monitor in wmi)
            {
                result.Add(new DisplayBrightnessState(
                    $"wmi:{monitor.Index}",
                    monitor.Index < displayLayout.Count
                        ? $"Built-in display ({displayLayout[monitor.Index].Name})"
                        : monitor.Index == 0 ? "Built-in display" : $"Built-in display {monitor.Index + 1}",
                    true,
                    monitor.Value,
                    IsPrimary: monitor.Index < displayLayout.Count ? displayLayout[monitor.Index].IsPrimary : monitor.Index == 0));
            }

            _skipPrimary = wmi.Count > 0;
        }

        var registry = EnsureRegistry();
        result.AddRange(registry.States());
        return result.Count == 0
            ? [new DisplayBrightnessState("display:none", "Display", false, null, "Display brightness is unavailable.")]
            : result;
    }

    private DdcRegistry EnsureRegistry()
    {
        var current = CurrentRegistry();
        if (current is not null && !_topologyDirty)
        {
            var key = TopologyKey(FilterMonitors(_platform.EnumerateMonitors()));
            if (string.Equals(current.TopologyKey, key, StringComparison.Ordinal))
            {
                RefreshValues(current);
                return current;
            }
        }

        return Rebuild(current);
    }

    // observed is the registry the caller found stale. If another caller replaced it while this one
    // waited, and the topology still matches, the newer registry is reused instead of probing again.
    private DdcRegistry Rebuild(DdcRegistry? observed)
    {
        _discoveryGate.Wait();
        try
        {
            var monitors = FilterMonitors(_platform.EnumerateMonitors());
            var key = TopologyKey(monitors);
            var current = CurrentRegistry();
            if (current is not null
                && !ReferenceEquals(current, observed)
                && string.Equals(current.TopologyKey, key, StringComparison.Ordinal))
            {
                return current;
            }

            _topologyDirty = false;

            var slots = new List<DdcSlot>();
            foreach (var monitor in monitors)
            {
                var physical = _platform.OpenPhysicalMonitors(monitor.Handle);
                if (physical.Count == 0)
                {
                    var device = monitor.Devices.FirstOrDefault();
                    slots.Add(new DdcSlot(null, new DisplayBrightnessState(
                        UnavailableId(monitor, device),
                        DisplayName(monitor, device, null, 0),
                        false,
                        null,
                        "DDC/CI is not available.",
                        IsPrimary: monitor.IsPrimary)));
                    continue;
                }

                for (var index = 0; index < physical.Count; index++)
                {
                    var device = index < monitor.Devices.Count ? monitor.Devices[index] : null;
                    var endpoint = new DdcEndpoint(
                        DdcId(monitor, device, index),
                        DisplayName(monitor, device, physical[index].Description, index),
                        device?.Model ?? "unknown",
                        device?.StableKey,
                        monitor.DeviceName,
                        index,
                        monitor.IsPrimary,
                        physical[index]);
                    var gate = Gate(endpoint.Id);
                    if (!gate.Semaphore.Wait(_timing.MonitorGateTimeout))
                    {
                        endpoint.Dispose();
                        _topologyDirty = true;
                        slots.Add(new DdcSlot(null, new DisplayBrightnessState(
                            endpoint.Id, endpoint.Name, false, null, DetectingError, IsPrimary: monitor.IsPrimary)));
                        continue;
                    }

                    bool readable;
                    try
                    {
                        readable = TryReadBrightness(endpoint, gate, preferHighLevel: false);
                    }
                    finally
                    {
                        gate.Semaphore.Release();
                    }

                    if (readable)
                    {
                        slots.Add(new DdcSlot(endpoint, null));
                    }
                    else
                    {
                        endpoint.Dispose();
                        slots.Add(new DdcSlot(null, new DisplayBrightnessState(
                            endpoint.Id,
                            endpoint.Name,
                            false,
                            null,
                            "DDC/CI brightness is not supported.",
                            IsPrimary: monitor.IsPrimary)));
                    }
                }
            }

            var replacement = new DdcRegistry(key, slots);
            DdcRegistry? previous;
            lock (_registrySync)
            {
                if (_disposed)
                {
                    previous = replacement;
                }
                else
                {
                    previous = _registry;
                    _registry = replacement;
                }
            }

            if (previous is not null)
            {
                Retire(previous);
            }

            return replacement;
        }
        finally
        {
            _discoveryGate.Release();
        }
    }

    private void RefreshValues(DdcRegistry registry)
    {
        foreach (var endpoint in registry.Endpoints)
        {
            var gate = Gate(endpoint.Id);
            // A write in progress already owns the freshest value; never queue a read behind it.
            if (!gate.Semaphore.Wait(0))
            {
                continue;
            }

            try
            {
                if (endpoint.Retired)
                {
                    continue;
                }

                if (TryReadBrightness(endpoint, gate, endpoint.UseHighLevel))
                {
                    endpoint.LastError = null;
                }
                else
                {
                    endpoint.LastError = "DDC/CI brightness read failed.";
                    endpoint.NeedsReopen = true;
                }
            }
            finally
            {
                gate.Semaphore.Release();
            }
        }
    }

    private WriteResult WriteDdc(string displayId, int normalized)
    {
        Interlocked.Increment(ref _activeWrites);
        try
        {
            var endpoint = FindEndpoint(displayId);
            if (endpoint is null)
            {
                // The panel may still hold an ID from before a topology change. Rediscover once.
                _ = Rebuild(CurrentRegistry());
                endpoint = FindEndpoint(displayId);
            }

            if (endpoint is null)
            {
                var model = ModelFromId(displayId);
                RecordFailure("unknown-id", model);
                return WriteResult.Failed("unknown-id", model);
            }

            var gate = Gate(displayId);
            if (!gate.Semaphore.Wait(_timing.MonitorGateTimeout))
            {
                RecordFailure("busy", endpoint.Model);
                return WriteResult.Failed("busy", endpoint.Model);
            }

            try
            {
                if (endpoint.Retired)
                {
                    // A rediscovery dropped this monitor; its handle may already be released.
                    var replacement = FindEndpoint(displayId);
                    if (replacement is null || replacement.Retired)
                    {
                        RecordFailure("unknown-id", endpoint.Model);
                        return WriteResult.Failed("unknown-id", endpoint.Model);
                    }

                    endpoint = replacement;
                }

                if (endpoint.NeedsReopen)
                {
                    _ = Reopen(endpoint, gate);
                }

                var accepted = TrySetBrightness(endpoint, gate, normalized);
                if (!accepted && Reopen(endpoint, gate))
                {
                    accepted = TrySetBrightness(endpoint, gate, normalized);
                }

                if (!accepted)
                {
                    endpoint.NeedsReopen = true;
                    _topologyDirty = true;
                    RecordFailure("set-failed", endpoint.Model);
                    return WriteResult.Failed("set-failed", endpoint.Model, endpoint.State());
                }

                endpoint.NeedsReopen = false;
                endpoint.Value = normalized;
                endpoint.LastError = null;
                Thread.Sleep(_timing.ReadbackDelay);
                DisplayBrightnessState? fresh = null;
                var verified = false;
                for (var attempt = 0; attempt <= _timing.ReadbackRetries; attempt++)
                {
                    if (attempt > 0)
                    {
                        Thread.Sleep(_timing.ReadbackRetryDelay);
                    }

                    if (!TryReadBrightness(endpoint, gate, endpoint.UseHighLevel))
                    {
                        continue;
                    }

                    fresh = endpoint.State();
                    if (Math.Abs(endpoint.Value - normalized) <= ReadbackTolerance)
                    {
                        verified = true;
                        break;
                    }
                }

                if (!verified)
                {
                    RecordFailure("readback-mismatch", endpoint.Model);
                }

                return new WriteResult(true, fresh, verified, false, endpoint.Model, verified ? null : "readback-mismatch");
            }
            finally
            {
                gate.Semaphore.Release();
            }
        }
        finally
        {
            Interlocked.Decrement(ref _activeWrites);
        }
    }

    // Called with the monitor gate held. Reopens the physical handle for the same stable monitor,
    // following it to a new HMONITOR when Windows recreated the logical monitor.
    private bool Reopen(DdcEndpoint endpoint, MonitorGate gate)
    {
        foreach (var monitor in FilterMonitors(_platform.EnumerateMonitors()))
        {
            var index = endpoint.StableKey is null
                ? string.Equals(monitor.DeviceName, endpoint.DeviceName, StringComparison.OrdinalIgnoreCase) ? endpoint.PhysicalIndex : -1
                : IndexOfDevice(monitor, endpoint.StableKey);
            if (index < 0)
            {
                continue;
            }

            var physical = _platform.OpenPhysicalMonitors(monitor.Handle);
            if (index >= physical.Count)
            {
                foreach (var item in physical)
                {
                    item.Dispose();
                }

                return false;
            }

            for (var other = 0; other < physical.Count; other++)
            {
                if (other != index)
                {
                    physical[other].Dispose();
                }
            }

            endpoint.SwapMonitor(physical[index]).Dispose();
            _topologyDirty = true;
            var readable = TryReadBrightness(endpoint, gate, preferHighLevel: false);
            endpoint.NeedsReopen = !readable;
            return readable;
        }

        return false;
    }

    private static int IndexOfDevice(DdcLogicalMonitor monitor, string stableKey)
    {
        for (var index = 0; index < monitor.Devices.Count; index++)
        {
            if (string.Equals(monitor.Devices[index].StableKey, stableKey, StringComparison.OrdinalIgnoreCase))
            {
                return index;
            }
        }

        return -1;
    }

    private bool TryReadBrightness(DdcEndpoint endpoint, MonitorGate gate, bool preferHighLevel)
    {
        if (preferHighLevel && TryReadHighLevel(endpoint, gate))
        {
            return true;
        }

        for (var attempt = 0; attempt < 2; attempt++)
        {
            WaitForSpacing(gate);
            var ok = endpoint.Monitor.TryReadVcpBrightness(out var current, out var maximum, out var error);
            gate.Touch();
            if (ok && IsValidRange(0, current, maximum))
            {
                endpoint.UseHighLevel = false;
                endpoint.Minimum = 0;
                endpoint.Maximum = maximum;
                endpoint.Value = ToPercentage(0, current, maximum);
                return true;
            }

            if (ok || !IsTransientDdcError(error))
            {
                break;
            }

            Thread.Sleep(_timing.TransientRetryDelay);
        }

        return !preferHighLevel && TryReadHighLevel(endpoint, gate);
    }

    private bool TryReadHighLevel(DdcEndpoint endpoint, MonitorGate gate)
    {
        WaitForSpacing(gate);
        var ok = endpoint.Monitor.TryReadHighLevelBrightness(out var minimum, out var current, out var maximum, out _);
        gate.Touch();
        if (!ok || !IsValidRange(minimum, current, maximum))
        {
            return false;
        }

        endpoint.UseHighLevel = true;
        endpoint.Minimum = minimum;
        endpoint.Maximum = maximum;
        endpoint.Value = ToPercentage(minimum, current, maximum);
        return true;
    }

    private bool TrySetBrightness(DdcEndpoint endpoint, MonitorGate gate, int normalized)
    {
        var target = endpoint.Minimum + (uint)Math.Round(
            (endpoint.Maximum - endpoint.Minimum) * normalized / 100d,
            MidpointRounding.AwayFromZero);
        for (var attempt = 0; attempt < 2; attempt++)
        {
            if (attempt > 0)
            {
                Thread.Sleep(_timing.TransientRetryDelay);
            }

            WaitForSpacing(gate);
            var ok = endpoint.UseHighLevel
                ? endpoint.Monitor.TryWriteHighLevelBrightness(target, out _)
                : endpoint.Monitor.TryWriteVcpBrightness(target, out _);
            gate.Touch();
            if (ok)
            {
                return true;
            }
        }

        return false;
    }

    private void WaitForSpacing(MonitorGate gate)
    {
        var remaining = _timing.CommandSpacing - gate.SinceLastCommand();
        if (remaining > TimeSpan.Zero)
        {
            Thread.Sleep(remaining);
        }
    }

    private async Task<IReadOnlyList<DisplayBrightnessState>> SetWmiAsync(
        string displayId,
        int normalized,
        CancellationToken cancellationToken)
    {
        await _wmiWriteGate.WaitAsync(cancellationToken);
        Interlocked.Increment(ref _activeWrites);
        try
        {
            var writeTask = Task.Run(() => SetWmiBrightness(displayId, normalized), CancellationToken.None);
            var accepted = false;
            try
            {
                accepted = await writeTask.WaitAsync(WmiWriteTimeout, cancellationToken);
            }
            catch (TimeoutException)
            {
            }

            DisplayBrightnessState? fresh = null;
            if (accepted)
            {
                await Task.Delay(_timing.ReadbackDelay, cancellationToken);
                try
                {
                    fresh = await ReadTargetFreshAsync(displayId, cancellationToken);
                }
                catch (Exception ex) when (ex is TimeoutException or ManagementException or COMException)
                {
                }
            }

            var verified = WriteMatches(accepted, fresh, normalized);
            if (!verified)
            {
                RecordFailure(accepted ? "readback-mismatch" : "set-failed", "wmi");
            }

            var annotated = Annotate(
                displayId,
                normalized,
                new WriteResult(accepted, fresh, verified, false, "wmi", null));
            StoreSnapshot(annotated);
            return annotated;
        }
        finally
        {
            Interlocked.Decrement(ref _activeWrites);
            _wmiWriteGate.Release();
        }
    }

    private IReadOnlyList<DisplayBrightnessState> Annotate(string displayId, int value, WriteResult result)
    {
        var current = ComposeCached();
        var matched = false;
        var error = result.Verified
            ? null
            : result.TimedOutCommand
                ? "Brightness command timed out."
                : result.Accepted
                    ? $"Brightness readback did not match {value}%."
                    : $"Brightness command failed for {value}%.";
        var annotated = current.Select(display =>
        {
            if (!string.Equals(display.Id, displayId, StringComparison.OrdinalIgnoreCase))
            {
                return display;
            }

            matched = true;
            var observed = result.Fresh ?? display;
            return observed with
            {
                Name = string.IsNullOrWhiteSpace(observed.Name) ? display.Name : observed.Name,
                IsPrimary = observed.IsPrimary ?? display.IsPrimary,
                Error = error,
                WriteVerified = result.Verified
            };
        }).ToList();
        if (!matched)
        {
            annotated.Add((result.Fresh ?? new DisplayBrightnessState(displayId, "Display", false, null)) with
            {
                Error = error,
                WriteVerified = result.Verified
            });
        }

        return annotated;
    }

    // Combines the last WMI states with the cached DDC registry without touching the hardware.
    private IReadOnlyList<DisplayBrightnessState> ComposeCached()
    {
        var last = LastSnapshot();
        var registry = CurrentRegistry();
        if (registry is null)
        {
            return last ?? FallbackStates("Brightness state is still loading.");
        }

        var combined = (last ?? [])
            .Where(display => display.Id.StartsWith("wmi:", StringComparison.OrdinalIgnoreCase))
            .Concat(registry.States())
            .ToList();
        return combined.Count == 0 ? last ?? FallbackStates("Brightness state is still loading.") : combined;
    }

    private IReadOnlyList<DdcLogicalMonitor> FilterMonitors(IReadOnlyList<DdcLogicalMonitor> monitors) =>
        _skipPrimary ? monitors.Where(monitor => !monitor.IsPrimary).ToArray() : monitors;

    private DdcEndpoint? FindEndpoint(string displayId)
    {
        var registry = CurrentRegistry();
        return registry?.Endpoints.FirstOrDefault(endpoint =>
            string.Equals(endpoint.Id, displayId, StringComparison.OrdinalIgnoreCase));
    }

    private DdcRegistry? CurrentRegistry()
    {
        lock (_registrySync)
        {
            return _registry;
        }
    }

    private MonitorGate Gate(string displayId) => _gates.GetOrAdd(displayId, _ => new MonitorGate());

    private void Retire(DdcRegistry registry)
    {
        foreach (var endpoint in registry.Endpoints)
        {
            endpoint.Retired = true;
            var gate = Gate(endpoint.Id);
            _ = Task.Run(() =>
            {
                gate.Semaphore.Wait();
                try
                {
                    endpoint.Dispose();
                }
                finally
                {
                    gate.Semaphore.Release();
                }
            });
        }
    }

    private IReadOnlyList<DisplayBrightnessState>? LastSnapshot()
    {
        lock (_readSync)
        {
            return _lastSnapshot;
        }
    }

    private void StoreSnapshot(IReadOnlyList<DisplayBrightnessState> snapshot)
    {
        lock (_readSync)
        {
            _lastSnapshot = snapshot;
            _lastSnapshotAt = DateTimeOffset.UtcNow;
        }
    }

    private IReadOnlyList<DisplayBrightnessState> FallbackStates(string error)
    {
        var displays = _displays.EnumerateMonitors();
        return displays.Count == 0
            ? [new DisplayBrightnessState("display:none", "Display", false, null, error)]
            : displays.Select(display => new DisplayBrightnessState(
                $"display:{display.NativeHandle.ToInt64():X}",
                display.Name,
                false,
                null,
                error,
                IsPrimary: display.IsPrimary)).ToArray();
    }

    private static void RecordFailure(string reason, string model) =>
        AppDiagnostics.Record("brightness.write.failed", detail: $"reason={reason};model={model}");

    private static string ModelFromId(string displayId)
    {
        var key = displayId.StartsWith("ddc:", StringComparison.OrdinalIgnoreCase) ? displayId[4..] : displayId;
        var dash = key.IndexOf('-');
        return dash > 0 ? key[..dash] : "unknown";
    }

    internal static string DdcId(DdcLogicalMonitor monitor, DdcMonitorDevice? device, int physicalIndex) =>
        device is null
            ? $"ddc:{NativeDdcPlatform.SanitizeKey(monitor.DeviceName)}-{physicalIndex}"
            : $"ddc:{device.StableKey}-{physicalIndex}";

    private static string UnavailableId(DdcLogicalMonitor monitor, DdcMonitorDevice? device) =>
        device is null
            ? $"display:{NativeDdcPlatform.SanitizeKey(monitor.DeviceName)}"
            : $"display:{device.StableKey}";

    private static string DisplayName(DdcLogicalMonitor monitor, DdcMonitorDevice? device, string? description, int physicalIndex)
    {
        var name = !string.IsNullOrWhiteSpace(device?.FriendlyName)
            ? device.FriendlyName!
            : !string.IsNullOrWhiteSpace(description)
                ? description!
                : monitor.DeviceName;
        return physicalIndex == 0 ? name : $"{name} {physicalIndex + 1}";
    }

    private static string TopologyKey(IReadOnlyList<DdcLogicalMonitor> monitors) => string.Join(
        '|',
        monitors.Select(monitor =>
            $"{monitor.Handle.ToInt64():X}:{monitor.DeviceName}:{monitor.IsPrimary}:{string.Join(',', monitor.Devices.Select(device => device.StableKey))}"));

    private static bool IsValidRange(uint minimum, uint current, uint maximum) =>
        minimum < maximum && current >= minimum && current <= maximum;

    private static int ToPercentage(uint minimum, uint current, uint maximum) =>
        Math.Clamp((int)Math.Round(
            (current - minimum) * 100d / (maximum - minimum),
            MidpointRounding.AwayFromZero), 0, 100);

    private static bool IsTransientDdcError(int error) => unchecked((uint)error) is
        ErrorGraphicsI2CTransmittingData
        or ErrorGraphicsI2CReceivingData
        or ErrorGraphicsDdcInvalidMessageCommand
        or ErrorGraphicsDdcInvalidMessageLength
        or ErrorGraphicsDdcInvalidMessageChecksum;

    private static IReadOnlyList<WmiBrightness> ReadWmiBrightness()
    {
        var result = new List<WmiBrightness>();
        try
        {
            using var searcher = new ManagementObjectSearcher(
                "root\\WMI",
                "SELECT CurrentBrightness, Active FROM WmiMonitorBrightness WHERE Active = TRUE");
            using var collection = searcher.Get();
            foreach (ManagementObject item in collection)
            {
                using (item)
                {
                    var value = Convert.ToInt32(item["CurrentBrightness"], System.Globalization.CultureInfo.InvariantCulture);
                    result.Add(new WmiBrightness(result.Count, Math.Clamp(value, 0, 100)));
                }
            }
        }
        catch (Exception ex) when (ex is ManagementException or UnauthorizedAccessException or COMException)
        {
        }

        return result;
    }

    private static bool SetWmiBrightness(string displayId, int value)
    {
        if (!int.TryParse(displayId.AsSpan("wmi:".Length), out var targetIndex))
        {
            return false;
        }

        try
        {
            using var searcher = new ManagementObjectSearcher(
                "root\\WMI",
                "SELECT * FROM WmiMonitorBrightnessMethods WHERE Active = TRUE");
            using var collection = searcher.Get();
            var index = 0;
            foreach (ManagementObject item in collection)
            {
                using (item)
                {
                    if (index++ != targetIndex)
                    {
                        continue;
                    }

                    _ = item.InvokeMethod("WmiSetBrightness", [0U, (byte)value]);
                    return true;
                }
            }
        }
        catch (Exception ex) when (ex is ManagementException or UnauthorizedAccessException or COMException)
        {
        }

        return false;
    }

    private void ThrowIfDisposed()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
    }

    private sealed record WriteResult(
        bool Accepted,
        DisplayBrightnessState? Fresh,
        bool Verified,
        bool TimedOutCommand,
        string Model,
        string? FailureReason)
    {
        public static WriteResult Failed(string reason, string model, DisplayBrightnessState? state = null) =>
            new(false, state, false, false, model, reason);

        public static WriteResult TimedOut(string model) => new(false, null, false, true, model, "timeout");
    }

    private sealed class MonitorGate
    {
        private long _lastCommandTimestamp;

        public SemaphoreSlim Semaphore { get; } = new(1, 1);

        public TimeSpan SinceLastCommand()
        {
            var last = Volatile.Read(ref _lastCommandTimestamp);
            return last == 0 ? TimeSpan.MaxValue : Stopwatch.GetElapsedTime(last);
        }

        public void Touch() => Volatile.Write(ref _lastCommandTimestamp, Stopwatch.GetTimestamp());
    }

    private sealed class DdcEndpoint(
        string id,
        string name,
        string model,
        string? stableKey,
        string deviceName,
        int physicalIndex,
        bool isPrimary,
        IDdcPhysicalMonitor monitor) : IDisposable
    {
        public string Id { get; } = id;

        public string Name { get; } = name;

        public string Model { get; } = model;

        public string? StableKey { get; } = stableKey;

        public string DeviceName { get; } = deviceName;

        public int PhysicalIndex { get; } = physicalIndex;

        public bool IsPrimary { get; } = isPrimary;

        public IDdcPhysicalMonitor Monitor { get; private set; } = monitor;

        public bool UseHighLevel { get; set; }

        public uint Minimum { get; set; }

        public uint Maximum { get; set; } = 100;

        public int Value { get; set; }

        public string? LastError { get; set; }

        public bool NeedsReopen { get; set; }

        public volatile bool Retired;

        public IDdcPhysicalMonitor SwapMonitor(IDdcPhysicalMonitor next)
        {
            var previous = Monitor;
            Monitor = next;
            return previous;
        }

        public DisplayBrightnessState State(string? error = null) =>
            new(Id, Name, true, Value, error ?? LastError, IsPrimary: IsPrimary);

        public void Dispose() => Monitor.Dispose();
    }

    private sealed record DdcSlot(DdcEndpoint? Endpoint, DisplayBrightnessState? Unavailable)
    {
        public DisplayBrightnessState State() => Endpoint?.State() ?? Unavailable!;
    }

    private sealed record DdcRegistry(string TopologyKey, IReadOnlyList<DdcSlot> Slots)
    {
        public IEnumerable<DdcEndpoint> Endpoints => Slots.Select(slot => slot.Endpoint).OfType<DdcEndpoint>();

        public IEnumerable<DisplayBrightnessState> States() => Slots.Select(slot => slot.State());
    }

    private sealed record WmiBrightness(int Index, int Value);
}
