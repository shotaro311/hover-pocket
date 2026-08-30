import Darwin
import Foundation

@MainActor
enum CalendarCapabilityLiveVerificationCommand {
    private enum VerificationError: Error {
        case externalIntegrationsDisabled
        case calendarReadGrantRequired
        case missingConfiguration
        case credentialCheckTimedOut
        case existingCredentialRequired
        case approvalUnexpected
        case receiptInvalid
        case auditContainsPrivateOutput
    }

    private enum CredentialLoadResult: Sendable {
        case loaded(GoogleOAuthStoredCredential?)
        case failed
        case timedOut
    }

    private final class CredentialCheckGate: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        private let continuation: CheckedContinuation<CredentialLoadResult, Never>

        init(continuation: CheckedContinuation<CredentialLoadResult, Never>) {
            self.continuation = continuation
        }

        func finish(_ result: CredentialLoadResult) {
            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            finished = true
            lock.unlock()
            continuation.resume(returning: result)
        }
    }

    static func run() -> Never {
        Task { @MainActor in
            do {
                let result = try await verify(
                    calendarReadGranted: CommandLine.arguments.contains("--grant-calendar-read")
                )
                print("calendar_capability_read_verify=ok")
                print("calendar_capability_origin=voice")
                print("calendar_capability_permission=granted")
                print("calendar_capability_approval=none")
                print("calendar_capability_readback=verified")
                print("calendar_capability_events=\(result.eventCount)")
                print("calendar_capability_audit=redacted")
                Darwin.exit(0)
            } catch {
                fputs("calendar_capability_read_verify=failed\n", stderr)
                fputs("error=\(safeCode(error))\n", stderr)
                Darwin.exit(1)
            }
        }
        RunLoop.main.run()
        Darwin.exit(1)
    }

    private static func verify(
        calendarReadGranted: Bool
    ) async throws -> (eventCount: Int, auditBytes: Int) {
        guard HoverPocketRuntimeEnvironment.shared.externalIntegrationsEnabled else {
            throw VerificationError.externalIntegrationsDisabled
        }
        guard calendarReadGranted else {
            throw VerificationError.calendarReadGrantRequired
        }
        guard GoogleOAuthConfiguration.current != nil else {
            throw VerificationError.missingConfiguration
        }
        let credential: GoogleOAuthStoredCredential
        switch await loadExistingCredential() {
        case .loaded(let storedCredential?):
            credential = storedCredential
        case .loaded(nil), .failed:
            throw VerificationError.existingCredentialRequired
        case .timedOut:
            throw VerificationError.credentialCheckTimedOut
        }
        let oauth = GoogleOAuthService(
            preloadedCredential: credential,
            allowsStoredCredentialMutation: false
        )
        guard oauth.hasRequiredCalendarCredential() else {
            throw VerificationError.existingCredentialRequired
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "HoverPocketCalendarCapabilityRead-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let calendarDataSource = GoogleCalendarCapabilityDataSource(
            store: GoogleCalendarStore(oauth: oauth)
        )
        let handlers = try PocketCapabilityHandlerSet(handlers: [
            CalendarListCapabilityHandler(dataSource: calendarDataSource)
        ])
        let registry = try CapabilityRegistry(handlers: handlers)
        let auditLog = try CapabilityBrokerAuditLog(rootDirectory: root)
        let broker = CapabilityBroker(
            registry: registry,
            ledger: try CapabilityBrokerLedger(rootDirectory: root),
            auditLog: auditLog
        )
        let now = Date()
        let principal = CapabilityPrincipal(
            userID: "local-user",
            agentSessionID: "calendar-read-live-verifier"
        )
        let permissions = CapabilityPermissionSet(
            principal: principal,
            permissions: ["calendar.events.read"]
        )
        let plan = CapabilityExecutionPlan(
            id: "calendar.read.live.\(UUID().uuidString.lowercased())",
            createdAt: now,
            origin: .voice,
            principal: principal,
            appContext: nil,
            steps: [CapabilityPlanStep(
                id: "listCalendar",
                capability: PocketCapabilityKeys.calendarList,
                arguments: [
                    "range": .string("today"),
                    "timezone": .string(TimeZone.current.identifier)
                ],
                idempotencyKey: "calendar.read.live.\(UUID().uuidString.lowercased())",
                dependencies: []
            )],
            requiredPermissions: ["calendar.events.read"]
        )
        let preparation = try broker.prepare(plan, permissions: permissions, now: now)
        guard preparation.approvalRequest == nil,
              preparation.approvalPresentations.isEmpty else {
            throw VerificationError.approvalUnexpected
        }
        let receipt = try await broker.execute(
            plan,
            permissions: permissions,
            approvalGrant: nil,
            now: now
        )
        guard receipt.status == .succeeded,
              receipt.steps.count == 1,
              receipt.steps[0].capability == PocketCapabilityKeys.calendarList,
              receipt.steps[0].status == .succeeded,
              receipt.steps[0].readback.status == .verified,
              let output = receipt.steps[0].output,
              case .array(let events)? = output["events"],
              events.count <= 128 else {
            throw VerificationError.receiptInvalid
        }
        let auditData = try auditLog.combinedData()
        let auditText = String(decoding: auditData, as: UTF8.self)
        guard !auditText.contains("\"safeTitle\"")
                && !auditText.contains("\"eventRef\"")
                && !auditText.contains("\"calendarId\"") else {
            throw VerificationError.auditContainsPrivateOutput
        }
        return (events.count, auditData.count)
    }

    private static func loadExistingCredential() async -> CredentialLoadResult {
        await withCheckedContinuation { continuation in
            let gate = CredentialCheckGate(continuation: continuation)
            Task.detached(priority: .userInitiated) {
                do {
                    gate.finish(.loaded(try GoogleOAuthKeychainStore().load()))
                } catch {
                    gate.finish(.failed)
                }
            }
            Task.detached(priority: .utility) {
                try? await Task.sleep(for: .seconds(5))
                gate.finish(.timedOut)
            }
        }
    }

    private static func safeCode(_ error: Error) -> String {
        switch error {
        case VerificationError.externalIntegrationsDisabled:
            "calendar_external_integrations_disabled"
        case VerificationError.calendarReadGrantRequired:
            "calendar_read_grant_required"
        case VerificationError.missingConfiguration:
            "calendar_configuration_missing"
        case VerificationError.credentialCheckTimedOut:
            "calendar_credential_check_timed_out"
        case VerificationError.existingCredentialRequired:
            "calendar_existing_credential_required"
        case VerificationError.approvalUnexpected:
            "calendar_read_approval_unexpected"
        case VerificationError.receiptInvalid:
            "calendar_read_receipt_invalid"
        case VerificationError.auditContainsPrivateOutput:
            "calendar_audit_private_output"
        case GoogleCalendarToolError.notConnected:
            "calendar_not_connected"
        default:
            "calendar_capability_read_failed"
        }
    }
}
