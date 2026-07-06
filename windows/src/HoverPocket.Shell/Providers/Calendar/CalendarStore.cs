using System.Globalization;
using HoverPocket.Shell.Services;

namespace HoverPocket.Shell.Providers.Calendar;

internal sealed class CalendarStore
{
    private readonly GoogleOAuthService _oauth;
    private readonly GoogleCalendarApiClient _apiClient;
    private readonly object _lock = new();
    private CalendarSnapshot? _snapshot;
    private DateTimeOffset _monthAnchor = new(DateTime.Today);
    private DateTimeOffset _selectedDate = new(DateTime.Today);
    private DateTimeOffset? _hoveredDate;
    private string _connectionStatus = "signed_out";
    private string _loadStatus = "idle";
    private string _message = string.Empty;

    public CalendarStore(GoogleOAuthService? oauth = null)
    {
        _oauth = oauth ?? new GoogleOAuthService();
        _apiClient = new GoogleCalendarApiClient(_oauth);
    }

    public CalendarProviderState BuildState()
    {
        lock (_lock)
        {
            RefreshConnectionStatus();
            var snapshot = _snapshot ?? EmptySnapshot(_monthAnchor);
            var selectedEvents = snapshot.EventsForDay(_selectedDate);
            return new CalendarProviderState(
                _connectionStatus,
                _loadStatus,
                ResolveMessage(),
                _monthAnchor,
                _selectedDate,
                _hoveredDate,
                snapshot.Sources,
                snapshot.DayCells(_monthAnchor, _selectedDate, _hoveredDate),
                selectedEvents,
                SetupInstructions());
        }
    }

    public async Task<CalendarProviderState> SignInAsync(CancellationToken cancellationToken = default)
    {
        lock (_lock)
        {
            _connectionStatus = "signing_in";
            _message = "Google Calendar 認証を開始しています。";
        }

        try
        {
            await _oauth.SignInAsync(cancellationToken);
            lock (_lock)
            {
                _connectionStatus = "signed_in";
                _message = "Google Calendar に接続しました。";
            }

            return await LoadMonthAsync(_monthAnchor, cancellationToken);
        }
        catch (Exception ex) when (ex is GoogleOAuthException or InvalidOperationException or IOException)
        {
            lock (_lock)
            {
                _connectionStatus = ex is GoogleOAuthException { RequiresReconnect: true } ? "needs_reconnect" : "signed_out";
                _loadStatus = "failed";
                _message = SafeMessage(ex);
            }

            return BuildState();
        }
    }

    public CalendarProviderState SignOut()
    {
        try
        {
            _oauth.SignOut();
        }
        catch (InvalidOperationException ex)
        {
            lock (_lock)
            {
                _message = SafeMessage(ex);
            }
        }

        lock (_lock)
        {
            _snapshot = null;
            _connectionStatus = "signed_out";
            _loadStatus = "idle";
            _message = "Google Calendar から切断しました。";
        }

        return BuildState();
    }

    public async Task<CalendarProviderState> LoadMonthAsync(
        DateTimeOffset monthAnchor,
        CancellationToken cancellationToken = default)
    {
        lock (_lock)
        {
            _monthAnchor = new DateTimeOffset(CalendarDateMath.StartOfMonth(monthAnchor.LocalDateTime));
            _loadStatus = "loading";
            _message = "予定を取得しています。";
        }

        try
        {
            if (!_oauth.IsConfigured)
            {
                throw new GoogleOAuthException("missing_configuration", "Google OAuth client is not configured.");
            }

            if (!_oauth.HasRequiredCalendarCredential())
            {
                var status = _oauth.StoredCredentialStatus();
                throw status == GoogleOAuthStoredCredentialStatus.NeedsReconnect
                    ? new GoogleOAuthException("needs_reconnect", "Reconnect Google Calendar to continue.", requiresReconnect: true)
                    : new GoogleOAuthException("signed_out", "Google Calendar is not connected.", requiresReconnect: true);
            }

            var snapshot = await _apiClient.FetchMonthAsync(monthAnchor, cancellationToken);
            lock (_lock)
            {
                _snapshot = snapshot;
                _monthAnchor = snapshot.MonthAnchor;
                _connectionStatus = "signed_in";
                _loadStatus = "loaded";
                _message = "予定を取得しました。";
            }
        }
        catch (Exception ex) when (ex is GoogleOAuthException or GoogleCalendarApiException or HttpRequestException or TaskCanceledException or InvalidOperationException)
        {
            lock (_lock)
            {
                _connectionStatus = ex is GoogleOAuthException { RequiresReconnect: true }
                    or GoogleCalendarApiException { RequiresReconnect: true }
                    ? "needs_reconnect"
                    : _connectionStatus;
                _loadStatus = "failed";
                _message = SafeMessage(ex);
            }
        }

        return BuildState();
    }

    public CalendarProviderState SelectDate(DateTimeOffset date)
    {
        lock (_lock)
        {
            _selectedDate = new DateTimeOffset(date.LocalDateTime.Date);
            if (_selectedDate.Month != _monthAnchor.Month || _selectedDate.Year != _monthAnchor.Year)
            {
                _monthAnchor = new DateTimeOffset(CalendarDateMath.StartOfMonth(_selectedDate.LocalDateTime));
            }
        }

        return BuildState();
    }

    public CalendarProviderState HoverDate(DateTimeOffset? date)
    {
        lock (_lock)
        {
            _hoveredDate = date is null ? null : new DateTimeOffset(date.Value.LocalDateTime.Date);
        }

        return BuildState();
    }

    public CalendarEventDraft? CreateDefaultDraft(DateTimeOffset day)
    {
        lock (_lock)
        {
            var source = WritableSources().FirstOrDefault(item => item.IsPrimary)
                ?? WritableSources().FirstOrDefault();
            if (source is null)
            {
                return null;
            }

            var localDay = day.LocalDateTime.Date;
            var start = new DateTimeOffset(localDay.AddHours(9));
            return new CalendarEventDraft(
                source.Id,
                null,
                string.Empty,
                null,
                null,
                start,
                start.AddHours(1),
                IsAllDay: false);
        }
    }

    public async Task<CalendarProviderState> CreateEventAsync(
        CalendarEventDraft draft,
        CancellationToken cancellationToken = default)
    {
        var normalized = draft.Normalized();
        try
        {
            EnsureWritableCalendar(normalized.CalendarId);
            await _apiClient.CreateEventAsync(normalized, cancellationToken);
            _message = "予定を追加しました。";
            return await LoadMonthAsync(_monthAnchor, cancellationToken);
        }
        catch (Exception ex) when (ex is GoogleOAuthException or GoogleCalendarApiException or HttpRequestException or TaskCanceledException or InvalidOperationException)
        {
            SetFailure(ex);
            return BuildState();
        }
    }

    public async Task<CalendarProviderState> UpdateEventAsync(
        CalendarEventDraft draft,
        CancellationToken cancellationToken = default)
    {
        var normalized = draft.Normalized();
        try
        {
            EnsureWritableEvent(normalized.CalendarId, normalized.EventId);
            await _apiClient.UpdateEventAsync(normalized, cancellationToken);
            _message = "予定を更新しました。";
            return await LoadMonthAsync(_monthAnchor, cancellationToken);
        }
        catch (Exception ex) when (ex is GoogleOAuthException or GoogleCalendarApiException or HttpRequestException or TaskCanceledException or InvalidOperationException)
        {
            SetFailure(ex);
            return BuildState();
        }
    }

    public async Task<CalendarProviderState> DeleteEventAsync(
        string calendarId,
        string eventId,
        CancellationToken cancellationToken = default)
    {
        try
        {
            EnsureWritableEvent(calendarId, eventId);
            await _apiClient.DeleteEventAsync(calendarId, eventId, cancellationToken);
            _message = "予定を削除しました。";
            return await LoadMonthAsync(_monthAnchor, cancellationToken);
        }
        catch (Exception ex) when (ex is GoogleOAuthException or GoogleCalendarApiException or HttpRequestException or TaskCanceledException or InvalidOperationException)
        {
            SetFailure(ex);
            return BuildState();
        }
    }

    public async Task<string> ReadDaySummaryAsync(DateTimeOffset day, CancellationToken cancellationToken = default)
    {
        if (!_oauth.HasRequiredCalendarCredential())
        {
            throw new GoogleOAuthException("signed_out", "Google Calendar is not connected.", requiresReconnect: true);
        }

        CalendarSnapshot? snapshot;
        lock (_lock)
        {
            snapshot = _snapshot;
        }

        if (snapshot is null || day < snapshot.RangeStart || day >= snapshot.RangeEnd)
        {
            await LoadMonthAsync(day, cancellationToken);
        }

        lock (_lock)
        {
            snapshot = _snapshot;
        }

        var events = snapshot?.EventsForDay(day) ?? [];
        var dayLabel = day.LocalDateTime.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
        if (events.Count == 0)
        {
            return $"{dayLabel} の予定はありません。";
        }

        var titles = string.Join(" / ", events.Take(3).Select(item => item.Title));
        return $"{dayLabel} の予定は {events.Count} 件です: {titles}";
    }

    public async Task<string> CreateFromAiLaneAsync(
        string title,
        DateTimeOffset start,
        DateTimeOffset end,
        CancellationToken cancellationToken = default)
    {
        if (!_oauth.HasRequiredCalendarCredential())
        {
            throw new GoogleOAuthException("signed_out", "Google Calendar is not connected.", requiresReconnect: true);
        }

        var draft = CreateDefaultDraft(start);
        if (draft is null)
        {
            await LoadMonthAsync(start, cancellationToken);
            draft = CreateDefaultDraft(start);
        }

        if (draft is null)
        {
            throw new GoogleCalendarApiException("no_writable_calendar", "No writable Google Calendar is available.");
        }

        draft = draft with
        {
            Title = title,
            Start = start,
            End = end
        };
        await CreateEventAsync(draft, cancellationToken);
        return "承認済みの予定を Google Calendar に追加しました。";
    }

    private IEnumerable<CalendarSource> WritableSources()
    {
        return (_snapshot?.Sources ?? []).Where(source => source.CanWrite);
    }

    private void EnsureWritableCalendar(string calendarId)
    {
        lock (_lock)
        {
            var source = _snapshot?.Sources.FirstOrDefault(item => string.Equals(item.Id, calendarId, StringComparison.Ordinal));
            if (source is not null && !source.CanWrite)
            {
                throw new InvalidOperationException("This calendar is read-only.");
            }
        }
    }

    private void EnsureWritableEvent(string calendarId, string? eventId)
    {
        if (string.IsNullOrWhiteSpace(eventId))
        {
            throw new InvalidOperationException("Missing Google Calendar event ID.");
        }

        lock (_lock)
        {
            var existing = _snapshot?.Events.FirstOrDefault(item =>
                string.Equals(item.CalendarId, calendarId, StringComparison.Ordinal)
                && string.Equals(item.GoogleEventId, eventId, StringComparison.Ordinal));
            if (existing is not null && !existing.CalendarCanWrite)
            {
                throw new InvalidOperationException("This calendar is read-only.");
            }
        }
    }

    private void SetFailure(Exception ex)
    {
        lock (_lock)
        {
            _connectionStatus = ex is GoogleOAuthException { RequiresReconnect: true }
                or GoogleCalendarApiException { RequiresReconnect: true }
                ? "needs_reconnect"
                : _connectionStatus;
            _loadStatus = "failed";
            _message = SafeMessage(ex);
        }
    }

    private void RefreshConnectionStatus()
    {
        if (_connectionStatus == "signing_in")
        {
            return;
        }

        if (!_oauth.IsConfigured)
        {
            _connectionStatus = "missing_configuration";
            return;
        }

        _connectionStatus = _oauth.StoredCredentialStatus() switch
        {
            GoogleOAuthStoredCredentialStatus.Ready => "signed_in",
            GoogleOAuthStoredCredentialStatus.NeedsReconnect => "needs_reconnect",
            _ => "signed_out"
        };
    }

    private string ResolveMessage()
    {
        if (!string.IsNullOrWhiteSpace(_message))
        {
            return _message;
        }

        return _connectionStatus switch
        {
            "missing_configuration" => "Google OAuth の設定が必要です。",
            "needs_reconnect" => "Google Calendar に再接続してください。",
            "signed_in" => "Google Calendar に接続済みです。",
            _ => "Google Calendar に接続してください。"
        };
    }

    private static CalendarSnapshot EmptySnapshot(DateTimeOffset monthAnchor)
    {
        var firstDay = CultureInfo.CurrentCulture.DateTimeFormat.FirstDayOfWeek;
        var range = CalendarDateMath.VisibleGridRange(monthAnchor.LocalDateTime, firstDay);
        return new CalendarSnapshot(
            [],
            [],
            range.Start,
            range.End,
            new DateTimeOffset(CalendarDateMath.StartOfMonth(monthAnchor.LocalDateTime)),
            DateTimeOffset.UtcNow);
    }

    private static CalendarSetupInstructions SetupInstructions()
    {
        return new CalendarSetupInstructions(
            GoogleOAuthConfiguration.ConfigurationPath,
            [
                "Google Cloud Console で Google Calendar API を有効化します。",
                "Google Auth Platform の Clients で Desktop app の OAuth クライアントを作成します。",
                "%APPDATA%\\HoverPocket\\oauth.json にダウンロードした JSON を配置します。",
                "必要な scope は calendar.events と calendar.readonly です。予定の作成/編集とカレンダー一覧取得に限定します。"
            ],
            [
                "Enable the Google Calendar API in Google Cloud Console.",
                "Create a Desktop app OAuth client in Google Auth Platform > Clients.",
                "Place the downloaded JSON at %APPDATA%\\HoverPocket\\oauth.json.",
                "HoverPocket requests calendar.events and calendar.readonly only, for event writes and calendar-list reads."
            ]);
    }

    private static string SafeMessage(Exception ex)
    {
        return ex switch
        {
            GoogleOAuthException oauth => oauth.Message,
            GoogleCalendarApiException api => api.Message,
            TaskCanceledException => "Google Calendar request timed out.",
            HttpRequestException => "Google Calendar network request failed.",
            _ => ex.Message
        };
    }
}
