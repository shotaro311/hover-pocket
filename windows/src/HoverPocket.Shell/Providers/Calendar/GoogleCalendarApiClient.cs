using System.Globalization;
using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using HoverPocket.Shell.Services;

namespace HoverPocket.Shell.Providers.Calendar;

internal sealed class GoogleCalendarApiException : Exception
{
    public GoogleCalendarApiException(string code, string message, bool requiresReconnect = false)
        : base(message)
    {
        Code = code;
        RequiresReconnect = requiresReconnect;
    }

    public string Code { get; }

    public bool RequiresReconnect { get; }
}

internal sealed class GoogleCalendarApiClient
{
    private static readonly HttpClient HttpClient = new();
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };

    private readonly GoogleOAuthService _oauth;

    public GoogleCalendarApiClient(GoogleOAuthService oauth)
    {
        _oauth = oauth;
    }

    public async Task<CalendarSnapshot> FetchMonthAsync(
        DateTimeOffset monthAnchor,
        CancellationToken cancellationToken = default)
    {
        var firstDay = CultureInfo.CurrentCulture.DateTimeFormat.FirstDayOfWeek;
        var range = CalendarDateMath.VisibleGridRange(monthAnchor.LocalDateTime, firstDay);
        return await WithAuthorizedRetryAsync(async accessToken =>
        {
            var sources = await FetchCalendarSourcesAsync(accessToken, cancellationToken);
            var selectedSources = sources.Where(source => !string.IsNullOrWhiteSpace(source.Id)).ToArray();
            var events = new List<CalendarEventOccurrence>();
            foreach (var source in selectedSources)
            {
                events.AddRange(await FetchEventsAsync(source, accessToken, range.Start, range.End, cancellationToken));
            }

            return new CalendarSnapshot(
                selectedSources,
                events.OrderBy(item => item.Start).ToArray(),
                range.Start,
                range.End,
                new DateTimeOffset(CalendarDateMath.StartOfMonth(monthAnchor.LocalDateTime)),
                DateTimeOffset.UtcNow);
        }, cancellationToken);
    }

    public async Task CreateEventAsync(CalendarEventDraft draft, CancellationToken cancellationToken = default)
    {
        var normalized = draft.Normalized();
        await WithAuthorizedRetryAsync(async accessToken =>
        {
            using var request = BuildCreateEventRequest(accessToken, normalized);
            await SendAsync(request, cancellationToken);
            return true;
        }, cancellationToken);
    }

    public async Task UpdateEventAsync(CalendarEventDraft draft, CancellationToken cancellationToken = default)
    {
        var normalized = draft.Normalized();
        if (string.IsNullOrWhiteSpace(normalized.EventId))
        {
            throw new GoogleCalendarApiException("missing_event_id", "Google Calendar event ID is missing.");
        }

        await WithAuthorizedRetryAsync(async accessToken =>
        {
            using var request = BuildUpdateEventRequest(accessToken, normalized);
            await SendAsync(request, cancellationToken);
            return true;
        }, cancellationToken);
    }

    public async Task DeleteEventAsync(
        string calendarId,
        string eventId,
        CancellationToken cancellationToken = default)
    {
        await WithAuthorizedRetryAsync(async accessToken =>
        {
            using var request = BuildDeleteEventRequest(accessToken, calendarId, eventId);
            await SendAsync(request, cancellationToken);
            return true;
        }, cancellationToken);
    }

    internal static HttpRequestMessage BuildCalendarListRequest(string accessToken)
    {
        var url = "https://www.googleapis.com/calendar/v3/users/me/calendarList?showHidden=false&maxResults=250";
        return AuthorizedRequest(HttpMethod.Get, url, accessToken);
    }

    internal static HttpRequestMessage BuildEventsListRequest(
        string accessToken,
        string calendarId,
        DateTimeOffset rangeStart,
        DateTimeOffset rangeEnd,
        string timeZone)
    {
        var query = new Dictionary<string, string>
        {
            ["timeMin"] = Rfc3339(rangeStart),
            ["timeMax"] = Rfc3339(rangeEnd),
            ["singleEvents"] = "true",
            ["orderBy"] = "startTime",
            ["timeZone"] = timeZone,
            ["maxResults"] = "2500"
        };
        var url = $"{EventsUrl(calendarId)}?{PercentEncodedForm(query)}";
        return AuthorizedRequest(HttpMethod.Get, url, accessToken);
    }

    internal static HttpRequestMessage BuildCreateEventRequest(string accessToken, CalendarEventDraft draft)
    {
        var request = AuthorizedRequest(HttpMethod.Post, EventsUrl(draft.CalendarId), accessToken);
        request.Content = JsonContent(WriteResource(draft));
        return request;
    }

    internal static HttpRequestMessage BuildUpdateEventRequest(string accessToken, CalendarEventDraft draft)
    {
        var request = AuthorizedRequest(HttpMethod.Patch, EventUrl(draft.CalendarId, draft.EventId ?? string.Empty), accessToken);
        request.Content = JsonContent(WriteResource(draft));
        return request;
    }

    internal static HttpRequestMessage BuildDeleteEventRequest(string accessToken, string calendarId, string eventId)
    {
        return AuthorizedRequest(HttpMethod.Delete, EventUrl(calendarId, eventId), accessToken);
    }

    private async Task<IReadOnlyList<CalendarSource>> FetchCalendarSourcesAsync(
        string accessToken,
        CancellationToken cancellationToken)
    {
        using var request = BuildCalendarListRequest(accessToken);
        var response = await SendJsonAsync<CalendarListResponse>(request, cancellationToken);
        var sources = response.Items
            .Where(item => item.Selected != false && item.Deleted != true)
            .Select(ToSource)
            .ToArray();

        return sources.Length > 0
            ? sources
            : response.Items.Take(1).Select(ToSource).ToArray();
    }

    private async Task<IReadOnlyList<CalendarEventOccurrence>> FetchEventsAsync(
        CalendarSource source,
        string accessToken,
        DateTimeOffset rangeStart,
        DateTimeOffset rangeEnd,
        CancellationToken cancellationToken)
    {
        var events = new List<CalendarEventOccurrence>();
        string? pageToken = null;
        do
        {
            using var request = BuildEventsListRequest(accessToken, source.Id, rangeStart, rangeEnd, TimeZoneInfo.Local.Id);
            if (!string.IsNullOrWhiteSpace(pageToken))
            {
                var separator = request.RequestUri?.Query.Length > 0 ? "&" : "?";
                request.RequestUri = new Uri($"{request.RequestUri}{separator}pageToken={Uri.EscapeDataString(pageToken)}");
            }

            var response = await SendJsonAsync<EventsListResponse>(request, cancellationToken);
            events.AddRange(response.Items.Select(item => Normalize(item, source)).Where(item => item is not null)!);
            pageToken = response.NextPageToken;
        } while (!string.IsNullOrWhiteSpace(pageToken));

        return events;
    }

    private async Task<T> WithAuthorizedRetryAsync<T>(
        Func<string, Task<T>> operation,
        CancellationToken cancellationToken)
    {
        var accessToken = await _oauth.AccessTokenAsync(cancellationToken: cancellationToken);
        try
        {
            return await operation(accessToken);
        }
        catch (GoogleCalendarApiException ex) when (ex.Code == "authorization_expired")
        {
            var refreshed = await _oauth.AccessTokenAsync(forceRefresh: true, cancellationToken);
            try
            {
                return await operation(refreshed);
            }
            catch (GoogleCalendarApiException retryEx) when (retryEx.Code == "authorization_expired")
            {
                throw new GoogleCalendarApiException("authorization_needs_reconnect", "Reconnect Google Calendar to continue.", requiresReconnect: true);
            }
        }
    }

    private static async Task<T> SendJsonAsync<T>(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        var data = await SendAsync(request, cancellationToken);
        try
        {
            return JsonSerializer.Deserialize<T>(data, JsonOptions)
                ?? throw new GoogleCalendarApiException("invalid_response", "Google Calendar response could not be read.");
        }
        catch (JsonException)
        {
            throw new GoogleCalendarApiException("invalid_response", "Google Calendar response could not be read.");
        }
    }

    private static async Task<string> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        using var response = await HttpClient.SendAsync(request, cancellationToken);
        var body = await response.Content.ReadAsStringAsync(cancellationToken);
        if (response.IsSuccessStatusCode)
        {
            return body;
        }

        var error = TryDeserialize<GoogleApiErrorResponse>(body);
        if (response.StatusCode == HttpStatusCode.Unauthorized || error?.IsAuthorizationExpired == true)
        {
            throw new GoogleCalendarApiException("authorization_expired", "Google Calendar authorization expired.", requiresReconnect: true);
        }

        if (response.StatusCode == HttpStatusCode.Forbidden && error?.IsInsufficientPermissions == true)
        {
            throw new GoogleCalendarApiException("authorization_needs_reconnect", "Reconnect Google Calendar to allow event editing.", requiresReconnect: true);
        }

        throw new GoogleCalendarApiException("request_failed", error?.SafeDescription ?? "Google Calendar request failed.");
    }

    private static T? TryDeserialize<T>(string json)
    {
        try
        {
            return JsonSerializer.Deserialize<T>(json, JsonOptions);
        }
        catch (JsonException)
        {
            return default;
        }
    }

    private static CalendarSource ToSource(CalendarListEntry item)
    {
        return new CalendarSource(
            item.Id,
            item.SummaryOverride ?? item.Summary,
            item.BackgroundColor,
            item.TimeZone,
            item.Primary == true,
            item.AccessRole);
    }

    private static CalendarEventOccurrence? Normalize(CalendarEventResource item, CalendarSource source)
    {
        if (item.Status == "cancelled")
        {
            return null;
        }

        var start = ParseDateTime(item.Start);
        var end = ParseDateTime(item.End);
        if (start is null || end is null)
        {
            return null;
        }

        var title = string.IsNullOrWhiteSpace(item.Summary) ? "Busy" : item.Summary.Trim();
        return new CalendarEventOccurrence(
            $"{source.Id}:{item.Id}",
            item.Id,
            source.Id,
            source.Title,
            source.ColorHex,
            source.CanWrite,
            title,
            item.Location,
            item.Description,
            start.Value.Date,
            end.Value.Date,
            start.Value.IsAllDay,
            item.HtmlLink);
    }

    private static (DateTimeOffset Date, bool IsAllDay)? ParseDateTime(CalendarEventDateTime? value)
    {
        if (value is null)
        {
            return null;
        }

        if (!string.IsNullOrWhiteSpace(value.DateTime)
            && DateTimeOffset.TryParse(value.DateTime, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var dateTime))
        {
            return (dateTime, false);
        }

        if (!string.IsNullOrWhiteSpace(value.Date)
            && DateTime.TryParseExact(value.Date, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var allDay))
        {
            return (new DateTimeOffset(DateTime.SpecifyKind(allDay, DateTimeKind.Local)), true);
        }

        return null;
    }

    private static GoogleCalendarEventWriteResource WriteResource(CalendarEventDraft draft)
    {
        if (draft.IsAllDay)
        {
            return new GoogleCalendarEventWriteResource(
                draft.Title,
                draft.Location,
                draft.Notes,
                new GoogleCalendarEventDateTimeWrite(AllDayString(draft.Start), null, null),
                new GoogleCalendarEventDateTimeWrite(AllDayString(draft.End), null, null));
        }

        return new GoogleCalendarEventWriteResource(
            draft.Title,
            draft.Location,
            draft.Notes,
            new GoogleCalendarEventDateTimeWrite(null, Rfc3339(draft.Start), TimeZoneInfo.Local.Id),
            new GoogleCalendarEventDateTimeWrite(null, Rfc3339(draft.End), TimeZoneInfo.Local.Id));
    }

    private static HttpRequestMessage AuthorizedRequest(HttpMethod method, string url, string accessToken)
    {
        var request = new HttpRequestMessage(method, url);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", accessToken);
        return request;
    }

    private static StringContent JsonContent<T>(T value)
    {
        return new StringContent(JsonSerializer.Serialize(value, JsonOptions), Encoding.UTF8, "application/json");
    }

    private static string EventsUrl(string calendarId)
    {
        return $"https://www.googleapis.com/calendar/v3/calendars/{PathComponent(calendarId)}/events";
    }

    private static string EventUrl(string calendarId, string eventId)
    {
        return $"{EventsUrl(calendarId)}/{PathComponent(eventId)}";
    }

    private static string PathComponent(string value)
    {
        return Uri.EscapeDataString(value);
    }

    private static string Rfc3339(DateTimeOffset value)
    {
        return value.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture);
    }

    private static string AllDayString(DateTimeOffset value)
    {
        return value.LocalDateTime.Date.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
    }

    private static string PercentEncodedForm(Dictionary<string, string> values)
    {
        return string.Join('&', values
            .OrderBy(pair => pair.Key, StringComparer.Ordinal)
            .Select(pair => $"{Uri.EscapeDataString(pair.Key)}={Uri.EscapeDataString(pair.Value)}"));
    }

    private sealed record CalendarListResponse(
        [property: JsonPropertyName("items")] IReadOnlyList<CalendarListEntry> Items);

    private sealed record CalendarListEntry(
        [property: JsonPropertyName("id")] string Id,
        [property: JsonPropertyName("summary")] string Summary,
        [property: JsonPropertyName("summaryOverride")] string? SummaryOverride,
        [property: JsonPropertyName("backgroundColor")] string? BackgroundColor,
        [property: JsonPropertyName("timeZone")] string? TimeZone,
        [property: JsonPropertyName("primary")] bool? Primary,
        [property: JsonPropertyName("selected")] bool? Selected,
        [property: JsonPropertyName("deleted")] bool? Deleted,
        [property: JsonPropertyName("accessRole")] string? AccessRole);

    private sealed record EventsListResponse(
        [property: JsonPropertyName("items")] IReadOnlyList<CalendarEventResource> Items,
        [property: JsonPropertyName("nextPageToken")] string? NextPageToken);

    private sealed record CalendarEventResource(
        [property: JsonPropertyName("id")] string Id,
        [property: JsonPropertyName("status")] string? Status,
        [property: JsonPropertyName("summary")] string? Summary,
        [property: JsonPropertyName("location")] string? Location,
        [property: JsonPropertyName("description")] string? Description,
        [property: JsonPropertyName("start")] CalendarEventDateTime? Start,
        [property: JsonPropertyName("end")] CalendarEventDateTime? End,
        [property: JsonPropertyName("htmlLink")] string? HtmlLink);

    private sealed record CalendarEventDateTime(
        [property: JsonPropertyName("date")] string? Date,
        [property: JsonPropertyName("dateTime")] string? DateTime);

    private sealed record GoogleCalendarEventWriteResource(
        [property: JsonPropertyName("summary")] string Summary,
        [property: JsonPropertyName("location")] string? Location,
        [property: JsonPropertyName("description")] string? Description,
        [property: JsonPropertyName("start")] GoogleCalendarEventDateTimeWrite Start,
        [property: JsonPropertyName("end")] GoogleCalendarEventDateTimeWrite End);

    private sealed record GoogleCalendarEventDateTimeWrite(
        [property: JsonPropertyName("date")] string? Date,
        [property: JsonPropertyName("dateTime")] string? DateTime,
        [property: JsonPropertyName("timeZone")] string? TimeZone);

    private sealed record GoogleApiErrorResponse(
        [property: JsonPropertyName("error")] GoogleApiErrorBody? Error)
    {
        public bool IsAuthorizationExpired => Error?.Code == 401 || Error?.Reasons.Contains("authError") == true;

        public bool IsInsufficientPermissions =>
            Error?.Reasons.Contains("insufficientPermissions") == true
            || (Error?.Code == 403 && (Error.Message ?? string.Empty).Contains("insufficient", StringComparison.OrdinalIgnoreCase));

        public string SafeDescription => Error?.Message ?? "Google Calendar request failed.";
    }

    private sealed record GoogleApiErrorBody(
        [property: JsonPropertyName("code")] int? Code,
        [property: JsonPropertyName("message")] string? Message,
        [property: JsonPropertyName("errors")] IReadOnlyList<GoogleApiErrorDetail>? Errors)
    {
        public ISet<string> Reasons => Errors?.Select(item => item.Reason).Where(reason => reason is not null).Cast<string>().ToHashSet(StringComparer.Ordinal)
            ?? new HashSet<string>(StringComparer.Ordinal);
    }

    private sealed record GoogleApiErrorDetail(
        [property: JsonPropertyName("reason")] string? Reason);
}
