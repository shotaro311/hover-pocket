namespace HoverPocket.Shell.Providers.Timer;

internal enum TimerColor
{
    Blue,
    Green,
    Orange,
    Pink
}

internal enum PomodoroPhase
{
    Work,
    Rest
}

internal sealed record TimerPreset(
    Guid Id,
    string Title,
    bool IsPomodoro,
    double DurationSeconds,
    double WorkDurationSeconds,
    double RestDurationSeconds,
    TimerColor Color,
    bool SoundEnabled)
{
    public static TimerPreset DefaultTimerDraft()
    {
        return new TimerPreset(
            Guid.NewGuid(),
            string.Empty,
            IsPomodoro: false,
            DurationSeconds: 10 * 60,
            WorkDurationSeconds: 25 * 60,
            RestDurationSeconds: 5 * 60,
            TimerColor.Blue,
            SoundEnabled: true);
    }

    public static TimerPreset DefaultPomodoroDraft()
    {
        return new TimerPreset(
            Guid.NewGuid(),
            string.Empty,
            IsPomodoro: true,
            DurationSeconds: 25 * 60,
            WorkDurationSeconds: 25 * 60,
            RestDurationSeconds: 5 * 60,
            TimerColor.Green,
            SoundEnabled: true);
    }
}

internal sealed record RunningTimer(
    Guid Id,
    string Title,
    TimerColor Color,
    bool SoundEnabled,
    bool IsPomodoro,
    PomodoroPhase Phase,
    int CompletedWorkCycles,
    DateTimeOffset EndAtUtc,
    double PhaseDurationSeconds,
    double? PausedRemainingSeconds,
    double WorkDurationSeconds,
    double RestDurationSeconds,
    Guid? PinnedPresetId)
{
    public bool IsPaused => PausedRemainingSeconds is not null;

    public double RemainingSeconds(DateTimeOffset nowUtc)
    {
        return Math.Max(0, PausedRemainingSeconds ?? EndAtUtc.Subtract(nowUtc).TotalSeconds);
    }

    public double Progress(DateTimeOffset nowUtc)
    {
        if (PhaseDurationSeconds <= 0)
        {
            return 0;
        }

        return Math.Clamp(1 - RemainingSeconds(nowUtc) / PhaseDurationSeconds, 0, 1);
    }
}

internal sealed record TimerAlert(
    Guid Id,
    string Title,
    TimerColor Color,
    DateTimeOffset StartedAtUtc,
    bool SoundEnabled);

internal sealed record RunningTimerSnapshot(
    Guid Id,
    string Title,
    TimerColor Color,
    bool SoundEnabled,
    bool IsPomodoro,
    PomodoroPhase Phase,
    int CompletedWorkCycles,
    DateTimeOffset EndAtUtc,
    double PhaseDurationSeconds,
    double? PausedRemainingSeconds,
    double WorkDurationSeconds,
    double RestDurationSeconds,
    Guid? PinnedPresetId,
    bool IsPaused,
    double RemainingSeconds,
    double Progress);

internal sealed record TimerSnapshot(
    TimerPreset DraftTimer,
    TimerPreset DraftPomodoro,
    IReadOnlyList<TimerPreset> PinnedPresets,
    IReadOnlyList<RunningTimerSnapshot> RunningTimers,
    TimerAlert? ActiveAlert,
    bool CanStartTimer,
    bool CanPin,
    DateTimeOffset NowUtc);
