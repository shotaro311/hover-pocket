using System.Net.Http;
using System.Text.Json;
using HoverPocket.Shell.Services;
using HoverPocket.Shell.Verification;

namespace HoverPocket.Shell.Providers.Calendar;

internal sealed class CalendarVerifier
{
    private readonly List<string> _failures = [];

    public int Run()
    {
        try
        {
            VerifyConsole.WriteLine("calendar verify: oauth-url/pkce");
            VerifyOAuthUrlAndPkce();
            VerifyConsole.WriteLine("calendar verify: loopback");
            VerifyLoopbackReceiver().GetAwaiter().GetResult();
            VerifyConsole.WriteLine("calendar verify: credential-manager");
            VerifyCredentialManagerRoundTrip();
            VerifyConsole.WriteLine("calendar verify: request-builders");
            VerifyRequestConstruction().GetAwaiter().GetResult();
            VerifyConsole.WriteLine("calendar verify: month-grid");
            VerifyMonthGridModel();
            VerifyConsole.WriteLine("calendar verify: read-only guards");
            VerifyReadOnlyGuards().GetAwaiter().GetResult();
        }
        catch (Exception ex)
        {
            _failures.Add($"unexpected: {ex.GetType().Name}: {ex.Message}");
        }

        if (_failures.Count == 0)
        {
            VerifyConsole.WriteLine("PASS calendar verify: oauth-url/pkce, loopback, credential-manager, request-builders, month-grid, read-only guards");
            return 0;
        }

        VerifyConsole.WriteLine("FAIL calendar verify:");
        foreach (var failure in _failures)
        {
            VerifyConsole.WriteLine($"- {failure}");
        }

        return 1;
    }

    private void VerifyOAuthUrlAndPkce()
    {
        var configuration = new GoogleOAuthConfiguration("verify-client-id.apps.googleusercontent.com", "verify-client-secret");
        var authorization = GoogleOAuthService.CreateAuthorizationRequest(configuration, "http://127.0.0.1:49152/");
        var query = ParseQuery(authorization.Url.Query);

        if (authorization.CodeVerifier.Length < 43 || authorization.CodeVerifier.Length > 128)
        {
            _failures.Add("oauth: PKCE verifier length is outside RFC range");
        }

        if (authorization.CodeChallenge != GoogleOAuthService.CodeChallenge(authorization.CodeVerifier))
        {
            _failures.Add("oauth: S256 code challenge did not match verifier");
        }

        if (!query.TryGetValue("code_challenge_method", out var method) || method != "S256")
        {
            _failures.Add("oauth: authorization URL did not require S256");
        }

        if (!query.TryGetValue("redirect_uri", out var redirectUri) || redirectUri != "http://127.0.0.1:49152/")
        {
            _failures.Add("oauth: redirect URI was not loopback");
        }

        if (!query.TryGetValue("scope", out var scope)
            || !scope.Contains(GoogleOAuthService.CalendarEventsScope, StringComparison.Ordinal)
            || !scope.Contains(GoogleOAuthService.CalendarReadonlyScope, StringComparison.Ordinal))
        {
            _failures.Add("oauth: required Calendar scopes were not present");
        }

        if (!query.TryGetValue("access_type", out var accessType) || accessType != "offline")
        {
            _failures.Add("oauth: refresh-token flow did not request offline access");
        }
    }

    private async Task VerifyLoopbackReceiver()
    {
        using var receiver = new LoopbackOAuthReceiver();
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        var wait = receiver.WaitForCallbackAsync(timeout.Token);
        using var client = new HttpClient();
        var response = await client
            .GetAsync($"{receiver.RedirectUri}?code=verify-code&state=verify-state", timeout.Token)
            .ConfigureAwait(false);
        var callback = await wait.ConfigureAwait(false);

        if (!response.IsSuccessStatusCode)
        {
            _failures.Add("loopback: receiver did not return success page");
        }

        if (callback.Code != "verify-code" || callback.State != "verify-state" || callback.Error is not null)
        {
            _failures.Add("loopback: callback query did not round-trip");
        }
    }

    private void VerifyCredentialManagerRoundTrip()
    {
        var target = $"HoverPocket.GoogleOAuth.Verify.{Guid.NewGuid():N}";
        var store = new GoogleOAuthCredentialStore(target);
        try
        {
            var credential = new GoogleOAuthStoredCredential(
                "verify-refresh-token",
                [GoogleOAuthService.CalendarEventsScope, GoogleOAuthService.CalendarReadonlyScope]);
            store.Save(credential);
            var loaded = store.Load();
            if (loaded is null
                || loaded.RefreshToken != credential.RefreshToken
                || !loaded.GrantedScopes.SequenceEqual(credential.GrantedScopes))
            {
                _failures.Add("credential-manager: saved credential did not load");
            }

            store.Delete();
            if (store.Load() is not null)
            {
                _failures.Add("credential-manager: verification credential was not deleted");
            }
        }
        catch (InvalidOperationException ex)
        {
            _failures.Add($"credential-manager: {ex.Message}");
            try
            {
                store.Delete();
            }
            catch (InvalidOperationException)
            {
            }
        }
    }

    private async Task VerifyRequestConstruction()
    {
        var accessToken = "verify-access-token";
        var rangeStart = new DateTimeOffset(2026, 6, 28, 0, 0, 0, TimeSpan.Zero);
        var rangeEnd = rangeStart.AddDays(42);
        using var calendarList = GoogleCalendarApiClient.BuildCalendarListRequest(accessToken);
        using var eventsList = GoogleCalendarApiClient.BuildEventsListRequest(accessToken, "primary", rangeStart, rangeEnd, "Asia/Tokyo");
        var draft = new CalendarEventDraft(
            "primary",
            null,
            "Verify event",
            "Room",
            "Notes",
            new DateTimeOffset(2026, 7, 6, 9, 0, 0, TimeSpan.Zero),
            new DateTimeOffset(2026, 7, 6, 10, 0, 0, TimeSpan.Zero),
            IsAllDay: false).Normalized();
        using var create = GoogleCalendarApiClient.BuildCreateEventRequest(accessToken, draft);
        using var update = GoogleCalendarApiClient.BuildUpdateEventRequest(accessToken, draft with { EventId = "event-1" });
        using var delete = GoogleCalendarApiClient.BuildDeleteEventRequest(accessToken, "primary", "event-1");

        if (calendarList.Method != HttpMethod.Get
            || calendarList.RequestUri?.AbsoluteUri != "https://www.googleapis.com/calendar/v3/users/me/calendarList?showHidden=false&maxResults=250")
        {
            _failures.Add("request: calendarList.list request was not correct");
        }

        if (eventsList.Method != HttpMethod.Get
            || eventsList.RequestUri?.AbsoluteUri.Contains("/calendars/primary/events", StringComparison.Ordinal) != true
            || eventsList.RequestUri.AbsoluteUri.Contains("singleEvents=true", StringComparison.Ordinal) != true)
        {
            _failures.Add("request: events.list request was not correct");
        }

        if (create.Method != HttpMethod.Post || update.Method.Method != "PATCH" || delete.Method != HttpMethod.Delete)
        {
            _failures.Add("request: CRUD HTTP methods were not correct");
        }

        var createBody = create.Content is null
            ? string.Empty
            : await create.Content.ReadAsStringAsync().ConfigureAwait(false);
        using var document = JsonDocument.Parse(createBody);
        if (!document.RootElement.TryGetProperty("summary", out var summary)
            || summary.GetString() != "Verify event"
            || !document.RootElement.TryGetProperty("start", out var start)
            || !start.TryGetProperty("dateTime", out _))
        {
            _failures.Add("request: event write body omitted expected fields");
        }
    }

    private void VerifyMonthGridModel()
    {
        var month = new DateTimeOffset(2026, 7, 1, 0, 0, 0, TimeSpan.Zero);
        var range = CalendarDateMath.VisibleGridRange(month.LocalDateTime, DayOfWeek.Sunday);
        var allDay = new CalendarEventOccurrence(
            "primary:all-day",
            "all-day",
            "primary",
            "Primary",
            null,
            CalendarCanWrite: true,
            "All-day",
            null,
            null,
            new DateTimeOffset(2026, 7, 1, 0, 0, 0, TimeSpan.Zero),
            new DateTimeOffset(2026, 7, 2, 0, 0, 0, TimeSpan.Zero),
            IsAllDay: true,
            null);
        var snapshot = new CalendarSnapshot(
            [new CalendarSource("primary", "Primary", null, "Asia/Tokyo", IsPrimary: true, "owner")],
            [allDay],
            range.Start,
            range.End,
            month,
            DateTimeOffset.UtcNow);

        var cells = snapshot.DayCells(
            month,
            month,
            null,
            new DateTimeOffset(2026, 7, 6, 0, 0, 0, TimeSpan.Zero));
        if (cells.Count != 42)
        {
            _failures.Add("grid: month grid did not contain 42 cells");
        }

        if (cells.First().Id != "2026-06-28" || cells.Last().Id != "2026-08-08")
        {
            _failures.Add("grid: visible month boundary was not correct");
        }

        var julyFirst = cells.FirstOrDefault(cell => cell.Id == "2026-07-01");
        if (julyFirst is null || julyFirst.Events.Count != 1 || !julyFirst.Events[0].IsAllDay)
        {
            _failures.Add("grid: all-day event was not assigned to its day cell");
        }

        if (!cells.Any(cell => cell.Id == "2026-07-06" && cell.IsToday))
        {
            _failures.Add("grid: today flag was not applied");
        }
    }

    private async Task VerifyReadOnlyGuards()
    {
        var month = new DateTimeOffset(2026, 7, 1, 0, 0, 0, TimeSpan.Zero);
        var range = CalendarDateMath.VisibleGridRange(month.LocalDateTime, DayOfWeek.Sunday);
        var snapshot = new CalendarSnapshot(
            [new CalendarSource("readonly", "Read only", null, "Asia/Tokyo", IsPrimary: false, "reader")],
            [],
            range.Start,
            range.End,
            month,
            DateTimeOffset.UtcNow);
        var store = new CalendarStore();
        var snapshotField = typeof(CalendarStore).GetField("_snapshot", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic);
        snapshotField?.SetValue(store, snapshot);

        var state = await store.CreateEventAsync(new CalendarEventDraft(
            "readonly",
            null,
            "Should not send",
            null,
            null,
            new DateTimeOffset(2026, 7, 6, 9, 0, 0, TimeSpan.Zero),
            new DateTimeOffset(2026, 7, 6, 10, 0, 0, TimeSpan.Zero),
            IsAllDay: false)).ConfigureAwait(false);

        if (state.LoadStatus != "failed" || !state.Message.Contains("read-only", StringComparison.OrdinalIgnoreCase))
        {
            _failures.Add("read-only: create did not return a non-throwing read-only failure state");
        }
    }

    private static Dictionary<string, string> ParseQuery(string query)
    {
        var trimmed = query.TrimStart('?');
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var part in trimmed.Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var separator = part.IndexOf('=', StringComparison.Ordinal);
            var key = separator < 0 ? part : part[..separator];
            var value = separator < 0 ? string.Empty : part[(separator + 1)..];
            values[Decode(key)] = Decode(value);
        }

        return values;
    }

    private static string Decode(string value)
    {
        return Uri.UnescapeDataString(value.Replace("+", " ", StringComparison.Ordinal));
    }
}
