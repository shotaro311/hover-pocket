import Foundation

#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26.0, *)
@Generable
private enum GeneratedCalendarIntentAction {
    case calendarReadDay
    case calendarCreateEvent
    case unclear
}

@available(macOS 26.0, *)
@Generable
private struct GeneratedCalendarIntentPlan {
    @Guide(description: "Choose calendarReadDay for reading events, calendarCreateEvent for creating one event, or unclear when the request is ambiguous.")
    var action: GeneratedCalendarIntentAction

    @Guide(description: "Target day for reading or all-day event creation. Format yyyy-MM-dd. Leave empty if unknown.")
    var date: String?

    @Guide(description: "Calendar event title. Required only for calendarCreateEvent.")
    var title: String?

    @Guide(description: "Event start time. Format yyyy-MM-dd'T'HH:mm:ss. Required only for timed calendarCreateEvent.")
    var start: String?

    @Guide(description: "Event end time. Format yyyy-MM-dd'T'HH:mm:ss. Required only for timed calendarCreateEvent.")
    var end: String?

    @Guide(description: "True only when the user explicitly asks for an all-day event.")
    var allDay: Bool
}
#endif

private struct ParsedCalendarEventDetails {
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let location: String?
    let notes: String?
}

struct AppleFoundationModelProvider: AIModelProvider {
    let descriptor = AIModelDescriptor(
        id: "apple.foundation-models.local",
        displayName: "Apple Intelligence",
        providerName: "Apple Foundation Models",
        capabilities: AIModelCapabilities(
            supportsToolCalling: true,
            supportsStructuredOutput: true,
            maxContextTokens: 4_096,
            roles: [.singleToolSelection, .structuredPlanner]
        )
    )

    func availability() async -> AIModelAvailability {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(let reason):
                return .unavailable(String(describing: reason))
            @unknown default:
                return .unavailable("Apple Foundation Models is unavailable.")
            }
        }
        #endif
        return .unavailable("Apple Foundation Models requires macOS 26 and Apple Intelligence.")
    }

    func makeIntentPlan(for input: String, context: AICommandContext) async throws -> IntentPlan {
        let normalized = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.shouldUseDeterministicShortcut(for: normalized) {
            return Self.makeDeterministicPlan(
                for: normalized,
                context: context,
                modelIdentifier: descriptor.id
            )
        }

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *),
           case .available = await availability(),
           let modelPlan = try await makeFoundationModelPlan(for: input, context: context) {
            return modelPlan
        }
        #endif

        return Self.makeDeterministicPlan(
            for: normalized,
            context: context,
            modelIdentifier: descriptor.id
        )
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private func makeFoundationModelPlan(for input: String, context: AICommandContext) async throws -> IntentPlan? {
        let session = LanguageModelSession(instructions: """
        You are a strict planner for a macOS menu-bar app.
        Choose exactly one of: calendar_read_day, calendar_create_event, unclear.
        Return only the requested structured value.
        For calendarReadDay include date=yyyy-MM-dd.
        For calendarCreateEvent include title, start=yyyy-MM-dd'T'HH:mm:ss, end=yyyy-MM-dd'T'HH:mm:ss, and allDay.
        Do not invent unavailable tools. Do not plan multiple steps.
        Current time zone: \(context.timeZoneIdentifier).
        """)
        let response = try await session.respond(
            to: input,
            generating: GeneratedCalendarIntentPlan.self
        )
        if let plan = Self.makePlan(
            from: response.content,
            sourceText: input,
            context: context,
            modelIdentifier: descriptor.id
        ) {
            return plan
        }

        let textResponse = try await session.respond(to: input)
        return Self.parseModelResponse(
            textResponse.content,
            sourceText: input,
            context: context,
            modelIdentifier: descriptor.id
        )
    }

    @available(macOS 26.0, *)
    private static func makePlan(
        from generated: GeneratedCalendarIntentPlan,
        sourceText: String,
        context: AICommandContext,
        modelIdentifier: String
    ) -> IntentPlan? {
        switch generated.action {
        case .calendarReadDay:
            guard let date = parseDay(generated.date, now: context.now) else { return nil }
            let action = PocketAction(
                kind: .calendarReadDay,
                sourceText: sourceText,
                readParameters: CalendarReadParameters(date: date)
            )
            return IntentPlan(
                sourceText: sourceText,
                primaryAction: action,
                candidates: [],
                confidence: 0.9,
                modelIdentifier: modelIdentifier
            )
        case .calendarCreateEvent:
            guard let title = generated.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else {
                return nil
            }
            let start = parseDateTime(generated.start)
                ?? parseDay(generated.date, now: context.now)
                ?? defaultEventStart(now: context.now)
            let end = parseDateTime(generated.end) ?? defaultEventEnd(start: start)
            let calendar = context.writableCalendars.first
            let action = PocketAction(
                kind: .calendarCreateEvent,
                sourceText: sourceText,
                createEventParameters: CalendarCreateEventParameters(
                    calendarID: calendar?.id,
                    calendarTitle: calendar?.title,
                    title: title,
                    start: start,
                    end: end,
                    isAllDay: generated.allDay,
                    location: nil,
                    notes: nil
                )
            )
            return IntentPlan(
                sourceText: sourceText,
                primaryAction: action,
                candidates: [],
                confidence: 0.88,
                modelIdentifier: modelIdentifier
            )
        case .unclear:
            return nil
        }
    }
    #endif

    private static func shouldUseDeterministicShortcut(for input: String) -> Bool {
        guard !input.isEmpty else { return false }
        if containsAny(input, keywords: ["今日の予定", "明日の予定", "予定教えて", "予定を見る"]) {
            return true
        }
        return containsAny(input, keywords: [
            "打ち合わせ", "会議", "meeting", "mtg", "納期", "締切", "締め切り",
            "deadline", "撮影", "収録"
        ])
    }

    private static func parseModelResponse(
        _ response: String,
        sourceText: String,
        context: AICommandContext,
        modelIdentifier: String
    ) -> IntentPlan? {
        let values = response
            .split(whereSeparator: \.isNewline)
            .reduce(into: [String: String]()) { partialResult, line in
                let pieces = line.split(separator: "=", maxSplits: 1).map(String.init)
                guard pieces.count == 2 else { return }
                partialResult[pieces[0].trimmingCharacters(in: .whitespacesAndNewlines)] =
                    pieces[1].trimmingCharacters(in: .whitespacesAndNewlines)
            }

        switch values["action"] {
        case "calendar_read_day":
            guard let date = parseDay(values["date"], now: context.now) else { return nil }
            let action = PocketAction(
                kind: .calendarReadDay,
                sourceText: sourceText,
                readParameters: CalendarReadParameters(date: date)
            )
            return IntentPlan(
                sourceText: sourceText,
                primaryAction: action,
                candidates: [],
                confidence: 0.86,
                modelIdentifier: modelIdentifier
            )
        case "calendar_create_event":
            guard let title = values["title"], !title.isEmpty else { return nil }
            let start = parseDateTime(values["start"]) ?? defaultEventStart(now: context.now)
            let end = parseDateTime(values["end"]) ?? defaultEventEnd(start: start)
            let allDay = values["allDay"] == "true"
            let calendar = context.writableCalendars.first
            let action = PocketAction(
                kind: .calendarCreateEvent,
                sourceText: sourceText,
                createEventParameters: CalendarCreateEventParameters(
                    calendarID: calendar?.id,
                    calendarTitle: calendar?.title,
                    title: title,
                    start: start,
                    end: end,
                    isAllDay: allDay,
                    location: nil,
                    notes: nil
                )
            )
            return IntentPlan(
                sourceText: sourceText,
                primaryAction: action,
                candidates: [],
                confidence: 0.82,
                modelIdentifier: modelIdentifier
            )
        default:
            return nil
        }
    }

    private static func makeDeterministicPlan(
        for input: String,
        context: AICommandContext,
        modelIdentifier: String
    ) -> IntentPlan {
        let normalized = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetDay = inferTargetDay(from: normalized, now: context.now)
        let canRead = containsAny(normalized, keywords: [
            "calendar", "予定", "カレンダー", "schedule", "today", "tomorrow", "明日", "今日"
        ])
        let canWrite = containsAny(normalized, keywords: [
            "add", "create", "schedule", "追加", "作成", "入れて", "登録", "予約",
            "会議", "打ち合わせ", "meeting", "mtg", "納期", "締切", "締め切り",
            "deadline", "撮影", "収録", "appointment"
        ])

        let readAction = PocketAction(
            kind: .calendarReadDay,
            sourceText: normalized,
            readParameters: CalendarReadParameters(date: targetDay)
        )
        let createAction = makeCreateEventAction(from: normalized, targetDay: targetDay, context: context)

        if canWrite, let createAction {
            return IntentPlan(
                sourceText: normalized,
                primaryAction: createAction,
                candidates: [readAction],
                confidence: 0.66,
                modelIdentifier: modelIdentifier
            )
        }

        if canRead {
            var candidates: [PocketAction] = []
            if let createAction {
                candidates.append(createAction)
            }
            return IntentPlan(
                sourceText: normalized,
                primaryAction: readAction,
                candidates: candidates,
                confidence: 0.72,
                modelIdentifier: modelIdentifier
            )
        }

        return IntentPlan(
            sourceText: normalized,
            primaryAction: nil,
            candidates: [readAction] + [createAction].compactMap { $0 },
            confidence: 0.2,
            modelIdentifier: modelIdentifier
        )
    }

    private static func makeCreateEventAction(
        from input: String,
        targetDay: Date,
        context: AICommandContext
    ) -> PocketAction? {
        guard let calendar = context.writableCalendars.first else { return nil }
        let details = parseEventDetails(from: input, targetDay: targetDay, context: context)
        return PocketAction(
            kind: .calendarCreateEvent,
            sourceText: input,
            createEventParameters: CalendarCreateEventParameters(
                calendarID: calendar.id,
                calendarTitle: calendar.title,
                title: details.title.isEmpty ? "New event" : details.title,
                start: details.start,
                end: details.end,
                isAllDay: details.isAllDay,
                location: details.location,
                notes: details.notes
            )
        )
    }

    private static func parseEventDetails(
        from input: String,
        targetDay: Date,
        context: AICommandContext
    ) -> ParsedCalendarEventDetails {
        let calendar = Calendar.current
        let startOfTargetDay = calendar.startOfDay(for: targetDay)
        let explicitStart = parseTime(from: input, on: startOfTargetDay)
        let isDeadlineLike = containsAny(input, keywords: ["納期", "締切", "締め切り", "deadline"])
        let isAllDay = explicitStart == nil && isDeadlineLike
        let start = isAllDay
            ? startOfTargetDay
            : (explicitStart ?? defaultEventStart(on: targetDay, now: context.now))
        let end = isAllDay
            ? (calendar.date(byAdding: .day, value: 1, to: startOfTargetDay) ?? startOfTargetDay.addingTimeInterval(86_400))
            : defaultEventEnd(start: start)

        return ParsedCalendarEventDetails(
            title: cleanedEventTitle(from: input),
            start: start,
            end: end,
            isAllDay: isAllDay,
            location: taggedValue(in: input, labels: ["場所", "location"]),
            notes: taggedValue(in: input, labels: ["メモ", "note", "notes"])
        )
    }

    private static func inferTargetDay(from input: String, now: Date) -> Date {
        let calendar = Calendar.current
        if containsAny(input, keywords: ["明日", "tomorrow"]) {
            return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        }
        if containsAny(input, keywords: ["昨日", "yesterday"]) {
            return calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)) ?? now
        }
        return parseDayFromFreeText(input, now: now) ?? calendar.startOfDay(for: now)
    }

    private static func cleanedEventTitle(from input: String) -> String {
        var title = removingTaggedSegments(from: input)
        [
            #"(?i)\b(calendar|add|create|schedule|appointment)\b"#,
            #"\b\d{4}-\d{2}-\d{2}\b"#,
            #"\b\d{1,2}/\d{1,2}\b"#,
            #"(午前|午後)?\s*\d{1,2}\s*[:：]\s*\d{2}"#,
            #"(午前|午後)?\s*\d{1,2}\s*時\s*(半|\d{1,2}\s*分?)?"#
        ].forEach { pattern in
            title = replacingRegex(in: title, pattern: pattern, with: " ")
        }
        [
            "予定", "カレンダー", "追加", "作成", "入れて", "登録", "予約",
            "今日", "明日", "昨日", "来週", "今週",
            "月曜日", "月曜", "火曜日", "火曜", "水曜日", "水曜", "木曜日", "木曜",
            "金曜日", "金曜", "土曜日", "土曜", "日曜日", "日曜",
            "next week", "this week", "today", "tomorrow", "yesterday"
        ].forEach {
            title = title.replacingOccurrences(of: $0, with: "", options: [.caseInsensitive, .diacriticInsensitive])
        }
        title = title
            .replacingOccurrences(of: "　", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "、。,:：")))

        if title.isEmpty {
            if containsAny(input, keywords: ["打ち合わせ", "会議", "meeting", "mtg"]) {
                return "打ち合わせ"
            }
            if containsAny(input, keywords: ["撮影", "収録"]) {
                return "撮影"
            }
            if containsAny(input, keywords: ["納期", "締切", "締め切り", "deadline"]) {
                return "納期"
            }
        }
        return title
    }

    private static func containsAny(_ input: String, keywords: [String]) -> Bool {
        keywords.contains { input.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    private static func parseDayFromFreeText(_ input: String, now: Date) -> Date? {
        if let explicitDate = parseExplicitDate(from: input, now: now) {
            return explicitDate
        }
        return parseWeekdayDate(from: input, now: now)
    }

    private static func parseExplicitDate(from input: String, now: Date) -> Date? {
        if let groups = matchGroups(pattern: #"\b(\d{4})-(\d{2})-(\d{2})\b"#, in: input),
           let yearText = group(groups, at: 0),
           let monthText = group(groups, at: 1),
           let dayText = group(groups, at: 2),
           let year = Int(yearText),
           let month = Int(monthText),
           let day = Int(dayText) {
            return date(year: year, month: month, day: day)
        }

        if let groups = matchGroups(pattern: #"\b(\d{1,2})/(\d{1,2})\b"#, in: input),
           let monthText = group(groups, at: 0),
           let dayText = group(groups, at: 1),
           let month = Int(monthText),
           let day = Int(dayText) {
            let calendar = Calendar.current
            let currentYear = calendar.component(.year, from: now)
            guard let candidate = date(year: currentYear, month: month, day: day) else { return nil }
            if candidate < calendar.startOfDay(for: now) {
                return date(year: currentYear + 1, month: month, day: day)
            }
            return candidate
        }

        return nil
    }

    private static func parseWeekdayDate(from input: String, now: Date) -> Date? {
        let weekdayRules: [(weekday: Int, keywords: [String])] = [
            (2, ["月曜日", "月曜", "monday"]),
            (3, ["火曜日", "火曜", "tuesday"]),
            (4, ["水曜日", "水曜", "wednesday"]),
            (5, ["木曜日", "木曜", "thursday"]),
            (6, ["金曜日", "金曜", "friday"]),
            (7, ["土曜日", "土曜", "saturday"]),
            (1, ["日曜日", "日曜", "sunday"])
        ]
        guard let targetWeekday = weekdayRules.first(where: { containsAny(input, keywords: $0.keywords) })?.weekday else {
            return nil
        }

        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: now)
        if containsAny(input, keywords: ["来週", "next week"]) {
            let currentWeekday = calendar.component(.weekday, from: todayStart)
            let currentMondayIndex = mondayBasedIndex(for: currentWeekday)
            let targetMondayIndex = mondayBasedIndex(for: targetWeekday)
            let currentWeekStart = calendar.date(byAdding: .day, value: -currentMondayIndex, to: todayStart) ?? todayStart
            let nextWeekStart = calendar.date(byAdding: .day, value: 7, to: currentWeekStart) ?? currentWeekStart
            return calendar.date(byAdding: .day, value: targetMondayIndex, to: nextWeekStart)
        }

        let currentWeekday = calendar.component(.weekday, from: todayStart)
        var daysUntilTarget = targetWeekday - currentWeekday
        if daysUntilTarget < 0 {
            daysUntilTarget += 7
        }
        return calendar.date(byAdding: .day, value: daysUntilTarget, to: todayStart)
    }

    private static func date(year: Int, month: Int, day: Int) -> Date? {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard let date = Calendar.current.date(from: components) else { return nil }
        return Calendar.current.startOfDay(for: date)
    }

    private static func parseDay(_ value: String?, now: Date) -> Date? {
        guard let value else { return nil }
        return parseDayFromFreeText(value, now: now)
    }

    private static func parseDateTime(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.date(from: value)
    }

    private static func parseTime(from input: String, on day: Date) -> Date? {
        if let groups = matchGroups(pattern: #"(午前|午後|am|pm)?\s*(\d{1,2})\s*[:：]\s*(\d{2})"#, in: input),
           let hourText = group(groups, at: 1),
           let minuteText = group(groups, at: 2),
           let rawHour = Int(hourText),
           let minute = Int(minuteText) {
            let hour = adjustedHour(rawHour, meridiem: group(groups, at: 0))
            return date(on: day, hour: hour, minute: minute)
        }

        if let groups = matchGroups(pattern: #"(午前|午後|am|pm)?\s*(\d{1,2})\s*時\s*(半|(\d{1,2})\s*分?)?"#, in: input),
           let hourText = group(groups, at: 1),
           let rawHour = Int(hourText) {
            let minute: Int
            if group(groups, at: 2) == "半" {
                minute = 30
            } else if let minuteText = group(groups, at: 3), let parsedMinute = Int(minuteText) {
                minute = parsedMinute
            } else {
                minute = 0
            }
            let hour = adjustedHour(rawHour, meridiem: group(groups, at: 0))
            return date(on: day, hour: hour, minute: minute)
        }

        return nil
    }

    private static func date(on day: Date, hour: Int, minute: Int) -> Date? {
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        let calendar = Calendar.current
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: calendar.startOfDay(for: day))
    }

    private static func adjustedHour(_ hour: Int, meridiem: String?) -> Int {
        let marker = meridiem?.lowercased()
        if marker == "午後" || marker == "pm" {
            return hour < 12 ? hour + 12 : hour
        }
        if (marker == "午前" || marker == "am"), hour == 12 {
            return 0
        }
        return hour
    }

    private static func taggedValue(in input: String, labels: [String]) -> String? {
        let labelPattern = labels.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        let pattern = #"(?:\#(labelPattern))\s*[:：]\s*([^,、。\n]+)"#
        guard let groups = matchGroups(pattern: pattern, in: input),
              let value = group(groups, at: 0)?.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "、。,:："))),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func removingTaggedSegments(from input: String) -> String {
        replacingRegex(
            in: input,
            pattern: #"(?:場所|location|メモ|notes?|note)\s*[:：]\s*[^,、。\n]+"#,
            with: " "
        )
    }

    private static func replacingRegex(in input: String, pattern: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return input
        }
        let range = NSRange(input.startIndex..., in: input)
        return regex.stringByReplacingMatches(in: input, range: range, withTemplate: replacement)
    }

    private static func matchGroups(pattern: String, in input: String) -> [String?]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)) else {
            return nil
        }
        return (1..<match.numberOfRanges).map { index in
            guard match.range(at: index).location != NSNotFound,
                  let range = Range(match.range(at: index), in: input) else {
                return nil
            }
            return String(input[range])
        }
    }

    private static func group(_ groups: [String?], at index: Int) -> String? {
        groups.indices.contains(index) ? groups[index] : nil
    }

    private static func mondayBasedIndex(for weekday: Int) -> Int {
        weekday == 1 ? 6 : weekday - 2
    }

    private static func defaultEventStart(now: Date) -> Date {
        defaultEventStart(on: now, now: now)
    }

    private static func defaultEventStart(on day: Date, now: Date) -> Date {
        let calendar = Calendar.current
        if calendar.isDate(day, inSameDayAs: now) {
            let components = calendar.dateComponents([.year, .month, .day, .hour], from: now)
            guard let currentHour = calendar.date(from: components),
                  let nextHour = calendar.date(byAdding: .hour, value: 1, to: currentHour) else {
                return now.addingTimeInterval(3_600)
            }
            return nextHour
        }
        let dayStart = calendar.startOfDay(for: day)
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: dayStart) ?? dayStart
    }

    private static func defaultEventEnd(start: Date) -> Date {
        Calendar.current.date(byAdding: .hour, value: 1, to: start) ?? start.addingTimeInterval(3_600)
    }
}
