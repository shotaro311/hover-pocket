import Foundation

struct AiUsageCopy {
    let language: AppLanguage

    func text(_ japanese: String, _ english: String) -> String {
        language == .japanese ? japanese : english
    }

    var accountChanging: String { text("サインイン状態を変更中…", "Changing sign-in…") }
    var checking: String { text("確認中…", "Checking…") }
    var unchecked: String { text("未確認", "Not checked") }

    func error(_ error: AiUsageFailure) -> String {
        switch error {
        case .network: text("ネットワークに接続できませんでした。", "Could not connect to the service.")
        case .changed: text("使用状況を読み取れませんでした。", "Could not read the usage response.")
        case .timeout: text("使用状況の確認がタイムアウトしました。", "The usage request timed out.")
        case .codexMissing: text("Codex CLIが見つかりません。", "Codex CLI could not be found.")
        case .blocked: text("サービスが確認画面を返しました。", "The service returned a verification page.")
        case .unavailable: text("使用状況を取得できませんでした。", "Usage is temporarily unavailable.")
        case .noAccess: text("請求情報を見る権限がありません。", "This account cannot access billing information.")
        case .ambiguous: text("Claude Consoleの組織を特定できません。", "Could not identify the Claude Console organization.")
        }
    }

    var remaining: String { text("残り", "Left") }
    var unavailable: String { text("取得できません", "Unavailable") }
    var signedOut: String { text("サインインしていません", "Signed out") }

    func percent(_ value: Double) -> String {
        formatNumber(value, decimals: 1) + "%"
    }

    func column(_ column: AiUsageColumn) -> String {
        switch column {
        case .session: text("5時間", "5-hour")
        case .weekly: text("1週間", "Weekly")
        case .other: text("別枠", "Other")
        }
    }

    func windowLabel(_ window: AiUsageWindow) -> String {
        if let model = window.model { return model }
        if window.column != .other { return column(window.column) }
        return durationLabel(window.minutes)
    }

    func durationLabel(_ duration: Int) -> String {
        if duration == 300 { return column(.session) }
        if duration == 10_080 { return column(.weekly) }
        let days = duration / 1440
        let hours = duration % 1440 / 60
        let minutes = duration % 60
        let parts = [
            days > 0 ? text("\(days)日", "\(days)d") : nil,
            hours > 0 ? text("\(hours)時間", "\(hours)h") : nil,
            minutes > 0 ? text("\(minutes)分", "\(minutes)m") : nil
        ].compactMap { $0 }
        return parts.isEmpty ? text("枠", "Window") : parts.joined(separator: text("", " "))
    }

    func reset(_ date: Date?, now: Date) -> String? {
        guard let date else { return nil }
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return text("リセット済み", "Reset") }
        if seconds >= 86_400 {
            let hours = Int(seconds / 3600)
            let days = hours / 24
            let remainder = hours % 24
            return text("\(days)日" + (remainder > 0 ? "\(remainder)時間" : ""),
                        "\(days)d" + (remainder > 0 ? " \(remainder)h" : ""))
        }
        let minutes = min(1439, Int(ceil(seconds / 60)))
        return String(format: "%d:%02d", minutes / 60, minutes % 60)
    }

    func resetHelp(_ date: Date) -> String {
        let time = formattedDate(date, japanese: "M/d(EEE) HH:mm", english: "EEE M/d HH:mm")
        return text("\(time)にリセット", "Resets \(time)")
    }

    func meterAccessibility(_ quota: AiUsageQuota, now: Date) -> String {
        let window = quota.window
        let label = quota.fullName(self)
        guard let value = window.remaining else { return "\(label) \(unavailable)" }
        let percent = percent(value)
        var result = text("\(label) 残り\(percent)", "\(label) \(percent) left")
        if let date = window.resetsAt, let time = reset(date, now: now) {
            result += date > now ? text("、あと\(time)でリセット", ", resets in \(time)") : text("、\(time)", ", \(time)")
        }
        return result
    }

    func updated(_ date: Date) -> String {
        let time = formattedDate(date, japanese: "HH:mm", english: "HH:mm")
        return text("\(time) 更新", "Updated \(time)")
    }

    func stale(_ date: Date) -> String {
        let time = formattedDate(date, japanese: "HH:mm", english: "HH:mm")
        return text("\(time) の値", "Value at \(time)")
    }

    func balanceExpiry(_ date: Date, now: Date) -> String {
        let day = formattedDate(date, japanese: "M/d", english: "M/d")
        return date > now ? text("\(day)まで", "Until \(day)") : text("期限切れ（\(day)）", "Expired (\(day))")
    }

    func balanceLabel(_ balance: AiUsageBalance) -> String {
        switch balance.kind {
        case .planCredit: balance.label ?? text("プラン特典のクレジット", "Plan credits")
        case .purchasedCredit: text("購入したクレジット", "Purchased credits")
        case .codexCredits: text("Codexクレジット", "Codex credits")
        case .computeUnits: text("コンピューティング ユニット", "Compute units")
        }
    }

    func balanceValue(_ balance: AiUsageBalance) -> String {
        switch balance.value {
        case .unlimited: return text("無制限", "Unlimited")
        case .unreadable: return text("読み取れません", "Unreadable")
        case .units(let units):
            return units > 0 && units < 0.1
                ? "<0.1" : units.formatted(.number.locale(Locale(identifier: "en_US")).precision(.fractionLength(1)))
        case .amount(let amount):
            let usd = balance.kind != .codexCredits
            if amount > 0 && amount < Decimal(sign: .plus, exponent: -2, significand: 1) {
                return usd ? "<$0.01" : "<0.01"
            }
            let value = amount.formatted(.number.locale(Locale(identifier: "en_US")).precision(.fractionLength(usd ? 2...2 : 0...2)))
            return usd ? "$" + value : value
        }
    }

    func balanceDetail(_ balance: AiUsageBalance, now: Date) -> String? {
        if balance.kind == .computeUnits {
            guard let rate = balance.perHour else { return text("消費量は不明", "Hourly usage unknown") }
            if rate == 0 { return text("いまは消費していません", "No current usage") }
            let value = rate < 0.01 ? "<0.01" : formatNumber(rate, decimals: 2)
            let hourly = text("消費 \(value)/時間", "\(value)/hour")
            guard case .units(let units) = balance.value, let hours = Int(exactly: floor(units / rate)) else { return hourly }
            return hourly + text(" · 約\(hours)時間分", " · about \(hours) hours left")
        }
        guard let expiry = balance.expiresAt else { return nil }
        let days = max(0, Int(ceil(expiry.timeIntervalSince(now) / 86400)))
        let date = formattedDate(expiry, japanese: "M/d(EEE)", english: "EEE M/d")
        if expiry <= now { return text("期限切れ（\(date)）", "Expired (\(date))") }
        return text("\(date)まで（あと\(days)日）", "Expires \(date) (\(days)d left)")
    }

    private func formatNumber(_ value: Double, decimals: Int) -> String {
        value.formatted(.number.locale(Locale(identifier: "en_US")).precision(.fractionLength(0...decimals)))
    }

    private func formattedDate(_ date: Date, japanese: String, english: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: text("ja_JP", "en_US"))
        formatter.dateFormat = text(japanese, english)
        return formatter.string(from: date)
    }
}
