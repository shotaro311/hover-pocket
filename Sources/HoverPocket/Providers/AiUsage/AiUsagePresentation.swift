import SwiftUI

enum AiUsageLayout: String, CaseIterable, Identifiable {
    case list, meter
    var id: Self { self }
}

enum AiUsageSection: CaseIterable, Hashable {
    case limits, balances

    var defaultOrder: [AiUsageService] {
        switch self {
        case .limits: [.codex, .claude, .gemini, .muse]
        case .balances: [.codex, .claudeAPI, .colab]
        }
    }

    func title(_ copy: AiUsageCopy) -> String {
        switch self {
        case .limits: copy.text("サブスクの利用枠", "Plan limits")
        case .balances: copy.text("クレジット・残高", "Credits and balances")
        }
    }

    func normalizedOrder(_ rawValues: [String]?) -> [AiUsageService] {
        let defaults = defaultOrder
        let saved = (rawValues ?? []).compactMap(AiUsageService.init(rawValue:))
        var seen = Set<AiUsageService>()
        return (saved + defaults).filter { defaults.contains($0) && seen.insert($0).inserted }
    }

    func moving(_ service: AiUsageService, to target: AiUsageService, in order: [AiUsageService]) -> [AiUsageService] {
        guard let from = order.firstIndex(of: service), let to = order.firstIndex(of: target), from != to else { return order }
        var result = order
        result.remove(at: from)
        result.insert(service, at: to)
        return result
    }

    func visibleRows(_ services: [AiUsagePanelService], in order: [AiUsageService]) -> [AiUsagePanelService] {
        let byID = Dictionary(uniqueKeysWithValues: services.map { ($0.id, $0) })
        return order.compactMap { byID[$0] }.filter { $0.appears(in: self) }
    }
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

    func appears(in section: AiUsageSection) -> Bool {
        let needsStatus = snapshot.refreshing || changingAccount || snapshot.status == .signedOut || hasFailure
        switch section {
        case .limits:
            return snapshot.reading?.windows.isEmpty == false ||
                (snapshot.reading == nil && needsStatus && AiUsageSection.limits.defaultOrder.contains(id))
        case .balances:
            return snapshot.reading?.balances.isEmpty == false ||
                (needsStatus && !AiUsageSection.limits.defaultOrder.contains(id))
        }
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

struct AiUsageReadingNumber: View {
    let amount: String
    let unit: String?
    let size: CGFloat
    let unitSize: CGFloat
    var color: Color = .primary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: unit == "%" ? 2 : 4) {
            Text(amount)
                .font(.system(size: size, weight: .medium))
                .monospacedDigit()
                .tracking(size >= 20 ? -0.02 * size : 0)
                .foregroundStyle(color)
            if let unit {
                Text(unit).font(.system(size: unitSize, weight: .medium))
                    .foregroundStyle(aiUsageColor(0x9ba6b5))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([amount, unit].compactMap { $0 }.joined(separator: unit == "%" ? "" : " "))
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
        service == .codex ? copy.text("Codex クレジット", "Codex credits") : service.title
    }

    var unit: String? {
        switch total.value {
        case .units: "CU"
        case .amount where service == .codex: "CR"
        default: nil
        }
    }

    func meterDetail(_ copy: AiUsageCopy, now: Date) -> String? {
        switch service {
        case .codex: return copy.text("サブスクの枠を超えた分に使う", "Used after plan limits")
        case .colab: return copy.balanceDetail(total, now: now)
        default: return total.expiresAt.map { copy.balanceExpiry($0, now: now) }
        }
    }

    func help(_ copy: AiUsageCopy, now: Date) -> String {
        parts.map { part in
            [copy.balanceLabel(part), copy.balanceValue(part), copy.balanceDetail(part, now: now)]
                .compactMap { $0 }.joined(separator: "  ")
        }.joined(separator: "\n")
    }
}
