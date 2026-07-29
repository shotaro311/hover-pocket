import AppKit
import SwiftUI

enum PanelLayoutVerificationCommand {
    @MainActor
    static func run() -> Never {
        _ = NSApplication.shared
        seedCalculatorHistory()

        var lines: [String] = []
        var failures: [String] = []
        var layoutCaseCount = 0
        let providers = ProviderRegistry.builtIn.providers
        let expectedPanelSizes: [(option: PanelSizeOption, width: CGFloat, height: CGFloat)] = [
            (.small, 520, 372),
            (.medium, 600, 430),
            (.large, 680, 488),
            (.extraLarge, 760, 546)
        ]
        let expectedTextSizes: [(option: PanelTextSizeOption, rawValue: String)] = [
            (.small, "small"),
            (.medium, "medium"),
            (.large, "large"),
            (.extraLarge, "extraLarge")
        ]
        let panelSizeCompatibility = PanelSizeOption.allCases == expectedPanelSizes.map { $0.option }
            && expectedPanelSizes.allSatisfy { expected in
                let actual = PanelLayout.previewSize(for: expected.option)
                return expected.option.rawValue == expectedRawValue(for: expected.option)
                    && actual.width == expected.width
                    && actual.height == expected.height
            }
        let textSizeCompatibility = PanelTextSizeOption.allCases == expectedTextSizes.map { $0.option }
            && expectedTextSizes.allSatisfy { expected in
                expected.option.rawValue == expected.rawValue
            }
        let persistenceCompatibility = verifySettingsPersistence()

        if !panelSizeCompatibility {
            failures.append("panel-size-compatibility")
        }
        if !textSizeCompatibility {
            failures.append("panel-text-size-compatibility")
        }
        if !persistenceCompatibility {
            failures.append("panel-settings-persistence")
        }
        lines.append("panel_size_compatibility=\(panelSizeCompatibility ? "ok" : "failed")")
        lines.append("panel_text_size_compatibility=\(textSizeCompatibility ? "ok" : "failed")")
        lines.append("panel_settings_persistence=\(persistenceCompatibility ? "ok" : "failed")")
        lines.append(
            "panel_dimensions=" + expectedPanelSizes.map {
                "\($0.option.rawValue):\(Int($0.width))x\(Int($0.height))"
            }.joined(separator: ",")
        )

        for panelSize in PanelSizeOption.allCases {
            let panel = PanelLayout.previewSize(for: panelSize)
            let contentSize = CGSize(width: panel.width, height: max(0, panel.height - 55))

            let calculatorMetrics = CalculatorLayoutMetrics(size: contentSize, showsHistory: true)
            let calculatorFits = calculatorMetrics.estimatedMaxContentHeight <= contentSize.height
                && calculatorMetrics.hasUsableMainColumnWidth
            if !calculatorFits {
                failures.append("calculator-\(panelSize.rawValue)")
            }
            lines.append(
                "calculator_layout_\(panelSize.rawValue)=height:\(format(calculatorMetrics.estimatedMaxContentHeight))/\(format(contentSize.height)),mainWidth:\(format(calculatorMetrics.mainMaxWidth)),fits:\(calculatorFits)"
            )

            for textSize in PanelTextSizeOption.allCases {
                let configuration = makeSettings(panelSize: panelSize, textSize: textSize)
                let settings = configuration.settings
                let actions = ProviderActions(isPreviewActive: false, settings: settings)

                for provider in providers {
                    layoutCaseCount += 1
                    let view = provider.makePreview(
                        snapshot: nil,
                        state: .idle,
                        actions: actions
                    )
                    .environment(\.panelTextSize, textSize)
                    .frame(width: contentSize.width, height: contentSize.height)

                    let host = NSHostingView(rootView: view)
                    host.frame = CGRect(origin: .zero, size: contentSize)
                    host.layoutSubtreeIfNeeded()

                    let fitting = host.fittingSize
                    if !fitting.width.isFinite || !fitting.height.isFinite {
                        failures.append("\(provider.manifest.id.rawValue)-\(panelSize.rawValue)-\(textSize.rawValue)")
                    }
                }
                cleanupSettingsSuite(configuration.suiteName)
            }
        }

        lines.insert("panel_layout_verify=\(failures.isEmpty ? "ok" : "failed")", at: 0)
        lines.insert("panel_layout_cases=\(layoutCaseCount)", at: 1)
        if !failures.isEmpty {
            lines.append("panel_layout_failures=\(failures.joined(separator: ","))")
        }

        lines.forEach { print($0) }
        exit(failures.isEmpty ? 0 : 1)
    }

    @MainActor
    private static func seedCalculatorHistory() {
        let store = CalculatorStore.shared
        store.reset()
        store.clearHistory()
        store.runSequence([
            .digit(6), .operation(.add), .digit(5),
            .operation(.add), .digit(9), .operation(.divide), .digit(2),
            .operation(.add), .digit(3), .operation(.subtract), .digit(5),
            .equals
        ])
    }

    @MainActor
    private static func makeSettings(panelSize: PanelSizeOption, textSize: PanelTextSizeOption) -> (settings: AppSettings, suiteName: String) {
        let suiteName = "local.codex.hover-pocket.panel-layout.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let settings = AppSettings(defaults: defaults)
        settings.panelSize = panelSize
        settings.panelTextSize = textSize
        return (settings, suiteName)
    }

    private static func cleanupSettingsSuite(_ suiteName: String) {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    @MainActor
    private static func verifySettingsPersistence() -> Bool {
        let suiteName = "local.codex.hover-pocket.panel-settings.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return false
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        for panelSize in PanelSizeOption.allCases {
            for textSize in PanelTextSizeOption.allCases {
                let settings = AppSettings(defaults: defaults)
                settings.panelSize = panelSize
                settings.panelTextSize = textSize

                let reloaded = AppSettings(defaults: defaults)
                guard reloaded.panelSize == panelSize,
                      reloaded.panelTextSize == textSize else {
                    return false
                }
            }
        }

        return true
    }

    private static func expectedRawValue(for option: PanelSizeOption) -> String {
        switch option {
        case .small:
            return "small"
        case .medium:
            return "medium"
        case .large:
            return "large"
        case .extraLarge:
            return "extraLarge"
        }
    }

    private static func format(_ value: CGFloat) -> String {
        String(format: "%.1f", Double(value))
    }
}
