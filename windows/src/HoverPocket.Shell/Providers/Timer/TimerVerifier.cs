using System.IO;
using HoverPocket.Shell.Verification;

namespace HoverPocket.Shell.Providers.Timer;

internal sealed class TimerVerifier
{
    private readonly List<string> _failures = [];

    public int Run()
    {
        var root = Path.Combine(Path.GetTempPath(), "HoverPocketTimerVerify", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            VerifyDefaults(root);
            VerifyStateTransitions(root);
            VerifyPersistenceAndRestore(root);
            VerifyExpiredDiscard(root);
            VerifyAbsoluteTimeAndPomodoro(root);
        }
        finally
        {
            try
            {
                Directory.Delete(root, recursive: true);
            }
            catch (IOException)
            {
            }
        }

        if (_failures.Count == 0)
        {
            VerifyConsole.WriteLine("PASS timer verify: start, pause, resume, stop, persistence, expired discard, absolute time");
            return 0;
        }

        VerifyConsole.WriteLine("FAIL timer verify:");
        foreach (var failure in _failures)
        {
            VerifyConsole.WriteLine($"- {failure}");
        }

        return 1;
    }

    private void VerifyDefaults(string root)
    {
        var clock = new ManualTimerClock(new DateTimeOffset(2026, 7, 5, 0, 0, 0, TimeSpan.Zero));
        using var store = NewStore(root, "defaults", clock);
        var snapshot = store.GetSnapshot();
        if (snapshot.DraftTimer.DurationSeconds != 10 * 60)
        {
            _failures.Add("defaults: normal timer duration was not 10 minutes");
        }

        if (snapshot.DraftPomodoro.WorkDurationSeconds != 25 * 60
            || snapshot.DraftPomodoro.RestDurationSeconds != 5 * 60)
        {
            _failures.Add("defaults: pomodoro work/rest durations were not 25/5 minutes");
        }
    }

    private void VerifyStateTransitions(string root)
    {
        var clock = new ManualTimerClock(new DateTimeOffset(2026, 7, 5, 0, 0, 0, TimeSpan.Zero));
        using var store = NewStore(root, "transitions", clock);
        var preset = TimerPreset.DefaultTimerDraft() with { DurationSeconds = 60, SoundEnabled = false };

        store.Start(preset);
        store.Start(preset);
        store.Start(preset);
        var snapshot = store.GetSnapshot();
        if (snapshot.RunningTimers.Count != TimerStore.MaxConcurrentTimers || snapshot.CanStartTimer)
        {
            _failures.Add("state transitions: max two running timers was not enforced");
        }

        var timerId = snapshot.RunningTimers[0].Id;
        store.Pause(timerId);
        clock.Advance(TimeSpan.FromSeconds(20));
        var paused = store.GetSnapshot().RunningTimers.First(timer => timer.Id == timerId);
        if (!paused.IsPaused || Math.Abs(paused.RemainingSeconds - 60) > 0.01)
        {
            _failures.Add("state transitions: pause did not freeze remaining seconds");
        }

        store.Resume(timerId);
        clock.Advance(TimeSpan.FromSeconds(10));
        var resumed = store.GetSnapshot().RunningTimers.First(timer => timer.Id == timerId);
        if (resumed.IsPaused || resumed.RemainingSeconds is > 50.01 or < 49.99)
        {
            _failures.Add("state transitions: resume did not anchor a new absolute end time");
        }

        store.Stop(timerId);
        if (store.GetSnapshot().RunningTimers.Any(timer => timer.Id == timerId))
        {
            _failures.Add("state transitions: stop did not remove the timer");
        }
    }

    private void VerifyPersistenceAndRestore(string root)
    {
        var clock = new ManualTimerClock(new DateTimeOffset(2026, 7, 5, 1, 0, 0, TimeSpan.Zero));
        var directory = Path.Combine(root, "restore");
        var preset = TimerPreset.DefaultTimerDraft() with { Title = "persist", DurationSeconds = 120, SoundEnabled = false };
        using (var store = NewStore(directory, clock))
        {
            store.Start(preset);
            for (var index = 0; index < TimerStore.MaxPinnedPresets + 2; index++)
            {
                store.PinPreset(preset with { Title = $"pin-{index}" });
            }
        }

        using var restored = NewStore(directory, clock);
        var snapshot = restored.GetSnapshot();
        if (snapshot.RunningTimers.Count != 1 || snapshot.RunningTimers[0].Title != "persist")
        {
            _failures.Add("persistence: running timer was not restored");
        }

        if (snapshot.PinnedPresets.Count != TimerStore.MaxPinnedPresets)
        {
            _failures.Add("persistence: pinned presets were not capped and restored at four");
        }
    }

    private void VerifyExpiredDiscard(string root)
    {
        var clock = new ManualTimerClock(new DateTimeOffset(2026, 7, 5, 2, 0, 0, TimeSpan.Zero));
        var directory = Path.Combine(root, "expired");
        using (var store = NewStore(directory, clock))
        {
            store.Start(TimerPreset.DefaultTimerDraft() with { DurationSeconds = 1, SoundEnabled = false });
        }

        clock.Advance(TimeSpan.FromSeconds(2));
        using var restored = NewStore(directory, clock);
        if (restored.GetSnapshot().RunningTimers.Count != 0 || restored.GetSnapshot().ActiveAlert is not null)
        {
            _failures.Add("expired discard: expired timer was restored or alerted late");
        }
    }

    private void VerifyAbsoluteTimeAndPomodoro(string root)
    {
        var clock = new ManualTimerClock(new DateTimeOffset(2026, 7, 5, 3, 0, 0, TimeSpan.Zero));
        var alertSound = new NullTimerAlertSound();
        using var store = new TimerStore(Path.Combine(root, "absolute"), clock, alertSound, enableScheduler: false);

        store.Start(TimerPreset.DefaultTimerDraft() with { DurationSeconds = 60, SoundEnabled = false });
        clock.Advance(TimeSpan.FromSeconds(42));
        var remaining = store.GetSnapshot().RunningTimers[0].RemainingSeconds;
        if (remaining is > 18.01 or < 17.99)
        {
            _failures.Add($"absolute time: expected 18 seconds remaining after clock advance, got {remaining}");
        }

        clock.Advance(TimeSpan.FromSeconds(19));
        store.CheckExpired();
        var afterExpired = store.GetSnapshot();
        if (afterExpired.RunningTimers.Count != 0 || afterExpired.ActiveAlert is null)
        {
            _failures.Add("absolute time: expired normal timer did not fire and leave an alert");
        }

        store.StopAlert();
        var pomodoro = TimerPreset.DefaultPomodoroDraft() with
        {
            WorkDurationSeconds = 1,
            RestDurationSeconds = 2,
            SoundEnabled = true
        };
        store.Start(pomodoro);
        clock.Advance(TimeSpan.FromSeconds(1.1));
        store.CheckExpired();
        var running = store.GetSnapshot().RunningTimers.SingleOrDefault(timer => timer.IsPomodoro);
        if (running is null
            || running.Phase != PomodoroPhase.Rest
            || running.CompletedWorkCycles != 1
            || running.RemainingSeconds is > 2.01 or < 1.99)
        {
            _failures.Add("pomodoro: work expiry did not switch to rest with absolute end time");
        }

        if (alertSound.StartCount != 1)
        {
            _failures.Add("alert sound: sound-enabled timer did not start the system sound loop");
        }
    }

    private static TimerStore NewStore(string root, string name, ManualTimerClock clock)
    {
        return NewStore(Path.Combine(root, name), clock);
    }

    private static TimerStore NewStore(string directory, ManualTimerClock clock)
    {
        return new TimerStore(directory, clock, new NullTimerAlertSound(), enableScheduler: false);
    }
}
