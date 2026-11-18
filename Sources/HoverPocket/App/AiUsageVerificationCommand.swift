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
        let now = Date()
        let copy = AiUsageCopy(language: .japanese)
        let sampleWindow = AiUsageWindow(model: "Fable", percent: 86, resetsAt: now + (4 * 24 + 21) * 3600 + 1800, minutes: 10_080)
        try t.check(copy.windowLabel(sampleWindow) == "Fable · 1週間" && copy.reset(sampleWindow.resetsAt, now: now).hasPrefix("あと4日21時間でリセット（"), "Model label and a long reset interval")
        try t.check(copy.reset(now + 20 * 60, now: now).contains("20分でリセット") && copy.elapsed(sampleWindow, now: now) != nil,
                    "Short reset and elapsed marker")
        try t.check(copy.level(79.9) == .normal && copy.level(80) == .warning && copy.level(90) == .critical, "Color thresholds at 80% and 90%")
        try t.check(copy.balanceValue(.init(kind: .planCredit, value: .amount(0.0001))) == "<$0.01" &&
                    copy.balanceValue(.init(kind: .computeUnits, value: .units(1e-30))) == "<0.1" &&
                    copy.balanceValue(.init(kind: .purchasedCredit, value: .amount(0))) == "$0.00", "Tiny positive balances and an explicit zero")
        try t.check(copy.balanceValue(.init(kind: .codexCredits, value: .unlimited)) == "無制限" &&
                    copy.balanceValue(.init(kind: .codexCredits, value: .unreadable)) == "読み取れません", "Credit states render without numbers")
        try t.check(copy.balanceDetail(.init(kind: .computeUnits, value: .units(8)), now: now) == "消費量は不明" &&
                    copy.balanceDetail(.init(kind: .computeUnits, value: .units(8), perHour: 0.004), now: now)?.contains("<0.01") == true,
                    "Unknown and tiny hourly consumption")
        let fixture = AiUsageStore { service in
            switch service {
            case .codex: .success(.init(plan: "Pro Lite", windows: [.init(percent: 19, resetsAt: now + 5 * 86400, minutes: 10_080)],
                                       balances: [.init(kind: .codexCredits, value: .amount(234.567))]))
            case .claude: .success(.init(plan: "Max 5x", windows: [
                .init(percent: 33, resetsAt: now + 70 * 60, minutes: 300),
                .init(percent: 93, resetsAt: now + 2 * 86400, minutes: 10_080),
                sampleWindow
            ]))
            case .claudeAPI: .success(.init(balances: [
                .init(kind: .planCredit, value: .amount(57.25), label: "API credit (Max)", expiresAt: now + 12 * 86400),
                .init(kind: .purchasedCredit, value: .amount(0.001), expiresAt: now + 82 * 86400)
            ]))
            case .gemini: .signedOut
            case .colab: .success(.init(balances: [.init(kind: .computeUnits, value: .units(61.83), perHour: 0.04)]))
            case .muse: .failure(.changed)
            }
        }
        fixture.refresh(AiUsageService.allCases)
        try await until { !fixture.snapshots.values.contains(where: \.refreshing) }
        try t.check(AiUsageSettingsView.canSignOut(.gemini, usage: fixture) &&
                    !AiUsageSettingsView.canSignOut(.colab, usage: fixture) && !AiUsageSettingsView.canSignOut(.codex, usage: fixture),
                    "Gemini can sign out when only Colab has a reading")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let providerStore = ProviderStore(registry: .init(providers: [AiUsageProvider()]), settings: settings)
        try capture(VStack(spacing: 0) {
            ProviderHeaderView(providerStore: providerStore, settings: settings, onOpenSettings: {}, onClosePanel: {})
            Divider()
            AiUsagePanelView(settings: settings, usage: fixture, isActive: false, openSettings: {})
        }.background(.black), name: "panel", size: NSSize(width: 520, height: 740), appearance: .darkAqua, output: output)
        try capture(VStack(alignment: .leading) {
            Text(SettingsCategory.ai.title(language: .japanese)).font(.title2.weight(.semibold))
            SettingsCard {
                AiUsageSettingsView(settings: settings, usage: fixture, codexAccount: .shared)
            }
        }.padding(24).frame(maxHeight: .infinity, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor)),
            name: "settings", size: NSSize(width: 640, height: 570), appearance: .aqua, output: output)
        for name in ["panel", "settings"] {
            let file = output.appendingPathComponent("\(name).png")
            try t.check(NSBitmapImageRep(data: Data(contentsOf: file))?.pixelsWide ?? 0 > 0, "Reopens the rendered \(name) PNG")
        }
    }

    private static func capture<V: View>(_ view: V, name: String, size: NSSize, appearance: NSAppearance.Name, output: URL) throws {
        let rect = NSRect(origin: .zero, size: size)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.frame = rect
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: rect) else { throw AiUsageFailure.unavailable }
        host.cacheDisplay(in: rect, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw AiUsageFailure.unavailable }
        try png.write(to: output.appendingPathComponent("\(name).png"), options: .atomic)
    }
}
