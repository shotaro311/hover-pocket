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
    static func run(iterations: Int = 100) async throws -> PanelSoakVerificationResult {
        guard CommandLine.arguments.contains("--verify-panel-soak") else {
            throw PanelSoakVerificationError.failed("panel_soak_explicit_flag_required")
        }

        let settingsDefaults = EphemeralAppSettingsDefaults()
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
            providerIDs: [TimerProvider.pluginID, CalculatorProvider.pluginID]
        )
    }
}
