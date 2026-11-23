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
    // How long a monitor that failed detection stays unsupported before the next read probes it again.
    public TimeSpan UnavailableRetry { get; init; } = TimeSpan.FromSeconds(30);

    // How long ReadAsync serves the last snapshot without touching the hardware.
    public TimeSpan CacheLifetime { get; init; } = TimeSpan.FromSeconds(15);

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
    private readonly ConcurrentDictionary<string, long> _contrastWriteSequences = new(StringComparer.OrdinalIgnoreCase);
    private Task<IReadOnlyList<DisplayBrightnessState>>? _activeRead;
    private IReadOnlyList<DisplayBrightnessState>? _lastSnapshot;
    private DateTimeOffset _lastSnapshotAt;
    private DdcRegistry? _registry;
    private int _readGeneration;
    private int _activeWrites;
    private volatile bool _topologyDirty;
    private volatile bool _skipPrimary;
    private volatile bool _contrastVisible;
    private bool _contrastRefreshPending;
    private long _contrastEnabledAt;
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

    // Verification only: runs on the rebuild thread after probing and before the registry swap.
    internal Action? BeforeRegistrySwapForVerify { get; set; }

    // Verification only: runs after request sequencing and before acquiring the monitor gate.
    internal Action<DdcFeature, string, int, uint?>? BeforeDdcWriteForVerify { get; set; }

    public async Task<IReadOnlyList<DisplayBrightnessState>> ReadAsync(CancellationToken cancellationToken)
    {
        ThrowIfDisposed();
        Task<IReadOnlyList<DisplayBrightnessState>> readTask;
        lock (_readSync)
        {
            if (Volatile.Read(ref _activeWrites) > 0 && (_lastSnapshot is not null || _contrastRefreshPending))
            {
                return _lastSnapshot ?? FallbackStates(DetectingError);
            }

            if (!_contrastRefreshPending && _lastSnapshot is not null
                && DateTimeOffset.UtcNow - _lastSnapshotAt <= _timing.CacheLifetime
                && (!_contrastVisible || CurrentRegistry()?.Endpoints.Any(endpoint => CanRetryContrast(endpoint.Contrast)) != true))
            {
                return _lastSnapshot;
            }

            if (_contrastRefreshPending || _activeRead is null || _activeRead.IsCompleted)
            {
                _activeRead = StartRead(_activeRead, _contrastVisible, _contrastRefreshPending);
                _contrastRefreshPending = false;
            }

            readTask = _activeRead;
        }

        try
        {
            return await readTask.WaitAsync(InitialReadWait, cancellationToken);
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

    public void SetContrastVisible(bool visible)
    {
        lock (_readSync)
        {
            if (_contrastVisible == visible)
            {
                return;
            }

            if (visible)
            {
                Volatile.Write(ref _contrastEnabledAt, Stopwatch.GetTimestamp());
                _lastSnapshotAt = DateTimeOffset.MinValue;
            }

            _contrastVisible = visible;
            _contrastRefreshPending = visible;
        }
    }

    public Task<IReadOnlyList<DisplayBrightnessState>> SetBrightnessAsync(
        string displayId,
        int value,
        CancellationToken cancellationToken) =>
        SetDisplayAsync(DdcFeature.Brightness, displayId, value, cancellationToken);

    public Task<IReadOnlyList<DisplayBrightnessState>> SetContrastAsync(
        string displayId,
        int value,
        CancellationToken cancellationToken) =>
        SetDisplayAsync(DdcFeature.Contrast, displayId, value, cancellationToken);

    private async Task<IReadOnlyList<DisplayBrightnessState>> SetDisplayAsync(
        DdcFeature feature,
        string displayId,
        int value,
        CancellationToken cancellationToken)
    {
        ThrowIfDisposed();
        var normalized = Math.Clamp(value, 0, 100);
        var isWmi = displayId.StartsWith("wmi:", StringComparison.OrdinalIgnoreCase);
        if (isWmi && feature == DdcFeature.Brightness)
        {
            return await SetWmiAsync(displayId, normalized, cancellationToken);
        }

        if (feature == DdcFeature.Contrast && (isWmi || !_contrastVisible))
        {
            var cached = LastSnapshot() ?? ComposeCached();
            return isWmi ? MarkWmiContrastUnsupported(cached, displayId) : cached;
        }

        if (!displayId.StartsWith("ddc:", StringComparison.OrdinalIgnoreCase))
        {
            RecordFailure("unknown-id", "unknown", feature);
            return StoreWriteResult(feature, displayId, normalized, WriteResult.Failed("unknown-id", "unknown"));
        }

        var sequences = feature == DdcFeature.Contrast ? _contrastWriteSequences : _writeSequences;
        long sequence;
        lock (_readSync)
        {
            sequence = sequences.AddOrUpdate(displayId, 1, (_, previous) => previous + 1);
        }

        var operation = Task.Run(() => WriteDdc(feature, displayId, normalized), CancellationToken.None);
        WriteResult result;
        try
        {
            result = await operation.WaitAsync(_timing.WriteTimeout, cancellationToken);
        }
        catch (TimeoutException)
        {
            var model = FindEndpoint(displayId)?.Model ?? "unknown";
            RecordFailure("timeout", model, feature);
            var timedOut = PublishResult(WriteResult.TimedOut(model));
            // Keep the monitor gate until the command really finishes and publish its late result.
            _ = operation.ContinueWith(
                completed => PublishResult(completed.Result, notify: true),
                CancellationToken.None,
                TaskContinuationOptions.OnlyOnRanToCompletion,
                TaskScheduler.Default);
            return timedOut;
        }

        return PublishResult(result);

        IReadOnlyList<DisplayBrightnessState> PublishResult(WriteResult outcome, bool notify = false)
        {
            lock (_readSync)
            {
                if (_disposed || (notify && sequences[displayId] != sequence))
                {
                    return _lastSnapshot ?? ComposeCached();
                }

                var snapshot = StoreWriteResult(feature, displayId, normalized, outcome);
                if (notify)
                {
                    StateChanged?.Invoke(this, snapshot);
                }

                return snapshot;
            }
        }
    }

    private static IReadOnlyList<DisplayBrightnessState> MarkWmiContrastUnsupported(
        IReadOnlyList<DisplayBrightnessState> cached,
        string displayId)
    {
        return cached.Any(display => string.Equals(display.Id, displayId, StringComparison.OrdinalIgnoreCase))
            ? cached.Select(display => string.Equals(display.Id, displayId, StringComparison.OrdinalIgnoreCase)
                ? display with { ContrastSupported = false } : display).ToArray()
            : [.. cached, new DisplayBrightnessState(displayId, "Built-in display", false, null, ContrastSupported: false)];
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
                return ReadDdcTarget(displayId, DdcFeature.Brightness)?.State;
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
                : new DisplayBrightnessState(displayId, previous?.Name ?? "Built-in display", true, target.Value,
                    IsPrimary: previous?.IsPrimary, ContrastSupported: false);
        }, CancellationToken.None);
        return await readTask.WaitAsync(_timing.WriteTimeout, cancellationToken);
    }

    internal async Task<(int Value, uint RawValue)?> ReadContrastFreshForVerifyAsync(
        string displayId, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var read = await Task.Run(() => ReadDdcTarget(displayId, DdcFeature.Contrast, TimeSpan.FromSeconds(30)),
            cancellationToken);
        return read is { State: { ContrastSupported: true, ContrastValue: int value } }
            ? (value, read.Value.RawValue)
            : null;
    }

    // Wait for the actual hardware command before the verifier attempts restoration.
    internal async Task<bool> SetContrastForVerifyAsync(
        string displayId, int value, TimeSpan gateTimeout, uint? rawValue = null)
    {
        var result = await Task.Run(() => WriteDdc(DdcFeature.Contrast, displayId, value, rawValue, gateTimeout));
        return result.Accepted;
    }

    private (DisplayBrightnessState State, uint RawValue)? ReadDdcTarget(
        string displayId, DdcFeature feature, TimeSpan? gateTimeout = null)
    {
        var endpoint = FindEndpoint(displayId);
        if (endpoint is null)
        {
            return null;
        }

        var gate = Gate(displayId);
        if (!gate.Semaphore.Wait(gateTimeout ?? _timing.MonitorGateTimeout))
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

            if (feature == DdcFeature.Contrast && (!_contrastVisible || endpoint.Contrast?.Supported != true))
            {
                return null;
            }

            var setting = endpoint.Setting(feature);
            var readable = TryReadSetting(endpoint, gate, feature, setting.UseHighLevel);
            if (feature == DdcFeature.Contrast && !readable)
            {
                return null;
            }

            return (endpoint.State(readable ? null : "DDC/CI brightness read failed."), setting.RawValue);
        }
        finally
        {
            gate.Semaphore.Release();
        }
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

    private Task<IReadOnlyList<DisplayBrightnessState>> StartRead(
        Task<IReadOnlyList<DisplayBrightnessState>>? previous,
        bool readContrast,
        bool preserveBrightnessWrite)
    {
        var generation = ++_readGeneration;
        return Task.Run(async () =>
        {
            if (previous is { IsCompleted: false })
            {
                try
                {
                    await previous;
                }
                catch (Exception ex) when (ex is ManagementException or COMException)
                {
                }
            }

            var snapshot = Read(readContrast);
            lock (_readSync)
            {
                if (generation != _readGeneration || _disposed)
                {
                    return _lastSnapshot ?? snapshot;
                }

                if (preserveBrightnessWrite && _lastSnapshot is { } last)
                {
                    snapshot = snapshot.Select(display =>
                    {
                        // A write that finished while this read ran may describe a newer value; its result is
                        // kept only when it describes the value this read observed.
                        var prior = last.FirstOrDefault(candidate => candidate.WriteVerified.HasValue
                            && string.Equals(candidate.Id, display.Id, StringComparison.OrdinalIgnoreCase)
                            && candidate.Supported == display.Supported
                            && candidate.Value == display.Value);
                        return prior is null ? display : display with
                        {
                            Error = prior.Error ?? display.Error,
                            WriteVerified = prior.WriteVerified
                        };
                    }).ToArray();
                }

                _lastSnapshot = snapshot;
                _lastSnapshotAt = readContrast && _contrastVisible
                    && snapshot.Any(display => display.Supported && display.ContrastSupported is null)
                    ? DateTimeOffset.MinValue
                    : DateTimeOffset.UtcNow;
                StateChanged?.Invoke(this, snapshot);
                return snapshot;
            }
        }, CancellationToken.None);
    }

    private IReadOnlyList<DisplayBrightnessState> Read(bool readContrast)
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
                    IsPrimary: monitor.Index < displayLayout.Count ? displayLayout[monitor.Index].IsPrimary : monitor.Index == 0,
                    ContrastSupported: false));
            }

            _skipPrimary = wmi.Count > 0;
        }

        var registry = EnsureRegistry(readContrast);
        result.AddRange(registry.States());
        return result.Count == 0
            ? [new DisplayBrightnessState("display:none", "Display", false, null, "Display brightness is unavailable.")]
            : result;
    }

    private DdcRegistry EnsureRegistry(bool readContrast)
    {
        var current = CurrentRegistry();
        // A monitor that did not answer (asleep, just woken, briefly busy) is shown as unsupported. Probe
        // again after a while instead of keeping it unsupported until the display topology changes.
        if (current is not null && !_topologyDirty && !current.ShouldRetryUnavailable(_timing.UnavailableRetry))
        {
            var key = TopologyKey(FilterMonitors(_platform.EnumerateMonitors()));
            if (string.Equals(current.TopologyKey, key, StringComparison.Ordinal))
            {
                RefreshValues(current, readContrast);
                return current;
            }
        }

        return Rebuild(current, readContrast);
    }

    // observed is the registry the caller found stale. If another caller replaced it while this one
    // waited, and the topology still matches, the newer registry is reused instead of probing again.
    private DdcRegistry Rebuild(DdcRegistry? observed, bool readContrast = false)
    {
        _discoveryGate.Wait();
        try
        {
            // Cleared before enumerating so a display change that arrives during the rebuild is not lost.
            var wasDirty = _topologyDirty;
            _topologyDirty = false;
            var monitors = FilterMonitors(_platform.EnumerateMonitors());
            var key = TopologyKey(monitors);
            var current = CurrentRegistry();
            if (current is not null
                && !ReferenceEquals(current, observed)
                && string.Equals(current.TopologyKey, key, StringComparison.Ordinal))
            {
                // Reusing another caller's rebuild: keep a pending change notice for the next read.
                if (wasDirty)
                {
                    _topologyDirty = true;
                }

                return current;
            }

            var probeStarted = Stopwatch.GetTimestamp();
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
                        readable = TryReadSetting(endpoint, gate, DdcFeature.Brightness, preferHighLevel: false);
                        if (readable && readContrast)
                        {
                            RefreshContrast(endpoint, gate);
                        }
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

            var replacement = new DdcRegistry(key, slots, Stopwatch.GetTimestamp());
            BeforeRegistrySwapForVerify?.Invoke();
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
                // Marks the old endpoints Retired first, so a writer that gets a gate from now on follows the
                // new endpoint.
                Retire(previous);
            }

            // A write that ran on an old endpoint while probing hands its newer value over. Gates are taken
            // one at a time so a slow monitor never makes a write to another monitor wait.
            if (!ReferenceEquals(previous, replacement))
            {
                foreach (var endpoint in replacement.Endpoints)
                {
                    var older = previous?.Endpoints.FirstOrDefault(candidate =>
                        string.Equals(candidate.Id, endpoint.Id, StringComparison.OrdinalIgnoreCase));
                    if (older is null)
                    {
                        continue;
                    }

                    var gate = Gate(endpoint.Id);
                    if (!gate.Semaphore.Wait(_timing.MonitorGateTimeout))
                    {
                        continue;
                    }

                    try
                    {
                        if (older.Brightness.ValueTimestamp > endpoint.Brightness.ValueTimestamp)
                        {
                            endpoint.Brightness.Value = older.Brightness.Value;
                        }

                        if (older.Contrast is { } contrast
                            && (endpoint.Contrast is null || (contrast.Supported == true
                                && contrast.ValueTimestamp > Math.Max(probeStarted, endpoint.Contrast.ValueTimestamp))))
                        {
                            endpoint.Contrast = contrast;
                        }
                    }
                    finally
                    {
                        gate.Semaphore.Release();
                    }
                }
            }

            return replacement;
        }
        finally
        {
            _discoveryGate.Release();
        }
    }

    private void RefreshValues(DdcRegistry registry, bool readContrast)
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

                if (TryReadSetting(endpoint, gate, DdcFeature.Brightness, endpoint.Brightness.UseHighLevel)
                    || Reopen(endpoint, gate, DdcFeature.Brightness))
                {
                    endpoint.Brightness.LastError = null;
                }
                else
                {
                    endpoint.Brightness.LastError = "DDC/CI brightness read failed.";
                    endpoint.Brightness.NeedsReopen = true;
                }

                if (readContrast)
                {
                    RefreshContrast(endpoint, gate);
                }
            }
            finally
            {
                gate.Semaphore.Release();
            }
        }
    }

    private bool CanRetryContrast(DdcSetting? setting) =>
        setting is { Supported: false, UnavailableSince: > 0 }
        && (setting.UnavailableSince <= Volatile.Read(ref _contrastEnabledAt)
            || Stopwatch.GetElapsedTime(setting.UnavailableSince) >= _timing.UnavailableRetry);

    private void RefreshContrast(DdcEndpoint endpoint, MonitorGate gate)
    {
        if (!_contrastVisible || (endpoint.Contrast?.Supported == false && !CanRetryContrast(endpoint.Contrast)))
        {
            return;
        }

        var enabledAt = Volatile.Read(ref _contrastEnabledAt);
        var setting = endpoint.Setting(DdcFeature.Contrast);
        if (setting.Supported == false)
        {
            setting.Supported = null;
        }

        var readable = TryReadSetting(endpoint, gate, DdcFeature.Contrast, setting.UseHighLevel)
            || (_contrastVisible && setting.Supported == true && Reopen(endpoint, gate, DdcFeature.Contrast));
        if (_contrastVisible && enabledAt == Volatile.Read(ref _contrastEnabledAt))
        {
            if (setting.Supported is null)
            {
                setting.UnavailableSince = readable ? 0 : Stopwatch.GetTimestamp();
                setting.Supported = readable;
            }

            setting.NeedsReopen = !readable;
            setting.LastError = readable || setting.Supported == false ? null : "DDC/CI contrast read failed.";
        }
    }

    private WriteResult WriteDdc(
        DdcFeature feature, string displayId, int normalized, uint? rawValue = null, TimeSpan? gateTimeout = null)
    {
        Interlocked.Increment(ref _activeWrites);
        try
        {
            BeforeDdcWriteForVerify?.Invoke(feature, displayId, normalized, rawValue);
            if (feature == DdcFeature.Contrast && !_contrastVisible)
            {
                return WriteResult.Skipped;
            }

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
                RecordFailure("unknown-id", model, feature);
                return WriteResult.Failed("unknown-id", model);
            }

            var gate = Gate(displayId);
            if (!gate.Semaphore.Wait(gateTimeout ?? _timing.MonitorGateTimeout))
            {
                RecordFailure("busy", endpoint.Model, feature);
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
                        RecordFailure("unknown-id", endpoint.Model, feature);
                        return WriteResult.Failed("unknown-id", endpoint.Model);
                    }

                    endpoint = replacement;
                }

                var setting = endpoint.Setting(feature);
                if (feature == DdcFeature.Contrast)
                {
                    if (!_contrastVisible)
                    {
                        return WriteResult.Skipped;
                    }

                    if (setting.Supported is null)
                    {
                        RefreshContrast(endpoint, gate);
                    }

                    if (setting.Supported != true)
                    {
                        return WriteResult.Skipped;
                    }
                }

                if (setting.NeedsReopen)
                {
                    _ = Reopen(endpoint, gate, feature);
                }

                var accepted = TrySetSetting(endpoint, gate, feature, normalized, rawValue);
                if (feature == DdcFeature.Contrast && !_contrastVisible && !accepted)
                {
                    return WriteResult.Skipped;
                }

                if (!accepted && Reopen(endpoint, gate, feature))
                {
                    accepted = TrySetSetting(endpoint, gate, feature, normalized, rawValue);
                }

                if (!accepted && feature == DdcFeature.Contrast && !setting.UseHighLevel
                    && TryReadHighLevel(endpoint, gate, feature))
                {
                    accepted = TrySetSetting(endpoint, gate, feature, normalized, rawValue);
                }

                if (!accepted)
                {
                    setting.NeedsReopen = true;
                    _topologyDirty = true;
                    RecordFailure("set-failed", endpoint.Model, feature);
                    return WriteResult.Failed("set-failed", endpoint.Model, endpoint.State());
                }

                setting.NeedsReopen = false;
                setting.Value = normalized;
                setting.LastError = null;
                Thread.Sleep(_timing.ReadbackDelay);
                DisplayBrightnessState? fresh = null;
                var verified = false;
                for (var attempt = 0; attempt <= _timing.ReadbackRetries; attempt++)
                {
                    if (attempt > 0)
                    {
                        Thread.Sleep(_timing.ReadbackRetryDelay);
                    }

                    if (!TryReadSetting(endpoint, gate, feature, setting.UseHighLevel))
                    {
                        continue;
                    }

                    fresh = endpoint.State();
                    if (rawValue.HasValue ? setting.RawValue == rawValue : Math.Abs(setting.Value - normalized) <= ReadbackTolerance)
                    {
                        verified = true;
                        break;
                    }
                }

                if (!verified)
                {
                    RecordFailure("readback-mismatch", endpoint.Model, feature);
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
    private bool Reopen(DdcEndpoint endpoint, MonitorGate gate, DdcFeature feature)
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
            var readable = TryReadSetting(endpoint, gate, feature, preferHighLevel: false);
            endpoint.Setting(feature).NeedsReopen = !readable;
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

    private bool TryReadSetting(DdcEndpoint endpoint, MonitorGate gate, DdcFeature feature, bool preferHighLevel)
    {
        if (preferHighLevel && TryReadHighLevel(endpoint, gate, feature))
        {
            return true;
        }

        for (var attempt = 0; attempt < 2; attempt++)
        {
            WaitForSpacing(gate);
            if (feature == DdcFeature.Contrast && !_contrastVisible)
            {
                return false;
            }

            var ok = endpoint.Monitor.TryReadVcp(feature, out var current, out var maximum, out var error);
            gate.Touch();
            if (ok && IsValidRange(0, current, maximum))
            {
                var setting = endpoint.Setting(feature);
                setting.UseHighLevel = false;
                setting.Minimum = 0;
                setting.Maximum = maximum;
                setting.RawValue = current;
                setting.Value = ToPercentage(0, current, maximum);
                return true;
            }

            if (ok || !IsTransientDdcError(error))
            {
                break;
            }

            Thread.Sleep(_timing.TransientRetryDelay);
        }

        return !preferHighLevel && TryReadHighLevel(endpoint, gate, feature);
    }

    private bool TryReadHighLevel(DdcEndpoint endpoint, MonitorGate gate, DdcFeature feature)
    {
        WaitForSpacing(gate);
        if (feature == DdcFeature.Contrast && !_contrastVisible)
        {
            return false;
        }

        var ok = endpoint.Monitor.TryReadHighLevel(feature, out var minimum, out var current, out var maximum, out _);
        gate.Touch();
        if (!ok || !IsValidRange(minimum, current, maximum))
        {
            return false;
        }

        var setting = endpoint.Setting(feature);
        setting.UseHighLevel = true;
        setting.Minimum = minimum;
        setting.Maximum = maximum;
        setting.RawValue = current;
        setting.Value = ToPercentage(minimum, current, maximum);
        return true;
    }

    private bool TrySetSetting(
        DdcEndpoint endpoint, MonitorGate gate, DdcFeature feature, int normalized, uint? rawValue)
    {
        var setting = endpoint.Setting(feature);
        var target = rawValue ?? setting.Minimum + (uint)Math.Round(
            (setting.Maximum - setting.Minimum) * normalized / 100d,
            MidpointRounding.AwayFromZero);
        if (target < setting.Minimum || target > setting.Maximum)
        {
            return false;
        }

        for (var attempt = 0; attempt < 2; attempt++)
        {
            if (attempt > 0)
            {
                Thread.Sleep(_timing.TransientRetryDelay);
            }

            WaitForSpacing(gate);
            if (feature == DdcFeature.Contrast && !_contrastVisible)
            {
                return false;
            }

            var ok = setting.UseHighLevel
                ? endpoint.Monitor.TryWriteHighLevel(feature, target, out _)
                : endpoint.Monitor.TryWriteVcp(feature, target, out _);
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

            return StoreWriteResult(
                DdcFeature.Brightness,
                displayId,
                normalized,
                new WriteResult(accepted, fresh, verified, false, "wmi", null));
        }
        finally
        {
            Interlocked.Decrement(ref _activeWrites);
            _wmiWriteGate.Release();
        }
    }

    private IReadOnlyList<DisplayBrightnessState> StoreWriteResult(
        DdcFeature feature, string displayId, int value, WriteResult result)
    {
        lock (_readSync)
        {
            var current = ComposeCached();
            if (result == WriteResult.Skipped)
            {
                return current;
            }

            var contrast = feature == DdcFeature.Contrast;
            var error = result.Verified
                ? null
                : result.TimedOutCommand
                    ? $"{feature} command timed out."
                    : result.Accepted
                        ? $"{feature} readback did not match {value}%."
                        : $"{feature} command failed for {value}%.";
            var annotated = current.ToList();
            var index = annotated.FindIndex(display => string.Equals(display.Id, displayId, StringComparison.OrdinalIgnoreCase));
            var display = index >= 0 ? annotated[index] : new DisplayBrightnessState(displayId, "Display", false, null);
            var observed = result.Fresh ?? display;
            var changed = contrast
                ? display with
                {
                    ContrastSupported = observed.ContrastSupported,
                    ContrastValue = observed.ContrastValue,
                    ContrastError = error,
                    ContrastWriteVerified = result.Verified
                }
                : display with
                {
                    Supported = observed.Supported,
                    Value = observed.Value,
                    Name = string.IsNullOrWhiteSpace(observed.Name) ? display.Name : observed.Name,
                    IsPrimary = observed.IsPrimary ?? display.IsPrimary,
                    Error = error,
                    WriteVerified = result.Verified
                };

            if (index >= 0)
            {
                annotated[index] = changed;
            }
            else
            {
                annotated.Add(changed);
            }

            _lastSnapshot = annotated;
            _lastSnapshotAt = _contrastVisible
                && annotated.Any(item => item.Supported && item.ContrastSupported is null)
                ? DateTimeOffset.MinValue
                : DateTimeOffset.UtcNow;
            return annotated;
        }
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
            .Concat(registry.States().Select(display =>
            {
                var previous = last?.FirstOrDefault(candidate =>
                    string.Equals(candidate.Id, display.Id, StringComparison.OrdinalIgnoreCase));
                return previous is null ? display : display with
                {
                    Error = previous.Error ?? display.Error,
                    WriteVerified = previous.WriteVerified,
                    ContrastError = previous.ContrastError ?? display.ContrastError,
                    ContrastWriteVerified = previous.ContrastWriteVerified
                };
            }))
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

    private static void RecordFailure(string reason, string model, DdcFeature feature = DdcFeature.Brightness) =>
        AppDiagnostics.Record(feature == DdcFeature.Contrast ? "contrast.write.failed" : "brightness.write.failed",
            detail: $"reason={reason};model={model}");

    private static string ModelFromId(string displayId)
    {
        var key = displayId.StartsWith("ddc:", StringComparison.OrdinalIgnoreCase) ? displayId[4..] : displayId;
        var dash = key.IndexOf('-');
        var model = dash > 0 ? key[..dash] : string.Empty;
        // The ID can come from a caller, so only a short alphanumeric model code reaches the diagnostics log.
        return model.Length is > 0 and <= 16 && model.All(char.IsAsciiLetterOrDigit) ? model : "unknown";
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
        public static WriteResult Skipped { get; } = new(false, null, false, false, "unknown", null);

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

        public DdcSetting Brightness { get; } = new();

        public DdcSetting? Contrast { get; set; }

        public DdcSetting Setting(DdcFeature feature) =>
            feature == DdcFeature.Contrast ? Contrast ??= new DdcSetting() : Brightness;

        public volatile bool Retired;

        public IDdcPhysicalMonitor SwapMonitor(IDdcPhysicalMonitor next)
        {
            var previous = Monitor;
            Monitor = next;
            return previous;
        }

        public DisplayBrightnessState State(string? error = null) =>
            new(Id, Name, true, Brightness.Value, error ?? Brightness.LastError, IsPrimary: IsPrimary,
                ContrastSupported: Contrast?.Supported,
                ContrastValue: Contrast is { Supported: true } contrast ? contrast.Value : null,
                ContrastError: Contrast?.LastError);

        public void Dispose() => Monitor.Dispose();
    }

    private sealed class DdcSetting
    {
        public bool? Supported { get; set; }

        public long UnavailableSince { get; set; }

        public bool UseHighLevel { get; set; }

        public uint Minimum { get; set; }

        public uint Maximum { get; set; } = 100;

        public uint RawValue { get; set; }

        private int _value;

        // When Value was last read from or written to the monitor; a rebuild keeps the newer of two values.
        public long ValueTimestamp { get; private set; }

        public int Value
        {
            get => _value;
            set
            {
                _value = value;
                ValueTimestamp = Stopwatch.GetTimestamp();
            }
        }

        public string? LastError { get; set; }

        public bool NeedsReopen { get; set; }
    }

    private sealed record DdcSlot(DdcEndpoint? Endpoint, DisplayBrightnessState? Unavailable)
    {
        public DisplayBrightnessState State() => Endpoint?.State() ?? Unavailable!;
    }

    private sealed record DdcRegistry(string TopologyKey, IReadOnlyList<DdcSlot> Slots, long BuiltTimestamp)
    {
        public IEnumerable<DdcEndpoint> Endpoints => Slots.Select(slot => slot.Endpoint).OfType<DdcEndpoint>();

        public bool ShouldRetryUnavailable(TimeSpan retryAfter) =>
            Slots.Any(slot => slot.Endpoint is null) && Stopwatch.GetElapsedTime(BuiltTimestamp) >= retryAfter;

        public IEnumerable<DisplayBrightnessState> States() => Slots.Select(slot => slot.State());
    }

    private sealed record WmiBrightness(int Index, int Value);
}
