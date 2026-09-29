import Foundation

enum PersonalCalendarEditing {
    static func patch(arguments: CapabilityObject, before: CapabilityObject) throws
        -> CapabilityObject
    {
        var patch: CapabilityObject = [:]
        for (input, remote) in [
            ("title", "summary"), ("location", "location"), ("notes", "description"),
        ] {
            if let value = arguments[input] { patch[remote] = value }
        }
        if arguments["start"] != nil || arguments["end"] != nil || arguments["isAllDay"] != nil {
            guard case .object(let startObject)? = before["start"],
                case .object(let endObject)? = before["end"]
            else { throw GoogleCalendarAPIError.invalidResponse }
            let wasAllDay = startObject["date"] != nil
            let allDay: Bool = {
                if case .bool(let value)? = arguments["isAllDay"] { return value }
                return wasAllDay
            }()
            if allDay != wasAllDay && (arguments["start"] == nil || arguments["end"] == nil) {
                throw CapabilityHandlerError.invalidArgument("provide_both_dates")
            }
            let startValue =
                arguments["start"] ?? startObject[wasAllDay ? "date" : "dateTime"] ?? .null
            let endValue = arguments["end"] ?? endObject[wasAllDay ? "date" : "dateTime"] ?? .null
            guard case .string(let start) = startValue, case .string(let end) = endValue else {
                throw CapabilityHandlerError.invalidArgument("dates")
            }
            if allDay {
                guard start.count == 10, end.count == 10, let a = CalendarCivilDate(rfc3339: start),
                    let b = CalendarCivilDate(rfc3339: end), a < b
                else { throw CapabilityHandlerError.invalidArgument("dates") }
            } else {
                guard try PersonalToolDate.parse(end) > PersonalToolDate.parse(start) else {
                    throw CapabilityHandlerError.invalidArgument("dates")
                }
            }
            var newStart: CapabilityObject = [allDay ? "date" : "dateTime": startValue]
            var newEnd: CapabilityObject = [allDay ? "date" : "dateTime": endValue]
            if !allDay {
                if let zone = startObject["timeZone"] { newStart["timeZone"] = zone }
                if let zone = endObject["timeZone"] { newEnd["timeZone"] = zone }
                if before["recurrence"] != nil {
                    newStart["timeZone"] =
                        newStart["timeZone"] ?? .string(TimeZone.current.identifier)
                    newEnd["timeZone"] = newEnd["timeZone"] ?? newStart["timeZone"]
                }
            }
            patch["start"] = .object(newStart)
            patch["end"] = .object(newEnd)
        }
        return patch
    }

    static func verify(patch: CapabilityObject, observed: CapabilityObject) throws {
        for (key, value) in patch {
            if key == "start" || key == "end" {
                guard case .object(let wanted) = value, case .object(let actual)? = observed[key]
                else {
                    throw CapabilityHandlerError.readbackMismatch("event_dates")
                }
                for (field, expected) in wanted {
                    if field == "dateTime", case .string(let a) = actual[field],
                        case .string(let e) = expected
                    {
                        guard try PersonalToolDate.parse(a) == PersonalToolDate.parse(e) else {
                            throw CapabilityHandlerError.readbackMismatch("event_dates")
                        }
                    } else if actual[field] != expected {
                        throw CapabilityHandlerError.readbackMismatch("event_dates")
                    }
                }
            } else if observed[key] != value && !(value == .string("") && observed[key] == nil) {
                throw CapabilityHandlerError.readbackMismatch("event_edit")
            }
        }
    }
}
