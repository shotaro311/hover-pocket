import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

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
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *),
           case .available = await availability(),
           let modelPlan = try await makeFoundationModelPlan(for: input, context: context) {
            return modelPlan
        }
        #endif

        return Self.makeDeterministicPlan(
            for: input,
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
        Output only key=value lines.
        For calendar_read_day include date=yyyy-MM-dd.
        For calendar_create_event include title=, start=yyyy-MM-dd'T'HH:mm:ss, end=yyyy-MM-dd'T'HH:mm:ss, allDay=true|false.
        Do not invent unavailable tools. Do not plan multiple steps.
        Current time zone: \(context.timeZoneIdentifier).
        """)
        let response = try await session.respond(to: input)
        return Self.parseModelResponse(
            response.content,
            sourceText: input,
            context: context,
            modelIdentifier: descriptor.id
        )
    }
    #endif

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
                requiresApproval: false,
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
                requiresApproval: true,
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
        let canRead = containsAny(normalized, keywords: ["calendar", "予定", "カレンダー", "schedule", "today", "tomorrow", "明日", "今日"])
        let canWrite = containsAny(normalized, keywords: ["add", "create", "schedule", "追加", "作成", "入れて", "登録", "予約", "会議", "打ち合わせ"])

        let readAction = PocketAction(
            kind: .calendarReadDay,
            sourceText: normalized,
            requiresApproval: false,
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
        let title = cleanedEventTitle(from: input)
        let start = defaultEventStart(on: targetDay, now: context.now)
        let end = defaultEventEnd(start: start)
        return PocketAction(
            kind: .calendarCreateEvent,
            sourceText: input,
            requiresApproval: true,
            createEventParameters: CalendarCreateEventParameters(
                calendarID: calendar.id,
                calendarTitle: calendar.title,
                title: title.isEmpty ? "New event" : title,
                start: start,
                end: end,
                isAllDay: false,
                location: nil,
                notes: nil
            )
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
        var title = input
        ["予定", "カレンダー", "calendar", "add", "create", "追加", "作成", "入れて", "登録", "予約"].forEach {
            title = title.replacingOccurrences(of: $0, with: "", options: [.caseInsensitive, .diacriticInsensitive])
        }
        return title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func containsAny(_ input: String, keywords: [String]) -> Bool {
        keywords.contains { input.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    private static func parseDayFromFreeText(_ input: String, now: Date) -> Date? {
        let pattern = #"\b(\d{4})-(\d{2})-(\d{2})\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
              match.numberOfRanges == 4,
              let yearRange = Range(match.range(at: 1), in: input),
              let monthRange = Range(match.range(at: 2), in: input),
              let dayRange = Range(match.range(at: 3), in: input),
              let year = Int(input[yearRange]),
              let month = Int(input[monthRange]),
              let day = Int(input[dayRange]) else {
            return nil
        }

        var components = Calendar.current.dateComponents([.hour, .minute, .second], from: now)
        components.year = year
        components.month = month
        components.day = day
        return Calendar.current.date(from: components)
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
