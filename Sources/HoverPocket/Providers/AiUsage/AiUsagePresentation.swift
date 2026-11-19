import SwiftUI

enum AiUsageLayout: String, CaseIterable, Identifiable {
    case list, meter
    var id: Self { self }
}

enum AiUsageColumn: String, CaseIterable, Identifiable {
    case session, weekly, other
    var id: Self { self }
}

struct AiUsageSort: Equatable {
    enum Direction: String { case asc, desc }

    let column: AiUsageColumn
    let direction: Direction

    init?(stored: [String]) {
        guard stored.count == 2, let column = AiUsageColumn(rawValue: stored[0]),
              let direction = Direction(rawValue: stored[1]) else { return nil }
        self.column = column
        self.direction = direction
    }

    init(column: AiUsageColumn, previous: Self?) {
        self.column = column
        self.direction = previous?.column == column && previous?.direction == .asc ? .desc : .asc
    }
}

enum AiUsageTint: UInt32, CaseIterable {
    case red = 0xff7c7c
    case yellow = 0xf5c35b
    case green = 0x5fd08a
    case blue = 0x5aa9ff

    var lowerBound: Double {
        switch self {
        case .red: 0
        case .yellow: 25
        case .green: 50
        case .blue: 70
        }
    }

    init(remaining: Double) {
        self = Self.allCases.last { remaining >= $0.lowerBound } ?? .red
    }

    var color: Color { aiUsageColor(rawValue) }
}

func aiUsageColor(_ hex: UInt32) -> Color {
    Color(red: Double(hex >> 16) / 255, green: Double(hex >> 8 & 255) / 255, blue: Double(hex & 255) / 255)
}

extension AiUsageWindow {
    var column: AiUsageColumn {
        if model != nil { return .other }
        switch kind {
        case .session where minutes == 300: return .session
        case .weekly: return .weekly
        default: return .other
        }
    }

    var remaining: Double? {
        percent.flatMap { $0.isFinite ? min(100, max(0, 100 - $0)) : nil }
    }
}

struct AiUsagePanelService: Identifiable {
    let id: AiUsageService
    let snapshot: AiUsageSnapshot
    let changingAccount: Bool

    func windows(in column: AiUsageColumn) -> [AiUsageWindow] {
        (snapshot.reading?.windows ?? []).filter { $0.column == column }
    }

    var orderedWindows: [AiUsageWindow] { AiUsageColumn.allCases.flatMap(windows(in:)) }

    var showsListRow: Bool {
        if snapshot.reading?.windows.isEmpty == false { return true }
        if snapshot.status == .signedOut { return true }
        return snapshot.reading == nil && (snapshot.refreshing || changingAccount || hasFailure)
    }

    private var hasFailure: Bool {
        if case .failure = snapshot.status { return true }
        return false
    }

    var readingOpacity: Double { snapshot.stale ? 0.5 : 1 }
    var staleDate: Date? { snapshot.stale ? snapshot.fetchedAt : nil }
    var updateDate: Date? { snapshot.status == .ready ? snapshot.fetchedAt : nil }

    func quota(_ window: AiUsageWindow) -> AiUsageQuota {
        let duplicate = window.model.map { model in
            (snapshot.reading?.windows.filter { $0.model == model }.count ?? 0) > 1
        } ?? false
        return .init(window: window, distinguishesDuration: duplicate)
    }

    func reason(_ copy: AiUsageCopy) -> String? {
        if case .failure(let error) = snapshot.status { return copy.error(error) }
        return nil
    }

    func emptyMessage(_ copy: AiUsageCopy) -> String {
        if snapshot.status == .signedOut { return copy.signedOut }
        if let reason = reason(copy) { return reason }
        if changingAccount { return copy.accountChanging }
        if snapshot.refreshing { return copy.checking }
        return snapshot.reading == nil ? copy.unchecked : copy.unavailable
    }

    static func sorted(_ services: [Self], by sort: AiUsageSort?) -> [Self] {
        guard let sort else { return services }
        let values = services.map { service in
            (service, service.windows(in: sort.column).compactMap(\.remaining).min())
        }
        return values.sorted { lhs, rhs in
            guard let left = lhs.1 else { return false }
            guard let right = rhs.1 else { return true }
            return sort.direction == .asc ? left < right : left > right
        }.map(\.0)
    }
}

struct AiUsageQuota {
    let window: AiUsageWindow
    var distinguishesDuration = false

    func durationSuffix(_ copy: AiUsageCopy) -> String? {
        distinguishesDuration ? copy.durationLabel(window.minutes) : nil
    }

    func fullName(_ copy: AiUsageCopy) -> String {
        [copy.windowLabel(window), durationSuffix(copy)].compactMap { $0 }.joined(separator: " ")
    }

    func resetText(_ copy: AiUsageCopy, now: Date) -> String? {
        guard window.remaining != nil else { return nil }
        return copy.reset(window.resetsAt, now: now)
    }

    func meterDetail(_ copy: AiUsageCopy, now: Date) -> String? {
        let parts = [durationSuffix(copy), resetText(copy, now: now)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    func help(_ copy: AiUsageCopy) -> String {
        let detail = window.remaining == nil ? copy.unavailable : window.resetsAt.map(copy.resetHelp)
        return [fullName(copy), detail].compactMap { $0 }.joined(separator: "\n")
    }
}

struct AiUsageQuotaLabel: View {
    let quota: AiUsageQuota
    let copy: AiUsageCopy

    var body: some View {
        HStack(spacing: 2) {
            Text(copy.windowLabel(quota.window))
                .lineLimit(1)
                .truncationMode(.tail)
            if let suffix = quota.durationSuffix(copy) {
                Text(suffix).lineLimit(1).fixedSize()
            }
        }
    }
}

struct AiUsagePanelBalance {
    let service: AiUsageService
    let parts: [AiUsageBalance]
    let total: AiUsageBalance

    init?(_ row: AiUsagePanelService) {
        guard let parts = row.snapshot.reading?.balances, let first = parts.first else { return nil }
        service = row.id
        self.parts = parts
        if service == .claudeAPI {
            let value: AiUsageBalance.Value
            if parts.contains(where: { $0.value == .unlimited }) {
                value = .unlimited
            } else if parts.allSatisfy({ if case .amount = $0.value { true } else { false } }) {
                value = .amount(parts.reduce(Decimal(0)) { sum, part in
                    if case .amount(let amount) = part.value { return sum + amount }
                    return sum
                })
            } else {
                value = .unreadable
            }
            let expiry = parts.compactMap(\.expiresAt).min()
            total = .init(kind: first.kind, value: value, expiresAt: expiry)
        } else {
            total = first
        }
    }

    func label(_ copy: AiUsageCopy) -> String {
        service == .codex ? copy.balanceLabel(total) : service.title
    }

    func meterLabel(_ copy: AiUsageCopy) -> String {
        service == .colab ? copy.text("ユニット", "Units") : copy.text("クレジット", "Credits")
    }

    func meterValue(_ copy: AiUsageCopy) -> String {
        let value = copy.balanceValue(total)
        switch total.value {
        case .units: return value + " CU"
        case .amount where service == .codex: return value + " CR"
        default: return value
        }
    }

    func meterDetail(_ copy: AiUsageCopy, now: Date) -> String? {
        if service == .colab { return copy.balanceDetail(total, now: now) }
        return total.expiresAt.map { copy.balanceExpiry($0, now: now) }
    }

    func help(_ copy: AiUsageCopy, now: Date) -> String {
        parts.map { part in
            [copy.balanceLabel(part), copy.balanceValue(part), copy.balanceDetail(part, now: now)]
                .compactMap { $0 }.joined(separator: "  ")
        }.joined(separator: "\n")
    }
}
