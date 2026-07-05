using System.Text.Json;
using HoverPocket.Shell.Bridge;

namespace HoverPocket.Shell.Providers.Timer;

internal sealed class TimerBridgeHandlers : IDisposable
{
    private readonly TimerStore _store;
    private BridgeDispatcher? _dispatcher;
    private Guid? _lastAlertId;

    public TimerBridgeHandlers(TimerStore? store = null)
    {
        _store = store ?? new TimerStore();
        _store.AlertFired += OnAlertFired;
    }

    public event EventHandler<TimerAlert>? AlertFired;

    public event EventHandler<TimerAlert?>? AlertChanged;

    public void Register(BridgeDispatcher dispatcher)
    {
        _dispatcher = dispatcher;
        dispatcher.Register("timer.getState", (_, _) => Task.FromResult<object?>(NotifyAlertState(_store.GetSnapshot())));
        dispatcher.Register("timer.updateDraft", UpdateDraftAsync);
        dispatcher.Register("timer.start", StartAsync);
        dispatcher.Register("timer.pause", (parameters, _) => Task.FromResult<object?>(NotifyAlertState(_store.Pause(ReadRequiredGuid(parameters, "id")))));
        dispatcher.Register("timer.resume", (parameters, _) => Task.FromResult<object?>(NotifyAlertState(_store.Resume(ReadRequiredGuid(parameters, "id")))));
        dispatcher.Register("timer.stop", (parameters, _) => Task.FromResult<object?>(NotifyAlertState(_store.Stop(ReadRequiredGuid(parameters, "id")))));
        dispatcher.Register("timer.stopAlert", (_, _) => Task.FromResult<object?>(NotifyAlertState(_store.StopAlert())));
        dispatcher.Register("timer.pinPreset", PinPresetAsync);
        dispatcher.Register("timer.removePinnedPreset", (parameters, _) => Task.FromResult<object?>(NotifyAlertState(_store.RemovePinnedPreset(ReadRequiredGuid(parameters, "id")))));
        dispatcher.Register("timer.togglePin", (parameters, _) => Task.FromResult<object?>(NotifyAlertState(_store.TogglePin(ReadRequiredGuid(parameters, "id")))));
    }

    public void Dispose()
    {
        _store.AlertFired -= OnAlertFired;
        _store.Dispose();
    }

    private Task<object?> UpdateDraftAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var kind = ReadRequiredString(parameters, "kind");
        var preset = ReadRequiredObject<TimerPreset>(parameters, "preset");
        var snapshot = kind.Equals("pomodoro", StringComparison.OrdinalIgnoreCase)
            ? _store.UpdateDraftPomodoro(preset)
            : _store.UpdateDraftTimer(preset);
        return Task.FromResult<object?>(NotifyAlertState(snapshot));
    }

    private Task<object?> StartAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var preset = ReadRequiredObject<TimerPreset>(parameters, "preset");
        var pinnedPresetId = ReadOptionalGuid(parameters, "pinnedPresetId");
        return Task.FromResult<object?>(NotifyAlertState(_store.Start(preset, pinnedPresetId)));
    }

    private Task<object?> PinPresetAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var preset = ReadRequiredObject<TimerPreset>(parameters, "preset");
        return Task.FromResult<object?>(NotifyAlertState(_store.PinPreset(preset)));
    }

    private void OnAlertFired(object? sender, TimerAlert alert)
    {
        _ = sender;
        _lastAlertId = alert.Id;
        AlertFired?.Invoke(this, alert);
        AlertChanged?.Invoke(this, alert);
        if (_dispatcher is not null)
        {
            _ = _dispatcher.PostEventAsync("timer.alert", new { alert, state = _store.GetSnapshot() });
        }
    }

    private TimerSnapshot NotifyAlertState(TimerSnapshot snapshot)
    {
        var activeAlertId = snapshot.ActiveAlert?.Id;
        if (activeAlertId != _lastAlertId)
        {
            _lastAlertId = activeAlertId;
            AlertChanged?.Invoke(this, snapshot.ActiveAlert);
        }

        return snapshot;
    }

    private static T ReadRequiredObject<T>(JsonElement? parameters, string propertyName)
    {
        if (parameters is null || !parameters.Value.TryGetProperty(propertyName, out var property))
        {
            throw new InvalidOperationException($"Missing object parameter: {propertyName}");
        }

        return JsonSerializer.Deserialize<T>(property.GetRawText(), BridgeJson.Options)
            ?? throw new InvalidOperationException($"Invalid object parameter: {propertyName}");
    }

    private static string ReadRequiredString(JsonElement? parameters, string propertyName)
    {
        if (parameters is null
            || !parameters.Value.TryGetProperty(propertyName, out var property)
            || property.ValueKind != JsonValueKind.String)
        {
            throw new InvalidOperationException($"Missing string parameter: {propertyName}");
        }

        return property.GetString() ?? string.Empty;
    }

    private static Guid ReadRequiredGuid(JsonElement? parameters, string propertyName)
    {
        return ReadOptionalGuid(parameters, propertyName)
            ?? throw new InvalidOperationException($"Missing guid parameter: {propertyName}");
    }

    private static Guid? ReadOptionalGuid(JsonElement? parameters, string propertyName)
    {
        if (parameters is null || !parameters.Value.TryGetProperty(propertyName, out var property))
        {
            return null;
        }

        return property.ValueKind == JsonValueKind.String
            && Guid.TryParse(property.GetString(), out var value)
            ? value
            : null;
    }
}
