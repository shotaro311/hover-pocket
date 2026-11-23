using System.Diagnostics;
using System.IO;
using System.Management;
using System.Runtime.InteropServices;
using System.Text.Json;
using HoverPocket.Shell.Bridge;
using HoverPocket.Shell.Configuration;
using HoverPocket.Shell.Settings;
using HoverPocket.Shell.Verification;

namespace HoverPocket.Shell.Providers.Controls;

internal sealed partial class ControlsVerifier
{
    private async Task VerifyContrastAsync()
    {
        await VerifyContrastDetectionAndWritesAsync();
        await VerifyContrastGateAndTimeoutAsync();
        await VerifyContrastRebuildAsync();
        await VerifyContrastRetryAsync(toggle: false);
        await VerifyContrastRetryAsync(toggle: true);
        await VerifyBrightnessRebuildKeepsContrastAsync();
        await VerifyContrastEnableDuringBrightnessWriteAsync();
        await VerifyBrightnessWritesOutOfSequenceAsync();
        await VerifyContrastHardwareRestorationAsync();
    }

    private async Task VerifyContrastDetectionAndWritesAsync()
    {
        var platform = FakeDdcPlatform.TwoMonitors();
        platform.Sub.ContrastUnsupported = true;
        var timing = FastTiming with { CacheLifetime = TimeSpan.FromMilliseconds(30) };
        using var service = new MonitorBrightnessService(platform, includeWmi: false, timing, listenForSystemEvents: false);
        var displays = await ReadSettledAsync(service, 2);
        var main = displays.First(display => display.IsPrimary == true);
        var sub = displays.First(display => display.IsPrimary == false);
        await Task.Delay(50);
        _ = await service.ReadAsync(CancellationToken.None);
        _ = await service.SetBrightnessAsync(main.Id, 55, CancellationToken.None);
        _ = await service.SetContrastAsync(main.Id, 65, CancellationToken.None);
        CheckContrast(platform.Main.ContrastReads + platform.Sub.ContrastReads
            + platform.Main.ContrastWrites + platform.Sub.ContrastWrites == 0, "off sent contrast commands");

        service.SetContrastVisible(true);
        displays = await ReadContrastWhenAsync(service, states =>
            states.Count == 2 && states.All(display => display.ContrastSupported.HasValue), CancellationToken.None);
        CheckContrast(Display(displays, main.Id) is { ContrastSupported: true, ContrastValue: 50 },
            "40 out of 80 did not read back as 50%");
        CheckContrast(Display(displays, sub.Id) is { Supported: true, Value: 73, ContrastSupported: false },
            "unsupported contrast changed brightness support");

        var subProbeCount = platform.Sub.ContrastReads;
        await Task.Delay(50);
        _ = await service.ReadAsync(CancellationToken.None);
        var subBrightness = Display(await service.SetBrightnessAsync(sub.Id, 72, CancellationToken.None), sub.Id);
        _ = await service.SetContrastAsync(sub.Id, 35, CancellationToken.None);
        CheckContrast(subBrightness is { WriteVerified: true, ContrastSupported: false }
            && platform.Sub.ContrastReads == subProbeCount && platform.Sub.ContrastWrites == 0,
            "unsupported feature was probed again or broke a brightness write");

        _ = await service.SetBrightnessAsync(main.Id, 61, CancellationToken.None);
        var changed = await service.SetContrastAsync(main.Id, 75, CancellationToken.None);
        var raw = await service.ReadContrastFreshForVerifyAsync(main.Id, CancellationToken.None);
        CheckContrast(Display(changed, main.Id) is
            { Value: 61, WriteVerified: true, ContrastValue: 75, ContrastWriteVerified: true, ContrastError: null }
            && raw is { RawValue: 60 }, "write verification or scaling was incorrect");

        platform.Main.IgnoreContrastWrites = true;
        var mismatch = await service.SetContrastAsync(main.Id, 30, CancellationToken.None);
        CheckContrast(Display(mismatch, main.Id) is
            { Error: null, WriteVerified: true, ContrastValue: 75, ContrastWriteVerified: false,
                ContrastError: "Contrast readback did not match 30%." },
            "contrast mismatch either lost the observed value or changed brightness verification");
        var brightness = await service.SetBrightnessAsync(main.Id, 64, CancellationToken.None);
        CheckContrast(Display(brightness, main.Id) is
            { Value: 64, WriteVerified: true, ContrastValue: 75, ContrastWriteVerified: false,
                ContrastError: "Contrast readback did not match 30%." },
            "brightness write lost the contrast state");

        var readsBeforeWmi = platform.Main.ContrastReads + platform.Sub.ContrastReads;
        var wmi = await service.SetContrastAsync("wmi:0", 50, CancellationToken.None);
        CheckContrast(Display(wmi, "wmi:0") is { ContrastSupported: false, WriteVerified: null, Error: null }
            && platform.Main.ContrastReads + platform.Sub.ContrastReads == readsBeforeWmi,
            "WMI target did not return unsupported without issuing a command");

        platform.Sub.ContrastUnsupported = false;
        platform.Sub.ContrastHighLevelOnly = true;
        service.InvalidateTopology();
        displays = await ReadContrastWhenAsync(service, states => Display(states, sub.Id)?.ContrastSupported == true,
            CancellationToken.None);
        CheckContrast(Display(displays, sub.Id) is { ContrastValue: 50 },
            "rediscovery did not retry unsupported contrast with high-level fallback");
        var highLevel = await service.SetContrastAsync(sub.Id, 65, CancellationToken.None);
        CheckContrast(Display(highLevel, sub.Id) is { ContrastValue: 65, ContrastWriteVerified: true },
            "high-level contrast write/readback failed");

        service.SetContrastVisible(false);
        var readsBeforeOff = platform.Main.ContrastReads + platform.Sub.ContrastReads;
        var writesBeforeOff = platform.Main.ContrastWrites + platform.Sub.ContrastWrites;
        service.InvalidateTopology();
        _ = await service.ReadAsync(CancellationToken.None);
        _ = await service.SetBrightnessAsync(sub.Id, 53, CancellationToken.None);
        _ = await service.SetContrastAsync(sub.Id, 37, CancellationToken.None);
        CheckContrast(platform.Main.ContrastReads + platform.Sub.ContrastReads == readsBeforeOff
            && platform.Main.ContrastWrites + platform.Sub.ContrastWrites == writesBeforeOff,
            "disabling contrast did not stop commands");
    }

    private async Task VerifyContrastGateAndTimeoutAsync()
    {
        var platform = FakeDdcPlatform.TwoMonitors();
        var timing = FastTiming with { WriteTimeout = TimeSpan.FromMilliseconds(650) };
        using var service = new MonitorBrightnessService(platform, includeWmi: false, timing, listenForSystemEvents: false);
        service.SetContrastVisible(true);
        var displays = await ReadContrastWhenAsync(service, states =>
            states.Count == 2 && states.All(display => display.ContrastSupported == true), CancellationToken.None);
        var main = displays.First(display => display.IsPrimary == true);
        var sub = displays.First(display => display.IsPrimary == false);
        platform.Sub.ContrastWriteDelay = TimeSpan.FromMilliseconds(950);
        var late = new TaskCompletionSource<DisplayBrightnessState>(TaskCreationOptions.RunContinuationsAsynchronously);
        service.StateChanged += (_, states) =>
        {
            if (Display(states, sub.Id) is { ContrastWriteVerified: true, ContrastValue: 65 } display)
            {
                late.TrySetResult(display);
            }
        };

        var slow = service.SetContrastAsync(sub.Id, 65, CancellationToken.None);
        var started = Stopwatch.StartNew();
        while (!platform.Sub.Busy && started.Elapsed < TimeSpan.FromMilliseconds(500))
        {
            await Task.Delay(5);
        }

        CheckContrast(platform.Sub.Busy, "slow contrast write did not acquire the monitor gate");
        var timer = Stopwatch.StartNew();
        var other = await service.SetBrightnessAsync(main.Id, 42, CancellationToken.None);
        CheckContrast(timer.Elapsed < TimeSpan.FromMilliseconds(500) && Display(other, main.Id)?.WriteVerified == true,
            "slow contrast command blocked another monitor");

        CheckContrast(Display(await slow, sub.Id) is { ContrastError: "Contrast command timed out.", Error: null },
            "timeout did not annotate contrast only");
        var same = service.SetBrightnessAsync(sub.Id, 56, CancellationToken.None);
        var settled = await same;
        CheckContrast(Display(settled, sub.Id) is { Value: 56, WriteVerified: true, ContrastValue: 65 }
            && platform.Sub.Overlaps == 0, "brightness and contrast overlapped on the same monitor");
        try
        {
            _ = await late.Task.WaitAsync(TimeSpan.FromSeconds(2));
        }
        catch (TimeoutException)
        {
            CheckContrast(false, "late contrast verification was not published");
        }
    }

    private async Task VerifyContrastRebuildAsync()
    {
        var platform = FakeDdcPlatform.TwoMonitors();
        using var service = new MonitorBrightnessService(platform, includeWmi: false, FastTiming, listenForSystemEvents: false);
        service.SetContrastVisible(true);
        var displays = await ReadContrastWhenAsync(service, states =>
            states.Count == 2 && states.All(display => display.ContrastSupported == true), CancellationToken.None);
        var main = displays.First(display => display.IsPrimary == true);
        var probeComplete = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var allowSwap = new ManualResetEventSlim();
        service.BeforeRegistrySwapForVerify = () =>
        {
            service.BeforeRegistrySwapForVerify = null;
            probeComplete.TrySetResult();
            _ = allowSwap.Wait(TimeSpan.FromSeconds(5));
        };
        var rebuilt = new TaskCompletionSource<IReadOnlyList<DisplayBrightnessState>>(TaskCreationOptions.RunContinuationsAsynchronously);
        service.StateChanged += (_, states) => rebuilt.TrySetResult(states);

        service.InvalidateTopology();
        var read = service.ReadAsync(CancellationToken.None);
        try
        {
            await probeComplete.Task.WaitAsync(TimeSpan.FromSeconds(3));
            var write = await service.SetContrastAsync(main.Id, 70, CancellationToken.None);
            CheckContrast(Display(write, main.Id) is { ContrastValue: 70, ContrastWriteVerified: true },
                "contrast write during rediscovery was not verified");
        }
        finally
        {
            allowSwap.Set();
        }

        _ = await read;
        displays = await rebuilt.Task.WaitAsync(TimeSpan.FromSeconds(3));
        CheckContrast(Display(displays, main.Id) is { ContrastValue: 70 },
            "rediscovery published a stale contrast sample");
    }

    private async Task VerifyContrastRetryAsync(bool toggle)
    {
        var platform = FakeDdcPlatform.TwoMonitors();
        platform.Main.ContrastUnsupported = true;
        var timing = FastTiming with
        {
            CacheLifetime = TimeSpan.FromMilliseconds(40),
            UnavailableRetry = TimeSpan.FromSeconds(1)
        };
        using var service = new MonitorBrightnessService(platform, includeWmi: false, timing, listenForSystemEvents: false);
        service.SetContrastVisible(true);
        var displays = await ReadContrastWhenAsync(service, states => states.Count == 2
            && states.All(display => display.ContrastSupported.HasValue), CancellationToken.None);
        var main = displays.First(display => display.IsPrimary == true);
        CheckContrast(main is { Supported: true, ContrastSupported: false }, "failed initial contrast probe was not classified");
        var failedReads = platform.Main.ContrastReads;
        platform.Main.ContrastUnsupported = false;
        await Task.Delay(timing.CacheLifetime + TimeSpan.FromMilliseconds(20));
        var early = Display(await service.ReadAsync(CancellationToken.None), main.Id);
        CheckContrast(early?.ContrastSupported == false && platform.Main.ContrastReads == failedReads,
            "unavailable contrast was probed before its retry interval");

        if (toggle)
        {
            service.SetContrastVisible(false);
            service.SetContrastVisible(true);
        }
        else
        {
            await Task.Delay(timing.UnavailableRetry);
        }

        displays = await ReadContrastWhenAsync(service, states => Display(states, main.Id)?.ContrastSupported == true,
            CancellationToken.None);
        CheckContrast(Display(displays, main.Id) is { ContrastSupported: true, ContrastValue: 50 }
            && platform.Main.ContrastReads == failedReads + 1, $"unavailable contrast did not retry once (toggle={toggle})");
    }

    private async Task VerifyBrightnessRebuildKeepsContrastAsync()
    {
        var platform = FakeDdcPlatform.TwoMonitors();
        platform.Sub.ContrastUnsupported = true;
        using var service = new MonitorBrightnessService(platform, includeWmi: false, FastTiming, listenForSystemEvents: false);
        service.SetContrastVisible(true);
        var displays = await ReadContrastWhenAsync(service, states => states.Count == 2
            && states.All(display => display.ContrastSupported.HasValue), CancellationToken.None);
        var main = displays.First(display => display.IsPrimary == true);
        var sub = displays.First(display => display.IsPrimary == false);
        _ = await service.SetContrastAsync(main.Id, 70, CancellationToken.None);
        var reads = platform.Main.ContrastReads + platform.Sub.ContrastReads;

        // A stale DDC ID forces the brightness write path to rebuild without probing contrast.
        var rebuilt = await service.SetBrightnessAsync("ddc:stale-id", 60, CancellationToken.None);
        CheckContrast(Display(rebuilt, main.Id) is { ContrastSupported: true, ContrastValue: 70 }
            && Display(rebuilt, sub.Id)?.ContrastSupported == false
            && platform.Main.ContrastReads + platform.Sub.ContrastReads == reads,
            "brightness-triggered rediscovery dropped cached contrast state or probed contrast");
    }

    private async Task VerifyContrastEnableDuringBrightnessWriteAsync()
    {
        var platform = FakeDdcPlatform.TwoMonitors();
        using var service = new MonitorBrightnessService(platform, includeWmi: false, FastTiming, listenForSystemEvents: false);
        var displays = await ReadSettledAsync(service, 2);
        var main = displays.First(display => display.IsPrimary == true);
        platform.Main.ReadbackLag = TimeSpan.FromSeconds(10);
        var previous = await service.SetBrightnessAsync(main.Id, 61, CancellationToken.None);

        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var resume = new ManualResetEventSlim();
        service.BeforeDdcWriteForVerify = (feature, _, _, _) =>
        {
            if (feature == DdcFeature.Brightness)
            {
                entered.TrySetResult();
                _ = resume.Wait(TimeSpan.FromSeconds(5));
            }
        };

        var write = service.SetBrightnessAsync(main.Id, 72, CancellationToken.None);
        try
        {
            await entered.Task.WaitAsync(TimeSpan.FromSeconds(3));
            service.SetContrastVisible(true);
            var during = await service.ReadAsync(CancellationToken.None);
            CheckContrast(ReferenceEquals(previous, during)
                && Display(during, main.Id) is { Error: "Brightness readback did not match 61%.", WriteVerified: false }
                && platform.Main.ContrastReads + platform.Sub.ContrastReads == 0,
                "enabling contrast refreshed the snapshot during a brightness write");
        }
        finally
        {
            resume.Set();
        }

        _ = await write;
        var after = await ReadContrastWhenAsync(service, states => Display(states, main.Id)?.ContrastSupported == true,
            CancellationToken.None);
        CheckContrast(Display(after, main.Id) is
            { ContrastSupported: true, Error: "Brightness readback did not match 72%.", WriteVerified: false },
            "enabling contrast lost the completed brightness write result or the pending contrast refresh");
    }

    private async Task VerifyBrightnessWritesOutOfSequenceAsync()
    {
        var platform = FakeDdcPlatform.TwoMonitors();
        using var service = new MonitorBrightnessService(platform, includeWmi: false, FastTiming, listenForSystemEvents: false);
        var main = (await ReadSettledAsync(service, 2)).First(display => display.IsPrimary == true);
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var resumeFirst = new ManualResetEventSlim();
        service.BeforeDdcWriteForVerify = (feature, _, value, _) =>
        {
            if (feature == DdcFeature.Brightness && value == 61)
            {
                entered.TrySetResult();
                _ = resumeFirst.Wait(TimeSpan.FromSeconds(5));
            }
        };

        var first = service.SetBrightnessAsync(main.Id, 61, CancellationToken.None);
        try
        {
            await entered.Task.WaitAsync(TimeSpan.FromSeconds(3));
            var second = await service.SetBrightnessAsync(main.Id, 77, CancellationToken.None);
            CheckContrast(Display(second, main.Id) is { Value: 77, WriteVerified: true } && platform.Main.Value == 77,
                "the later brightness request did not acquire the gate first");
        }
        finally
        {
            resumeFirst.Set();
        }

        var lastWrite = Display(await first, main.Id);
        var lastRead = Display(await service.ReadAsync(CancellationToken.None), main.Id);
        CheckContrast(lastWrite is { Value: 61, WriteVerified: true }
            && lastRead?.Value == platform.Main.Value && platform.Main.Value == 61,
            "the earlier request's later completion did not match the final hardware value");
    }

    private async Task VerifyContrastHardwareRestorationAsync()
    {
        var platform = FakeDdcPlatform.TwoMonitors();
        platform.Main.ContrastMaximum = 187;
        platform.Sub.ContrastUnsupported = true;
        var timing = FastTiming with { WriteTimeout = TimeSpan.FromSeconds(4) };
        using var service = new MonitorBrightnessService(platform, includeWmi: false, timing, listenForSystemEvents: false);
        service.SetContrastVisible(true);
        _ = await ReadContrastWhenAsync(service,
            states => states.Count == 2 && states.All(display => display.ContrastSupported.HasValue), CancellationToken.None);
        var originalRaw = platform.Main.ContrastRawValue;
        var reads = 0;
        var observedReadFinished = 0;
        var restoredBeforeReadFinished = false;
        var restoreAttempts = 0;
        Task<DisplayBrightnessState?>? competingRead = null;
        using var competingReadStarted = new ManualResetEventSlim();
        using var releaseCompetingRead = new ManualResetEventSlim();
        platform.Main.BeforeRead = feature =>
        {
            if (feature == DdcFeature.Contrast && Interlocked.Increment(ref reads) == 3)
            {
                // Original sample, write readback, then the verifier's fresh sample.
                Thread.Sleep(TimeSpan.FromMilliseconds(4200));
                Volatile.Write(ref observedReadFinished, 1);
            }
            else if (feature == DdcFeature.Brightness)
            {
                competingReadStarted.Set();
                _ = releaseCompetingRead.Wait(TimeSpan.FromSeconds(5));
            }
        };
        service.BeforeDdcWriteForVerify = (feature, id, value, raw) =>
        {
            if (feature != DdcFeature.Contrast || !raw.HasValue)
            {
                return;
            }

            if (++restoreAttempts == 1)
            {
                restoredBeforeReadFinished = Volatile.Read(ref observedReadFinished) == 0;
                competingRead = service.ReadTargetFreshAsync(id, CancellationToken.None);
                _ = competingReadStarted.Wait(TimeSpan.FromSeconds(5));
            }
            else
            {
                releaseCompetingRead.Set();
            }
        };

        var output = new List<string>();
        try
        {
            var result = await VerifyContrastHardwareAsync(service, TimeSpan.FromSeconds(5),
                TimeSpan.FromMilliseconds(150), output.Add);
            CheckContrast(result == 0 && !restoredBeforeReadFinished
                && competingReadStarted.IsSet && restoreAttempts >= 2
                && platform.Main.ContrastWrites == 2 && platform.Main.ContrastRawValue == originalRaw
                && output.Any(line => line.Contains($"restored=21%({originalRaw})", StringComparison.Ordinal)),
                "hardware verifier did not wait for the long sample, retry a busy restore, and confirm the original raw value");
        }
        finally
        {
            releaseCompetingRead.Set();
            if (competingRead is not null)
            {
                _ = await competingRead;
            }
        }

        platform.Main.BeforeRead = null;
        service.BeforeDdcWriteForVerify = (feature, _, _, raw) =>
        {
            if (feature == DdcFeature.Contrast && raw.HasValue)
            {
                platform.Main.IgnoreContrastWrites = true;
            }
        };
        output.Clear();
        var mismatch = await VerifyContrastHardwareAsync(service, TimeSpan.FromSeconds(5),
            TimeSpan.FromMilliseconds(150), output.Add);
        CheckContrast(mismatch == 1 && platform.Main.ContrastRawValue != originalRaw
            && output.Any(line => line.StartsWith("contrast_hardware_verify=failed", StringComparison.Ordinal)),
            "hardware verifier reported success when the monitor accepted but ignored restoration");

        // The monitor ignores only the first restoration command; the verifier must retry and restore it.
        var restoreWrites = 0;
        service.BeforeDdcWriteForVerify = (feature, _, _, raw) =>
        {
            if (feature == DdcFeature.Contrast && raw.HasValue)
            {
                platform.Main.IgnoreContrastWrites = ++restoreWrites == 1;
            }
        };
        platform.Main.IgnoreContrastWrites = false;
        var restoreBefore = platform.Main.ContrastRawValue;
        output.Clear();
        var retried = await VerifyContrastHardwareAsync(service, TimeSpan.FromSeconds(5),
            TimeSpan.FromMilliseconds(150), output.Add);
        CheckContrast(retried == 0 && restoreWrites >= 2 && platform.Main.ContrastRawValue == restoreBefore
            && output.Any(line => line.StartsWith("contrast_hardware_verify=ok", StringComparison.Ordinal)),
            "hardware verifier did not retry a restoration the monitor ignored once");
        service.BeforeDdcWriteForVerify = null;
        platform.Main.IgnoreContrastWrites = false;
    }

    private async Task VerifyContrastSettingsAsync()
    {
        var providers = ProviderRegistry.CreateDefault();
        var ids = providers.ProviderIds;
        var defaults = UserSettingsStore.CreateDefault(ids);
        CheckContrast(!defaults.ControlsContrastVisible, "visibility defaulted to on");
        var enabled = defaults.Clone();
        enabled.ControlsContrastVisible = true;
        CheckContrast(UserSettingsStore.Normalize(enabled.Clone(), ids).ControlsContrastVisible
            && !UserSettingsStore.Normalize(defaults.Clone(), ids).ControlsContrastVisible,
            "Clone or Normalize lost the visibility preference");

        var store = UserSettingsStore.CreateTemporary("ControlsContrastVerify");
        enabled.ClipboardPrivateMode = true;
        store.Save(enabled);
        using var panel = new PanelBridgeController(providers, store, store.Load(ids), externalIntegrationsEnabled: false);
        var dispatcher = new BridgeDispatcher();
        using var attachment = panel.Attach(dispatcher);
        CheckContrast(await VisibilityAsync("controls.getContrastVisible", null) == true, "startup did not read saved visibility");
        foreach (var visible in new[] { false, true })
        {
            CheckContrast(await VisibilityAsync("controls.setContrastVisible", new { visible }) == visible
                && await VisibilityAsync("controls.getContrastVisible", null) == visible
                && store.Load(ids).ControlsContrastVisible == visible, "bridge visibility save did not survive disk readback");
        }

        await VerifyContrastSettingsResetAsync(providers, enabled);
        await VerifyContrastSaveRollbackAsync(providers, defaults);

        async Task<bool?> VisibilityAsync(string method, object? parameters)
        {
            var response = await dispatcher.ProcessRawMessageAsync(JsonSerializer.Serialize(new
            {
                id = "contrast-verify",
                method,
                @params = parameters
            }));
            using var document = JsonDocument.Parse(response!);
            return document.RootElement.TryGetProperty("result", out var result)
                && result.ValueKind == JsonValueKind.Object
                && result.TryGetProperty("visible", out var value) ? value.GetBoolean() : null;
        }
    }

    private async Task VerifyContrastSettingsResetAsync(ProviderRegistry providers, UserSettings enabled)
    {
        var store = UserSettingsStore.CreateTemporary("ControlsContrastResetVerify");
        var resetDefaults = UserSettingsStore.CreateDefault(providers.ProviderIds);
        resetDefaults.ClipboardPrivateMode = true;
        store.Save(enabled);
        using var panel = new PanelBridgeController(providers, store, store.Load(providers.ProviderIds),
            startupRegistration: new InMemoryStartupRegistrationService(), externalIntegrationsEnabled: false,
            isolatedVoiceE2EDefaults: resetDefaults);
        var platform = FakeDdcPlatform.TwoMonitors();
        var timing = FastTiming with { CacheLifetime = TimeSpan.Zero };
        using var service = new MonitorBrightnessService(platform, includeWmi: false, timing, listenForSystemEvents: false);
        using var controls = new ControlsBridgeController(new FakeVolumeService(), service, new FakeMediaService(),
            new FakePreviewService(), new FakeMediaSourceActivator());
        panel.RegisterControlsMethods(new BridgeDispatcher().Register, controls);
        var settings = new BridgeDispatcher();
        using var attachment = panel.Attach(settings, BridgeSurface.Settings);
        var displays = await ReadContrastWhenAsync(service, states => states.Count == 2
            && states.All(display => display.ContrastSupported == true), CancellationToken.None);
        var main = displays.First(display => display.IsPrimary == true);
        var reads = platform.Main.ContrastReads + platform.Sub.ContrastReads;
        CheckContrast(reads > 0, "initial saved setting did not reach the fake hardware service");

        var response = await settings.ProcessRawMessageAsync("""{"id":"contrast-reset","method":"settings.resetDefaults"}""");
        using var document = JsonDocument.Parse(response!);
        service.InvalidateTopology();
        _ = await service.ReadAsync(CancellationToken.None);
        _ = await service.SetBrightnessAsync(main.Id, 62, CancellationToken.None);
        _ = await service.SetContrastAsync(main.Id, 65, CancellationToken.None);
        CheckContrast(document.RootElement.TryGetProperty("result", out _)
            && !store.Load(providers.ProviderIds).ControlsContrastVisible
            && platform.Main.ContrastReads + platform.Sub.ContrastReads == reads
            && platform.Main.ContrastWrites + platform.Sub.ContrastWrites == 0,
            "settings reset did not save off and disable contrast commands");
    }

    private async Task VerifyContrastSaveRollbackAsync(ProviderRegistry providers, UserSettings defaults)
    {
        var store = UserSettingsStore.CreateTemporary("ControlsContrastRollbackVerify");
        defaults.ClipboardPrivateMode = true;
        store.Save(defaults);
        using var panel = new PanelBridgeController(providers, store, defaults,
            startupRegistration: new InMemoryStartupRegistrationService(), externalIntegrationsEnabled: false);
        var applied = new List<(bool Service, bool Saved)>();
        var brightness = new FakeBrightnessService
        {
            ContrastVisibilityChanged = visible => applied.Add((visible, store.Load(providers.ProviderIds).ControlsContrastVisible))
        };
        using var controls = new ControlsBridgeController(new FakeVolumeService(), brightness, new FakeMediaService(),
            new FakePreviewService(), new FakeMediaSourceActivator());
        var dispatcher = new BridgeDispatcher();
        panel.RegisterControlsMethods(dispatcher.Register, controls);
        panel.RegisterControlsMethods(new BridgeDispatcher().Register, controls);
        applied.Clear();

        const string toggle = """{"id":"contrast-save","method":"controls.setContrastVisible","params":{"visible":true}}""";
        using (var locked = File.Open(store.SettingsPath, FileMode.Open, FileAccess.Read, FileShare.Read))
        {
            var response = await dispatcher.ProcessRawMessageAsync(toggle);
            using var document = JsonDocument.Parse(response!);
            CheckContrast(document.RootElement.TryGetProperty("error", out _)
                && applied.SequenceEqual([(true, false), (false, false)]),
                "failed contrast save did not apply before saving and roll back before returning the error");
        }

        applied.Clear();
        var saved = await dispatcher.ProcessRawMessageAsync(toggle);
        using var success = JsonDocument.Parse(saved!);
        CheckContrast(success.RootElement.TryGetProperty("result", out _)
            && applied.SequenceEqual([(true, false), (true, true)])
            && store.Load(providers.ProviderIds).ControlsContrastVisible,
            "successful contrast save did not apply before saving or subscribed twice");
    }

    internal static async Task<int> RunContrastHardwareAsync()
    {
        using var service = new MonitorBrightnessService();
        return await VerifyContrastHardwareAsync(service, TimeSpan.FromSeconds(30), TimeSpan.FromSeconds(5),
            VerifyConsole.WriteLine);
    }

    private static async Task<int> VerifyContrastHardwareAsync(
        MonitorBrightnessService service, TimeSpan restoreTimeout, TimeSpan restoreGateWait, Action<string> log)
    {
        service.SetContrastVisible(true);
        var displays = await ReadContrastWhenAsync(service, states =>
            states.Count > 0 && states.All(display =>
                display.Error != "Brightness detection is still running."
                && (!display.Supported || display.ContrastSupported.HasValue)), CancellationToken.None);
        var supported = displays.Where(display => display.ContrastSupported == true).ToArray();
        var failed = supported.Length == 0
            || displays.Any(display => display.Error == "Brightness detection is still running."
                || (display.Supported && display.ContrastSupported is null));
        foreach (var display in supported)
        {
            var original = await ReadSampleAsync(display.Id);
            if (original is not { } initial)
            {
                log($"contrast_hardware display={display.Name} original=unavailable");
                failed = true;
                continue;
            }

            var requested = initial.Value > 95 ? initial.Value - 5 : initial.Value + 5;
            var accepted = false;
            var restoreAccepted = false;
            (int Value, uint RawValue)? observed = null;
            (int Value, uint RawValue)? restored = null;
            try
            {
                accepted = await WriteSampleAsync(display.Id, requested, restoreGateWait);
                observed = await ReadSampleAsync(display.Id);
            }
            finally
            {
                // Succeeds only when the original raw value reads back; a monitor that accepts the command but
                // ignores it once is retried within the remaining budget.
                var timer = Stopwatch.StartNew();
                var remaining = restoreTimeout;
                var restoredMatches = false;
                while (!restoredMatches && remaining > TimeSpan.Zero)
                {
                    var wait = remaining < restoreGateWait ? remaining : restoreGateWait;
                    var acceptedNow = await WriteSampleAsync(display.Id, initial.Value, wait, initial.RawValue);
                    restoreAccepted |= acceptedNow;
                    if (acceptedNow)
                    {
                        restored = await ReadSampleAsync(display.Id);
                        restoredMatches = restored?.RawValue == initial.RawValue;
                    }

                    remaining = restoreTimeout - timer.Elapsed;
                    if (!restoredMatches && remaining > TimeSpan.Zero)
                    {
                        var pause = TimeSpan.FromMilliseconds(250);
                        await Task.Delay(remaining < pause ? remaining : pause);
                        remaining = restoreTimeout - timer.Elapsed;
                    }
                }

                restored ??= await ReadSampleAsync(display.Id);
                log($"contrast_hardware display={display.Name} original={Format(initial)} "
                    + $"requested={requested}% accepted={accepted} readback={Format(observed)} "
                    + $"restore_accepted={restoreAccepted} restored={Format(restored)}");
            }

            failed |= !accepted || !restoreAccepted || observed is not { } changed || changed.RawValue == initial.RawValue
                || Math.Abs(changed.Value - requested) > MonitorBrightnessService.ReadbackTolerance
                || restored?.RawValue != initial.RawValue;
        }

        log($"contrast_hardware_verify={(failed ? "failed" : "ok")} supported={supported.Length}");
        return failed ? 1 : 0;

        async Task<(int Value, uint RawValue)?> ReadSampleAsync(string id)
        {
            try
            {
                return await service.ReadContrastFreshForVerifyAsync(id, CancellationToken.None);
            }
            catch (Exception exception) when (exception is ManagementException or COMException)
            {
                return null;
            }
        }

        async Task<bool> WriteSampleAsync(string id, int value, TimeSpan gateWait, uint? rawValue = null)
        {
            try
            {
                return await service.SetContrastForVerifyAsync(id, value, gateWait, rawValue);
            }
            catch (Exception exception) when (exception is ManagementException or COMException)
            {
                return false;
            }
        }

        static string Format((int Value, uint RawValue)? sample) =>
            sample is { } value ? $"{value.Value}%({value.RawValue})" : "unavailable";
    }

    private static DisplayBrightnessState? Display(IReadOnlyList<DisplayBrightnessState> states, string id) =>
        states.FirstOrDefault(display => display.Id == id);

    private static async Task<IReadOnlyList<DisplayBrightnessState>> ReadContrastWhenAsync(
        MonitorBrightnessService service,
        Func<IReadOnlyList<DisplayBrightnessState>, bool> ready,
        CancellationToken cancellationToken)
    {
        var timer = Stopwatch.StartNew();
        IReadOnlyList<DisplayBrightnessState> states;
        do
        {
            states = await service.ReadAsync(cancellationToken);
            if (ready(states))
            {
                return states;
            }

            await Task.Delay(25, cancellationToken);
        }
        while (timer.Elapsed < TimeSpan.FromSeconds(10));

        return states;
    }

    private void CheckContrast(bool passed, string failure)
    {
        if (!passed)
        {
            _failures.Add($"contrast: {failure}");
        }
    }
}
