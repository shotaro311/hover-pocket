using System.Management;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
using HoverPocket.Shell.Display;

namespace HoverPocket.Shell.Providers.Controls;

internal sealed class MonitorBrightnessService : IMonitorBrightnessService, IDisposable
{
    private const uint MonitorCapabilityBrightness = 0x00000002;
    private const byte VcpLuminance = 0x10;
    private const uint ErrorGraphicsI2CTransmittingData = 0xC0262582;
    private const uint ErrorGraphicsDdcInvalidMessageCommand = 0xC0262589;
    private const uint ErrorGraphicsDdcInvalidMessageLength = 0xC026258A;
    private const uint ErrorGraphicsDdcInvalidMessageChecksum = 0xC026258B;
    private static readonly TimeSpan CacheLifetime = TimeSpan.FromSeconds(15);
    private static readonly TimeSpan DiscoveryLifetime = TimeSpan.FromMinutes(2);
    private static readonly TimeSpan DdcCommandSpacing = TimeSpan.FromMilliseconds(100);
    private static readonly TimeSpan DdcRetryDelay = TimeSpan.FromMilliseconds(55);
    private readonly DisplayLayoutService _displays = new();
    private readonly object _readSync = new();
    private readonly object _ddcSync = new();
    private readonly SemaphoreSlim _writeGate = new(1, 1);
    private Task<IReadOnlyList<DisplayBrightnessState>>? _activeRead;
    private IReadOnlyList<DisplayBrightnessState>? _lastSnapshot;
    private DateTimeOffset _lastSnapshotAt;
    private DdcDiscovery? _ddcDiscovery;
    private int _readGeneration;
    private bool _disposed;

    public event EventHandler<IReadOnlyList<DisplayBrightnessState>>? StateChanged;

    public async Task<IReadOnlyList<DisplayBrightnessState>> ReadAsync(CancellationToken cancellationToken)
    {
        ThrowIfDisposed();
        Task<IReadOnlyList<DisplayBrightnessState>> readTask;
        lock (_readSync)
        {
            if (_writeGate.CurrentCount == 0 && _lastSnapshot is not null)
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
            var snapshot = await readTask.WaitAsync(TimeSpan.FromMilliseconds(180), cancellationToken);
            StoreSnapshot(snapshot);
            return snapshot;
        }
        catch (TimeoutException)
        {
            return LastSnapshot() ?? FallbackStates("Brightness detection is still running.");
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
        await _writeGate.WaitAsync(cancellationToken);
        try
        {
            var normalized = Math.Clamp(value, 0, 100);
            var writeTask = Task.Run(() => displayId.StartsWith("wmi:", StringComparison.OrdinalIgnoreCase)
                ? SetWmiBrightness(displayId, normalized)
                : displayId.StartsWith("ddc:", StringComparison.OrdinalIgnoreCase)
                    && SetDdcBrightness(displayId, normalized), CancellationToken.None);
            var commandAccepted = false;
            try
            {
                commandAccepted = await writeTask.WaitAsync(TimeSpan.FromMilliseconds(2500), cancellationToken);
            }
            catch (TimeoutException)
            {
            }

            var annotated = AnnotateWrite(displayId, normalized, commandAccepted);
            StoreSnapshot(annotated);
            return annotated;
        }
        finally
        {
            _writeGate.Release();
        }
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
                lock (_ddcSync)
                {
                    return _ddcDiscovery?.Endpoints.FirstOrDefault(endpoint =>
                        string.Equals(endpoint.Id, displayId, StringComparison.OrdinalIgnoreCase))?.ReadState(refreshValue: true);
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
                : new DisplayBrightnessState(displayId, previous?.Name ?? "Built-in display", true, target.Value);
        }, CancellationToken.None);
        return await readTask.WaitAsync(TimeSpan.FromMilliseconds(2500), cancellationToken);
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        lock (_ddcSync)
        {
            _ddcDiscovery?.Dispose();
            _ddcDiscovery = null;
        }

        _writeGate.Dispose();
    }

    private Task<IReadOnlyList<DisplayBrightnessState>> StartRead()
    {
        var generation = ++_readGeneration;
        var task = Task.Run<IReadOnlyList<DisplayBrightnessState>>(
            () => Read(CancellationToken.None),
            CancellationToken.None);
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

    private IReadOnlyList<DisplayBrightnessState> AnnotateWrite(string displayId, int value, bool accepted)
    {
        var current = LastSnapshot() ?? FallbackStates("Brightness state is still loading.");
        return current.Select(display => string.Equals(display.Id, displayId, StringComparison.OrdinalIgnoreCase)
            ? display with
            {
                Value = accepted ? value : display.Value,
                Error = accepted ? null : $"Brightness command failed for {value}%.",
                WriteVerified = accepted
            }
            : display).ToArray();
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

    private IReadOnlyList<DisplayBrightnessState> Read(CancellationToken cancellationToken)
    {
        var result = new List<DisplayBrightnessState>();
        var displayLayout = _displays.EnumerateMonitors();
        var wmi = ReadWmiBrightness();
        foreach (var monitor in wmi)
        {
            cancellationToken.ThrowIfCancellationRequested();
            result.Add(new DisplayBrightnessState(
                $"wmi:{monitor.Index}",
                monitor.Index < displayLayout.Count
                    ? $"Built-in display ({displayLayout[monitor.Index].Name})"
                    : monitor.Index == 0 ? "Built-in display" : $"Built-in display {monitor.Index + 1}",
                true,
                monitor.Value));
        }

        var externalDisplays = displayLayout
            .Where(display => !(display.IsPrimary && wmi.Count > 0))
            .ToArray();
        result.AddRange(ReadExternalDisplays(externalDisplays, cancellationToken));

        return result.Count == 0
            ? [new DisplayBrightnessState("display:none", "Display", false, null, "Display brightness is unavailable.")]
            : result;
    }

    private IReadOnlyList<DisplayBrightnessState> ReadExternalDisplays(
        IReadOnlyList<DisplayMonitor> displays,
        CancellationToken cancellationToken)
    {
        lock (_ddcSync)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var topologyKey = TopologyKey(displays);
            var rebuild = _ddcDiscovery is null
                || !string.Equals(_ddcDiscovery.TopologyKey, topologyKey, StringComparison.Ordinal)
                || DateTimeOffset.UtcNow - _ddcDiscovery.DiscoveredAt > DiscoveryLifetime;
            if (rebuild)
            {
                var replacement = DiscoverDdcMonitors(displays, topologyKey, cancellationToken);
                _ddcDiscovery?.Dispose();
                _ddcDiscovery = replacement;
            }

            return _ddcDiscovery!.ReadStates(refreshValues: !rebuild, cancellationToken);
        }
    }

    private static DdcDiscovery DiscoverDdcMonitors(
        IReadOnlyList<DisplayMonitor> displays,
        string topologyKey,
        CancellationToken cancellationToken)
    {
        var endpoints = new List<DdcMonitorEndpoint>();
        var unavailable = new List<DisplayBrightnessState>();
        foreach (var display in displays)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (display.NativeHandle == IntPtr.Zero)
            {
                unavailable.Add(Unsupported(display, "Display brightness is unavailable."));
                continue;
            }

            var physicalMonitors = GetPhysicalMonitors(display.NativeHandle);
            if (physicalMonitors.Length == 0)
            {
                unavailable.Add(Unsupported(display, "DDC/CI is not available."));
                continue;
            }

            for (var index = 0; index < physicalMonitors.Length; index++)
            {
                var physical = physicalMonitors[index];
                var handle = new SafePhysicalMonitorHandle(physical.Handle);
                var name = string.IsNullOrWhiteSpace(physical.Description)
                    ? DisplayName(display, index)
                    : physical.Description.Trim();
                var highLevel = GetMonitorCapabilities(handle, out var capabilities, out _)
                    && (capabilities & MonitorCapabilityBrightness) != 0;
                if (TryReadBrightness(handle, highLevel, out var minimum, out var current, out var maximum, out var usedHighLevel))
                {
                    endpoints.Add(new DdcMonitorEndpoint(
                        DdcId(display.NativeHandle, index),
                        name,
                        display.NativeHandle,
                        index,
                        handle,
                        usedHighLevel,
                        minimum,
                        current,
                        maximum));
                }
                else
                {
                    handle.Dispose();
                    unavailable.Add(new DisplayBrightnessState(
                        DdcId(display.NativeHandle, index),
                        name,
                        false,
                        null,
                        "DDC/CI brightness is not supported."));
                }
            }
        }

        return new DdcDiscovery(topologyKey, endpoints, unavailable);
    }

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

    private bool SetDdcBrightness(string displayId, int value)
    {
        lock (_ddcSync)
        {
            var endpoint = _ddcDiscovery?.Endpoints.FirstOrDefault(candidate =>
                string.Equals(candidate.Id, displayId, StringComparison.OrdinalIgnoreCase));
            if (endpoint is null || !endpoint.SetBrightness(value))
            {
                if (_ddcDiscovery is not null)
                {
                    _ddcDiscovery.DiscoveredAt = DateTimeOffset.MinValue;
                }

                return false;
            }

            return true;
        }
    }

    private static bool TryReadBrightness(
        SafePhysicalMonitorHandle handle,
        bool preferHighLevel,
        out uint minimum,
        out uint current,
        out uint maximum,
        out bool usedHighLevel)
    {
        if (preferHighLevel
            && GetMonitorBrightness(handle, out minimum, out current, out maximum)
            && IsValidRange(minimum, current, maximum))
        {
            usedHighLevel = true;
            return true;
        }

        for (var attempt = 0; attempt < 2; attempt++)
        {
            if (GetVCPFeatureAndVCPFeatureReply(
                    handle,
                    VcpLuminance,
                    out _,
                    out current,
                    out maximum)
                && IsValidRange(0, current, maximum))
            {
                minimum = 0;
                usedHighLevel = false;
                return true;
            }

            if (attempt > 0 || !IsTransientDdcError(Marshal.GetLastWin32Error()))
            {
                break;
            }

            Thread.Sleep(DdcRetryDelay);
        }

        minimum = 0;
        current = 0;
        maximum = 0;
        usedHighLevel = false;
        return false;
    }

    private static bool TrySetBrightness(DdcMonitorEndpoint endpoint, uint value)
    {
        if (endpoint.UseHighLevel && SetMonitorBrightness(endpoint.Handle, value))
        {
            return true;
        }

        if (endpoint.UseHighLevel)
        {
            Thread.Sleep(DdcRetryDelay);
        }

        for (var attempt = 0; attempt < 2; attempt++)
        {
            if (SetVCPFeature(endpoint.Handle, VcpLuminance, value))
            {
                endpoint.UseHighLevel = false;
                return true;
            }

            if (attempt > 0)
            {
                break;
            }

            Thread.Sleep(DdcRetryDelay);
        }

        return false;
    }

    private static bool IsValidRange(uint minimum, uint current, uint maximum) =>
        minimum < maximum && current >= minimum && current <= maximum;

    private static bool IsTransientDdcError(int error) => unchecked((uint)error) is
        ErrorGraphicsI2CTransmittingData
        or ErrorGraphicsDdcInvalidMessageCommand
        or ErrorGraphicsDdcInvalidMessageLength
        or ErrorGraphicsDdcInvalidMessageChecksum;

    private static PhysicalMonitor[] GetPhysicalMonitors(IntPtr monitor)
    {
        if (!GetNumberOfPhysicalMonitorsFromHMONITOR(monitor, out var count) || count == 0)
        {
            return [];
        }

        var result = new PhysicalMonitor[count];
        if (GetPhysicalMonitorsFromHMONITOR(monitor, count, result))
        {
            return result;
        }

        foreach (var physical in result)
        {
            if (physical.Handle != IntPtr.Zero)
            {
                _ = DestroyPhysicalMonitor(physical.Handle);
            }
        }

        return [];
    }

    private static DisplayBrightnessState Unsupported(DisplayMonitor display, string error)
    {
        return new DisplayBrightnessState(
            $"display:{display.NativeHandle.ToInt64():X}",
            DisplayName(display, 0),
            false,
            null,
            error);
    }

    private static string DisplayName(DisplayMonitor display, int physicalIndex)
    {
        var prefix = display.Name;
        return physicalIndex == 0 ? prefix : $"{prefix} {physicalIndex + 1}";
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
                error)).ToArray();
    }

    private static string TopologyKey(IReadOnlyList<DisplayMonitor> displays) => string.Join(
        '|',
        displays.Select(display => $"{display.NativeHandle.ToInt64():X}:{display.Name}:{display.IsPrimary}"));

    private static string DdcId(IntPtr handle, int index) => $"ddc:{handle.ToInt64():X}:{index}";

    private void ThrowIfDisposed()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
    }

    [DllImport("dxva2.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr monitor, out uint count);

    [DllImport("dxva2.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetPhysicalMonitorsFromHMONITOR(
        IntPtr monitor,
        uint count,
        [Out] PhysicalMonitor[] physicalMonitorArray);

    [DllImport("dxva2.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyPhysicalMonitor(IntPtr monitor);

    [DllImport("dxva2.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetMonitorCapabilities(
        SafePhysicalMonitorHandle monitor,
        out uint capabilities,
        out uint colorTemperatures);

    [DllImport("dxva2.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetMonitorBrightness(
        SafePhysicalMonitorHandle monitor,
        out uint minimum,
        out uint current,
        out uint maximum);

    [DllImport("dxva2.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetMonitorBrightness(SafePhysicalMonitorHandle monitor, uint brightness);

    [DllImport("dxva2.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetVCPFeatureAndVCPFeatureReply(
        SafePhysicalMonitorHandle monitor,
        byte vcpCode,
        out VcpCodeType codeType,
        out uint currentValue,
        out uint maximumValue);

    [DllImport("dxva2.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetVCPFeature(
        SafePhysicalMonitorHandle monitor,
        byte vcpCode,
        uint newValue);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct PhysicalMonitor
    {
        public IntPtr Handle;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string Description;
    }

    private enum VcpCodeType
    {
        Momentary,
        SetParameter
    }

    private sealed class SafePhysicalMonitorHandle : SafeHandleZeroOrMinusOneIsInvalid
    {
        public SafePhysicalMonitorHandle(IntPtr handle)
            : base(ownsHandle: true)
        {
            SetHandle(handle);
        }

        protected override bool ReleaseHandle() => DestroyPhysicalMonitor(handle);
    }

    private sealed class DdcMonitorEndpoint(
        string id,
        string name,
        IntPtr logicalMonitorHandle,
        int physicalMonitorIndex,
        SafePhysicalMonitorHandle handle,
        bool useHighLevel,
        uint minimum,
        uint current,
        uint maximum) : IDisposable
    {
        public string Id { get; } = id;

        public string Name { get; } = name;

        public SafePhysicalMonitorHandle Handle { get; private set; } = handle;

        public bool UseHighLevel { get; set; } = useHighLevel;

        public uint Minimum { get; private set; } = minimum;

        public uint Maximum { get; private set; } = maximum;

        public int Value { get; private set; } = ToPercentage(minimum, current, maximum);

        private DateTimeOffset _lastCommandStartedAt = DateTimeOffset.MinValue;

        public DisplayBrightnessState ReadState(bool refreshValue)
        {
            if (!refreshValue)
            {
                return State();
            }

            if (!TryReadBrightness(Handle, UseHighLevel, out var minimum, out var current, out var maximum, out var usedHighLevel))
            {
                return State("DDC/CI brightness read failed.");
            }

            UseHighLevel = usedHighLevel;
            Minimum = minimum;
            Maximum = maximum;
            Value = ToPercentage(minimum, current, maximum);
            return State();
        }

        public bool SetBrightness(int value)
        {
            var normalized = Math.Clamp(value, 0, 100);
            WaitForCommandSpacing();
            if (!TrySetNormalizedBrightness(normalized))
            {
                if (!Reconnect())
                {
                    return false;
                }

                WaitForCommandSpacing();
                if (!TrySetNormalizedBrightness(normalized))
                {
                    return false;
                }
            }

            Value = normalized;
            return true;
        }

        public void Dispose() => Handle.Dispose();

        private DisplayBrightnessState State(string? error = null) =>
            new(Id, Name, true, Value, error);

        private bool TrySetNormalizedBrightness(int normalized)
        {
            _lastCommandStartedAt = DateTimeOffset.UtcNow;
            var target = Minimum + (uint)Math.Round(
                (Maximum - Minimum) * normalized / 100d,
                MidpointRounding.AwayFromZero);
            return TrySetBrightness(this, target);
        }

        private void WaitForCommandSpacing()
        {
            var remaining = DdcCommandSpacing - (DateTimeOffset.UtcNow - _lastCommandStartedAt);
            if (remaining > TimeSpan.Zero)
            {
                Thread.Sleep(remaining);
            }
        }

        private bool Reconnect()
        {
            var monitors = GetPhysicalMonitors(logicalMonitorHandle);
            if (physicalMonitorIndex < 0 || physicalMonitorIndex >= monitors.Length)
            {
                DestroyUnusedMonitors(monitors, -1);
                return false;
            }

            var replacement = new SafePhysicalMonitorHandle(monitors[physicalMonitorIndex].Handle);
            DestroyUnusedMonitors(monitors, physicalMonitorIndex);
            if (!TryReadBrightness(
                    replacement,
                    UseHighLevel,
                    out var nextMinimum,
                    out var nextCurrent,
                    out var nextMaximum,
                    out var nextUseHighLevel))
            {
                replacement.Dispose();
                return false;
            }

            var previous = Handle;
            Handle = replacement;
            UseHighLevel = nextUseHighLevel;
            Minimum = nextMinimum;
            Maximum = nextMaximum;
            Value = ToPercentage(nextMinimum, nextCurrent, nextMaximum);
            previous.Dispose();
            _lastCommandStartedAt = DateTimeOffset.UtcNow;
            return true;
        }

        private static void DestroyUnusedMonitors(IReadOnlyList<PhysicalMonitor> monitors, int retainedIndex)
        {
            for (var index = 0; index < monitors.Count; index++)
            {
                if (index != retainedIndex && monitors[index].Handle != IntPtr.Zero)
                {
                    _ = DestroyPhysicalMonitor(monitors[index].Handle);
                }
            }
        }

        private static int ToPercentage(uint minimum, uint current, uint maximum) =>
            Math.Clamp((int)Math.Round(
                (current - minimum) * 100d / (maximum - minimum),
                MidpointRounding.AwayFromZero), 0, 100);
    }

    private sealed class DdcDiscovery(
        string topologyKey,
        IReadOnlyList<DdcMonitorEndpoint> endpoints,
        IReadOnlyList<DisplayBrightnessState> unavailable) : IDisposable
    {
        public string TopologyKey { get; } = topologyKey;

        public IReadOnlyList<DdcMonitorEndpoint> Endpoints { get; } = endpoints;

        public IReadOnlyList<DisplayBrightnessState> Unavailable { get; } = unavailable;

        public DateTimeOffset DiscoveredAt { get; set; } = DateTimeOffset.UtcNow;

        public IReadOnlyList<DisplayBrightnessState> ReadStates(
            bool refreshValues,
            CancellationToken cancellationToken)
        {
            var states = new List<DisplayBrightnessState>(Endpoints.Count + Unavailable.Count);
            states.AddRange(Unavailable);
            foreach (var endpoint in Endpoints)
            {
                cancellationToken.ThrowIfCancellationRequested();
                states.Add(endpoint.ReadState(refreshValues));
            }

            return states;
        }

        public void Dispose()
        {
            foreach (var endpoint in Endpoints)
            {
                endpoint.Dispose();
            }
        }
    }

    private sealed record WmiBrightness(int Index, int Value);
}
