import Foundation

struct AiUsageCopy {
    let language: AppLanguage
    enum Level { case normal, warning, critical }

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

    func level(_ percent: Double) -> Level {
        if percent >= 90 { return .critical }
        if percent >= 80 { return .warning }
        return .normal
    }

    func percent(_ value: Double) -> String {
        formatNumber(value, decimals: 1) + "%"
    }

    func windowLabel(_ window: AiUsageWindow) -> String {
        let label: String = switch window.kind {
        case .session: text("5時間", "5-hour")
        case .weekly: text("1週間", "Weekly")
        case .window where window.minutes >= 1440 && window.minutes % 1440 == 0:
            text("\(window.minutes / 1440)日", "\(window.minutes / 1440)-day")
        case .window where window.minutes >= 60:
            text("\(Int((Double(window.minutes) / 60).rounded()))時間", "\(Int((Double(window.minutes) / 60).rounded()))-hour")
        case .window: text("枠", "Window")
        }
        return window.model.map { $0 + " · " + label } ?? label
    }

    func elapsed(_ window: AiUsageWindow, now: Date) -> Double? {
        guard let reset = window.resetsAt else { return nil }
        let duration = Double(window.minutes) * 60
        let remaining = reset.timeIntervalSince(now)
        guard remaining > 0, remaining <= duration else { return nil }
        return 1 - remaining / duration
    }

    func elapsedLabel(_ elapsed: Double) -> String {
        let percent = Int((elapsed * 100).rounded())
        return text("経過\(percent)%", "\(percent)% elapsed")
    }

    func reset(_ date: Date?, now: Date) -> String {
        guard let date else { return text("リセット時刻は不明", "Reset time unknown") }
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return text("リセット済み（次の更新で反映）", "Reset (updates on next refresh)") }
        let relative: String
        if seconds >= 86_400 {
            let hours = Int(seconds / 3600)
            let days = hours / 24
            let remainder = hours % 24
            relative = text("\(days)日" + (remainder > 0 ? "\(remainder)時間" : ""),
                            "\(days)d" + (remainder > 0 ? " \(remainder)h" : ""))
            let time = formattedDate(date, japanese: "M/d(EEE) HH:mm", english: "EEE M/d HH:mm")
            return text("あと\(relative)でリセット（\(time)）", "Resets in \(relative) (\(time))")
        }
        let minutes = Int(ceil(seconds / 60))
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours > 0 {
            relative = text("\(hours)時間" + (remainder > 0 ? "\(remainder)分" : ""),
                            "\(hours)h" + (remainder > 0 ? " \(remainder)m" : ""))
        } else {
            relative = text("\(minutes)分", "\(minutes)m")
        }
        return text("あと\(relative)でリセット", "Resets in \(relative)")
    }

    func stale(_ date: Date) -> String {
        let time = formattedDate(date, japanese: "M/d HH:mm", english: "M/d HH:mm")
        return text("\(time) 時点の値", "Previous reading at \(time)")
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
