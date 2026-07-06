using System.Text.Json;
using HoverPocket.Shell.Bridge;

namespace HoverPocket.Shell.Providers.Calendar;

internal sealed class CalendarBridgeController
{
    private readonly CalendarStore _store;

    public CalendarBridgeController(CalendarStore? store = null)
    {
        _store = store ?? new CalendarStore();
    }

    public CalendarStore Store => _store;

    public void Attach(BridgeDispatcher dispatcher)
    {
        dispatcher.Register("calendar.getState", (_, _) => Task.FromResult<object?>(_store.BuildState()));
        dispatcher.Register("calendar.signIn", SignInAsync);
        dispatcher.Register("calendar.signOut", (_, _) => Task.FromResult<object?>(_store.SignOut()));
        dispatcher.Register("calendar.loadMonth", LoadMonthAsync);
        dispatcher.Register("calendar.selectDate", SelectDateAsync);
        dispatcher.Register("calendar.hoverDate", HoverDateAsync);
        dispatcher.Register("calendar.createDefaultDraft", CreateDefaultDraftAsync);
        dispatcher.Register("calendar.createEvent", CreateEventAsync);
        dispatcher.Register("calendar.updateEvent", UpdateEventAsync);
        dispatcher.Register("calendar.deleteEvent", DeleteEventAsync);
    }

    private async Task<object?> SignInAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        _ = parameters;
        return await _store.SignInAsync(cancellationToken);
    }

    private async Task<object?> LoadMonthAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        var month = ReadOptionalDate(parameters, "month") ?? DateTimeOffset.Now;
        return await _store.LoadMonthAsync(month, cancellationToken);
    }

    private Task<object?> SelectDateAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return Task.FromResult<object?>(_store.SelectDate(ReadRequiredDate(parameters, "date")));
    }

    private Task<object?> HoverDateAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return Task.FromResult<object?>(_store.HoverDate(ReadOptionalDate(parameters, "date")));
    }

    private Task<object?> CreateDefaultDraftAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var date = ReadRequiredDate(parameters, "date");
        return Task.FromResult<object?>(new { draft = _store.CreateDefaultDraft(date) });
    }

    private async Task<object?> CreateEventAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        var draft = ReadRequiredObject<CalendarEventDraft>(parameters, "draft");
        return await _store.CreateEventAsync(draft, cancellationToken);
    }

    private async Task<object?> UpdateEventAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        var draft = ReadRequiredObject<CalendarEventDraft>(parameters, "draft");
        return await _store.UpdateEventAsync(draft, cancellationToken);
    }

    private async Task<object?> DeleteEventAsync(JsonElement? parameters, CancellationToken cancellationToken)
    {
        return await _store.DeleteEventAsync(
            ReadRequiredString(parameters, "calendarId"),
            ReadRequiredString(parameters, "eventId"),
            cancellationToken);
    }

    private static DateTimeOffset ReadRequiredDate(JsonElement? parameters, string propertyName)
    {
        return ReadOptionalDate(parameters, propertyName)
            ?? throw new InvalidOperationException($"Missing date parameter: {propertyName}");
    }

    private static DateTimeOffset? ReadOptionalDate(JsonElement? parameters, string propertyName)
    {
        if (parameters is null
            || !parameters.Value.TryGetProperty(propertyName, out var property)
            || property.ValueKind != JsonValueKind.String)
        {
            return null;
        }

        return DateTimeOffset.TryParse(property.GetString(), out var parsed)
            ? parsed
            : null;
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

    private static T ReadRequiredObject<T>(JsonElement? parameters, string propertyName)
    {
        if (parameters is null || !parameters.Value.TryGetProperty(propertyName, out var property))
        {
            throw new InvalidOperationException($"Missing object parameter: {propertyName}");
        }

        return JsonSerializer.Deserialize<T>(property.GetRawText(), BridgeJson.Options)
            ?? throw new InvalidOperationException($"Invalid object parameter: {propertyName}");
    }
}
