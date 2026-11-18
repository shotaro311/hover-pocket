import CoreFoundation
import Foundation

enum AiUsageParsers {
    typealias Object = [String: Any]
    private static let posix = Locale(identifier: "en_US_POSIX")

    static func json(_ text: String) throws -> Any {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix(")]}'") { body.removeFirst(4) }
        do {
            return try JSONSerialization.jsonObject(with: Data(body.utf8), options: .fragmentsAllowed)
        } catch {
            throw AiUsageFailure.changed
        }
    }

    static func codexAccount(_ response: CodexJSONValue) throws -> [String: CodexJSONValue]? {
        switch response.objectValue?["account"] {
        case .object(let account): account
        case .null: nil
        default: throw AiUsageFailure.changed
        }
    }

    static func codex(_ response: CodexJSONValue, account: [String: CodexJSONValue] = [:]) throws -> AiUsageReading {
        let single = response.objectValue?["rateLimits"]?.objectValue
        var buckets = (response.objectValue?["rateLimitsByLimitId"]?.objectValue ?? [:]).compactMapValues(\.objectValue)
        if buckets.isEmpty, let single {
            buckets[single["limitId"]?.stringValue ?? "codex"] = single
        }
        let keys = buckets.keys.sorted { left, right in
            if left.lowercased() == "codex" { return right.lowercased() != "codex" }
            if right.lowercased() == "codex" { return false }
            return left < right
        }
        var reading = AiUsageReading()
        for key in keys {
            guard let bucket = buckets[key] else { continue }
            reading.plan = reading.plan ?? codexPlan(bucket["planType"]?.stringValue)
            let model = key.lowercased() == "codex" ? nil : clean(bucket["limitName"]?.stringValue ?? key)
            for (position, fallback) in [("primary", 300), ("secondary", 10_080)] {
                guard let window = bucket[position]?.objectValue, let used = window["usedPercent"]?.doubleValue else { continue }
                let minutes = window["windowDurationMins"]?.integerValue.flatMap(Int.init(exactly:)) ?? fallback
                guard minutes > 0 else { throw AiUsageFailure.changed }
                reading.windows.append(try AiUsageWindow(
                    model: model, percent: percent(used), resetsAt: unixTime(window["resetsAt"]?.doubleValue), minutes: minutes
                ))
            }
        }
        reading.plan = reading.plan ?? codexPlan(account["planType"]?.stringValue)
        guard !reading.windows.isEmpty else { throw AiUsageFailure.changed }
        reading.windows = Array(reading.windows.prefix(12))
        let main = keys.first { $0.lowercased() == "codex" }.flatMap { buckets[$0] }
        let direct = single?["credits"]
        if let balance = codexCredits(direct == nil || direct == .null ? main?["credits"] : direct) {
            reading.balances = [balance]
        }
        return reading
    }

    private static func codexPlan(_ value: String?) -> String? {
        guard let value, value != "unknown" else { return nil }
        return switch value {
        case "prolite": "Pro Lite"
        case "promax": "Pro Max"
        case "edu": "Edu"
        case "free", "go", "plus", "pro", "team", "business", "enterprise": value.capitalized
        default: clean(value)
        }
    }

    private static func codexCredits(_ credits: CodexJSONValue?) -> AiUsageBalance? {
        guard let credits, credits != .null else { return nil }
        guard let fields = credits.objectValue else { return .init(kind: .codexCredits, value: .unreadable) }
        if fields["unlimited"] == .bool(true) { return .init(kind: .codexCredits, value: .unlimited) }
        guard let balance = fields["balance"], balance != .null else {
            return fields["hasCredits"] == .bool(true) ? .init(kind: .codexCredits, value: .unreadable) : nil
        }
        let text = balance.stringValue ?? balance.doubleValue.map { String($0) }
        guard let text, let amount = decimal(text), amount >= 0, amount <= 1_000_000_000 else {
            return .init(kind: .codexCredits, value: .unreadable)
        }
        return .init(kind: .codexCredits, value: .amount(amount))
    }

    static func claudeOrganization(_ json: Any, console: Bool) throws -> (id: String, plan: String?) {
        guard let organizations = json as? [Any] else { throw AiUsageFailure.changed }
        let matches = organizations.compactMap { element -> (UUID, Object)? in
            guard let org = element as? Object,
                  (org["capabilities"] as? [String])?.contains(console ? "api" : "chat") == true,
                  let rawID = org["uuid"] as? String, rawID.utf8.count == 36,
                  let id = UUID(uuidString: rawID) else { return nil }
            return (id, org)
        }
        if console, Set(matches.map(\.0)).count > 1 { throw AiUsageFailure.ambiguous }
        guard let (id, organization) = matches.first else { throw AiUsageFailure.unavailable }
        let tier = (organization["rate_limit_tier"] as? String)?.lowercased() ?? ""
        let capabilities = organization["capabilities"] as? [String] ?? []
        let plan: String? = if console { nil }
            else if tier.contains("max_20x") { "Max 20x" }
            else if tier.contains("max_5x") { "Max 5x" }
            else if capabilities.contains("claude_max") { "Max" }
            else if capabilities.contains("claude_pro") { "Pro" }
            else { nil }
        return (id.uuidString.lowercased(), plan)
    }

    static func claude(_ json: Any, plan: String?) throws -> AiUsageReading {
        guard let usage = json as? Object else { throw AiUsageFailure.changed }
        var windows: [AiUsageWindow] = []
        if let limits = usage["limits"] as? [Any] {
            for case let limit as Object in limits {
                guard let used = number(limit["percent"])?.doubleValue else { continue }
                let kind = limit["kind"] as? String
                let group = limit["group"] as? String
                let minutes: Int
                if kind == "session" || group == "session" { minutes = 300 }
                else if kind == "weekly_all" || kind == "weekly_scoped" || group == "weekly" { minutes = 10_080 }
                else { continue }
                let scope = (limit["scope"] as? Object)?["model"] as? Object
                let model = clean(scope?["display_name"] as? String ?? scope?["id"] as? String)
                windows.append(try AiUsageWindow(
                    model: model ?? (kind == "weekly_scoped" ? "Model" : nil),
                    percent: percent(used), resetsAt: date(limit["resets_at"]), minutes: minutes
                ))
            }
        } else if usage["limits"] == nil || usage["limits"] is NSNull {
            let fields: [(String, Int, String?)] = [
                ("five_hour", 300, nil), ("seven_day", 10_080, nil),
                ("seven_day_opus", 10_080, "Opus"), ("seven_day_sonnet", 10_080, "Sonnet"),
                ("seven_day_fable", 10_080, "Fable")
            ]
            for (key, minutes, model) in fields {
                guard let limit = usage[key] as? Object, let used = number(limit["utilization"])?.doubleValue else { continue }
                windows.append(try AiUsageWindow(model: model, percent: percent(used), resetsAt: date(limit["resets_at"]), minutes: minutes))
            }
        }
        guard !windows.isEmpty else { throw AiUsageFailure.changed }
        return .init(plan: plan, windows: Array(windows.prefix(12)))
    }

    static func claudeCredits(_ json: Any) throws -> AiUsageReading {
        guard let object = json as? Object else { throw AiUsageFailure.changed }
        try requireUSD(object)
        var balances: [AiUsageBalance] = []
        var purchases: [Date?: Decimal] = [:]
        for (key, kind) in [("promo_tranches", AiUsageBalance.Kind.planCredit), ("tranches", .purchasedCredit)] {
            guard let raw = object[key], !(raw is NSNull) else { continue }
            guard let tranches = raw as? [Object] else { throw AiUsageFailure.changed }
            for tranche in tranches {
                try requireUSD(tranche)
                let amount = try minorAmount(tranche["remaining"])
                let expiry = try date(tranche["expires_at"])
                if kind == .planCredit {
                    balances.append(.init(kind: kind, value: .amount(amount), label: clean(tranche["name"] as? String), expiresAt: expiry))
                } else {
                    purchases[expiry, default: 0] += amount
                }
            }
        }
        for expiry in purchases.keys.sorted(by: { ($0 ?? .distantFuture) < ($1 ?? .distantFuture) }) {
            if let amount = purchases[expiry] {
                balances.append(.init(kind: .purchasedCredit, value: .amount(amount), expiresAt: expiry))
            }
        }
        if balances.isEmpty {
            guard try minorAmount(object["balance"]) == 0 else { throw AiUsageFailure.changed }
            balances = [.init(kind: .purchasedCredit, value: .amount(0))]
        }
        return .init(balances: balances)
    }

    private static func requireUSD(_ object: Object) throws {
        if let currency = object["currency"], currency as? String != "USD" { throw AiUsageFailure.changed }
    }

    private static func minorAmount(_ raw: Any?) throws -> Decimal {
        guard let holder = raw as? Object,
              let value = holder["credits"] as? Object ?? holder["money"] as? Object,
              let amount = integer(value["amount_minor"]), (0..<1_000_000_000_000).contains(amount),
              let exponent = integer(value["exponent"]), (0...6).contains(exponent) else { throw AiUsageFailure.changed }
        try requireUSD(holder)
        try requireUSD(value)
        return Decimal(amount) / pow(Decimal(10), Int(exponent))
    }

    static func gemini(_ body: String) throws -> AiUsageReading? {
        let raw = try json(body)
        for case let result as Object in (raw as? [Any] ?? [raw]) {
            guard let viewer = (result["data"] as? Object)?["viewer"] else { continue }
            if viewer is NSNull { return nil }
            guard let info = ((viewer as? Object)?["rpcs"] as? Object)?["getUsageInfo"] as? Object,
                  let pools = info["pools"] as? [Any] else { throw AiUsageFailure.changed }
            var windows: [AiUsageWindow] = []
            for (type, minutes) in [("GXU_FIVE_HOURLY", 300), ("GXU_WEEKLY", 10_080)] {
                guard let pool = pools.compactMap({ $0 as? Object }).first(where: { $0["poolType"] as? String == type }),
                      let fraction = number(pool["percentageUsed"])?.doubleValue else { continue }
                windows.append(try AiUsageWindow(
                    percent: percent(fraction * 100), resetsAt: date((pool["gxu"] as? Object)?["windowRefreshesAt"]), minutes: minutes
                ))
            }
            guard !windows.isEmpty else { throw AiUsageFailure.changed }
            return .init(plan: info["subscriptionTier"] as? String == "TIER1" ? "Pro" : nil, windows: windows)
        }
        throw AiUsageFailure.changed
    }

    static func colab(_ body: String) throws -> AiUsageReading {
        guard let result = try json(body) as? Object,
              let balance = number(result["currentBalance"])?.doubleValue,
              (0...1_000_000).contains(balance) else { throw AiUsageFailure.changed }
        let rate = number(result["consumptionRateHourly"]).map(\.doubleValue).flatMap {
            (0..<10_000).contains($0) ? $0 : nil
        }
        return .init(balances: [.init(kind: .computeUnits, value: .units(balance), perHour: rate)])
    }

    static func muse(_ body: String) throws -> AiUsageReading {
        var subscription: Object?
        for line in body.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].allSatisfy({ $0.isHexDigit }),
                  let row = (try? json(String(parts[1]))) as? Object,
                  let success = row["success"] as? NSNumber,
                  CFGetTypeID(success) == CFBooleanGetTypeID(), success.boolValue,
                  let candidate = row["subscription"] as? Object else { continue }
            subscription = candidate
        }
        guard let sub = subscription, let usage = sub["usage"] as? Object,
              let used = number(usage["percentUsed"])?.doubleValue else { throw AiUsageFailure.changed }
        return .init(
            plan: clean((sub["tier"] as? Object)?["name"] as? String),
            windows: [try AiUsageWindow(percent: percent(used), resetsAt: unixTime(number(usage["resetsAt"])?.doubleValue), minutes: 10_080)]
        )
    }

    private static func number(_ value: Any?) -> NSNumber? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number
    }

    private static func integer(_ value: Any?) -> Int64? {
        guard let value = number(value),
              !["f", "d"].contains(String(cString: value.objCType)) else { return nil }
        return Int64(value.stringValue)
    }

    private static func decimal(_ text: String) -> Decimal? {
        guard text.range(of: #"^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil else { return nil }
        return Decimal(string: text, locale: posix)
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let filtered = value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && $0.properties.generalCategory != .format
        }
        let name = String(String.UnicodeScalarView(filtered)).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : String(name.prefix(40))
    }

    private static func percent(_ value: Double) throws -> Double {
        guard (0...1000).contains(value) else { throw AiUsageFailure.changed }
        return (min(value, 100) * 10).rounded() / 10
    }

    private static func unixTime(_ value: Double?) throws -> Date? {
        guard let value else { return nil }
        guard (946_684_800..<7_258_118_400).contains(value) else { throw AiUsageFailure.changed }
        return Date(timeIntervalSince1970: value)
    }

    private static func date(_ value: Any?) throws -> Date? {
        guard let value, !(value is NSNull) else { return nil }
        guard let text = value as? String else { throw AiUsageFailure.changed }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var parsed = formatter.date(from: text)
        if parsed == nil {
            formatter.formatOptions = [.withInternetDateTime]
            parsed = formatter.date(from: text)
        }
        guard let parsed else { throw AiUsageFailure.changed }
        return try unixTime(parsed.timeIntervalSince1970)
    }
}

private extension CodexJSONValue {
    var doubleValue: Double? {
        switch self {
        case .integer(let value): Double(value)
        case .number(let value): value
        default: nil
        }
    }
}
