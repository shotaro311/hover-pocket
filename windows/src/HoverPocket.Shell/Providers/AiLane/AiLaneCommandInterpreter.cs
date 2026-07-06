using System.Globalization;
using System.Text.RegularExpressions;

namespace HoverPocket.Shell.Providers.AiLane;

internal sealed class AiLaneCommandInterpreter
{
    private readonly Func<DateTime> _todayProvider;

    public AiLaneCommandInterpreter()
        : this(() => DateTime.Today)
    {
    }

    internal AiLaneCommandInterpreter(Func<DateTime> todayProvider)
    {
        _todayProvider = todayProvider;
    }

    public AiLaneInterpretation Interpret(string input)
    {
        var normalized = (input ?? string.Empty).Trim();
        if (string.IsNullOrWhiteSpace(normalized))
        {
            return Unknown("empty_command");
        }

        if (LooksLikeCreate(normalized))
        {
            return CreateCalendarApproval(normalized);
        }

        if (LooksLikeRead(normalized))
        {
            return new AiLaneInterpretation(
                AiLaneCommandKind.ReadCalendar,
                "Calendar を確認します。",
                null,
                ResolveDate(normalized));
        }

        return Unknown("unknown_command");
    }

    private AiLaneInterpretation CreateCalendarApproval(string input)
    {
        var start = ResolveStart(input);
        var title = ResolveTitle(input);
        var card = new AiLaneApprovalCard(
            Guid.NewGuid().ToString("N"),
            "calendar.create",
            title,
            FormatLocalDateTime(start),
            FormatLocalDateTime(start.AddHours(1)),
            AllDay: false,
            Location: string.Empty,
            Notes: string.Empty,
            Calendar: "default");

        return new AiLaneInterpretation(
            AiLaneCommandKind.CreateCalendarEvent,
            "承認待ちの予定案を作成しました。",
            card);
    }

    private DateTime ResolveStart(string input)
    {
        var date = ResolveDate(input).Date;

        var match = Regex.Match(input, @"(?<!\d)([01]?\d|2[0-3])時", RegexOptions.CultureInvariant);
        if (match.Success && int.TryParse(match.Groups[1].Value, CultureInfo.InvariantCulture, out var hour))
        {
            return date.AddHours(hour);
        }

        return date.AddHours(9);
    }

    private DateTimeOffset ResolveDate(string input)
    {
        var date = input.Contains("明日", StringComparison.OrdinalIgnoreCase)
            ? _todayProvider().Date.AddDays(1)
            : _todayProvider().Date;
        return new DateTimeOffset(date);
    }

    private static string ResolveTitle(string input)
    {
        if (input.Contains("打ち合わせ", StringComparison.OrdinalIgnoreCase))
        {
            return "打ち合わせ";
        }

        if (input.Contains("会議", StringComparison.OrdinalIgnoreCase))
        {
            return "会議";
        }

        if (input.Contains("meeting", StringComparison.OrdinalIgnoreCase))
        {
            return "Meeting";
        }

        return "予定";
    }

    private static bool LooksLikeRead(string input)
    {
        return input.Contains("予定", StringComparison.OrdinalIgnoreCase)
            || input.Contains("calendar", StringComparison.OrdinalIgnoreCase)
            || input.Contains("schedule", StringComparison.OrdinalIgnoreCase);
    }

    private static bool LooksLikeCreate(string input)
    {
        var hasCreateWord = input.Contains("打ち合わせ", StringComparison.OrdinalIgnoreCase)
            || input.Contains("会議", StringComparison.OrdinalIgnoreCase)
            || input.Contains("meeting", StringComparison.OrdinalIgnoreCase);
        var hasTime = input.Contains('時') || input.Contains(':');
        return hasCreateWord && hasTime;
    }

    private static string FormatLocalDateTime(DateTime value)
    {
        return value.ToString("yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture);
    }

    private static AiLaneInterpretation Unknown(string reason)
    {
        return new AiLaneInterpretation(
            AiLaneCommandKind.Unknown,
            $"解釈できませんでした: {reason}",
            null);
    }
}
