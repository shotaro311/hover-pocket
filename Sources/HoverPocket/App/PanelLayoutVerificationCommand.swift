import AppKit
import SwiftUI

enum PanelLayoutVerificationCommand {
    @MainActor
    static func run() -> Never {
        _ = NSApplication.shared
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
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
        let settingsWindowCompatibility = verifySettingsWindowLayout()
        let isolatedSettings = SettingsCategory.available(externalIntegrationsEnabled: false)
        let settingsIsolation = !isolatedSettings.contains(.library) && !isolatedSettings.contains(.capture)
            && isolatedSettings.contains(.ai) && isolatedSettings.contains(.general)
        if !settingsIsolation { failures.append("settings-external-integrations-isolation") }
        lines.append("settings_external_integrations_isolation=\(settingsIsolation ? "ok" : "failed")")

        if !panelSizeCompatibility {
            failures.append("panel-size-compatibility")
        }
        if !textSizeCompatibility {
            failures.append("panel-text-size-compatibility")
        }
        if !persistenceCompatibility {
            failures.append("panel-settings-persistence")
        }
        if !settingsWindowCompatibility {
            failures.append("settings-window-layout")
        }
        lines.append("panel_size_compatibility=\(panelSizeCompatibility ? "ok" : "failed")")
        lines.append("panel_text_size_compatibility=\(textSizeCompatibility ? "ok" : "failed")")
        lines.append("panel_settings_persistence=\(persistenceCompatibility ? "ok" : "failed")")
        lines.append("settings_window_layout=\(settingsWindowCompatibility ? "ok" : "failed")")
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
                    .environment(\.providerViewport, contentSize)
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

        let manual = PanelLayout.manualSizeLimits()
        let sizes = [manual.minimum, manual.maximum, CGSize(width: manual.maximum.width, height: manual.minimum.height),
                     CGSize(width: manual.minimum.width, height: manual.maximum.height), CGSize(width: 640, height: 470)]
        let clampedMinimum = PanelLayout.clampManualSize(CGSize(width: 1, height: 1), additionalHeight: 126)
        let clampedMaximum = PanelLayout.clampManualSize(CGSize(width: 90000, height: 90000), additionalHeight: 126)
        if clampedMinimum != CGSize(width: 520, height: 498) || clampedMaximum != CGSize(width: 880, height: 756) {
            failures.append("manual-size-limits")
        }
        var manualCases = 0
        let evidence = FileManager.default.temporaryDirectory.appendingPathComponent("HoverPocket-ManualLayout-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        for (index, size) in sizes.enumerated() {
            let viewport = CGSize(width: size.width, height: size.height - 55)
            let metrics = CalendarPreviewMetrics(viewport: viewport)
            let detailWidth = viewport.width - metrics.outerHorizontalPadding * 2 - metrics.paneSpacing * 2 - 1 - metrics.calendarWidth
            if abs(metrics.dayHeight / metrics.dayWidth - 0.875) > 0.001 || detailWidth < 180 {
                failures.append("calendar-manual-\(index)")
            }
            for textSize in PanelTextSizeOption.allCases {
                let configuration = makeSettings(panelSize: .small, textSize: textSize)
                for provider in providers {
                    let preview = provider.manifest.id.rawValue == "google-calendar"
                        ? AnyView(GoogleCalendarPreviewView(isActive: false, settings: configuration.settings, showsCalendarForLayoutVerification: true))
                        : provider.makePreview(snapshot: nil, state: .idle,
                            actions: ProviderActions(isPreviewActive: false, settings: configuration.settings))
                    let view = preview
                        .environment(\.panelTextSize, textSize).environment(\.providerViewport, viewport)
                        .frame(width: viewport.width, height: viewport.height)
                    let host = NSHostingView(rootView: view)
                    host.frame = CGRect(origin: .zero, size: viewport); host.layoutSubtreeIfNeeded()
                    let fitting = host.fittingSize
                    if !fitting.width.isFinite || !fitting.height.isFinite || fitting.width > viewport.width + 1 || fitting.height > viewport.height + 1 {
                        failures.append("manual-\(index)-\(provider.manifest.id.rawValue)-\(textSize.rawValue)")
                    }
                    if textSize == .medium, let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                        let window = NSWindow(contentRect: CGRect(origin: .zero, size: viewport), styleMask: .borderless, backing: .buffered, defer: false)
                        window.appearance = NSAppearance(named: .darkAqua)
                        window.contentView = host
                        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                        host.layoutSubtreeIfNeeded()
                        host.displayIfNeeded()
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        try? bitmap.representation(using: .png, properties: [:])?.write(to: evidence.appendingPathComponent("\(provider.manifest.id.rawValue)-\(index).png"))
                        window.contentView = nil
                    }
                    manualCases += 1
                }
                cleanupSettingsSuite(configuration.suiteName)
            }
        }
        lines.append("manual_layout_cases=\(manualCases) minimum=520x372 maximum=880x630 mixed_dimensions=true calendar_proportions=true evidence=\(evidence.path)")
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

    private static func verifySettingsWindowLayout() -> Bool {
        let preferred = SettingsWindowLayout.contentSize(
            limitedTo: NSSize(width: 1_200, height: 900)
        )
        guard preferred == SettingsWindowLayout.preferredContentSize else {
            return false
        }

        let compactLimit = NSSize(width: 480, height: 420)
        let compact = SettingsWindowLayout.contentSize(limitedTo: compactLimit)
        let compactMinimum = SettingsWindowLayout.minimumContentSize(limitedTo: compact)
        return compact.width == compactLimit.width
            && compact.height == compactLimit.height
            && compactMinimum.width == compact.width
            && compactMinimum.height == compact.height
            && SettingsWindowLayout.styleMask.contains(.resizable)
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

        let initial = AppSettings(defaults: defaults)
        guard initial.panelAttachmentStyle == .preserveMenu,
              !initial.automaticallyCoverMenuOnNoNotchDisplays else { return false }
        for style in PanelAttachmentStyle.allCases {
            AppSettings(defaults: defaults).panelAttachmentStyle = style
            guard let independent = UserDefaults(suiteName: suiteName),
                  independent.string(forKey: "panelAttachmentStyle") == style.rawValue,
                  AppSettings(defaults: independent).panelAttachmentStyle == style else { return false }
        }
        defaults.set("future-unknown-style", forKey: "panelAttachmentStyle")
        guard AppSettings(defaults: defaults).panelAttachmentStyle == .preserveMenu else { return false }

        for automatic in [false, true] {
            for style in PanelAttachmentStyle.allCases {
                let settings = AppSettings(defaults: defaults)
                settings.panelAttachmentStyle = style
                settings.automaticallyCoverMenuOnNoNotchDisplays = automatic
                guard let independent = UserDefaults(suiteName: suiteName),
                      independent.bool(forKey: "automaticallyCoverMenuOnNoNotchDisplays") == automatic else { return false }
                let reloaded = AppSettings(defaults: independent)
                guard reloaded.automaticallyCoverMenuOnNoNotchDisplays == automatic,
                      reloaded.panelAttachmentStyle == style,
                      reloaded.resolvedPanelAttachmentStyle(hasNotch: true) == style,
                      reloaded.resolvedPanelAttachmentStyle(hasNotch: false) == (automatic ? .coverMenu : style) else { return false }
            }
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
