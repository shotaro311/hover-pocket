import AppKit
import Combine
import Network
import SwiftUI
import WebKit

@MainActor
enum AiUsageVerificationCommand {
    static func run(output: URL) async throws {
        let verify = Checks()
        try parsers(verify)
        try await service(verify)
        try await webKit(verify)
        try await robotsResponses(verify)
        try await presentation(verify, output: output)
        try await CodexChatController.verifySignInStatus(at: output)
        print("PASS AI Usage: \(verify.count) checks, plus chat sign-in regression. PNG evidence: \(output.path)")
    }

    #if DEBUG
    static func runAnonymous() async -> Bool {
        let services: [AiUsageService] = [.claude, .claudeAPI, .gemini, .colab, .muse]
        var signedOutCount = 0
        for service in services {
            for attempt in 1...2 {
                var evidence: [String] = []
                let result = await AiUsageWebReader().readAnonymously(service) { observation in
                    switch observation {
                    case .document(let status, let mimeType):
                        evidence.append("robots=\(status) \(mimeType)")
                    case .fetch(let status, let type, let html, let truncated):
                        evidence.append("fetch=\(status) type=\(type) html=\(html) truncated=\(truncated)")
                    case .redirect:
                        evidence.append("robotsRedirect=true")
                    case .preventedWrite:
                        evidence.append("writePrevented=true")
                    case .navigationFailure(let domain, let code):
                        evidence.append("navigationFailure=\(domain):\(code)")
                    }
                }
                let status: String = switch result {
                case .signedOut: "signedOut"
                case .failure(let reason): String(describing: reason)
                case .success: "unexpectedSignedIn"
                }
                print("AI Usage anonymous: service=\(service.rawValue) attempt=\(attempt) result=\(status) \(evidence.joined(separator: " "))")
                if result == .signedOut {
                    signedOutCount += 1
                    break
                }
            }
        }
        let passed = signedOutCount == services.count
        print("\(passed ? "PASS" : "FAIL") AI Usage anonymous: \(signedOutCount)/\(services.count) signedOut")
        return passed
    }
    #endif

    private final class Checks {
        private(set) var count = 0
        func check(_ pass: @autoclosure () throws -> Bool, _ label: String) throws {
            guard try pass() else { throw LibraryError.message("AI Usage: " + label) }
            count += 1
            print("PASS AI Usage: " + label)
        }

        func rejects(_ label: String, failure: AiUsageFailure = .changed, _ read: () throws -> Void) throws {
            do { try read() }
            catch let error as AiUsageFailure {
                try check(error == failure, label)
                return
            }
            try check(false, label)
        }
    }

    private static func parsers(_ t: Checks) throws {
        func codexJSON(_ text: String) throws -> CodexJSONValue {
            try JSONDecoder().decode(CodexJSONValue.self, from: Data(text.utf8))
        }
        let account = try codexJSON(#"{"account":{"type":"chatgpt","planType":"prolite"}}"#)
        try t.check(try AiUsageParsers.codexAccount(account)?["type"] == .string("chatgpt"), "Codex explicit account object")
        try t.check(try AiUsageParsers.codexAccount(codexJSON(#"{"account":null}"#)) == nil, "Codex null account is signed out")
        for text in ["{}", #"{"account":false}"#] {
            try t.rejects("Codex missing or invalid account is a format error") { _ = try AiUsageParsers.codexAccount(codexJSON(text)) }
        }
        let codex = try AiUsageParsers.codex(codexJSON("""
            {"rateLimits":{"primary":{"usedPercent":41,"windowDurationMins":10080,"resetsAt":1796000000},
                "credits":{"balance":"12345.6789"}},
             "rateLimitsByLimitId":{
                "codex_model":{"limitName":"Example model","primary":{"usedPercent":73,"windowDurationMins":300}},
                "codex":{"primary":{"usedPercent":41,"windowDurationMins":10080,"resetsAt":1796000000}}}}
            """), account: AiUsageParsers.codexAccount(account) ?? [:])
        try t.check(codex.plan == "Pro Lite" && codex.windows.map(\.kind) == [.weekly, .session], "Codex weekly primary and ordinary bucket first")
        try t.check(codex.windows[1].model == "Example model" && codex.windows[0].resetsAt == Date(timeIntervalSince1970: 1_796_000_000), "Codex model name and Unix reset")
        try t.check(codex.balances.first?.value == .amount(Decimal(string: "12345.6789")!), "Codex credit count at full precision")
        for (body, expected) in [
            (#"{"balance":42.5}"#, AiUsageBalance.Value.amount(42.5)),
            (#"{"balance":"lots"}"#, .unreadable), (#"{"balance":true}"#, .unreadable),
            (#"{"hasCredits":true}"#, .unreadable), (#"{"unlimited":true,"balance":null}"#, .unlimited)
        ] {
            let text = #"{"rateLimits":{"primary":{"usedPercent":5,"windowDurationMins":10080},"credits":"# + body + "}}"
            let value = try AiUsageParsers.codex(codexJSON(text))
            try t.check(value.windows.count == 1 && value.balances.first?.value == expected, "Codex credits \(expected) keep usage windows")
        }
        let bucketCredits = try AiUsageParsers.codex(codexJSON("""
            {"rateLimits":{},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":5},"credits":{"balance":25}}}}
            """))
        try t.check(bucketCredits.balances.first?.value == .amount(25), "Codex credits fall back to ordinary bucket")
        let absent = try AiUsageParsers.codex(codexJSON(#"{"rateLimits":{"primary":{"usedPercent":0},"credits":{"hasCredits":false,"balance":null}}}"#))
        try t.check(absent.balances.isEmpty && absent.windows.first?.percent == 0, "Codex missing balance adds no row and explicit 0% survives")
        for text in [#"{"rateLimits":{"primary":null}}"#, #"{"rateLimits":{"primary":{"usedPercent":5,"resetsAt":99999999999999}}}"#] {
            try t.rejects("Codex empty windows or impossible reset") { _ = try AiUsageParsers.codex(codexJSON(text)) }
        }

        let organizations = #"""
        [{"uuid":"0000000a-0000-4000-8000-000000000001","capabilities":["api"]},
         {"uuid":"0000000A-0000-4000-8000-000000000001","capabilities":["api"]},
         {"uuid":"../invalid","capabilities":["chat","api"]},
         {"uuid":"0000000b-0000-4000-8000-000000000002","capabilities":["chat"],"rate_limit_tier":"default_claude_max_5x"}]
        """#
        let chatOrg = try AiUsageParsers.claudeOrganization(AiUsageParsers.json(organizations), console: false)
        let apiOrg = try AiUsageParsers.claudeOrganization(AiUsageParsers.json(organizations), console: true)
        try t.check(chatOrg.id == "0000000b-0000-4000-8000-000000000002" && chatOrg.plan == "Max 5x", "Claude validates UUID and selects chat tier")
        try t.check(apiOrg.id == "0000000a-0000-4000-8000-000000000001", "Console deduplicates UUID case and skips unusable organizations")
        try t.rejects("Console refuses more than one API organization", failure: .ambiguous) {
            _ = try AiUsageParsers.claudeOrganization(AiUsageParsers.json(organizations.replacingOccurrences(of: #""chat"],"#, with: #""api"],"#)), console: true)
        }
        try t.rejects("Claude rejects a UUID containing a path", failure: .unavailable) {
            _ = try AiUsageParsers.claudeOrganization(AiUsageParsers.json(#"[{"uuid":"../invalid","capabilities":["chat"]}]"#), console: false)
        }
        let claude = try AiUsageParsers.claude(AiUsageParsers.json("""
            {"limits":[{"kind":"session","percent":28,"resets_at":"2026-12-18T02:00:00.126177+00:00"},
                {"kind":"weekly_all","percent":44},
                {"kind":"weekly_scoped","percent":86,"scope":{"model":{"display_name":"Fable"}}}]}
            """), plan: chatOrg.plan)
        try t.check(claude.plan == "Max 5x" && claude.windows.map(\.kind) == [.session,.weekly,.weekly], "Claude modern windows and plan")
        try t.check(claude.windows[2].model == "Fable" && claude.windows[0].resetsAt != nil, "Claude Fable and fractional-second reset")
        let legacy = try AiUsageParsers.claude(AiUsageParsers.json(#"{"five_hour":{"utilization":12.5},"seven_day":{"utilization":140},"seven_day_opus":{"utilization":7}}"#), plan: nil)
        try t.check(legacy.windows.map(\.percent) == [12.5, 100, 7] && legacy.windows.last?.model == "Opus", "Claude legacy windows and over-limit value")
        for body in [#"{"limits":[]}"#, #"{"five_hour":{"utilization":false}}"#, #"{"limits":[{"kind":"session","percent":-1}]}"#] {
            try t.rejects("Claude missing, Boolean or invalid usage is unreadable") {
                _ = try AiUsageParsers.claude(AiUsageParsers.json(body), plan: nil)
            }
        }

        func credits(_ body: String) throws -> [AiUsageBalance] {
            try AiUsageParsers.claudeCredits(AiUsageParsers.json(body)).balances
        }
        let balances = try credits("""
            {"currency":"USD","promo_tranches":[
              {"name":"API credit (Max)","remaining":{"credits":{"amount_minor":5000,"exponent":2}},"expires_at":"2026-12-12T00:00:00Z"}],
             "tranches":[
              {"remaining":{"money":{"currency":"USD","amount_minor":1220,"exponent":2}},"expires_at":"2026-12-24T00:00:00Z"},
              {"remaining":{"credits":{"amount_minor":134,"exponent":2}},"expires_at":"2026-12-24T00:00:00Z"},
              {"remaining":{"credits":{"amount_minor":1,"exponent":4}},"expires_at":"2027-01-15T00:00:00Z"}]}
            """)
        try t.check(balances.map(\.kind) == [.planCredit,.purchasedCredit,.purchasedCredit] && balances[0].label == "API credit (Max)", "Console separates plan grants and purchases by expiry")
        try t.check(balances.map(\.value) == [.amount(50), .amount(Decimal(string: "13.54")!), .amount(Decimal(string: "0.0001")!)] && balances.allSatisfy { $0.expiresAt != nil }, "Console exponent, exact amount and grouping")
        try t.check(try credits(#"{"balance":{"credits":{"amount_minor":0,"exponent":2}},"tranches":[]}"#).first?.value == .amount(0), "Console explicit zero without tranches")
        for body in [
            #"{"balance":{"credits":{"amount_minor":1500,"exponent":2}},"tranches":[]}"#,
            #"{"currency":"USD"}"#, #"{"promo_tranches":{}}"#,
            #"{"promo_tranches":[{"remaining":{"credits":{"amount_minor":100,"exponent":2}}},{"remaining":{}}]}"#,
            #"{"currency":"EUR","balance":{"credits":{"amount_minor":0,"exponent":2}}}"#,
            #"{"tranches":[{"currency":"JPY","remaining":{"credits":{"amount_minor":100,"exponent":0}}}]}"#,
            #"{"tranches":[{"remaining":{"money":{"currency":"EUR","amount_minor":100,"exponent":2}}}]}"#,
            #"{"tranches":[{"remaining_amount_minor_units":100,"currency":"USD"}]}"#
        ] {
            try t.rejects("Console refuses unknown, incomplete or non-USD credit details") { _ = try credits(body) }
        }
        for value in ["null", "\"2\"", "false", "1.5", "2.0", "2e0", "-1", "7"] {
            try t.rejects("Console refuses invalid exponent \(value)") {
                _ = try credits(#"{"tranches":[{"remaining":{"credits":{"amount_minor":10,"exponent":"# + value + "}}}]}")
            }
        }
        for value in ["null", "\"20\"", "false", "1.5", "2.000000000000000001", "-1", "1000000000000"] {
            try t.rejects("Console refuses invalid minor amount \(value)") {
                _ = try credits(#"{"tranches":[{"remaining":{"credits":{"exponent":2,"amount_minor":"# + value + "}}}]}")
            }
        }

        let geminiText = #"""
        [{"data":{"viewer":{"rpcs":{"getUsageInfo":{"subscriptionTier":"TIER1","pools":[
          {"poolType":"GXU_WEEKLY","percentageUsed":0.25,"gxu":{"windowRefreshesAt":"2026-12-23T05:45:14.306471Z"}},
          {"poolType":"GXU_FIVE_HOURLY","percentageUsed":0}]}}}}}]
        """#
        let gemini = try AiUsageParsers.gemini(")]}'\n" + geminiText)
        try t.check(gemini?.plan == "Pro" && gemini?.windows.map(\.percent) == [0,25], "Gemini XSSI, sorted pools, 0.25 fraction and explicit zero")
        try t.check(try AiUsageParsers.gemini(#"[{"data":{"viewer":null},"errors":[{"message":"example"}]}]"#) == nil, "Gemini null viewer is signed out")
        for body in ["<html></html>", #"{"data":{}}"#, #"{"data":{"viewer":{"rpcs":{}}}}"#, geminiText.replacingOccurrences(of: "0.25", with: "-0.5")] {
            try t.rejects("Gemini HTML, missing or negative data is unreadable") { _ = try AiUsageParsers.gemini(body) }
        }

        let colab = try AiUsageParsers.colab(")]}'\n" + #"{"currentBalance":87.6543,"consumptionRateHourly":0}"#)
        try t.check(colab.balances.first?.value == .units(87.6543) && colab.balances.first?.perHour == 0, "Colab preserves precision and true zero rate")
        let tiny = try AiUsageParsers.colab(#"{"currentBalance":1e-30,"consumptionRateHourly":0.004}"#)
        try t.check(tiny.balances.first?.value == .units(1e-30) && tiny.balances.first?.perHour == 0.004, "Colab retains very small positive balance and rate")
        for body in [#"{"currentBalance":2}"#, #"{"currentBalance":2,"consumptionRateHourly":"fast"}"#, #"{"currentBalance":2,"consumptionRateHourly":-1}"#] {
            try t.check(try AiUsageParsers.colab(body).balances.first?.perHour == nil, "Colab unknown hourly rate stays unknown")
        }
        for body in [#"{"currentBalance":-1}"#, #"{"currentBalance":true}"#, "<html></html>"] {
            try t.rejects("Colab invalid or HTML balance is unreadable") { _ = try AiUsageParsers.colab(body) }
        }

        let museText = "0:{\"a\":\"$@1\"}\n" + #"1:{"success":true,"subscription":{"usage":{"percentUsed":9,"resetsAt":1796000000},"tier":{"name":"Plus"}}}"#
        let muse = try AiUsageParsers.muse(museText)
        try t.check(muse.plan == "Plus" && muse.windows.first?.kind == .weekly && muse.windows.first?.percent == 9, "Muse Flight action, weekly usage and plan")
        for value in [#"1:{"success":false}"#, museText.replacingOccurrences(of: #""percentUsed":9"#, with: #""percentUsed":-3"#)] {
            try t.rejects("Muse failed action or negative percent") { _ = try AiUsageParsers.muse(value) }
        }
        let scripts = AiUsageWebReader.museChunkPaths(#"<script src="/_next/static/chunks/a.js"></script> static/immutable/chunks/b.js static/chunks/a.js"#, limit: 10)
        try t.check(scripts == ["/_next/static/chunks/a.js", "/_next/static/immutable/chunks/b.js"], "Muse recognizes both chunk directories and deduplicates")
        try t.check(AiUsageWebReader.museSettingsModule("e.A(765).then(({preloadSettings})=>X)") == "765", "Muse detects settings module")
        try t.check(AiUsageWebReader.museLoaderPaths(",765,e=>{e.v(t=>Promise.all([\"static/immutable/chunks/settings.js\"]", module: "765") == ["/_next/static/immutable/chunks/settings.js"], "Muse extracts settings loader paths")
        let fixtureID = String(repeating: "a", count: 40)
        try t.check(AiUsageWebReader.museActionID("createServerReference(\"\(fixtureID)\",e,0,\"fetchSubscriptionAction\")") == fixtureID, "Muse extracts a validated action ID")

        func web(_ code: Int, _ body: String, type: String = "basic", truncated: Bool = false, colab: Bool = false, billing: Bool = false) -> AiUsageResult? {
            AiUsageWebReader.classify(.init(status: code, type: type, body: body, truncated: truncated, bytes: body.utf8.count), colab: colab, billing: billing)
        }
        try t.check(web(403, #"{"error":{"type":"permission_error"}}"#) == .signedOut, "JSON 403 explicitly signs out")
        try t.check(web(401, #"{"error":"Authentication required"}"#) == .signedOut, "Muse JSON 401 explicitly signs out")
        try t.check(web(403, #"{"error":"permission denied"}"#, billing: true) == .failure(.noAccess) && web(401, "<html>", billing: true) == .failure(.noAccess), "Console billing refusal after account discovery")
        try t.check(web(401, "<html>", colab: true) == .signedOut && web(403, "<html>", colab: true) == .failure(.blocked), "Only Colab 401 HTML is signed out")
        for (status, body) in [(200, "<!doctype html>"), (401, "<html>"), (403, "denied"), (302, ""), (403, #"{"error":false}"#)] {
            try t.check(web(status, body) == .failure(.blocked), "HTML, redirect or unrecognized HTTP \(status) is an error")
        }
        try t.check(web(0, "", type: "opaqueredirect") == .failure(.blocked), "Manual redirect stays an error")
        try t.check(web(401, #"{"error":"partial"}"#, truncated: true, colab: true) == .failure(.changed), "A cut-off response never signs out")
        try t.check(web(200, "{}") == nil && web(503, "{}") == .failure(.unavailable), "Complete 200 proceeds and 503 fails")
    }

    private static func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw AiUsageFailure.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor
    private final class ReadFixture {
        var result = AiUsageResult.failure(.unavailable)
        var signedOut = false
    }

    private static func service(_ t: Checks) async throws {
        let quota = AiUsageReading(plan: "Sample", windows: [.init(percent: 42, minutes: 300)])
        let balance = AiUsageReading(balances: [.init(kind: .computeUnits, value: .units(45.6))])
        var now = Date(timeIntervalSince1970: 1_796_000_000)
        var calls: [AiUsageService: Int] = [:]
        let response = ReadFixture()
        response.result = .success(quota)
        let store = AiUsageStore(reader: { id in
            calls[id, default: 0] += 1
            return id == .gemini ? .signedOut : response.result
        }, now: { now })
        try t.check(calls.isEmpty, "No reads at creation")
        store.refresh(AiUsageService.allCases)
        store.refresh(AiUsageService.allCases, force: true)
        try await until { !store.snapshots.values.contains(where: \.refreshing) }
        try t.check(calls.count == 6 && calls.values.allSatisfy { $0 == 1 }, "First reads and same-generation joins")
        store.refresh(AiUsageService.allCases)
        try t.check(!store.snapshots.values.contains(where: \.refreshing), "Reuses recent values")
        now += 121
        response.result = .failure(.network)
        store.refresh(AiUsageService.allCases)
        try t.check(!store.snapshot(.gemini).refreshing, "Signed-out state reused beyond two minutes")
        try await until { !store.snapshots.values.contains(where: \.refreshing) }
        try t.check(store.snapshot(.claude).reading == quota && store.snapshot(.claude).stale &&
                    store.snapshot(.claude).fetchedAt == now - 121, "Error preserves previous data and fetch time")
        try t.check(calls[.codex] == 2 && calls[.gemini] == 1, "Failure and signed-out result are independent")
        now += 1680
        store.refresh([.gemini])
        try await until { !store.snapshot(.gemini).refreshing }
        try t.check(calls[.gemini] == 2, "Rechecks signed-out state after thirty minutes")
        store.refresh([.gemini], force: true)
        try await until { !store.snapshot(.gemini).refreshing }
        try t.check(calls[.gemini] == 3 && calls[.codex] == 2, "Forced refresh reads only requested service")

        var fresh = AiUsageSnapshot()
        fresh.apply(.failure(.changed), at: now)
        try t.check(fresh.reading == nil && !fresh.stale, "First failure creates neither a bar nor zero balance")
        fresh.apply(.success(balance), at: now)
        fresh.apply(.failure(.timeout), at: now)
        try t.check(fresh.stale && fresh.reading == balance, "Balance survives a transient error")
        fresh.apply(.signedOut, at: now)
        try t.check(fresh.reading == nil && fresh.fetchedAt == nil && !fresh.stale, "Explicit sign-out removes stale data")

        var first: CheckedContinuation<AiUsageResult, Never>?
        var reads = 0
        var oldReadReturned = false
        let race = AiUsageStore(reader: { _ in
            reads += 1
            if reads == 1 {
                let result = await withCheckedContinuation { first = $0 }
                oldReadReturned = true
                return result
            }
            return .success(.init(plan: "New"))
        })
        race.refresh([.claude])
        try await until { first != nil }
        race.beginAccountChange(.claude)
        race.endAccountChange(.claude)
        try await until { race.snapshot(.claude).reading?.plan == "New" }
        first?.resume(returning: .success(.init(plan: "Old")))
        try await until { oldReadReturned }
        try t.check(reads == 2 && race.snapshot(.claude).reading?.plan == "New", "Old generation discarded even if its response finishes after the new one")

        var clearing: CheckedContinuation<Void, Error>?
        var oldColab: CheckedContinuation<AiUsageResult, Never>?
        var googleReads: [AiUsageService: Int] = [:]
        let account = ReadFixture()
        let google = AiUsageStore(reader: { id in
            googleReads[id, default: 0] += 1
            if id == .colab && googleReads[id] == 2 { return await withCheckedContinuation { oldColab = $0 } }
            if account.signedOut { return .signedOut }
            return .success(id == .colab ? balance : quota)
        })
        google.refresh([.gemini, .colab])
        try await until { google.snapshot(.colab).reading == balance && google.snapshot(.gemini).reading == quota }
        google.refresh([.colab], force: true)
        try await until { oldColab != nil }
        var notifications: [[AiUsageService: AiUsageSnapshot]] = []
        let subscription = google.$snapshots.dropFirst().sink { notifications.append($0) }
        let hold = Task {
            try await google.signOut(.gemini) {
                try await withCheckedThrowingContinuation { clearing = $0 }
            }
        }
        try await until { clearing != nil }
        try t.check(google.snapshot(.colab).reading == nil && google.snapshot(.gemini).reading == nil &&
                    google.isChangingAccount(.colab), "Gemini sign-out atomically clears both services")
        oldColab?.resume(returning: .success(balance))
        do { try await google.signOut(.gemini) { throw CancellationError() } }
        catch is CancellationError {}
        google.refresh([.gemini, .colab], force: true)
        await Task.yield()
        try t.check(googleReads == [.gemini: 1, .colab: 2] && google.isChangingAccount(.colab), "Overlapping cancellation leaves the first hold in effect")
        account.signedOut = true
        clearing?.resume()
        try await hold.value
        try await until { google.snapshot(.gemini).status == .signedOut && google.snapshot(.colab).status == .signedOut }
        try t.check(googleReads == [.gemini: 2, .colab: 3], "Sign-out completion rereads both shared services")
        try t.check(notifications.allSatisfy { $0[.colab]?.reading == nil && $0[.gemini]?.reading == nil }, "No notification leaks old Gemini or Colab data")
        subscription.cancel()

        account.signedOut = false
        google.refresh([.gemini, .colab], force: true)
        try await until { google.snapshot(.colab).reading == balance && google.snapshot(.gemini).reading == quota }
        google.beginAccountChange(.gemini)
        notifications.removeAll()
        let afterSignIn = google.$snapshots.dropFirst().sink { notifications.append($0) }
        google.endAccountChange(.gemini)
        try t.check(notifications.count == 1 && notifications[0][.colab]?.refreshing == true &&
                    notifications[0][.gemini]?.refreshing == true && notifications[0][.colab]?.reading == nil,
                    "Completing sign-in starts both new reads in a single notification")
        try await until { !google.snapshots.values.contains(where: \.refreshing) }
        afterSignIn.cancel()
        do { try await google.signOut(.gemini) { throw AiUsageFailure.network } }
        catch AiUsageFailure.network {}
        try await until { !google.snapshots.values.contains(where: \.refreshing) }
        try t.check(googleReads == [.gemini: 5, .colab: 6] && google.snapshot(.colab).reading == balance, "Failed sign-out rereads the actual account")
        do {
            try await google.signOut(.colab) { try t.check(false, "Colab clear must never run") }
            try t.check(false, "Colab has no sign-out")
        } catch AiUsageFailure.unavailable {
            try t.check(true, "Colab has no sign-out of its own")
        }
    }

    private static func webKit(_ t: Checks) async throws {
        let owners = [.claude, .claudeAPI, .gemini, .muse] as [AiUsageService]
        try t.check(Set(owners.compactMap(AiUsageWebProfiles.identifier)).count == 4 &&
                    AiUsageWebProfiles.identifier(for: .gemini) == AiUsageWebProfiles.identifier(for: .colab),
                    "Four distinct persistent profiles, with Google shared")
        let robots = URL(string: "https://fixture.invalid/robots.txt")!
        try t.check(AiUsageWebSession.permitsRobotsNavigation(robots, targetIsMainFrame: true, robots: robots) &&
                    !AiUsageWebSession.permitsRobotsNavigation(robots, targetIsMainFrame: false, robots: robots) &&
                    !AiUsageWebSession.permitsRobotsNavigation(URL(string: "https://fixture.invalid/other"), targetIsMainFrame: true, robots: robots) &&
                    !AiUsageWebSession.permitsRobotsNavigation(URL(string: "https://different.invalid/robots.txt"), targetIsMainFrame: true, robots: robots),
                    "Only exact robots document can navigate in the hidden view")
        try t.check(AiUsageWebSession.validPath("/test?q=one") && !AiUsageWebSession.validPath("//other.invalid") &&
                    !AiUsageWebSession.validPath("/\\other.invalid") && !AiUsageWebSession.validPath("/\nother"), "Cross-origin and malformed request paths refused")
        try t.check(AiUsageWebReader.expectedHost("accounts.google.com", for: .gemini) &&
                    AiUsageWebReader.expectedHost("login.microsoftonline.com", for: .claudeAPI) &&
                    !AiUsageWebReader.expectedHost("claude.ai.fixture.invalid", for: .claude) &&
                    !AiUsageWebReader.expectedHost("badmuse.ai", for: .muse),
                    "Sign-in host allowlist handles identity providers and lookalikes")

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let world = WKContentWorld.world(name: "HoverPocket.AiUsage.Verify")
        webView.loadHTMLString("<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'\"><p>Offline fixture</p>", baseURL: robots)
        try await until { !webView.isLoading && webView.url == robots }
        _ = try await webView.callAsyncJavaScript(
            #"""
            globalThis.fetch = async (url, options) => {
                if (options.credentials !== "include" || options.mode !== "same-origin" ||
                    options.redirect !== "manual" || options.cache !== "no-store") throw new Error("options");
                if (url.pathname === "/post" && (options.method !== "POST" || options.body !== "fixture")) throw new Error("arguments");
                return new Response(url.pathname === "/large" ? "é".repeat(600) : '{"ok":1}');
            };
            return true;
            """#, arguments: [:], in: nil, contentWorld: world
        )
        func fetch(_ paths: [String], method: String = "GET", cap: Int) async throws -> [AiUsageWebResponse] {
            let raw = try await webView.callAsyncJavaScript(AiUsageWebSession.fetchScript, arguments: [
                "origin": "https://fixture.invalid", "paths": paths, "method": method, "headers": [:],
                "payload": "fixture", "cap": cap
            ], in: nil, contentWorld: world)
            guard let text = raw as? String else { throw AiUsageFailure.changed }
            return try JSONDecoder().decode([AiUsageWebResponse].self, from: Data(text.utf8))
        }
        let first = try await fetch(["/one"], cap: 1000)
        let second = try await fetch(["/post"], method: "POST", cap: 1000)
        try t.check(first.first?.body == #"{"ok":1}"# && second.first?.body == first.first?.body,
                    "WebKit runs two consecutive production evaluations with page JavaScript disabled")
        let capped = try await fetch(["/large", "/one"], cap: 1000)
        try t.check(capped.count == 2 && capped[0].truncated && capped[0].bytes == 1000 && capped[0].body.count == 500 &&
                    !capped[1].truncated, "WebKit caps streamed bytes per response and reports truncation")
    }

    private static func robotsResponses(_ t: Checks) async throws {
        let allowed = URL(string: "https://fixture.invalid/login")
        try t.check(AiUsageSignInNavigation.allows(allowed, isMainFrame: true), "HTTPS is allowed at the top level of sign-in and popups")
        for raw in ["about:blank", "about:srcdoc", "data:text/html,fixture", "blob:https://fixture.invalid/id", "http://fixture.invalid/"] {
            let url = URL(string: raw)
            try t.check(AiUsageSignInNavigation.allows(url, isMainFrame: false) &&
                        !AiUsageSignInNavigation.allows(url, isMainFrame: true),
                        "Sign-in only restricts the top-level navigation for \(raw)")
        }

        let fixture = try RobotsFixture()
        defer { fixture.listener.cancel() }
        try await until { fixture.port != nil }
        guard let port = fixture.port,
              let robots = URL(string: "http://127.0.0.1:\(port)/robots.txt"),
              let redirect = URL(string: "http://127.0.0.1:\(port)/redirect/robots.txt")
        else { throw AiUsageFailure.unavailable }

        var bootstrapStatus: Int?
        var bootstrapMIME: String?
        var writePrevented = false
        let session = AiUsageWebSession(robots: robots, store: .nonPersistent(), readOnly: true)
        session.observe = { observation in
            switch observation {
            case .document(let status, let mimeType):
                bootstrapStatus = status
                bootstrapMIME = mimeType
            case .preventedWrite:
                writePrevented = true
            default:
                break
            }
        }
        try await session.open()
        try t.check(bootstrapStatus == 403 && bootstrapMIME == "text/html", "Hidden WebKit opens an exact robots document with HTTP 403 text/html")
        let first = try await session.fetch("/first")
        let second = try await session.fetch("/second")
        try t.check(first.status == 200 && first.body == #"{"scriptRan":false}"# &&
                    second.status == 200 && second.body == first.body,
                    "Production fetch works twice after 403 with page JavaScript disabled")
        do {
            _ = try await session.fetch("/first", method: "POST")
            try t.check(false, "Read-only WebKit must refuse POST")
        } catch AiUsageFailure.blocked {
            try t.check(writePrevented, "Read-only WebKit refuses POST before evaluation")
        }

        let redirected = AiUsageWebSession(robots: redirect, store: .nonPersistent())
        do {
            try await redirected.open()
            try t.check(false, "Redirected robots navigation must fail")
        } catch AiUsageFailure.blocked {
            try t.check(true, "A robots redirect to another URL is blocked")
        }
        do {
            _ = try await redirected.fetch("/first")
            try t.check(false, "A rejected document must never allow fetch")
        } catch AiUsageFailure.blocked {
            try t.check(true, "No fetch can use a rejected navigation")
        }
    }

    // This in-process fixture binds only to loopback and serves fixed responses.
    @MainActor
    private final class RobotsFixture {
        let listener: NWListener
        private(set) var port: UInt16?

        init() throws {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { connection in
                connection.start(queue: .main)
                Self.receive(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard case .ready = state else { return }
                MainActor.assumeIsolated {
                    self?.port = self?.listener.port?.rawValue
                }
            }
            listener.start(queue: .main)
        }

        private nonisolated static func receive(_ connection: NWConnection, buffered: Data = Data()) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { chunk, _, complete, error in
                let request = buffered + (chunk ?? Data())
                guard error == nil, request.count <= 16_384 else { connection.cancel(); return }
                guard let text = String(data: request, encoding: .utf8), text.contains("\r\n\r\n") else {
                    if complete { connection.cancel() }
                    else { receive(connection, buffered: request) }
                    return
                }

                let status: String
                let headers: String
                let body: String
                switch text.split(separator: " ").dropFirst().first {
                case "/robots.txt":
                    status = "403 Forbidden"
                    headers = "Content-Type: text/html; charset=UTF-8\r\n"
                    body = #"<html><body>Fixture<script>document.cookie = "fixtureScriptRan=yes";</script></body></html>"#
                case "/redirect/robots.txt":
                    status = "302 Found"
                    headers = "Location: /different.txt\r\n"
                    body = ""
                case "/first", "/second":
                    status = "200 OK"
                    headers = "Content-Type: application/json\r\n"
                    body = #"{"scriptRan":\#(text.contains("fixtureScriptRan=yes"))}"#
                default:
                    status = "200 OK"
                    headers = "Content-Type: text/plain\r\n"
                    body = "Unexpected navigation"
                }
                let reply = "HTTP/1.1 \(status)\r\n\(headers)Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    private static func presentation(_ t: Checks, output: URL) async throws {
        let defaults = EphemeralAppSettingsDefaults()
        defaults.set(["timer", "calculator"], forKey: "providerOrder")
        let settings = AppSettings(defaults: defaults)
        let now = Date()
        let copy = AiUsageCopy(language: .japanese)
        let scenario = PresentationScenario(now: now)
        let sampleWindow = scenario.sampleWindow
        try verifyPresentationSettings(t, defaults: defaults, settings: settings)
        try verifyPresentationCopy(t, copy: copy, now: now, sampleWindow: sampleWindow)
        try verifyOrderAndLayout(t, defaults: defaults, settings: settings, now: now)

        let reader: AiUsageStore.Reader = { (service: AiUsageService) -> AiUsageResult in
            scenario.fixtureResult(for: service)
        }
        let fixture = AiUsageStore(reader: reader, now: { scenario.now })
        fixture.refresh(AiUsageService.allCases)
        try await waitForReadings(fixture)
        scenario.now = now.addingTimeInterval(30)
        fixture.refresh([AiUsageService.claude], force: true)
        try await waitForReadings(fixture)
        try verifyFreshReadings(t, fixture: fixture, now: now, latest: scenario.now, copy: copy)

        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let panel = AiUsagePanelView(settings: settings, usage: fixture, isActive: false, openSettings: {})
        let preview = panel.background(Color.black)
        let minimum: CGFloat = PanelLayout.manualSizeLimits().minimum.width - PanelLayout.surfaceSidePadding * 2
        try captureFreshPanels(t, preview: preview, panel: panel, output: output, minimum: minimum, now: now)
        try verifyNativeReordering(t, panel: panel)
        try verifyNumberTypography(t)

        scenario.showsFailures = true
        fixture.beginAccountChange(AiUsageService.muse)
        fixture.endAccountChange(AiUsageService.muse)
        let affected: [AiUsageService] = [.codex, .claude, .gemini]
        fixture.refresh(affected, force: true)
        try await waitForReadings(fixture)
        try verifyFailedReadings(t, fixture: fixture, copy: copy)
        let claude = panelService(AiUsageService.claude, in: fixture)
        let other = claude.windows(in: AiUsageColumn.other).map(claude.quota)
        try verifyMeterDetails(t, quotas: other, copy: copy, now: now)
        let quota = AiUsageQuota(window: sampleWindow)
        try verifyReadingOpacity(t, quota: quota, copy: copy, now: now)
        try verifySettingsAction(t, copy: copy)
        try verifyNarrowContent(t, quota: quota, copy: copy, now: now)
        try captureStatePanels(t, preview: preview, settings: settings, output: output, minimum: minimum)
        try verifySettingsImage(t, settings: settings, fixture: fixture, output: output)
        try verifyPanelImages(t, output: output, minimum: minimum)
        let services = AiUsageService.allCases.map { panelService($0, in: fixture) }
        try verifyPanelWidths(t, panel: panel, services: services, now: now, minimum: minimum)
    }

    private static func waitForReadings(_ fixture: AiUsageStore) async throws {
        try await until { !fixture.snapshots.values.contains(where: \AiUsageSnapshot.refreshing) }
    }

    private static func panelService(_ service: AiUsageService, in fixture: AiUsageStore) -> AiUsagePanelService {
        AiUsagePanelService(id: service, snapshot: fixture.snapshot(service), changingAccount: fixture.isChangingAccount(service))
    }

    private static func verifyPresentationSettings(
        _ t: Checks, defaults: EphemeralAppSettingsDefaults, settings: AppSettings
    ) throws {
        let existingTool = PluginManifest(id: .init(rawValue: "fixture-tool"), title: "Sample tool", symbolName: "square",
                                          defaultEnabled: true, requestedPermissions: [], refreshPolicy: .manual)
        let available = ProviderRegistry.builtIn.manifests + [existingTool]
        try t.check(settings.visibleManifests(available).last?.id == AiUsageProvider.pluginID,
                    "Existing provider order gains AI Usage after built-in and personal tools")
        settings.providerOrderRawValues = [AiUsageProvider.pluginID.rawValue, existingTool.id.rawValue]
        try t.check(settings.visibleManifests(available).first?.id == AiUsageProvider.pluginID,
                    "An explicit AI Usage position still takes priority")
        defaults.set(["muse", "../example"], forKey: "hiddenAiUsageServices")
        try t.check(AppSettings(defaults: defaults).hiddenAiUsageServices == [.muse], "Settings ignores unknown service identifiers")
        settings.hiddenAiUsageServices.insert(.gemini)
        try t.check(AppSettings(defaults: defaults).hiddenAiUsageServices == [.gemini], "Service visibility persists and reads back")
        settings.hiddenAiUsageServices = []
    }

    private static func verifyPresentationCopy(
        _ t: Checks, copy: AiUsageCopy, now: Date, sampleWindow: AiUsageWindow
    ) throws {
        try t.check(copy.windowLabel(sampleWindow) == "Fable" && copy.reset(sampleWindow.resetsAt, now: now) == "3日21時間"
                    && sampleWindow.column == .other && sampleWindow.resetsAt.map(copy.resetHelp)?.hasSuffix("にリセット") == true,
                    "Other quota has both its model name and reset countdown plus exact-date help")
        try t.check(copy.reset(now + 35 * 60, now: now) == "0:35" && copy.reset(now + 289 * 60, now: now) == "4:49"
                    && copy.reset(now + 3 * 86400, now: now) == "3日" && copy.reset(now, now: now) == "リセット済み"
                    && copy.reset(nil, now: now) == nil, "Short, long, overdue and unknown reset countdowns")
        let english = AiUsageCopy(language: .english)
        try t.check(english.reset(sampleWindow.resetsAt, now: now) == "3d 21h" &&
                    english.reset(now, now: now) == "Reset" && sampleWindow.resetsAt.map(english.resetHelp)?.hasPrefix("Resets ") == true,
                    "English reset copy and help")
        try t.check([0, 24.99, 25, 49.99, 50, 69.99, 70, 100].map(AiUsageTint.init(remaining:)) ==
                    [.red, .red, .yellow, .yellow, .green, .green, .blue, .blue], "Four color thresholds on remaining usage")
        try t.check(sampleWindow.remaining.map(copy.percent) == "24%" && copy.percent(94.9) == "94.9%" &&
                    AiUsageMeterView.angle(at: 0) == 135 && AiUsageMeterView.angle(at: 50) == 270 &&
                    AiUsageMeterView.angle(at: 100) == 405, "Remaining percentage formatting and clockwise angular range")
        try t.check(AiUsageWindow(percent: 55, minutes: 4320).column == .other &&
                    copy.windowLabel(.init(percent: 55, minutes: 4320)) == "3日" &&
                    AiUsageWindow(model: "Short", percent: 55, minutes: 300).column == .other,
                    "Named standard windows and unnamed nonstandard durations belong in Other")
        try t.check(copy.balanceValue(.init(kind: .planCredit, value: .amount(0.0001))) == "<$0.01" &&
                    copy.balanceValue(.init(kind: .computeUnits, value: .units(1e-30))) == "<0.1" &&
                    copy.balanceValue(.init(kind: .purchasedCredit, value: .amount(0))) == "$0.00", "Tiny positive balances and an explicit zero")
        try t.check(copy.balanceValue(.init(kind: .codexCredits, value: .unlimited)) == "無制限" &&
                    copy.balanceValue(.init(kind: .codexCredits, value: .unreadable)) == "読み取れません", "Credit states render without numbers")
        try t.check(copy.balanceDetail(.init(kind: .computeUnits, value: .units(8)), now: now) == "消費量は不明" &&
                    copy.balanceDetail(.init(kind: .computeUnits, value: .units(8), perHour: 0.004), now: now)?.contains("<0.01") == true,
                    "Unknown and tiny hourly consumption")
    }

    private static func verifyFreshReadings(
        _ t: Checks, fixture: AiUsageStore, now: Date, latest: Date, copy: AiUsageCopy
    ) throws {
        let fresh: [AiUsagePanelService] = AiUsageService.allCases.map { panelService($0, in: fixture) }
        let newest = fresh.compactMap(\AiUsagePanelService.updateDate).max()
        let otherServices = fresh.filter { $0.id != AiUsageService.claude }
        let newestWithoutClaude = otherServices.compactMap(\AiUsagePanelService.updateDate).max()
        try t.check(newest == latest && newestWithoutClaude == now,
                    "Header selects the newest successful visible reading")

        let codex = panelService(AiUsageService.codex, in: fixture)
        var oldSuccess = codex.snapshot
        oldSuccess.fetchedAt = now.addingTimeInterval(-86_400)
        let oldRow = AiUsagePanelService(id: AiUsageService.codex, snapshot: oldSuccess, changingAccount: false)
        let stillFresh = oldRow.staleDate == nil && !oldRow.snapshot.stale
        try t.check(oldRow.updateDate == oldSuccess.fetchedAt && stillFresh,
                    "Elapsed time alone neither dims a successful reading nor changes its update label")

        let limits = AiUsageSection.limits.visibleRows(fresh, in: AiUsageSection.limits.defaultOrder)
        let balances = AiUsageSection.balances.visibleRows(fresh, in: AiUsageSection.balances.defaultOrder)
        let tableRows = limits.map(\AiUsagePanelService.id)
        let balanceCards = balances.map(\AiUsagePanelService.id)
        try t.check(tableRows == AiUsageSection.limits.defaultOrder && balanceCards == AiUsageSection.balances.defaultOrder,
                    "Quota rows and balance cards use separate section membership, and Codex appears in both")
        let fixtureCodex = limits.first { $0.id == AiUsageService.codex }
        let separateCodex = balances.first { $0.id == AiUsageService.codex }
        let codexCredit = separateCodex.flatMap(AiUsagePanelBalance.init)
        try t.check(fixtureCodex?.orderedWindows.count == 2 && codexCredit?.unit == "CR",
                    "Codex exposes its usage windows and an independent credit card")

        let colab = panelService(AiUsageService.colab, in: fixture)
        let loadingSnapshot = AiUsageSnapshot(refreshing: true)
        let loading = AiUsagePanelService(id: AiUsageService.colab, snapshot: loadingSnapshot, changingAccount: false)
        let idle = AiUsagePanelService(id: AiUsageService.colab, snapshot: AiUsageSnapshot(), changingAccount: false)
        let loadingInBalances = loading.appears(in: .balances) && !loading.appears(in: .limits)
        try t.check(loadingInBalances && !idle.appears(in: .balances), "A balance-only service gets a card while checking")
        var signedOutSnapshot = AiUsageSnapshot()
        signedOutSnapshot.apply(.signedOut, at: now)
        let signedOutBalance = AiUsagePanelService(id: .claudeAPI, snapshot: signedOutSnapshot, changingAccount: false)
        try t.check(signedOutBalance.appears(in: .balances) && !signedOutBalance.appears(in: .limits),
                    "A signed-out balance-only service stays in the balance section")

        let claudeAPI = panelService(AiUsageService.claudeAPI, in: fixture)
        let api = AiUsagePanelBalance(claudeAPI)
        let apiHelp = api?.help(copy, now: now) ?? ""
        let hasBreakdown = apiHelp.contains("$57.25") && apiHelp.contains("$47.73")
        let expectedExpiry = now.addingTimeInterval(12 * 86_400)
        let apiValue = api.map { copy.balanceValue($0.total) }
        try t.check(apiValue == "$104.98" && api?.unit == nil && hasBreakdown && api?.total.expiresAt == expectedExpiry,
                    "Claude API adds the balances and retains both amounts and dates in help")
        let codexAmount = AiUsagePanelBalance(codex)
        let colabAmount = AiUsagePanelBalance(colab)
        let hasCodexUnits = codexAmount?.unit == "CR" && codexAmount.map { copy.balanceValue($0.total) } == "40,957"
        let hasColabUnits = colabAmount?.unit == "CU" && colabAmount.map { copy.balanceValue($0.total) } == "570.2"
        try t.check(hasCodexUnits && hasColabUnits, "Credit and unit values use independent CR and CU labels")
        try t.check(codexAmount?.meterDetail(copy, now: now) == "サブスクの枠を超えた分に使う",
                    "Codex credit card explains that credits are used after plan limits")
    }

    private static func verifyFailedReadings(_ t: Checks, fixture: AiUsageStore, copy: AiUsageCopy) throws {
        let geminiCanSignOut = AiUsageSettingsView.canSignOut(AiUsageService.gemini, usage: fixture)
        let colabCanSignOut = AiUsageSettingsView.canSignOut(AiUsageService.colab, usage: fixture)
        let codexCanSignOut = AiUsageSettingsView.canSignOut(AiUsageService.codex, usage: fixture)
        try t.check(geminiCanSignOut && !colabCanSignOut && !codexCanSignOut,
                    "Gemini can sign out when only Colab has a reading")

        let codex = panelService(AiUsageService.codex, in: fixture)
        let staleLabel = codex.snapshot.fetchedAt.map(copy.stale)
        let staleReason = codex.reason(copy) == copy.error(AiUsageFailure.network)
        let retainsReading = codex.snapshot.stale && staleLabel?.hasSuffix(" の値") == true
        try t.check(retainsReading && staleReason && codex.updateDate == nil,
                    "Stale data preserves its value and error, and is excluded from the update clock")
        let gemini = panelService(AiUsageService.gemini, in: fixture)
        let muse = panelService(AiUsageService.muse, in: fixture)
        let signedOutWithoutUpdate = gemini.emptyMessage(copy) == copy.signedOut && gemini.updateDate == nil
        let museError = muse.emptyMessage(copy) == copy.error(AiUsageFailure.changed)
        let museHasNoReading = muse.orderedWindows.isEmpty && muse.updateDate == nil
        try t.check(signedOutWithoutUpdate && museError && museHasNoReading,
                    "Signed-out and error states have reasons and no update clock or numeric reading")
        try t.check(gemini.appears(in: .limits) && muse.appears(in: .limits) && codex.appears(in: .limits),
                    "Signed-out, error-only and stale quota services remain listed")
    }

    private static func verifyMeterDetails(_ t: Checks, quotas: [AiUsageQuota], copy: AiUsageCopy, now: Date) throws {
        let unavailable = quotas.first
        let unavailableAccessibility = unavailable.map { copy.meterAccessibility($0, now: now) }
        let hidesReading = unavailable?.window.remaining == nil && unavailable?.resetText(copy, now: now) == nil
        try t.check(hidesReading && unavailable?.help(copy) == "Fable\n取得できません" &&
                    unavailableAccessibility == "Fable 取得できません",
                    "Unreadable meter has no value or reset line, and explains the state in help and accessibility")
        let longQuotas = Array(quotas.dropFirst())
        let names = longQuotas.map { $0.fullName(copy) }
        let hasFullLabels = longQuotas.allSatisfy { quota in
            let name = quota.fullName(copy)
            let help = quota.help(copy)
            let accessibility = copy.meterAccessibility(quota, now: now)
            return help.hasPrefix(name + "\n") && accessibility.hasPrefix(name + " ")
        }
        try t.check(names == ["GPT-5.3-Codex-Spark 5時間", "GPT-5.3-Codex-Spark 1週間"] && hasFullLabels,
                    "Duplicate quota names retain the full name and duration in help and accessibility")
        let details = longQuotas.map { $0.meterDetail(copy, now: now) }
        try t.check(details == ["5時間 · 4:49", "1週間 · 3日21時間"],
                    "The second meter line combines duplicate duration and remaining reset time")
        let unreadableWindow = AiUsageWindow(model: "GPT-5.3-Codex-Spark", percent: nil,
                                             resetsAt: now.addingTimeInterval(3600), minutes: 300)
        let unreadableDuplicate = AiUsageQuota(window: unreadableWindow, distinguishesDuration: true)
        let duplicateDetail = unreadableDuplicate.meterDetail(copy, now: now)
        let duplicateHelp = unreadableDuplicate.help(copy)
        try t.check(unavailable?.meterDetail(copy, now: now) == nil &&
                    duplicateDetail == "5時間" && duplicateHelp == "GPT-5.3-Codex-Spark 5時間\n取得できません",
                    "Unreadable duplicate meter shows only the duration on its second line")
    }

    private static func captureFreshPanels<V: View>(
        _ t: Checks, preview: V, panel: AiUsagePanelView, output: URL, minimum: CGFloat, now: Date
    ) throws {
        let claude = panelService(AiUsageService.claude, in: panel.usage)
        let listSize = NSSize(width: minimum, height: 470)
        let list = try capture(preview, size: listSize, appearance: NSAppearance.Name.darkAqua)
        try list.write(to: output.appendingPathComponent("list.png"), options: Data.WritingOptions.atomic)
        try verifyRowMetadata(t, panel: panel, service: claude, now: now, width: minimum)

        panel.settings.aiUsageLayout = AiUsageLayout.meter
        let meterSize = NSSize(width: 760, height: 510)
        let meter = try capture(preview, size: meterSize, appearance: NSAppearance.Name.darkAqua)
        try meter.write(to: output.appendingPathComponent("meter.png"), options: Data.WritingOptions.atomic)
        try verifyRowMetadata(t, panel: panel, service: claude, now: now, width: minimum)
    }

    private static func captureStatePanels<V: View>(
        _ t: Checks, preview: V, settings: AppSettings, output: URL, minimum: CGFloat
    ) throws {
        let meterSize = NSSize(width: minimum, height: 790)
        let states = try capture(preview, size: meterSize, appearance: NSAppearance.Name.darkAqua)
        try states.write(to: output.appendingPathComponent("meter-states.png"), options: Data.WritingOptions.atomic)
        settings.aiUsageLayout = AiUsageLayout.list
        try verifyPinnedListHeader(t, view: preview, width: minimum)
        let listSize = NSSize(width: minimum, height: 585)
        let listStates = try capture(preview, size: listSize, appearance: NSAppearance.Name.darkAqua)
        try listStates.write(to: output.appendingPathComponent("list-states.png"), options: Data.WritingOptions.atomic)
    }

    private static func verifySettingsImage(_ t: Checks, settings: AppSettings, fixture: AiUsageStore, output: URL) throws {
        let account = CodexVoiceAccountLoginController(contextProvider: { [] }, browserOpener: { _ in false }, credentialChangeHandler: {})
        let content = VStack(alignment: HorizontalAlignment.leading) {
            Text(SettingsCategory.ai.title(language: .japanese)).font(.title2.weight(.semibold))
            SettingsCard {
                AiUsageSettingsView(settings: settings, usage: fixture, codexAccount: account)
            }
        }.padding(24).frame(maxHeight: .infinity, alignment: .top)
            .background(Color(nsColor: NSColor.windowBackgroundColor))
        let size = NSSize(width: 680, height: 690)
        let settingsPNG = try capture(content, size: size, appearance: NSAppearance.Name.aqua)
        try t.check(NSBitmapImageRep(data: settingsPNG)?.pixelsWide ?? 0 > 0, "Settings still renders with the service order controls")
        try settingsPNG.write(to: output.appendingPathComponent("settings.png"), options: Data.WritingOptions.atomic)
    }

    private static func verifyPanelImages(_ t: Checks, output: URL, minimum: CGFloat) throws {
        for name in ["list", "meter", "meter-states", "list-states", "settings"] {
            let file = output.appendingPathComponent("\(name).png")
            let bitmap = try NSBitmapImageRep(data: Data(contentsOf: file))
            try t.check((bitmap?.pixelsWide ?? 0) >= Int(minimum), "Reopens the rendered \(name) PNG")
            if name != "settings" {
                let expected = name.hasSuffix("-states") ? Set([AiUsageTint.green, .yellow]) : Set(AiUsageTint.allCases)
                try t.check(bitmap.map(solidMeterColors) == expected, "\(name) renders the expected palette and dims stale values")
            }
        }
    }

    private static func verifyPanelWidths(
        _ t: Checks, panel: AiUsagePanelView, services: [AiUsagePanelService], now: Date, minimum: CGFloat
    ) throws {
        let settings = panel.settings
        for layout in AiUsageLayout.allCases {
            settings.aiUsageLayout = layout
            for size in PanelTextSizeOption.allCases {
                let content = panel.panelContent(services, now: now, width: minimum)
                    .environment(\.panelTextSize, size)
                let fitting = NSHostingController(rootView: content)
                    .sizeThatFits(in: CGSize(width: minimum, height: .greatestFiniteMagnitude))
                try t.check(fitting.width <= minimum + 0.5, "\(layout) content fits minimum width at \(size) text size")
            }
        }
    }

    private static func verifyPinnedListHeader<V: View>(_ t: Checks, view: V, width: CGFloat) throws {
        try withHostingView(view, size: NSSize(width: width, height: 155), appearance: .darkAqua) { host in
            @MainActor func findScrollView(_ view: NSView) -> NSScrollView? {
                if let scroll = view as? NSScrollView { return scroll }
                for child in view.subviews {
                    if let scroll = findScrollView(child) { return scroll }
                }
                return nil
            }
            guard let scroll = findScrollView(host), let document = scroll.documentView else {
                throw LibraryError.message("AI Usage: no native scroll view in list")
            }
            let clip = scroll.contentView
            let start = clip.bounds.origin
            try t.check(document.bounds.height > clip.bounds.height + 60, "Fixture has enough content to scroll")
            let before = try readBitmap(host)
            let end = CGPoint(x: start.x, y: start.y + (clip.isFlipped ? 60 : -60))
            clip.scroll(to: end)
            scroll.reflectScrolledClipView(clip)
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            let after = try readBitmap(host)
            let header = CGRect(x: 38, y: 34, width: width - 60, height: 40)
            let rows = CGRect(x: 14, y: 85, width: width - 28, height: 60)
            try t.check(abs(clip.bounds.minY - start.y) > 40 &&
                        samePixels(before, after, in: header) && !samePixels(before, after, in: rows),
                        "List column headings stay in place when rows scroll")
        }
    }

    private static func verifySettingsAction(_ t: Checks, copy: AiUsageCopy) throws {
        let proposal = CGSize(width: 320, height: 50)
        let bordered = NSHostingController(rootView: AiUsageSignedOutView(copy: copy, openSettings: {}).font(.system(size: 12)))
        let plain = NSHostingController(rootView: HStack(spacing: 6) {
            Text(copy.signedOut).foregroundStyle(.secondary)
            Button(copy.text("設定を開く", "Open Settings"), action: {}).buttonStyle(.borderless).controlSize(.small)
        }.font(.system(size: 12)))
        try t.check(bordered.sizeThatFits(in: proposal).width > plain.sizeThatFits(in: proposal).width + 4,
                    "Signed-out settings action uses a bordered button with its own padding")
    }

    private static func verifyReadingOpacity(_ t: Checks, quota: AiUsageQuota, copy: AiUsageCopy, now: Date) throws {
        func rendered<V: View>(_ view: V, size: NSSize) throws -> NSBitmapImageRep {
            try withHostingView(view.background(.black), size: size, appearance: .darkAqua, read: readBitmap)
        }
        let meterSize = NSSize(width: AiUsageMeterView.width, height: AiUsageMeterView.height)
        let freshMeter = try rendered(AiUsageMeterView(quota: quota, copy: copy, now: now), size: meterSize)
        let staleMeter = try rendered(AiUsageMeterView(quota: quota, copy: copy, now: now, readingOpacity: 0.5), size: meterSize)
        try t.check(samePixels(freshMeter, staleMeter, in: CGRect(x: 32, y: 69, width: 52, height: 37)) &&
                    !samePixels(freshMeter, staleMeter, in: CGRect(x: 35, y: 45, width: 46, height: 19)) &&
                    !samePixels(freshMeter, staleMeter, in: CGRect(x: 41, y: 1, width: 34, height: 13)),
                    "Stale meter dims the value and arcs while keeping the name and reset text at full brightness")
        let listSize = NSSize(width: 200, height: 36)
        let freshList = try rendered(AiUsageListQuotaView(quota: quota, copy: copy, now: now), size: listSize)
        let staleList = try rendered(AiUsageListQuotaView(quota: quota, copy: copy, now: now, readingOpacity: 0.5), size: listSize)
        try t.check(samePixels(freshList, staleList, in: CGRect(x: 0, y: 0, width: 24, height: 22)) &&
                    samePixels(freshList, staleList, in: CGRect(x: 147, y: 0, width: 53, height: 22)) &&
                    solidMeterColors(freshList) == [.red] && solidMeterColors(staleList).isEmpty,
                    "Stale list cell keeps its name and reset text at full brightness and dims the reading")
    }

    private static func samePixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, in rect: CGRect) -> Bool {
        let scale = CGFloat(a.pixelsWide) / a.size.width
        let pixels = rect.applying(CGAffineTransform(scaleX: scale, y: scale)).integral
        guard let first = a.cgImage?.cropping(to: pixels), let second = b.cgImage?.cropping(to: pixels) else { return false }
        return NSBitmapImageRep(cgImage: first).representation(using: .png, properties: [:]) ==
            NSBitmapImageRep(cgImage: second).representation(using: .png, properties: [:])
    }

    private static func verifyNarrowContent(_ t: Checks, quota: AiUsageQuota, copy: AiUsageCopy, now: Date) throws {
        func size<V: View>(_ view: V, width: CGFloat) -> CGSize {
            NSHostingController(rootView: view)
                .sizeThatFits(in: CGSize(width: width, height: 200))
        }
        let cell = AiUsageListQuotaView(quota: quota, copy: copy, now: now)
        let inline = size(cell, width: 160)
        let stacked = size(cell, width: 96)
        try t.check(stacked.width <= 96.5 && stacked.height >= inline.height + 10,
                    "A narrow quota cell moves the complete reset time below the bar")
        let reason = copy.error(.network)
        let text = AiUsageReasonText(message: reason)
        let wrapped = size(text, width: 125)
        let natural = size(Text(reason).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true), width: 125)
        try t.check(wrapped.height > size(text, width: 360).height && abs(wrapped.height - natural.height) < 0.5,
                    "Error text wraps to two lines at a narrow width without shortening it")
    }

    private static func verifyRowMetadata(_ t: Checks, panel: AiUsagePanelView, service: AiUsagePanelService, now: Date, width: CGFloat) throws {
        var alternate = service.snapshot
        alternate.reading?.plan = "Unrelated plan name"
        alternate.fetchedAt = now - 60
        let variant = AiUsagePanelService(id: service.id, snapshot: alternate, changingAccount: false)
        func render(_ row: AiUsagePanelService) throws -> Data {
            try capture(panel.panelContent([row], now: now, width: width).background(.black),
                        size: NSSize(width: width, height: 170), appearance: .darkAqua)
        }
        try t.check(try render(service) == render(variant), "Fresh service content omits its plan name and fetch time")
    }

    private static func solidMeterColors(_ bitmap: NSBitmapImageRep) -> Set<AiUsageTint> {
        guard let image = bitmap.cgImage, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: image.width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { return [] }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        var found = Set<AiUsageTint>()
        for y in stride(from: 0, to: image.height, by: 4) {
            for x in stride(from: 0, to: image.width, by: 4) {
                let pixel = bytes + y * context.bytesPerRow + x * 4
                for tint in AiUsageTint.allCases where !found.contains(tint) {
                    let hex = tint.rawValue
                    if abs(Int(pixel[0]) - Int(hex >> 16)) <= 3 &&
                        abs(Int(pixel[1]) - Int(hex >> 8 & 255)) <= 3 &&
                        abs(Int(pixel[2]) - Int(hex & 255)) <= 3 {
                        found.insert(tint)
                    }
                }
                if found.count == AiUsageTint.allCases.count { return found }
            }
        }
        return found
    }

    private static func verifyOrderAndLayout(_ t: Checks, defaults: EphemeralAppSettingsDefaults,
                                             settings: AppSettings, now: Date) throws {
        let limits: AiUsageSection = .limits
        let balances: AiUsageSection = .balances
        try t.check(settings.aiUsageLayout == .list && settings.aiUsageServiceOrder == limits.defaultOrder &&
                    settings.aiUsageBalanceOrder == balances.defaultOrder && settings.aiUsageSort == nil,
                    "Existing settings start in List and use the default order for each section")
        let malformed = EphemeralAppSettingsDefaults()
        malformed.set("unknown", forKey: "aiUsageLayout")
        malformed.set(["bogus", "muse", "claude-api", "muse", "codex"], forKey: "aiUsageServiceOrder")
        malformed.set(["colab", "colab", "muse", "invalid"], forKey: "aiUsageBalanceOrder")
        malformed.set(["weekly", "backwards"], forKey: "aiUsageSort")
        let repaired = AppSettings(defaults: malformed)
        let repairedLimits = repaired.aiUsageServiceOrder == [.muse, .codex, .claude, .gemini]
        let repairedBalances = repaired.aiUsageBalanceOrder == [.colab, .codex, .claudeAPI]
        try t.check(repaired.aiUsageLayout == .list && repaired.aiUsageSort == nil && repairedLimits && repairedBalances,
                    "Migration removes unknown, duplicate and out-of-section IDs and appends missing services")
        let legacy = EphemeralAppSettingsDefaults()
        legacy.set(["colab", "muse", "codex", "claude-api"], forKey: "aiUsageServiceOrder")
        let migrated = AppSettings(defaults: legacy)
        migrated.stepAiUsageService(.muse, in: .limits, by: 1)
        let restoredBalances = AppSettings(defaults: legacy).aiUsageBalanceOrder
        try t.check(restoredBalances == [.colab, .codex, .claudeAPI],
                    "Legacy balance order migrates once and is preserved after a limits move")
        try t.check(!settings.canStepAiUsageService(.codex, in: limits, by: -1) &&
                    settings.canStepAiUsageService(.codex, in: limits, by: 1) &&
                    settings.canStepAiUsageService(.muse, in: limits, by: -1) &&
                    !settings.canStepAiUsageService(.colab, in: balances, by: 1),
                    "Settings arrows disable only the outer moves of each section")
        settings.hiddenAiUsageServices = [.gemini]
        settings.stepAiUsageService(.muse, in: limits, by: -1)
        try t.check(settings.aiUsageServiceOrder == [.codex, .claude, .muse, .gemini] &&
                    settings.aiUsageBalanceOrder == balances.defaultOrder, "Settings Move up affects only limits")
        settings.stepAiUsageService(.muse, in: limits, by: 1)
        try t.check(settings.aiUsageServiceOrder == limits.defaultOrder, "Settings Move down restores the limits order")

        let reordering = AiUsageReordering()
        let item = AiUsageOrderItem(service: .codex, section: balances)
        let frames: [AiUsageService: CGRect] = [
            .codex: CGRect(x: 0, y: 0, width: 170, height: 80),
            .colab: CGRect(x: 180, y: 0, width: 170, height: 80)
        ]
        let target = CGPoint(x: 200, y: 40)
        reordering.begin(item, in: frames, settings: settings)
        reordering.move(item, to: target)
        let preview = reordering.order(in: balances, settings: settings)
        try t.check(preview == [.claudeAPI, .colab, .codex] && settings.aiUsageBalanceOrder == balances.defaultOrder,
                    "Pointer movement previews the new order without writing settings")
        reordering.move(item, to: CGPoint(x: 200, y: 160))
        try t.check(reordering.order(in: balances, settings: settings) == preview &&
                    reordering.order(in: limits, settings: settings) == limits.defaultOrder,
                    "Pointer targets outside the source section do not affect either preview order")
        reordering.cancel()
        try t.check(reordering.order(in: balances, settings: settings) == balances.defaultOrder,
                    "Cancellation restores the saved order")
        reordering.begin(item, in: frames, settings: settings)
        reordering.move(item, to: target)
        reordering.end(item, at: target, insideWindow: false, settings: settings)
        try t.check(settings.aiUsageBalanceOrder == balances.defaultOrder,
                    "Release outside the window restores the saved order")
        settings.aiUsageSort = AiUsageSort(column: .other, previous: nil)
        try t.check(!reordering.allowsMovement(in: limits, settings: settings) &&
                    reordering.allowsMovement(in: balances, settings: settings),
                    "List column sorting disables movement only for limits")
        reordering.begin(item, in: frames, settings: settings)
        reordering.end(item, at: target, insideWindow: true, settings: settings)
        settings.aiUsageLayout = .meter
        try t.check(reordering.allowsMovement(in: limits, settings: settings),
                    "The meter keeps manual limits order while a table sort is stored")
        let reloaded = AppSettings(defaults: defaults)
        try t.check(reloaded.aiUsageLayout == .meter && reloaded.aiUsageSort == settings.aiUsageSort &&
                    reloaded.aiUsageServiceOrder == limits.defaultOrder &&
                    reloaded.aiUsageBalanceOrder == preview && reloaded.hiddenAiUsageServices == [.gemini],
                    "Both layouts, both orders, hidden IDs and sort survive settings recreation")
        func sample(_ id: AiUsageService, _ values: [Double?]) -> AiUsagePanelService {
            var snapshot = AiUsageSnapshot()
            snapshot.apply(.success(.init(windows: values.map { .init(model: "Extra", percent: $0, minutes: 300) })), at: now)
            return .init(id: id, snapshot: snapshot, changingAccount: false)
        }
        let rows = [sample(.muse, [nil]), sample(.colab, [70]), sample(.codex, [95, 10]),
                    sample(.gemini, []), sample(.claude, [70])]
        let ascending = settings.aiUsageSort
        let descending = AiUsageSort(column: .other, previous: ascending)
        try t.check(AiUsagePanelService.sorted(rows, by: ascending).map(\.id) == [.codex, .colab, .claude, .muse, .gemini],
                    "Other sorts by minimum remaining with stable ties and missing values last")
        try t.check(AiUsagePanelService.sorted(rows, by: descending).map(\.id) == [.colab, .claude, .codex, .muse, .gemini] &&
                    AiUsageSort(column: .other, previous: descending).direction == .asc,
                    "Second press reverses the order and missing values remain last")
        try t.check(AiUsageSort(column: .weekly, previous: descending).direction == .asc &&
                    AiUsagePanelService.sorted(rows, by: nil).map(\.id) == rows.map(\.id),
                    "A new sort starts ascending and reset restores custom order")
        settings.saveAiUsageOrder(balances.defaultOrder, in: balances)
        settings.aiUsageLayout = .list
        settings.aiUsageSort = nil
        settings.hiddenAiUsageServices = []
    }

    private static func verifyNativeReordering(_ t: Checks, panel: AiUsagePanelView) throws {
        let settings = panel.settings
        let section: AiUsageSection = .balances
        let original = settings.aiUsageOrder(in: section)
        defer { settings.saveAiUsageOrder(original, in: section) }
        let preview = panel.background(Color.black)
        let size = NSSize(width: 760, height: 630)
        try withHostingView(preview, size: size, appearance: NSAppearance.Name.darkAqua) { host in
            guard let window = host.window else { throw LibraryError.message("AI Usage: missing fixture window") }
            let handles = reorderHandles(in: host)
            let source = handles.first { $0.item == AiUsageOrderItem(service: .codex, section: section) }
            let target = handles.first { $0.item == AiUsageOrderItem(service: .colab, section: section) }
            guard let source, let target, let item = source.item, let reordering = source.reordering else {
                throw LibraryError.message("AI Usage: missing native balance handles")
            }

            let origin = source.convert(CGPoint(x: source.bounds.midX, y: source.bounds.midY), to: nil)
            let destination = target.convert(CGPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
            let local = host.superview?.convert(origin, from: nil) ?? origin
            try t.check(host.hitTest(local) === source &&
                        source.accessibilityLabel() == "Codex クレジットを移動",
                        "A window hit test reaches the named native reorder handle")
            let frames = reordering.frames(in: section, window: window)
            let sourceFits = frames[.codex]?.contains(origin) == true
            let targetFits = frames[.colab]?.contains(destination) == true
            try t.check(sourceFits && targetFits, "Native handle events target the visible card bounds")
            let pasteboard = NSPasteboard(name: .drag)
            let pasteboardCount = pasteboard.changeCount
            let down = try pointerEvent(.leftMouseDown, point: origin, window: window)
            let drag = try pointerEvent(.leftMouseDragged, point: destination, window: window)
            let up = try pointerEvent(.leftMouseUp, point: destination, window: window)
            source.mouseDown(with: down)
            source.mouseDragged(with: drag)
            let expected: [AiUsageService] = [.claudeAPI, .colab, .codex]
            let renderedOrder = reordering.order(in: section, settings: settings)
            try t.check(source.isReordering && renderedOrder == expected && settings.aiUsageBalanceOrder == original,
                        "Native mouse drag previews the movement before release")
            updateFixtureLayout(host)
            let movedHandle = reorderHandles(in: host).first { $0.item == item }
            let movedCenter = source.convert(CGPoint(x: source.bounds.midX, y: source.bounds.midY), to: nil)
            try t.check(movedHandle === source && abs(movedCenter.x - destination.x) < 1,
                        "The rendered card moves to the target slot without replacing its tracking handle")
            let escape = try keyEvent(53, window: window)
            source.keyDown(with: escape)
            source.mouseUp(with: up)
            try t.check(!reordering.isMoving(item) && settings.aiUsageBalanceOrder == original,
                        "Escape followed by mouse-up cancels a native drag")
            updateFixtureLayout(host)
            source.mouseDown(with: down)
            source.mouseDragged(with: drag)
            let outsidePoint = CGPoint(x: window.frame.width + 10, y: destination.y)
            let outside = try pointerEvent(.leftMouseUp, point: outsidePoint, window: window)
            source.mouseUp(with: outside)
            try t.check(!reordering.isMoving(item) && settings.aiUsageBalanceOrder == original,
                        "A native mouse-up outside the window cancels the drag")
            updateFixtureLayout(host)
            source.mouseDown(with: down)
            source.mouseDragged(with: drag)
            source.mouseUp(with: up)
            try t.check(settings.aiUsageBalanceOrder == expected && pasteboard.changeCount == pasteboardCount,
                        "Native mouse release saves order without starting an OS drag session")
            let upArrow = try keyEvent(126, window: window)
            try t.check(window.makeFirstResponder(source) && window.firstResponder === source,
                        "The reorder handle accepts keyboard focus")
            source.keyDown(with: upArrow)
            try t.check(settings.aiUsageBalanceOrder == [.claudeAPI, .codex, .colab],
                        "An arrow key on the focused handle moves it by one position")
        }
    }

    private static func updateFixtureLayout(_ host: NSView) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
    }

    private static func reorderHandles(in view: NSView) -> [AiUsageOrderHandleView] {
        if let handle = view as? AiUsageOrderHandleView { return [handle] }
        return view.subviews.flatMap { reorderHandles(in: $0) }
    }

    private static func pointerEvent(_ type: NSEvent.EventType, point: CGPoint, window: NSWindow) throws -> NSEvent {
        guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                                             clickCount: 1, pressure: 1) else { throw AiUsageFailure.unavailable }
        return event
    }

    private static func keyEvent(_ code: UInt16, window: NSWindow) throws -> NSEvent {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil, characters: "",
                                           charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)
        else { throw AiUsageFailure.unavailable }
        return event
    }

    private static func verifyNumberTypography(_ t: Checks) throws {
        func width(_ amount: String) -> CGFloat {
            let view = AiUsageReadingNumber(amount: amount, unit: nil, size: 27, unitSize: 12)
            return NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: 200, height: 60)).width
        }
        try t.check(abs(width("111.1") - width("888.8")) < 0.5, "Reading uses tabular digits")
        try t.check(width("WW") > width("ii") + 5, "Reading uses a proportional system font rather than a monospaced font")
    }

    @MainActor
    private final class PresentationScenario {
        private let referenceDate: Date
        let sampleWindow: AiUsageWindow
        var now: Date
        var showsFailures = false

        init(now: Date) {
            self.now = now
            self.referenceDate = now
            let longReset = now.addingTimeInterval(336_600)
            self.sampleWindow = AiUsageWindow(model: "Fable", percent: 76, resetsAt: longReset, minutes: 10_080)
        }

        func fixtureResult(for service: AiUsageService) -> AiUsageResult {
            switch service {
            case .codex:
                if showsFailures { return AiUsageResult.failure(AiUsageFailure.network) }
                let session = AiUsageWindow(percent: 5.1, resetsAt: referenceDate.addingTimeInterval(17_340), minutes: 300)
                let weekly = AiUsageWindow(percent: 79, resetsAt: sampleWindow.resetsAt, minutes: 10_080)
                let credits = AiUsageBalance(kind: .codexCredits, value: .amount(40957))
                let reading = AiUsageReading(plan: "Pro Lite", windows: [session, weekly], balances: [credits])
                return AiUsageResult.success(reading)
            case .claude:
                return AiUsageResult.success(claudeReading())
            case .claudeAPI:
                let planExpiry = referenceDate.addingTimeInterval(12 * 86_400)
                let purchaseExpiry = referenceDate.addingTimeInterval(82 * 86_400)
                let plan = AiUsageBalance(kind: .planCredit, value: .amount(57.25),
                                          label: "API credit (Max)", expiresAt: planExpiry)
                let purchase = AiUsageBalance(kind: .purchasedCredit, value: .amount(47.73), expiresAt: purchaseExpiry)
                let reading = AiUsageReading(balances: [plan, purchase])
                return AiUsageResult.success(reading)
            case .gemini:
                if showsFailures { return AiUsageResult.signedOut }
                let weekly = AiUsageWindow(percent: 48, resetsAt: referenceDate.addingTimeInterval(2100), minutes: 10_080)
                let reading = AiUsageReading(windows: [weekly])
                return AiUsageResult.success(reading)
            case .colab:
                let balance = AiUsageBalance(kind: .computeUnits, value: .units(570.2), perHour: 0.8)
                let reading = AiUsageReading(balances: [balance])
                return AiUsageResult.success(reading)
            case .muse:
                if showsFailures { return AiUsageResult.failure(AiUsageFailure.changed) }
                let reset = referenceDate.addingTimeInterval(6 * 86_400 + 1800)
                let weekly = AiUsageWindow(percent: 57, resetsAt: reset, minutes: 10_080)
                let reading = AiUsageReading(windows: [weekly])
                return AiUsageResult.success(reading)
            }
        }

        private func claudeReading() -> AiUsageReading {
            let session = AiUsageWindow(percent: 33, resetsAt: referenceDate.addingTimeInterval(4200), minutes: 300)
            let weeklyReset = referenceDate.addingTimeInterval(2 * 86_400 + 1800)
            let weekly = AiUsageWindow(percent: 55, resetsAt: weeklyReset, minutes: 10_080)
            var windows = [session, weekly]
            if showsFailures {
                let unavailable = AiUsageWindow(model: "Fable", percent: nil,
                                                resetsAt: referenceDate.addingTimeInterval(3600), minutes: 10_080)
                let model = "GPT-5.3-Codex-Spark"
                let sparkSession = AiUsageWindow(model: model, percent: 30.1,
                                                 resetsAt: referenceDate.addingTimeInterval(17_340), minutes: 300)
                let sparkWeekly = AiUsageWindow(model: model, percent: 55.1, resetsAt: sampleWindow.resetsAt, minutes: 10_080)
                windows.append(contentsOf: [unavailable, sparkSession, sparkWeekly])
            } else {
                windows.append(sampleWindow)
            }
            return AiUsageReading(plan: "Max 5x", windows: windows)
        }
    }

    private static func capture<V: View>(_ view: V, size: NSSize, appearance: NSAppearance.Name) throws -> Data {
        try withHostingView(view, size: size, appearance: appearance) { host in
            guard let png = try readBitmap(host).representation(using: .png, properties: [:]) else {
                throw AiUsageFailure.unavailable
            }
            return png
        }
    }

    private static func withHostingView<V: View, Result>(
        _ view: V, size: NSSize, appearance: NSAppearance.Name, read: (NSView) throws -> Result
    ) rethrows -> Result {
        let rect = NSRect(origin: .zero, size: size)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.frame = rect
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        return try withExtendedLifetime(window) { try read(host) }
    }

    private static func readBitmap(_ host: NSView) throws -> NSBitmapImageRep {
        let rect = host.bounds
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: rect) else { throw AiUsageFailure.unavailable }
        host.cacheDisplay(in: rect, to: bitmap)
        return bitmap
    }
}
