import AppKit
import Foundation

struct PanelSoakVerificationResult: Sendable {
    let iterations: Int
    let providerSwitches: Int
    let recoveryCycles: Int
    let animatedTransitionCycles: Int
    let warmOpenMaximumMilliseconds: Double
    let baselineWindowCount: Int
    let finalWindowCount: Int
    let baselineThreadCount: Int
    let finalThreadCount: Int
    let maximumThreadCount: Int
    let baselineResidentMiB: Double
    let finalResidentMiB: Double
    let baselineSocketCount: Int
    let finalSocketCount: Int
    let baselineChildProcessCount: Int
    let finalChildProcessCount: Int
}

enum PanelSoakVerificationError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let code):
            return code
        }
    }
}

@MainActor
enum PanelSoakVerificationCommand {
    static func run(iterations: Int = 100, packageDirectory: URL? = nil) async throws -> PanelSoakVerificationResult {
        guard CommandLine.arguments.contains("--verify-panel-soak") else {
            throw PanelSoakVerificationError.failed("panel_soak_explicit_flag_required")
        }

        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .milliseconds(300))

        let settingsDefaults = EphemeralAppSettingsDefaults()
        var providerIDs = [TimerProvider.pluginID, CalculatorProvider.pluginID]
        if let packageDirectory {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("PocketToolsSoak-" + UUID().uuidString)
            let definitions = root.appendingPathComponent("Host")
            let data = root.appendingPathComponent("Data")
            let brokerRoot = root.appendingPathComponent("Broker")
            let broker = CapabilityBroker(registry: try CapabilityRegistry(handlers: PocketCapabilityHandlerSet()),
                ledger: try CapabilityBrokerLedger(rootDirectory: brokerRoot), auditLog: try CapabilityBrokerAuditLog(rootDirectory: brokerRoot))
            let lifecycle = try PocketAppLifecycleManager(rootDirectory: definitions, userDataRoot: data)
            let proposal = try lifecycle.stage(draftDirectory: packageDirectory)
            let grant = try lifecycle.approve(requestID: proposal.requestID, bindingDigest: proposal.bindingDigest)
            let receipt = try lifecycle.install(proposal, approvalGrant: grant)
            let activation = try PocketAppRuntimeActivationRegistry(rootDirectory: definitions, userDataRoot: data, broker: broker, userID: "verification")
            _ = try activation.synchronize(receipt)
            AINativeRuntime.shared.configure(generatedActivationRegistry: activation)
            providerIDs = [CalculatorProvider.pluginID, PluginID(rawValue: PocketSurfaceRegistry.generatedProviderID(appID: receipt.packageID))]
        }
        let registry = ProviderRegistry(
            providers: [
                TimerProvider(),
                CalculatorProvider()
            ]
        )
        let controller = HoverWindowController(
            settingsDefaults: settingsDefaults,
            providerRegistry: registry
        )
        return try await controller.runNonPhysicalSoakVerification(
            iterations: iterations,
            providerIDs: providerIDs
        )
    }
}
