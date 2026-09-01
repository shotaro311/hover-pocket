import Combine
import Foundation

@MainActor
struct VoiceCapabilityContext {
    let registry: CapabilityRegistry
    let broker: CapabilityBroker
}

@MainActor
final class AINativeRuntime: ObservableObject {
    static let shared = AINativeRuntime()

    private let principal = CapabilityPrincipal(userID: "local-user")
    private var adapter: TodayFocusTextAdapter?
    @Published private(set) var pocketAppExecutionRuntime: PocketAppExecutionRuntime?
    @Published private(set) var pocketAppGenerationController: PocketAppGenerationController?
    @Published private(set) var generatedExecutionRuntimeRegistry: PocketExecutionRuntimeRegistry?
    @Published private(set) var generatedSurfaceRegistry: PocketSurfaceRegistry?
    @Published private(set) var capabilityDataGovernanceController: CapabilityDataGovernanceController?
    private(set) var voiceCapabilityContext: VoiceCapabilityContext?
    private var generatedActivationRegistry: PocketAppRuntimeActivationRegistry?
    private var builtInActivationLease: PocketAppActivationLease?
    private var preservedManagedGeneratedProviderIDs: Set<String> = []

    private init() {}

    var isAvailable: Bool { adapter != nil }

    var isPocketAppAvailable: Bool { pocketAppExecutionRuntime != nil }

    var managedGeneratedProviderIDs: Set<String> {
        var providerIDs = preservedManagedGeneratedProviderIDs
        if let controller = pocketAppGenerationController {
            providerIDs.formUnion(controller.managedPackages.map {
                PocketSurfaceRegistry.generatedProviderID(appID: $0.packageID)
            })
            providerIDs.formUnion(controller.managementIssues.map {
                PocketSurfaceRegistry.generatedProviderID(appID: $0.packageID)
            })
            return providerIDs
        }
        if let appIDs = try? generatedActivationRegistry?.managedAppIDs() {
            providerIDs.formUnion(appIDs.map {
                PocketSurfaceRegistry.generatedProviderID(appID: $0)
            })
        }
        return providerIDs
    }

    func configure(
        adapter: TodayFocusTextAdapter?,
        pocketAppExecutionRuntime: PocketAppExecutionRuntime? = nil,
        pocketAppGenerationController: PocketAppGenerationController? = nil,
        generatedActivationRegistry: PocketAppRuntimeActivationRegistry? = nil,
        builtInActivationLease: PocketAppActivationLease? = nil,
        capabilityDataGovernanceController: CapabilityDataGovernanceController? = nil,
        voiceCapabilityContext: VoiceCapabilityContext? = nil,
        preservingManagedGeneratedProviderIDs: Set<String> = []
    ) {
        let retainedProviderIDs = managedGeneratedProviderIDs.union(
            preservingManagedGeneratedProviderIDs.filter {
                PocketSurfaceRegistry.generatedAppID(providerID: $0) != nil
            }
        )
        self.builtInActivationLease?.invalidate()
        self.generatedActivationRegistry?.shutdown()
        self.pocketAppGenerationController?.shutdown()
        self.adapter = adapter
        self.pocketAppExecutionRuntime = pocketAppExecutionRuntime
        self.pocketAppGenerationController = pocketAppGenerationController
        self.generatedActivationRegistry = generatedActivationRegistry
        self.generatedExecutionRuntimeRegistry = generatedActivationRegistry?.executionRegistry
        self.generatedSurfaceRegistry = generatedActivationRegistry?.surfaceRegistry
        self.capabilityDataGovernanceController = capabilityDataGovernanceController
        self.voiceCapabilityContext = voiceCapabilityContext
        self.builtInActivationLease = builtInActivationLease
        if let pocketAppGenerationController {
            self.preservedManagedGeneratedProviderIDs = Set(
                pocketAppGenerationController.managedPackages.map {
                    PocketSurfaceRegistry.generatedProviderID(appID: $0.packageID)
                } + pocketAppGenerationController.managementIssues.map {
                    PocketSurfaceRegistry.generatedProviderID(appID: $0.packageID)
                }
            )
        } else {
            self.preservedManagedGeneratedProviderIDs = retainedProviderIDs
        }
    }

    func forgetManagedGeneratedProviderID(_ providerID: String) {
        preservedManagedGeneratedProviderIDs.remove(providerID)
    }

    func recordGeneratedAppUse(appID: String) {
        generatedActivationRegistry?.recordUse(appID: appID)
        pocketAppGenerationController?.refreshHealth()
    }

    func recoverAfterSystemTransition() {
        _ = generatedActivationRegistry?.recoverAfterSystemTransition()
        pocketAppGenerationController?.recoverAfterSystemTransition()
    }

    func prepareTodayFocus(
        event: GoogleCalendarEventOccurrence,
        durationSeconds: Int = 1_500,
        now: Date = Date()
    ) throws -> TodayFocusDraft {
        guard let adapter else {
            throw CapabilityBrokerError.unavailable(PocketCapabilityKeys.timerStart)
        }
        let purpose = event.title.isEmpty ? "今日の予定" : event.title
        return try adapter.prepareFocus(
            event: TodayFocusCalendarEvent(
                eventRef: event.id,
                safeTitle: purpose,
                start: event.start,
                end: event.end
            ),
            durationSeconds: durationSeconds,
            purpose: purpose,
            principal: principal,
            permissions: permissionSet,
            now: now
        )
    }

    func approveAndExecute(_ draft: TodayFocusDraft, now: Date = Date()) async throws -> CapabilityWorkflowReceipt {
        guard let adapter else {
            throw CapabilityBrokerError.unavailable(PocketCapabilityKeys.timerStart)
        }
        return try await adapter.approveAndExecute(
            draft,
            permissions: permissionSet,
            now: now
        )
    }

    func reject(_ draft: TodayFocusDraft, now: Date = Date()) {
        guard let adapter,
              let request = draft.preparation.approvalRequest else { return }
        do {
            _ = try adapter.reject(
                requestID: request.id,
                planDigest: draft.preparation.planDigest,
                now: now
            )
        } catch CapabilityBrokerError.approvalRejected {
        } catch {
        }
    }

    private var permissionSet: CapabilityPermissionSet {
        CapabilityPermissionSet(
            principal: principal,
            permissions: ["calendar.events.read", "sticky.write", "timer.write"]
        )
    }
}
