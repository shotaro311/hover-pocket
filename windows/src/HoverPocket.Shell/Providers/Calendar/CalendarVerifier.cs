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
            VerifyConsole.WriteLine("calendar verify: oauth-configuration");
            VerifyOAuthConfigurationResolution();
            VerifyConsole.WriteLine("calendar verify: setup-instructions");
            VerifySetupInstructions();
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
            VerifyConsole.WriteLine("PASS calendar verify: oauth-configuration, setup-instructions, oauth-url/pkce, loopback, credential-manager, request-builders, month-grid, read-only guards");
            return 0;
        }

        VerifyConsole.WriteLine("FAIL calendar verify:");
        foreach (var failure in _failures)
        {
            VerifyConsole.WriteLine($"- {failure}");
        }

        return 1;
    }

    private void VerifyOAuthConfigurationResolution()
    {
        var root = Path.Combine(Path.GetTempPath(), "HoverPocket", "OAuthVerify", Guid.NewGuid().ToString("N"));
        var fallbackPath = Path.Combine(root, "oauth.json");
        var missingPath = Path.Combine(root, "missing-oauth.json");
        var embedded = new GoogleOAuthConfiguration(
            "verify-embedded-client.apps.googleusercontent.com",
            "verify-embedded-secret");

        try
        {
            Directory.CreateDirectory(root);
            var embeddedOnly = GoogleOAuthConfiguration.LoadFromSources(embedded, missingPath);
            if (embeddedOnly?.ClientId != embedded.ClientId || embeddedOnly.ClientSecret != embedded.ClientSecret)
            {
                _failures.Add("oauth-config: embedded configuration did not load without oauth.json");
            }

            File.WriteAllText(
                fallbackPath,
                """
                {
                  "installed": {
                    "client_id": "verify-file-client.apps.googleusercontent.com",
                    "client_secret": "verify-file-secret"
                  }
                }
                """);
            var fallback = GoogleOAuthConfiguration.LoadFromSources(null, fallbackPath);
            if (fallback?.ClientId != "verify-file-client.apps.googleusercontent.com"
                || fallback.ClientSecret != "verify-file-secret")
            {
                _failures.Add("oauth-config: oauth.json fallback did not load");
            }

            var precedence = GoogleOAuthConfiguration.LoadFromSources(embedded, fallbackPath);
            if (precedence?.ClientId != embedded.ClientId || precedence.ClientSecret != embedded.ClientSecret)
            {
                _failures.Add("oauth-config: embedded configuration did not take precedence over oauth.json");
            }

            if (GoogleOAuthConfiguration.LoadFromSources(null, missingPath) is not null)
            {
                _failures.Add("oauth-config: missing embedded and oauth.json configuration did not return null");
            }

            var assemblyEmbedded = GoogleOAuthConfiguration.LoadEmbedded();
            VerifyConsole.WriteLine($"oauth_embedded_metadata={(assemblyEmbedded is null ? "absent" : "present")}");
            if (assemblyEmbedded is not null)
            {
                var resolved = GoogleOAuthConfiguration.LoadFromSources(assemblyEmbedded, missingPath);
                if (resolved is null)
                {
                    _failures.Add("oauth-config: assembly metadata was present but did not resolve without oauth.json");
                }
            }
        }
        finally
        {
            try
            {
                if (Directory.Exists(root))
                {
                    Directory.Delete(root, recursive: true);
                }
            }
            catch (IOException)
            {
            }
            catch (UnauthorizedAccessException)
            {
            }
        }
    }

    private void VerifySetupInstructions()
    {
        var setup = CalendarStore.SetupInstructions();
        if (!string.Equals(setup.Path, GoogleOAuthConfiguration.ConfigurationPath, StringComparison.Ordinal)
            || !setup.Ja.Any(step => step.Contains("%APPDATA%\\HoverPocket\\oauth.json", StringComparison.Ordinal))
            || !setup.En.Any(step => step.Contains("%APPDATA%\\HoverPocket\\oauth.json", StringComparison.Ordinal)))
        {
            _failures.Add("setup: oauth.json placement path was not included");
        }

        if (!setup.Ja.Any(step => step.Contains("再起動", StringComparison.Ordinal))
            || !setup.En.Any(step => step.Contains("restart", StringComparison.OrdinalIgnoreCase)))
        {
            _failures.Add("setup: restart guidance was not included");
        }
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
            || !scope.Contains(GoogleOAuthService.CalendarListReadonlyScope, StringComparison.Ordinal)
            || scope.Contains(GoogleOAuthService.CalendarReadonlyScope, StringComparison.Ordinal))
        {
            _failures.Add("oauth: minimized Calendar scopes were not correct");
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
                [GoogleOAuthService.CalendarEventsScope, GoogleOAuthService.CalendarListReadonlyScope]);
            store.Save(credential);
            var loaded = store.Load();
            if (loaded is null
                || loaded.RefreshToken != credential.RefreshToken
                || !loaded.GrantedScopes.SequenceEqual(credential.GrantedScopes))
            {
                _failures.Add("credential-manager: saved credential did not load");
            }

            if (!GoogleOAuthService.HasRequiredCalendarScopes(
                    [GoogleOAuthService.CalendarEventsScope, GoogleOAuthService.CalendarReadonlyScope]))
            {
                _failures.Add("credential-manager: legacy calendar.readonly scope was not accepted as calendar-list access");
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
        var localTimeZone = GoogleCalendarApiClient.IanaTimeZoneId(TimeZoneInfo.Local);
        using var eventsListForLocalTimeZone = GoogleCalendarApiClient.BuildEventsListRequest(
            accessToken,
            "primary",
            rangeStart,
            rangeEnd,
            localTimeZone);
        var customTimeZone = TimeZoneInfo.CreateCustomTimeZone(
            "HoverPocket Unknown",
            TimeSpan.Zero,
            "HoverPocket Unknown",
            "HoverPocket Unknown");
        var unknownTimeZone = GoogleCalendarApiClient.IanaTimeZoneId(customTimeZone);
        using var eventsListWithoutTimeZone = GoogleCalendarApiClient.BuildEventsListRequest(
            accessToken,
            "primary",
            rangeStart,
            rangeEnd,
            unknownTimeZone);
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
        const string deterministicEventId = "hp0123456789abcdef";
        using var idempotentCreate = GoogleCalendarApiClient.BuildCreateEventRequest(
            accessToken,
            draft,
            deterministicEventId);
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

        var localEventsQuery = ParseQuery(eventsListForLocalTimeZone.RequestUri?.Query ?? string.Empty);
        if (localTimeZone is null)
        {
            if (localEventsQuery.ContainsKey("timeZone"))
            {
                _failures.Add("request: unresolved local time zone should be omitted from events.list");
            }
        }
        else if (!localEventsQuery.TryGetValue("timeZone", out var localQueryTimeZone)
            || localQueryTimeZone != localTimeZone)
        {
            _failures.Add($"request: events.list did not use IANA time zone {localTimeZone}");
        }

        if (unknownTimeZone is not null
            || ParseQuery(eventsListWithoutTimeZone.RequestUri?.Query ?? string.Empty).ContainsKey("timeZone"))
        {
            _failures.Add("request: unknown local time zone was not omitted from events.list");
        }

        if (OperatingSystem.IsWindows())
        {
            var tokyoTimeZone = TimeZoneInfo.FindSystemTimeZoneById("Tokyo Standard Time");
            if (GoogleCalendarApiClient.IanaTimeZoneId(tokyoTimeZone) != "Asia/Tokyo")
            {
                _failures.Add("request: Windows Tokyo time zone did not convert to Asia/Tokyo");
            }
        }

        if (create.Method != HttpMethod.Post || update.Method.Method != "PATCH" || delete.Method != HttpMethod.Delete)
        {
            _failures.Add("request: CRUD HTTP methods were not correct");
        }

        var createBody = create.Content is null
            ? string.Empty
            : await create.Content.ReadAsStringAsync().ConfigureAwait(false);
        using var document = JsonDocument.Parse(createBody);
        var start = default(JsonElement);
        if (!document.RootElement.TryGetProperty("summary", out var summary)
            || summary.GetString() != "Verify event"
            || !document.RootElement.TryGetProperty("start", out start)
            || !start.TryGetProperty("dateTime", out _))
        {
            _failures.Add("request: event write body omitted expected fields");
        }

        if (document.RootElement.TryGetProperty("id", out _))
        {
            _failures.Add("request: ordinary event create unexpectedly included a custom id");
        }

        var idempotentCreateBody = idempotentCreate.Content is null
            ? string.Empty
            : await idempotentCreate.Content.ReadAsStringAsync().ConfigureAwait(false);
        using var idempotentDocument = JsonDocument.Parse(idempotentCreateBody);
        if (!idempotentDocument.RootElement.TryGetProperty("id", out var eventId)
            || eventId.GetString() != deterministicEventId)
        {
            _failures.Add("request: idempotent event create omitted the deterministic id");
        }

        if (start.ValueKind == JsonValueKind.Object)
        {
            var hasStartTimeZone = start.TryGetProperty("timeZone", out var startTimeZone);
            if (localTimeZone is null)
            {
                if (hasStartTimeZone)
                {
                    _failures.Add("request: unresolved local time zone should be omitted from event write body");
                }
            }
            else if (!hasStartTimeZone || startTimeZone.GetString() != localTimeZone)
            {
                _failures.Add($"request: event write body did not use IANA time zone {localTimeZone}");
            }

            var end = default(JsonElement);
            var endTimeZone = default(JsonElement);
            var hasEnd = document.RootElement.TryGetProperty("end", out end);
            var hasEndTimeZone = hasEnd
                && end.ValueKind == JsonValueKind.Object
                && end.TryGetProperty("timeZone", out endTimeZone);
            if (!hasEnd || end.ValueKind != JsonValueKind.Object)
            {
                _failures.Add("request: event write body omitted the expected end object");
            }
            else if (localTimeZone is null)
            {
                if (hasEndTimeZone)
                {
                    _failures.Add("request: unresolved local time zone should be omitted from event end");
                }
            }
            else if (!hasEndTimeZone || endTimeZone.GetString() != localTimeZone)
            {
                _failures.Add($"request: event end did not use IANA time zone {localTimeZone}");
            }
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
