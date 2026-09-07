import CoreFoundation
import Foundation

enum PocketCollectionError: Error, Equatable {
    case invalidSchema
    case invalidRecord
    case invalidDocument
    case revisionConflict
    case recordNotFound
    case capacityExceeded
    case persistenceFailed
}

struct PocketCollectionSchema: Equatable, Sendable {
    struct Field: Equatable, Sendable {
        let title: String
        let type: String
        let required: Bool
        let nullable: Bool
        let choices: [String]
        let maximumLength: Int
    }

    let version: Int
    let title: String
    let fields: [String: Field]

    static func validIdentifier(_ value: String) -> Bool {
        value.range(of: "^[a-zA-Z][a-zA-Z0-9_-]{0,63}$", options: .regularExpression) != nil
    }

    init(data: Data) throws {
        guard data.count <= 64 * 1_024,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["$schema", "schemaVersion", "title", "fields"],
              object["$schema"] as? String == "hoverpocket://schemas/pocket-collection/v1",
              let version = Self.integer(object["schemaVersion"]), version > 0,
              let title = object["title"] as? String, Self.validText(title, limit: 120),
              let rawFields = object["fields"] as? [String: [String: Any]],
              (1...32).contains(rawFields.count) else { throw PocketCollectionError.invalidSchema }
        var fields: [String: Field] = [:]
        for (key, raw) in rawFields {
            let requiredKeys: Set<String> = ["title", "type", "required", "nullable"]
            guard Self.validIdentifier(key), requiredKeys.isSubset(of: Set(raw.keys)),
                  Set(raw.keys).isSubset(of: requiredKeys.union(["choices", "maxLength"])),
                  let label = raw["title"] as? String, Self.validText(label, limit: 120),
                  let type = raw["type"] as? String,
                  ["string", "number", "boolean", "date", "enum"].contains(type),
                  let required = Self.boolean(raw["required"]),
                  let nullable = Self.boolean(raw["nullable"]) else { throw PocketCollectionError.invalidSchema }
            let choices = raw["choices"] as? [String] ?? []
            let length = raw["maxLength"].flatMap(Self.integer) ?? 4_096
            guard (1...4_096).contains(length),
                  raw["maxLength"] == nil || (type == "string" && Self.integer(raw["maxLength"]) != nil),
                  type == "enum"
                    ? ((1...64).contains(choices.count) && Set(choices).count == choices.count
                       && choices.allSatisfy { Self.validText($0, limit: 120) })
                    : raw["choices"] == nil else { throw PocketCollectionError.invalidSchema }
            fields[key] = Field(title: label, type: type, required: required, nullable: nullable,
                                choices: choices, maximumLength: length)
        }
        self.version = version
        self.title = title
        self.fields = fields
    }

    func validate(_ record: [String: PocketJSONValue]) throws {
        guard Set(record.keys).isSubset(of: Set(fields.keys)) else { throw PocketCollectionError.invalidRecord }
        for (key, field) in fields {
            guard let value = record[key] else {
                if field.required { throw PocketCollectionError.invalidRecord }
                continue
            }
            if value == .null {
                guard field.nullable else { throw PocketCollectionError.invalidRecord }
                continue
            }
            let valid: Bool
            switch (field.type, value) {
            case ("string", .string(let text)):
                valid = text.unicodeScalars.count <= field.maximumLength && !text.contains("\0")
            case ("number", .number(let number)): valid = number.isFinite
            case ("boolean", .bool): valid = true
            case ("enum", .string(let choice)): valid = field.choices.contains(choice)
            case ("date", .string(let text)): valid = Self.validDate(text)
            default: valid = false
            }
            guard valid else { throw PocketCollectionError.invalidRecord }
        }
    }

    static func integer(_ value: Any?) -> Int? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite, value.doubleValue.rounded() == value.doubleValue,
              abs(value.doubleValue) <= 9_007_199_254_740_991 else { return nil }
        return value.intValue
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return value.boolValue
    }

    private static func validText(_ text: String, limit: Int) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && text.unicodeScalars.count <= limit && !text.contains("\0")
    }

    private static func validDate(_ value: String) -> Bool {
        guard value.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil else { return false }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
    }
}
