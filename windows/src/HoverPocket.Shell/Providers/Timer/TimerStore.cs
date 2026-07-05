using System.IO;
using System.Media;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace HoverPocket.Shell.Providers.Timer;

internal sealed class TimerStore : IDisposable
{
    public const int MaxConcurrentTimers = 2;
    public const int MaxPinnedPresets = 4;

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) }
    };

    private readonly object _gate = new();
    private readonly ITimerClock _clock;
    private readonly ITimerAlertSound _alertSound;
    private readonly bool _enableScheduler;
    private System.Threading.Timer? _tickTimer;
    private bool _disposed;

    public TimerStore(
        string? storageDirectory = null,
        ITimerClock? clock = null,
        ITimerAlertSound? alertSound = null,
        bool enableScheduler = true)
    {
        StorageDirectory = storageDirectory ?? DefaultStorageDirectory();
        _clock = clock ?? SystemTimerClock.Instance;
        _alertSound = alertSound ?? new SystemTimerAlertSound();
        _enableScheduler = enableScheduler;

        DraftTimer = LoadOrDefault(DraftsPath, DraftsSnapshot.Default()).Timer;
        DraftPomodoro = LoadOrDefault(DraftsPath, DraftsSnapshot.Default()).Pomodoro;
        PinnedPresets = LoadOrDefault(PinnedPath, Array.Empty<TimerPreset>())
            .Take(MaxPinnedPresets)
            .ToList();
        RunningTimers = RestoreRunningTimers();
        SyncTickTimer();
    }

    public event EventHandler<TimerAlert>? AlertFired;

    public string StorageDirectory { get; }

    public TimerPreset DraftTimer { get; private set; }

    public TimerPreset DraftPomodoro { get; private set; }

    public List<TimerPreset> PinnedPresets { get; private set; }

    public List<RunningTimer> RunningTimers { get; private set; }

    public TimerAlert? ActiveAlert { get; private set; }

    private string DraftsPath => Path.Combine(StorageDirectory, "drafts.json");

    private string PinnedPath => Path.Combine(StorageDirectory, "pinned.json");

    private string RunningPath => Path.Combine(StorageDirectory, "running.json");

    public TimerSnapshot GetSnapshot()
    {
        lock (_gate)
        {
            return BuildSnapshotLocked(_clock.UtcNow);
        }
    }

    public TimerSnapshot UpdateDraftTimer(TimerPreset preset)
    {
        lock (_gate)
        {
            DraftTimer = preset with { IsPomodoro = false };
            PersistDraftsLocked();
            return BuildSnapshotLocked(_clock.UtcNow);
        }
    }

    public TimerSnapshot UpdateDraftPomodoro(TimerPreset preset)
    {
        lock (_gate)
        {
            DraftPomodoro = preset with { IsPomodoro = true };
            PersistDraftsLocked();
            return BuildSnapshotLocked(_clock.UtcNow);
        }
    }

    public TimerSnapshot Start(TimerPreset preset, Guid? pinnedPresetId = null)
    {
        lock (_gate)
        {
            if (RunningTimers.Count >= MaxConcurrentTimers)
            {
                return BuildSnapshotLocked(_clock.UtcNow);
            }

            var phaseDuration = ClampDuration(preset.IsPomodoro ? preset.WorkDurationSeconds : preset.DurationSeconds);
            if (phaseDuration <= 0)
            {
                return BuildSnapshotLocked(_clock.UtcNow);
            }

            var now = _clock.UtcNow;
            RunningTimers.Add(new RunningTimer(
                Guid.NewGuid(),
                preset.Title,
                preset.Color,
                preset.SoundEnabled,
                preset.IsPomodoro,
                PomodoroPhase.Work,
                0,
                now.AddSeconds(phaseDuration),
                phaseDuration,
                PausedRemainingSeconds: null,
                WorkDurationSeconds: ClampDuration(preset.WorkDurationSeconds),
                RestDurationSeconds: ClampDuration(preset.RestDurationSeconds),
                pinnedPresetId));
            PersistRunningLocked();
            SyncTickTimerLocked();
            return BuildSnapshotLocked(now);
        }
    }

    public TimerSnapshot Pause(Guid id)
    {
        lock (_gate)
        {
            var index = RunningTimers.FindIndex(timer => timer.Id == id);
            if (index >= 0 && !RunningTimers[index].IsPaused)
            {
                var timer = RunningTimers[index];
                RunningTimers[index] = timer with { PausedRemainingSeconds = timer.RemainingSeconds(_clock.UtcNow) };
                PersistRunningLocked();
                SyncTickTimerLocked();
            }

            return BuildSnapshotLocked(_clock.UtcNow);
        }
    }

    public TimerSnapshot Resume(Guid id)
    {
        lock (_gate)
        {
            var index = RunningTimers.FindIndex(timer => timer.Id == id);
            if (index >= 0 && RunningTimers[index].PausedRemainingSeconds is { } remaining)
            {
                RunningTimers[index] = RunningTimers[index] with
                {
                    PausedRemainingSeconds = null,
                    EndAtUtc = _clock.UtcNow.AddSeconds(remaining)
                };
                PersistRunningLocked();
                SyncTickTimerLocked();
            }

            return BuildSnapshotLocked(_clock.UtcNow);
        }
    }

    public TimerSnapshot Stop(Guid id)
    {
        lock (_gate)
        {
            RunningTimers.RemoveAll(timer => timer.Id == id);
            if (ActiveAlert?.Id == id)
            {
                StopAlertLocked();
            }

            PersistRunningLocked();
            SyncTickTimerLocked();
            return BuildSnapshotLocked(_clock.UtcNow);
        }
    }

    public TimerSnapshot StopAlert()
    {
        lock (_gate)
        {
            StopAlertLocked();
            return BuildSnapshotLocked(_clock.UtcNow);
        }
    }

    public TimerSnapshot PinPreset(TimerPreset preset)
    {
        lock (_gate)
        {
            if (PinnedPresets.Count < MaxPinnedPresets)
            {
                PinnedPresets.Add(preset with { Id = Guid.NewGuid() });
                PersistPinnedLocked();
            }

            return BuildSnapshotLocked(_clock.UtcNow);
        }
    }

    public TimerSnapshot RemovePinnedPreset(Guid id)
    {
        lock (_gate)
        {
            PinnedPresets.RemoveAll(preset => preset.Id == id);
            for (var index = 0; index < RunningTimers.Count; index++)
            {
                if (RunningTimers[index].PinnedPresetId == id)
                {
                    RunningTimers[index] = RunningTimers[index] with { PinnedPresetId = null };
                }
            }

            PersistPinnedLocked();
            PersistRunningLocked();
            return BuildSnapshotLocked(_clock.UtcNow);
        }
    }

    public TimerSnapshot TogglePin(Guid timerId)
    {
        lock (_gate)
        {
            var index = RunningTimers.FindIndex(timer => timer.Id == timerId);
            if (index < 0)
            {
                return BuildSnapshotLocked(_clock.UtcNow);
            }

            var timer = RunningTimers[index];
            if (timer.PinnedPresetId is { } pinnedPresetId)
            {
                return RemovePinnedPreset(pinnedPresetId);
            }

            if (PinnedPresets.Count >= MaxPinnedPresets)
            {
                return BuildSnapshotLocked(_clock.UtcNow);
            }

            var preset = new TimerPreset(
                Guid.NewGuid(),
                timer.Title,
                timer.IsPomodoro,
                timer.IsPomodoro ? timer.WorkDurationSeconds : timer.PhaseDurationSeconds,
                timer.WorkDurationSeconds,
                timer.RestDurationSeconds,
                timer.Color,
                timer.SoundEnabled);
            PinnedPresets.Add(preset);
            RunningTimers[index] = timer with { PinnedPresetId = preset.Id };
            PersistPinnedLocked();
            PersistRunningLocked();
            return BuildSnapshotLocked(_clock.UtcNow);
        }
    }

    public TimerSnapshot CheckExpired()
    {
        List<TimerAlert> firedAlerts = [];
        TimerSnapshot snapshot;
        lock (_gate)
        {
            var now = _clock.UtcNow;
            var expired = RunningTimers
                .Where(timer => !timer.IsPaused && timer.EndAtUtc <= now)
                .ToArray();

            foreach (var timer in expired)
            {
                var alert = FireLocked(timer, now);
                if (alert is not null)
                {
                    firedAlerts.Add(alert);
                }
            }

            if (expired.Length > 0)
            {
                PersistRunningLocked();
            }

            SyncTickTimerLocked();
            snapshot = BuildSnapshotLocked(now);
        }

        foreach (var alert in firedAlerts)
        {
            AlertFired?.Invoke(this, alert);
        }

        return snapshot;
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _tickTimer?.Dispose();
        _alertSound.Dispose();
    }

    private TimerAlert? FireLocked(RunningTimer timer, DateTimeOffset now)
    {
        var index = RunningTimers.FindIndex(candidate => candidate.Id == timer.Id);
        if (index < 0)
        {
            return null;
        }

        var alert = new TimerAlert(timer.Id, timer.Title, timer.Color, now, timer.SoundEnabled);
        ActiveAlert = alert;
        if (timer.SoundEnabled)
        {
            _alertSound.StartLoop();
        }

        if (timer.IsPomodoro)
        {
            var next = RunningTimers[index];
            next = next.Phase == PomodoroPhase.Work
                ? next with
                {
                    CompletedWorkCycles = next.CompletedWorkCycles + 1,
                    Phase = PomodoroPhase.Rest,
                    PhaseDurationSeconds = Math.Max(next.RestDurationSeconds, 1)
                }
                : next with
                {
                    Phase = PomodoroPhase.Work,
                    PhaseDurationSeconds = Math.Max(next.WorkDurationSeconds, 1)
                };
            RunningTimers[index] = next with { EndAtUtc = now.AddSeconds(next.PhaseDurationSeconds) };
        }
        else
        {
            RunningTimers.RemoveAt(index);
        }

        return alert;
    }

    private void StopAlertLocked()
    {
        _alertSound.Stop();
        ActiveAlert = null;
    }

    private List<RunningTimer> RestoreRunningTimers()
    {
        var decoded = LoadOrDefault(RunningPath, Array.Empty<RunningTimer>());
        var now = _clock.UtcNow;
        var restored = decoded
            .Where(timer => timer.IsPaused || timer.EndAtUtc > now)
            .Take(MaxConcurrentTimers)
            .ToList();
        if (restored.Count != decoded.Length)
        {
            RunningTimers = restored;
            PersistRunningLocked();
        }

        return restored;
    }

    private TimerSnapshot BuildSnapshotLocked(DateTimeOffset now)
    {
        return new TimerSnapshot(
            DraftTimer,
            DraftPomodoro,
            PinnedPresets.ToArray(),
            RunningTimers.Select(timer => new RunningTimerSnapshot(
                timer.Id,
                timer.Title,
                timer.Color,
                timer.SoundEnabled,
                timer.IsPomodoro,
                timer.Phase,
                timer.CompletedWorkCycles,
                timer.EndAtUtc,
                timer.PhaseDurationSeconds,
                timer.PausedRemainingSeconds,
                timer.WorkDurationSeconds,
                timer.RestDurationSeconds,
                timer.PinnedPresetId,
                timer.IsPaused,
                timer.RemainingSeconds(now),
                timer.Progress(now))).ToArray(),
            ActiveAlert,
            RunningTimers.Count < MaxConcurrentTimers,
            PinnedPresets.Count < MaxPinnedPresets,
            now);
    }

    private void PersistDraftsLocked()
    {
        Persist(DraftsPath, new DraftsSnapshot(DraftTimer, DraftPomodoro));
    }

    private void PersistPinnedLocked()
    {
        Persist(PinnedPath, PinnedPresets);
    }

    private void PersistRunningLocked()
    {
        Persist(RunningPath, RunningTimers);
    }

    private void Persist<T>(string path, T value)
    {
        Directory.CreateDirectory(StorageDirectory);
        var json = JsonSerializer.Serialize(value, JsonOptions);
        File.WriteAllText(path, json);
    }

    private T LoadOrDefault<T>(string path, T fallback)
    {
        try
        {
            if (!File.Exists(path))
            {
                return fallback;
            }

            return JsonSerializer.Deserialize<T>(File.ReadAllText(path), JsonOptions) ?? fallback;
        }
        catch (JsonException)
        {
            return fallback;
        }
        catch (IOException)
        {
            return fallback;
        }
        catch (UnauthorizedAccessException)
        {
            return fallback;
        }
    }

    private void SyncTickTimer()
    {
        lock (_gate)
        {
            SyncTickTimerLocked();
        }
    }

    private void SyncTickTimerLocked()
    {
        if (!_enableScheduler || _disposed)
        {
            return;
        }

        var needsTick = RunningTimers.Any(timer => !timer.IsPaused);
        if (needsTick && _tickTimer is null)
        {
            _tickTimer = new System.Threading.Timer(_ => CheckExpired(), null, TimeSpan.FromSeconds(1), TimeSpan.FromSeconds(1));
            return;
        }

        if (!needsTick && _tickTimer is not null)
        {
            _tickTimer.Dispose();
            _tickTimer = null;
        }
    }

    private static double ClampDuration(double seconds)
    {
        if (double.IsNaN(seconds) || double.IsInfinity(seconds))
        {
            return 0;
        }

        return Math.Clamp(seconds, 0, 24 * 60 * 60 - 1);
    }

    private static string DefaultStorageDirectory()
    {
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        return Path.Combine(appData, "HoverPocket", "timer");
    }

    private sealed record DraftsSnapshot(TimerPreset Timer, TimerPreset Pomodoro)
    {
        public static DraftsSnapshot Default()
        {
            return new DraftsSnapshot(TimerPreset.DefaultTimerDraft(), TimerPreset.DefaultPomodoroDraft());
        }
    }
}

internal interface ITimerClock
{
    DateTimeOffset UtcNow { get; }
}

internal sealed class SystemTimerClock : ITimerClock
{
    public static SystemTimerClock Instance { get; } = new();

    public DateTimeOffset UtcNow => DateTimeOffset.UtcNow;
}

internal sealed class ManualTimerClock(DateTimeOffset utcNow) : ITimerClock
{
    public DateTimeOffset UtcNow { get; private set; } = utcNow;

    public void Advance(TimeSpan duration)
    {
        UtcNow = UtcNow.Add(duration);
    }
}

internal interface ITimerAlertSound : IDisposable
{
    void StartLoop();

    void Stop();
}

internal sealed class SystemTimerAlertSound : ITimerAlertSound
{
    private System.Threading.Timer? _loopTimer;

    public void StartLoop()
    {
        Stop();
        Play(null);
        _loopTimer = new System.Threading.Timer(Play, null, TimeSpan.FromSeconds(1.2), TimeSpan.FromSeconds(1.2));
    }

    public void Stop()
    {
        _loopTimer?.Dispose();
        _loopTimer = null;
    }

    public void Dispose()
    {
        Stop();
    }

    private static void Play(object? state)
    {
        _ = state;
        SystemSounds.Exclamation.Play();
    }
}

internal sealed class NullTimerAlertSound : ITimerAlertSound
{
    public int StartCount { get; private set; }

    public void StartLoop()
    {
        StartCount++;
    }

    public void Stop()
    {
    }

    public void Dispose()
    {
    }
}
