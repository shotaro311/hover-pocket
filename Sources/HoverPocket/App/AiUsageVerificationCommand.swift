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
        let sampleWindow = AiUsageWindow(model: "Fable", percent: 76, resetsAt: now + (3 * 24 + 21) * 3600 + 1800, minutes: 10_080)
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
        try verifyOrderAndLayout(t, defaults: defaults, settings: settings, now: now)
        try t.check(copy.balanceValue(.init(kind: .planCredit, value: .amount(0.0001))) == "<$0.01" &&
                    copy.balanceValue(.init(kind: .computeUnits, value: .units(1e-30))) == "<0.1" &&
                    copy.balanceValue(.init(kind: .purchasedCredit, value: .amount(0))) == "$0.00", "Tiny positive balances and an explicit zero")
        try t.check(copy.balanceValue(.init(kind: .codexCredits, value: .unlimited)) == "無制限" &&
                    copy.balanceValue(.init(kind: .codexCredits, value: .unreadable)) == "読み取れません", "Credit states render without numbers")
        try t.check(copy.balanceDetail(.init(kind: .computeUnits, value: .units(8)), now: now) == "消費量は不明" &&
                    copy.balanceDetail(.init(kind: .computeUnits, value: .units(8), perHour: 0.004), now: now)?.contains("<0.01") == true,
                    "Unknown and tiny hourly consumption")
        let scenario = PresentationScenario(now: now)
        let fixture = AiUsageStore(reader: { service in
            switch service {
            case .codex:
                if scenario.showsFailures { return .failure(.network) }
                return .success(.init(plan: "Pro Lite", windows: [
                    .init(percent: 5.1, resetsAt: now + 289 * 60, minutes: 300),
                    .init(percent: 79, resetsAt: now + (3 * 24 + 21) * 3600 + 1800, minutes: 10_080)
                ], balances: [.init(kind: .codexCredits, value: .amount(40957))]))
            case .claude:
                var windows: [AiUsageWindow] = [
                    .init(percent: 33, resetsAt: now + 70 * 60, minutes: 300),
                    .init(percent: 55, resetsAt: now + 2 * 86400 + 1800, minutes: 10_080)
                ]
                if scenario.showsFailures {
                    windows += [
                        .init(model: "Fable", percent: nil, resetsAt: now + 3600, minutes: 10_080),
                        .init(model: "GPT-5.3-Codex-Spark", percent: 30.1, resetsAt: now + 289 * 60, minutes: 300),
                        .init(model: "GPT-5.3-Codex-Spark", percent: 55.1,
                              resetsAt: now + (3 * 24 + 21) * 3600 + 1800, minutes: 10_080)
                    ]
                } else {
                    windows.append(sampleWindow)
                }
                return .success(.init(plan: "Max 5x", windows: windows))
            case .claudeAPI:
                return .success(.init(balances: [
                    .init(kind: .planCredit, value: .amount(57.25), label: "API credit (Max)", expiresAt: now + 12 * 86400),
                    .init(kind: .purchasedCredit, value: .amount(47.73), expiresAt: now + 82 * 86400)
                ]))
            case .gemini:
                return scenario.showsFailures ? .signedOut : .success(.init(windows: [
                    .init(percent: 48, resetsAt: now + 35 * 60, minutes: 10_080)
                ]))
            case .colab:
                return .success(.init(balances: [.init(kind: .computeUnits, value: .units(570.2), perHour: 0.8)]))
            case .muse:
                return scenario.showsFailures ? .failure(.changed) : .success(.init(windows: [
                    .init(percent: 57, resetsAt: now + 6 * 86400 + 1800, minutes: 10_080)
                ]))
            }
        }, now: { scenario.now })
        func row(_ service: AiUsageService) -> AiUsagePanelService {
            .init(id: service, snapshot: fixture.snapshot(service), changingAccount: fixture.isChangingAccount(service))
        }
        fixture.refresh(AiUsageService.allCases)
        try await until { !fixture.snapshots.values.contains(where: \.refreshing) }
        scenario.now = now + 30
        fixture.refresh([.claude], force: true)
        try await until { !fixture.snapshot(.claude).refreshing }

        let fresh = AiUsageService.allCases.map(row)
        try t.check(fresh.compactMap(\.updateDate).max() == scenario.now &&
                    fresh.filter { $0.id != .claude }.compactMap(\.updateDate).max() == now,
                    "Header selects the newest successful visible reading")
        var oldSuccess = row(.codex).snapshot
        oldSuccess.fetchedAt = now - 86400
        let oldRow = AiUsagePanelService(id: .codex, snapshot: oldSuccess, changingAccount: false)
        try t.check(oldRow.updateDate == oldSuccess.fetchedAt && oldRow.staleDate == nil && !oldRow.snapshot.stale,
                    "Elapsed time alone neither dims a successful reading nor changes its update label")
        try t.check(fresh.filter(\.showsListRow).map(\.id) == [.codex, .claude, .gemini, .muse] &&
                    fresh.compactMap(AiUsagePanelBalance.init).map(\.service) == [.codex, .claudeAPI, .colab],
                    "Successful balance-only services have chips and meters but no table rows")
        let loading = AiUsagePanelService(id: .colab, snapshot: .init(refreshing: true), changingAccount: false)
        let idle = AiUsagePanelService(id: .colab, snapshot: .init(), changingAccount: false)
        try t.check(loading.showsListRow && !idle.showsListRow, "A balance service gets a row while checking")
        let api = AiUsagePanelBalance(row(.claudeAPI))
        try t.check(api?.meterValue(copy) == "$104.98" && api?.help(copy, now: now).contains("$57.25") == true &&
                    api?.help(copy, now: now).contains("$47.73") == true && api?.total.expiresAt == now + 12 * 86400,
                    "Claude API adds the balances and retains both amounts and dates in help")
        try t.check(AiUsagePanelBalance(row(.codex))?.meterValue(copy) == "40,957 CR" &&
                    AiUsagePanelBalance(row(.colab))?.meterValue(copy) == "570.2 CU", "Native units in the balance meters")

        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let panel = AiUsagePanelView(settings: settings, usage: fixture, isActive: false, openSettings: {})
        let preview = panel.background(.black)
        let minimum = PanelLayout.manualSizeLimits().minimum.width - PanelLayout.surfaceSidePadding * 2
        let list = try capture(preview, size: NSSize(width: minimum, height: 350), appearance: .darkAqua)
        try list.write(to: output.appendingPathComponent("list.png"), options: .atomic)
        try verifyRowMetadata(t, panel: panel, service: row(.claude), now: now, width: minimum)
        settings.aiUsageLayout = .meter
        let meter = try capture(preview, size: NSSize(width: 760, height: 510), appearance: .darkAqua)
        try meter.write(to: output.appendingPathComponent("meter.png"), options: .atomic)
        try verifyRowMetadata(t, panel: panel, service: row(.claude), now: now, width: minimum)

        scenario.showsFailures = true
        fixture.beginAccountChange(.muse)
        fixture.endAccountChange(.muse)
        fixture.refresh([.codex, .claude, .gemini], force: true)
        try await until { !fixture.snapshots.values.contains(where: \.refreshing) }
        try t.check(AiUsageSettingsView.canSignOut(.gemini, usage: fixture) &&
                    !AiUsageSettingsView.canSignOut(.colab, usage: fixture) && !AiUsageSettingsView.canSignOut(.codex, usage: fixture),
                    "Gemini can sign out when only Colab has a reading")
        try t.check(row(.codex).snapshot.stale && row(.codex).reason(copy) == copy.error(.network) &&
                    row(.codex).updateDate == nil &&
                    row(.codex).snapshot.fetchedAt.map(copy.stale)?.hasSuffix(" の値") == true,
                    "Stale data preserves its value and error, and is excluded from the update clock")
        try t.check(row(.gemini).emptyMessage(copy) == copy.signedOut && row(.gemini).updateDate == nil &&
                    row(.muse).emptyMessage(copy) == copy.error(.changed) && row(.muse).orderedWindows.isEmpty &&
                    row(.muse).updateDate == nil, "Signed-out and error states have reasons and no update clock or numeric reading")
        let claude = row(.claude)
        let other = claude.windows(in: .other).map(claude.quota)
        try t.check(row(.gemini).showsListRow && row(.muse).showsListRow && row(.codex).showsListRow,
                    "Signed-out, error-only and stale quota services remain listed")
        let unavailable = other.first
        try t.check(unavailable?.window.remaining == nil && unavailable?.resetText(copy, now: now) == nil &&
                    unavailable?.help(copy) == "Fable\n取得できません" &&
                    unavailable.map { copy.meterAccessibility($0, now: now) } == "Fable 取得できません",
                    "Unreadable meter has no value or reset line, and explains the state in help and accessibility")
        let longQuotas = Array(other.dropFirst())
        try t.check(longQuotas.map { $0.fullName(copy) } == ["GPT-5.3-Codex-Spark 5時間", "GPT-5.3-Codex-Spark 1週間"] &&
                    longQuotas.allSatisfy { quota in
                        quota.help(copy).hasPrefix(quota.fullName(copy) + "\n") &&
                        copy.meterAccessibility(quota, now: now).hasPrefix(quota.fullName(copy) + " ")
                    }, "Duplicate quota names retain the full name and duration in help and accessibility")
        try t.check(longQuotas.map { $0.meterDetail(copy, now: now) } == ["5時間 · 4:49", "1週間 · 3日21時間"],
                    "The second meter line combines duplicate duration and remaining reset time")
        let unreadableDuplicate = AiUsageQuota(window: .init(model: "GPT-5.3-Codex-Spark", percent: nil,
                                                            resetsAt: now + 3600, minutes: 300), distinguishesDuration: true)
        try t.check(unavailable?.meterDetail(copy, now: now) == nil &&
                    unreadableDuplicate.meterDetail(copy, now: now) == "5時間" &&
                    unreadableDuplicate.help(copy) == "GPT-5.3-Codex-Spark 5時間\n取得できません",
                    "Unreadable duplicate meter shows only the duration on its second line")
        try verifyReadingOpacity(t, quota: .init(window: sampleWindow), copy: copy, now: now)
        try verifySettingsAction(t, copy: copy)
        try verifyNarrowContent(t, quota: .init(window: sampleWindow), copy: copy, now: now)
        let states = try capture(preview, size: NSSize(width: minimum, height: 790), appearance: .darkAqua)
        try states.write(to: output.appendingPathComponent("meter-states.png"), options: .atomic)
        settings.aiUsageLayout = .list
        try verifyPinnedListHeader(t, view: preview, width: minimum)
        let listStates = try capture(preview, size: NSSize(width: minimum, height: 375), appearance: .darkAqua)
        try listStates.write(to: output.appendingPathComponent("list-states.png"), options: .atomic)
        let account = CodexVoiceAccountLoginController(contextProvider: { [] }, browserOpener: { _ in false }, credentialChangeHandler: {})
        let settingsPNG = try capture(VStack(alignment: .leading) {
            Text(SettingsCategory.ai.title(language: .japanese)).font(.title2.weight(.semibold))
            SettingsCard {
                AiUsageSettingsView(settings: settings, usage: fixture, codexAccount: account)
            }
        }.padding(24).frame(maxHeight: .infinity, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor)),
            size: NSSize(width: 680, height: 580), appearance: .aqua)
        try t.check(NSBitmapImageRep(data: settingsPNG)?.pixelsWide ?? 0 > 0, "Settings still renders with the service order controls")
        try settingsPNG.write(to: output.appendingPathComponent("settings.png"), options: .atomic)
        for name in ["list", "meter", "meter-states", "list-states", "settings"] {
            let file = output.appendingPathComponent("\(name).png")
            let bitmap = try NSBitmapImageRep(data: Data(contentsOf: file))
            try t.check((bitmap?.pixelsWide ?? 0) >= Int(minimum), "Reopens the rendered \(name) PNG")
            if name != "settings" {
                let expected = name.hasSuffix("-states") ? Set([AiUsageTint.green, .yellow]) : Set(AiUsageTint.allCases)
                try t.check(bitmap.map(solidMeterColors) == expected, "\(name) renders the expected palette and dims stale values")
            }
        }
        for layout in AiUsageLayout.allCases {
            settings.aiUsageLayout = layout
            for size in PanelTextSizeOption.allCases {
                let content = panel.panelContent(AiUsageService.allCases.map(row), now: now, width: minimum)
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
            let header = CGRect(x: 38, y: 34, width: width - 60, height: 22)
            let rows = CGRect(x: 14, y: 70, width: width - 28, height: 75)
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
        try t.check(settings.aiUsageLayout == .list && settings.aiUsageServiceOrder == AiUsageService.allCases && settings.aiUsageSort == nil,
                    "Existing settings start in List and keep the original order")
        let malformed = EphemeralAppSettingsDefaults()
        malformed.set("unknown", forKey: "aiUsageLayout")
        malformed.set(["bogus", "muse", "muse", "codex"], forKey: "aiUsageServiceOrder")
        malformed.set(["weekly", "backwards"], forKey: "aiUsageSort")
        let repaired = AppSettings(defaults: malformed)
        try t.check(repaired.aiUsageLayout == .list && repaired.aiUsageSort == nil &&
                    repaired.aiUsageServiceOrder == [.muse, .codex, .claude, .claudeAPI, .gemini, .colab],
                    "Invalid layout and sort fall back, and order removes duplicate and unknown IDs")
        try t.check(!settings.canStepAiUsageService(.codex, by: -1) && settings.canStepAiUsageService(.codex, by: 1) &&
                    settings.canStepAiUsageService(.muse, by: -1) && !settings.canStepAiUsageService(.muse, by: 1),
                    "Ordering arrows disable only the outer moves")
        settings.hiddenAiUsageServices = [.gemini]
        try t.check(!AiUsagePanelView.applyDrop(["outside:muse"], token: "fixture", target: .codex, settings: settings) &&
                    AiUsagePanelView.applyDrop(["fixture:muse"], token: "fixture", target: .codex, settings: settings),
                    "List drop updates the saved order and rejects an external payload")
        settings.stepAiUsageService(.muse, by: -1)
        try t.check(settings.aiUsageServiceOrder.first == .muse, "Settings Move up does not cross the first row")
        settings.stepAiUsageService(.muse, by: 1)
        try t.check(settings.aiUsageServiceOrder.prefix(2).elementsEqual([.codex, .muse]), "Settings Move down changes the shared order")
        settings.stepAiUsageService(.muse, by: -1)
        try t.check(settings.aiUsageServiceOrder.first == .muse, "Settings Move up changes the shared order")
        settings.aiUsageSort = .init(column: .other, previous: nil)
        try t.check(!AiUsagePanelView.applyDrop(["fixture:muse"], token: "fixture", target: .colab, settings: settings),
                    "List stops accepting drops when a sort is active")
        settings.aiUsageLayout = .meter
        try t.check(AiUsagePanelView.applyDrop(["fixture:muse"], token: "fixture", target: .claudeAPI, settings: settings),
                    "Meter cards reorder the shared preference while a list sort is retained")
        let reloaded = AppSettings(defaults: defaults)
        try t.check(reloaded.aiUsageLayout == .meter && reloaded.aiUsageSort == settings.aiUsageSort &&
                    reloaded.aiUsageServiceOrder == [.codex, .claude, .claudeAPI, .muse, .gemini, .colab] &&
                    reloaded.visibleAiUsageServices == [.codex, .claude, .claudeAPI, .muse, .colab],
                    "Both layouts, settings order, hidden IDs and sort survive settings recreation")
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
        _ = settings.moveAiUsageService(.muse, to: .colab)
        settings.aiUsageLayout = .list
        settings.aiUsageSort = nil
        settings.hiddenAiUsageServices = []
    }

    private final class PresentationScenario {
        var now: Date
        var showsFailures = false

        init(now: Date) { self.now = now }
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
