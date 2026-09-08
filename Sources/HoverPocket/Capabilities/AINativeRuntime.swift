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

    @Published private(set) var pocketAppGenerationController: PocketAppGenerationController?
    @Published private(set) var generatedExecutionRuntimeRegistry: PocketExecutionRuntimeRegistry?
    @Published private(set) var generatedSurfaceRegistry: PocketSurfaceRegistry?
    @Published private(set) var capabilityDataGovernanceController: CapabilityDataGovernanceController?
    private(set) var voiceCapabilityContext: VoiceCapabilityContext?
    private var generatedActivationRegistry: PocketAppRuntimeActivationRegistry?
    private var preservedManagedGeneratedProviderIDs: Set<String> = []

    private init() {}

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
        pocketAppGenerationController: PocketAppGenerationController? = nil,
        generatedActivationRegistry: PocketAppRuntimeActivationRegistry? = nil,
        capabilityDataGovernanceController: CapabilityDataGovernanceController? = nil,
        voiceCapabilityContext: VoiceCapabilityContext? = nil,
        preservingManagedGeneratedProviderIDs: Set<String> = []
    ) {
        let retainedProviderIDs = managedGeneratedProviderIDs.union(
            preservingManagedGeneratedProviderIDs.filter {
                PocketSurfaceRegistry.generatedAppID(providerID: $0) != nil
            }
        )
        self.generatedActivationRegistry?.shutdown()
        self.pocketAppGenerationController?.shutdown()
        self.pocketAppGenerationController = pocketAppGenerationController
        self.generatedActivationRegistry = generatedActivationRegistry
        self.generatedExecutionRuntimeRegistry = generatedActivationRegistry?.executionRegistry
        self.generatedSurfaceRegistry = generatedActivationRegistry?.surfaceRegistry
        self.capabilityDataGovernanceController = capabilityDataGovernanceController
        self.voiceCapabilityContext = voiceCapabilityContext
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

}
