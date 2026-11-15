using System.Diagnostics;
using HoverPocket.Shell.Verification;

namespace HoverPocket.Shell.Providers.Controls;

// Deterministic checks of MonitorBrightnessService against a fake DDC/CI layer: a slow monitor must not
// block writes to another one, HMONITOR changes must not invalidate display IDs, a readback that lags the
// write is accepted, and commands never overlap after a timed-out write.
internal sealed partial class ControlsVerifier
{
    private static readonly BrightnessTiming FastTiming = new(
        TimeSpan.FromMilliseconds(5),
        TimeSpan.FromMilliseconds(20),
        TimeSpan.FromMilliseconds(30),
        2,
        TimeSpan.FromMilliseconds(5),
        TimeSpan.FromSeconds(2),
        TimeSpan.FromSeconds(3));

    private async Task VerifyBrightnessServiceReliabilityAsync()
    {
        await VerifySlowMonitorDoesNotBlockOtherMonitorAsync();
        await VerifyStableIdAcrossMonitorHandleChangeAsync();
        await VerifyDelayedReadbackIsAcceptedAsync();
        await VerifyTimedOutWriteDoesNotOverlapAsync();
        await VerifyDisplayOrderAndNamesAsync();
        await VerifyUnavailableMonitorIsRetriedAsync();
        await VerifyRebuildKeepsNewerWrittenValueAsync();
        await VerifyRebuildSwapDoesNotBlockOtherMonitorAsync();
    }

    // While a rebuild hands values over, a slow write on the sub monitor must not delay a write to the main one.
    private async Task VerifyRebuildSwapDoesNotBlockOtherMonitorAsync()
    {
        var platform = FakeDdcPlatform.TwoMonitors();
        using var service = new MonitorBrightnessService(platform, includeWmi: false, FastTiming, listenForSystemEvents: false);
        var displays = await ReadSettledAsync(service, 2);
        var main = displays.First(display => display.IsPrimary == true);
        var sub = displays.First(display => display.IsPrimary == false);
        Task? subWrite = null;
        platform.Sub.WriteDelay = TimeSpan.FromMilliseconds(1500);
        // Runs after probing and before the swap: start a slow sub write and wait until it owns the sub gate
        // (the fake monitor is busy), so the swap happens while that gate is held.
        service.BeforeRegistrySwapForVerify = () =>
        {
            service.BeforeRegistrySwapForVerify = null;
            subWrite = Task.Run(() => service.SetBrightnessAsync(sub.Id, 40, CancellationToken.None));
            var busyDeadline = DateTimeOffset.UtcNow + TimeSpan.FromSeconds(1);
            while (!platform.Sub.Busy && DateTimeOffset.UtcNow < busyDeadline)
            {
                Thread.Sleep(5);
            }
        };
        service.InvalidateTopology();
        _ = service.ReadAsync(CancellationToken.None);
        var deadline = DateTimeOffset.UtcNow + TimeSpan.FromSeconds(3);
        while (subWrite is null && DateTimeOffset.UtcNow < deadline)
        {
            await Task.Delay(10);
        }

        await Task.Delay(100);
        var timer = Stopwatch.StartNew();
        var written = await service.SetBrightnessAsync(main.Id, 30, CancellationToken.None);
        timer.Stop();
        if (subWrite is not null)
        {
            await subWrite;
        }

        platform.Sub.WriteDelay = TimeSpan.Zero;
        VerifyConsole.WriteLine($"brightness_swap_main_write_ms={timer.Elapsed.TotalMilliseconds:F0}");
        if (subWrite is null)
        {
            _failures.Add("brightness swap: the sub write did not start during the rebuild");
        }
        else if (timer.Elapsed > TimeSpan.FromMilliseconds(700)
                 || written.FirstOrDefault(display => display.Id == main.Id)?.WriteVerified != true)
        {
            _failures.Add($"brightness swap: main write waited {timer.Elapsed.TotalMilliseconds:F0}ms behind the sub monitor");
        }
    }

    // A monitor that does not answer during detection (asleep, just woken) must come back without a
    // display topology change.
    private async Task VerifyUnavailableMonitorIsRetriedAsync()
    {
        var platform = FakeDdcPlatform.TwoMonitors();
        platform.Sub.Unresponsive = true;
        var timing = FastTiming with { UnavailableRetry = TimeSpan.FromMilliseconds(200), CacheLifetime = TimeSpan.FromMilliseconds(50) };
        using var service = new MonitorBrightnessService(platform, includeWmi: false, timing, listenForSystemEvents: false);
        var deadline = DateTimeOffset.UtcNow + TimeSpan.FromSeconds(4);
        IReadOnlyList<DisplayBrightnessState> displays = [];
        while (DateTimeOffset.UtcNow < deadline)
        {
            displays = await service.ReadAsync(CancellationToken.None);
            if (displays.Any(display => display.IsPrimary == false && display.Id.StartsWith("ddc:", StringComparison.Ordinal) && !display.Supported))
            {
                break;
            }

            await Task.Delay(30);
        }

        if (!displays.Any(display => display.IsPrimary == false && !display.Supported))
        {
            _failures.Add("brightness retry: unresponsive sub monitor was not reported as unsupported first");
            return;
        }

        platform.Sub.Unresponsive = false;
        deadline = DateTimeOffset.UtcNow + TimeSpan.FromSeconds(4);
        while (DateTimeOffset.UtcNow < deadline)
        {
            displays = await service.ReadAsync(CancellationToken.None);
            if (displays.Any(display => display.IsPrimary == false && display.Supported && display.Value == 73))
            {
                return;
            }

            await Task.Delay(50);
        }

        _failures.Add("brightness retry: sub monitor stayed unsupported after it started answering");
    }

    // A rebuild that probes a slow monitor must not replace a value written meanwhile to another monitor.
    private async Task VerifyRebuildKeepsNewerWrittenValueAsync()
    {
        var platform = FakeDdcPlatform.TwoMonitors();
        using var service = new MonitorBrightnessService(platform, includeWmi: false, FastTiming, listenForSystemEvents: false);
        var displays = await ReadSettledAsync(service, 2);
        var main = displays.First(display => display.IsPrimary == true);
        platform.Sub.ReadDelay = TimeSpan.FromMilliseconds(600);
        var published = new System.Collections.Concurrent.ConcurrentQueue<int?>();
        service.InvalidateTopology();
        _ = service.ReadAsync(CancellationToken.None);
        await Task.Delay(150);
        var written = await service.SetBrightnessAsync(main.Id, 20, CancellationToken.None);
        service.StateChanged += (_, states) =>
            published.Enqueue(states.FirstOrDefault(display => display.Id == main.Id)?.Value);
        await Task.Delay(1200);
        platform.Sub.ReadDelay = TimeSpan.Zero;
        if (written.FirstOrDefault(display => display.Id == main.Id)?.WriteVerified != true)
        {
            _failures.Add("brightness rebuild: write during rebuild was not verified");
        }

        if (published.IsEmpty || published.Any(value => value != 20))
        {
            _failures.Add($"brightness rebuild: published main values after the write were {string.Join(",", published)} instead of 20");
        }
    }

    private async Task VerifySlowMonitorDoesNotBlockOtherMonitorAsync()
    {
        var platform = FakeDdcPlatform.TwoMonitors();
        using var service = new MonitorBrightnessService(platform, includeWmi: false, FastTiming, listenForSystemEvents: false);
        var displays = await ReadSettledAsync(service, 2);
        var sub = displays.FirstOrDefault(display => display.IsPrimary == false);
        if (sub is null)
        {
            _failures.Add("brightness isolation: fake sub monitor was not detected");
            return;
        }

        // Main becomes slow, as during a capability query, and a rediscovery starts in the background.
        platform.Main.ReadDelay = TimeSpan.FromMilliseconds(1500);
        service.InvalidateTopology();
        var backgroundRead = service.ReadAsync(CancellationToken.None);
        await Task.Delay(50);
        var timer = Stopwatch.StartNew();
        var written = await service.SetBrightnessAsync(sub.Id, 40, CancellationToken.None);
        timer.Stop();
        await backgroundRead;
        var state = written.FirstOrDefault(display => display.Id == sub.Id);
        VerifyConsole.WriteLine($"brightness_isolation_write_ms={timer.Elapsed.TotalMilliseconds:F0}");
        if (timer.Elapsed > TimeSpan.FromMilliseconds(700) || state?.WriteVerified != true || platform.Sub.Value != 40)
        {
            _failures.Add(
                $"brightness isolation: sub write waited {timer.Elapsed.TotalMilliseconds:F0}ms "
                + $"verified={state?.WriteVerified} value={platform.Sub.Value}");
        }

        platform.Main.ReadDelay = TimeSpan.Zero;
    }

    private async Task VerifyStableIdAcrossMonitorHandleChangeAsync()
    {
        var platform = FakeDdcPlatform.TwoMonitors();
        using var service = new MonitorBrightnessService(platform, includeWmi: false, FastTiming, listenForSystemEvents: false);
        var before = await ReadSettledAsync(service, 2);
        var sub = before.FirstOrDefault(display => display.IsPrimary == false);
        if (sub is null)
        {
            _failures.Add("brightness stable id: fake sub monitor was not detected");
            return;
        }

        // Windows recreates the logical monitor: new HMONITOR, and old physical handles stop working.
        platform.ReplaceSubHandle();
        var written = await service.SetBrightnessAsync(sub.Id, 35, CancellationToken.None);
        var state = written.FirstOrDefault(display => display.Id == sub.Id);
        if (state?.WriteVerified != true || platform.Sub.Value != 35)
        {
            _failures.Add(
                $"brightness stable id: write after HMONITOR change failed verified={state?.WriteVerified} "
                + $"value={platform.Sub.Value} error={state?.Error}");
        }

        service.InvalidateTopology();
        var after = await ReadSettledAsync(service, 2);
        var idsBefore = string.Join(",", before.Select(display => display.Id));
        var idsAfter = string.Join(",", after.Select(display => display.Id));
        if (!string.Equals(idsBefore, idsAfter, StringComparison.Ordinal))
        {
            _failures.Add($"brightness stable id: ids changed {idsBefore} -> {idsAfter}");
        }
    }

    private async Task VerifyDelayedReadbackIsAcceptedAsync()
    {
        var platform = FakeDdcPlatform.TwoMonitors();
        platform.Sub.ReadbackLag = TimeSpan.FromMilliseconds(140);
        using var service = new MonitorBrightnessService(
            platform,
            includeWmi: false,
            BrightnessTiming.Default,
            listenForSystemEvents: false);
        var displays = await ReadSettledAsync(service, 2);
        var sub = displays.First(display => display.IsPrimary == false);
        var written = await service.SetBrightnessAsync(sub.Id, 61, CancellationToken.None);
        var state = written.FirstOrDefault(display => display.Id == sub.Id);
        if (state?.WriteVerified != true || state.Value != 61 || state.Error is not null)
        {
            _failures.Add(
                $"brightness readback: 140ms lag was not accepted verified={state?.WriteVerified} "
                + $"value={state?.Value} error={state?.Error}");
        }
    }

    private async Task VerifyTimedOutWriteDoesNotOverlapAsync()
    {
        var platform = FakeDdcPlatform.TwoMonitors();
        var timing = FastTiming with { WriteTimeout = TimeSpan.FromMilliseconds(250) };
        using var service = new MonitorBrightnessService(platform, includeWmi: false, timing, listenForSystemEvents: false);
        var displays = await ReadSettledAsync(service, 2);
        var sub = displays.First(display => display.IsPrimary == false);
        var published = new System.Collections.Concurrent.ConcurrentQueue<int?>();
        service.StateChanged += (_, states) =>
            published.Enqueue(states.FirstOrDefault(display => display.Id == sub.Id)?.Value);
        platform.Sub.WriteDelay = TimeSpan.FromMilliseconds(700);
        var first = await service.SetBrightnessAsync(sub.Id, 30, CancellationToken.None);
        var firstState = first.FirstOrDefault(display => display.Id == sub.Id);
        platform.Sub.WriteDelay = TimeSpan.Zero;
        // Sent while the slow command still runs: it must queue behind it, not overlap it.
        _ = await service.SetBrightnessAsync(sub.Id, 50, CancellationToken.None);
        await Task.Delay(1500);
        var settled = await service.ReadAsync(CancellationToken.None);
        var settledState = settled.FirstOrDefault(display => display.Id == sub.Id);
        if (firstState?.Error != "Brightness command timed out.")
        {
            _failures.Add($"brightness timeout: first write reported {firstState?.Error ?? "no error"}");
        }

        if (platform.Sub.Overlaps != 0)
        {
            _failures.Add($"brightness timeout: {platform.Sub.Overlaps} DDC commands overlapped on one monitor");
        }

        // The late result of the first write must not replace the newer one in the published state.
        if (platform.Sub.Value != 50 || settledState?.Value != 50 || settledState.WriteVerified != true)
        {
            _failures.Add(
                $"brightness timeout: queued write did not settle hardware={platform.Sub.Value} "
                + $"published={settledState?.Value} verified={settledState?.WriteVerified}");
        }

        // A superseded write's late result must never be published, not even briefly.
        if (published.Contains(30))
        {
            _failures.Add($"brightness timeout: the superseded 30% result was published ({string.Join(",", published)})");
        }
    }

    private async Task VerifyDisplayOrderAndNamesAsync()
    {
        var platform = FakeDdcPlatform.TwoMonitors(subFirst: true);
        using var service = new MonitorBrightnessService(platform, includeWmi: false, FastTiming, listenForSystemEvents: false);
        var displays = await ReadSettledAsync(service, 2);
        var summary = string.Join(",", displays.Select(display => $"{display.Name}:{display.IsPrimary}"));
        if (summary != "LG ULTRAGEAR+:True,U16ZT:False")
        {
            _failures.Add($"brightness order: expected primary first with EDID names, got {summary}");
        }
    }

    private static async Task<IReadOnlyList<DisplayBrightnessState>> ReadSettledAsync(
        MonitorBrightnessService service,
        int expectedCount)
    {
        var deadline = DateTimeOffset.UtcNow + TimeSpan.FromSeconds(6);
        IReadOnlyList<DisplayBrightnessState> displays = [];
        while (DateTimeOffset.UtcNow < deadline)
        {
            displays = await service.ReadAsync(CancellationToken.None);
            if (displays.Count == expectedCount
                && displays.All(display => display.Id.StartsWith("ddc:", StringComparison.Ordinal) && display.Supported))
            {
                return displays;
            }

            await Task.Delay(30);
        }

        return displays;
    }

    private sealed class FakeDdcPlatform : IDdcPlatform
    {
        private readonly List<(IntPtr Handle, string DeviceName, bool IsPrimary, DdcMonitorDevice Device, FakeMonitorHardware Hardware)> _monitors = [];

        public FakeMonitorHardware Main { get; } = new(54);

        public FakeMonitorHardware Sub { get; } = new(73);

        public static FakeDdcPlatform TwoMonitors(bool subFirst = false)
        {
            var platform = new FakeDdcPlatform();
            var main = ((IntPtr)0x1001, @"\\.\DISPLAY5", true,
                new DdcMonitorDevice("GSM7861-5-9d3d97b-0-UID540928", "GSM7861", "LG ULTRAGEAR+"), platform.Main);
            var sub = ((IntPtr)0x2001, @"\\.\DISPLAY9", false,
                new DdcMonitorDevice("HSJ1600-4-124f0533-0-UID69", "HSJ1600", "U16ZT"), platform.Sub);
            platform._monitors.AddRange(subFirst ? [sub, main] : [main, sub]);
            return platform;
        }

        public void ReplaceSubHandle()
        {
            lock (_monitors)
            {
                var index = _monitors.FindIndex(monitor => !monitor.IsPrimary);
                var current = _monitors[index];
                _monitors[index] = (current.Handle + 0x10, current.DeviceName, current.IsPrimary, current.Device, current.Hardware);
                current.Hardware.Generation++;
            }
        }

        public IReadOnlyList<DdcLogicalMonitor> EnumerateMonitors()
        {
            lock (_monitors)
            {
                // The real platform returns primary first; keep that contract even when configured otherwise.
                return _monitors
                    .OrderByDescending(monitor => monitor.IsPrimary)
                    .Select(monitor => new DdcLogicalMonitor(monitor.Handle, monitor.DeviceName, monitor.IsPrimary, [monitor.Device]))
                    .ToArray();
            }
        }

        public IReadOnlyList<IDdcPhysicalMonitor> OpenPhysicalMonitors(IntPtr monitorHandle)
        {
            lock (_monitors)
            {
                var match = _monitors.FirstOrDefault(monitor => monitor.Handle == monitorHandle);
                return match.Hardware is null ? [] : [new FakePhysicalMonitor(match.Hardware, match.Hardware.Generation)];
            }
        }
    }

    private sealed class FakeMonitorHardware(int initial)
    {
        private readonly object _sync = new();
        private int _previous = initial;
        private int _target = initial;
        private long _appliedAtTimestamp;
        private int _inFlight;

        public int Generation { get; set; } = 1;

        public TimeSpan ReadDelay { get; set; }

        // Simulates a monitor that is asleep or not answering DDC/CI.
        public bool Unresponsive { get; set; }

        public bool Busy => Volatile.Read(ref _inFlight) > 0;

        public TimeSpan WriteDelay { get; set; }

        public TimeSpan ReadbackLag { get; set; }

        public int Overlaps;

        public int Value
        {
            get
            {
                lock (_sync)
                {
                    return _target;
                }
            }
        }

        public bool Read(int generation, out uint current)
        {
            using var scope = Enter();
            Thread.Sleep(ReadDelay);
            lock (_sync)
            {
                var applied = Stopwatch.GetTimestamp() >= _appliedAtTimestamp;
                current = (uint)(applied ? _target : _previous);
            }

            return generation == Generation && !Unresponsive;
        }

        public bool Write(int generation, uint value)
        {
            using var scope = Enter();
            Thread.Sleep(WriteDelay);
            if (generation != Generation)
            {
                return false;
            }

            lock (_sync)
            {
                _previous = _target;
                _target = (int)value;
                _appliedAtTimestamp = Stopwatch.GetTimestamp() + (long)(ReadbackLag.TotalSeconds * Stopwatch.Frequency);
            }

            return true;
        }

        private InFlightScope Enter()
        {
            if (Interlocked.Increment(ref _inFlight) > 1)
            {
                Interlocked.Increment(ref Overlaps);
            }

            return new InFlightScope(this);
        }

        private readonly struct InFlightScope(FakeMonitorHardware owner) : IDisposable
        {
            public void Dispose() => Interlocked.Decrement(ref owner._inFlight);
        }
    }

    private sealed class FakePhysicalMonitor(FakeMonitorHardware hardware, int generation) : IDdcPhysicalMonitor
    {
        public string Description => "Generic PnP Monitor";

        public bool TryReadVcpBrightness(out uint current, out uint maximum, out int error)
        {
            maximum = 100;
            var ok = hardware.Read(generation, out current);
            error = ok ? 0 : unchecked((int)0xC026258D);
            return ok;
        }

        public bool TryWriteVcpBrightness(uint value, out int error)
        {
            var ok = hardware.Write(generation, value);
            error = ok ? 0 : unchecked((int)0xC026258D);
            return ok;
        }

        public bool TryReadHighLevelBrightness(out uint minimum, out uint current, out uint maximum, out int error)
        {
            minimum = 0;
            return TryReadVcpBrightness(out current, out maximum, out error);
        }

        public bool TryWriteHighLevelBrightness(uint value, out int error) => TryWriteVcpBrightness(value, out error);

        public void Dispose()
        {
        }
    }
}
