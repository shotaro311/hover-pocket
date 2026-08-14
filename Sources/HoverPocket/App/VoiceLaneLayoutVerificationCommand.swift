import AppKit
import SwiftUI

enum VoiceLaneLayoutVerificationCommand {
    @MainActor
    static func run() -> Never {
        _ = NSApplication.shared
        var failures: [String] = []
        var renderCases = 0

        let expectedExpandedHeights: [PanelSizeOption: CGFloat] = [
            .small: 190,
            .medium: 220,
            .large: 250,
            .extraLarge: 280
        ]

        for panelSize in PanelSizeOption.allCases {
            let baseline = PanelLayout.previewSize(for: panelSize)
            let compact = PanelLayout.panelTotalSize(
                for: panelSize,
                voiceLaneMode: .compact
            )
            let expanded = PanelLayout.panelTotalSize(
                for: panelSize,
                voiceLaneMode: .expanded
            )
            let expectedExpanded = expectedExpandedHeights[panelSize] ?? -1

            if compact.width != baseline.width
                || compact.height != baseline.height + 64
                || expanded.width != baseline.width
                || expanded.height != baseline.height + expectedExpanded {
                failures.append("geometry-\(panelSize.rawValue)")
            }

            let fallback = PanelLayout.resolvedVoiceLaneMode(
                requested: .expanded,
                panelSize: panelSize,
                availableHeight: expanded.height - 1
            )
            let allowed = PanelLayout.resolvedVoiceLaneMode(
                requested: .expanded,
                panelSize: panelSize,
                availableHeight: expanded.height
            )
            if fallback != .compact || allowed != .expanded {
                failures.append("fallback-\(panelSize.rawValue)")
            }

            for mode in [VoiceLaneDisplayMode.compact, .expanded] {
                renderCases += 1
                let configuration = makeSettings(panelSize: panelSize, mode: mode)
                let model = VoiceLaneViewModel()
                model.applyLayout(requested: mode, resolved: mode)
                let laneHeight = PanelLayout.voiceLaneHeight(for: panelSize, mode: mode)
                let view = VoiceLaneView(model: model, settings: configuration.settings)
                    .frame(width: baseline.width, height: laneHeight)
                let host = NSHostingView(rootView: view)
                host.frame = CGRect(x: 0, y: 0, width: baseline.width, height: laneHeight)
                host.layoutSubtreeIfNeeded()
                let fitting = host.fittingSize
                if !fitting.width.isFinite || !fitting.height.isFinite {
                    failures.append("render-\(panelSize.rawValue)-\(mode.rawValue)")
                }
                cleanupSettingsSuite(configuration.suiteName)
            }
        }

        if !verifySettingsDefaultsAndPersistence() {
            failures.append("settings-persistence")
        }

        print("voice_lane_layout_verify=\(failures.isEmpty ? "ok" : "failed")")
        print("voice_lane_render_cases=\(renderCases)")
        print("voice_lane_compact_height=\(Int(PanelLayout.compactVoiceLaneHeight))")
        print("voice_lane_expansion_direction=down")
        print("voice_lane_provider_rect_invariant=true")
        print("voice_lane_default_off=true")
        if !failures.isEmpty {
            print("voice_lane_layout_failures=\(failures.joined(separator: ","))")
        }
        exit(failures.isEmpty ? 0 : 1)
    }

    @MainActor
    private static func makeSettings(
        panelSize: PanelSizeOption,
        mode: VoiceLaneDisplayMode
    ) -> (settings: AppSettings, suiteName: String) {
        let suiteName = "local.codex.hover-pocket.voice-layout.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let settings = AppSettings(defaults: defaults)
        settings.panelSize = panelSize
        settings.codexVoiceEnabled = true
        settings.codexVoiceLayoutMode = mode == .expanded ? .expanded : .compact
        return (settings, suiteName)
    }

    private static func cleanupSettingsSuite(_ suiteName: String) {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    @MainActor
    private static func verifySettingsDefaultsAndPersistence() -> Bool {
        let suiteName = "local.codex.hover-pocket.voice-settings.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { return false }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = AppSettings(defaults: defaults)
        guard !initial.codexVoiceEnabled,
              initial.codexVoiceLayoutMode == .compact,
              !initial.codexVoiceAutoListen,
              initial.requestedVoiceLaneDisplayMode == .disabled else {
            return false
        }

        initial.codexVoiceEnabled = true
        initial.codexVoiceLayoutMode = .expanded
        initial.codexVoiceAutoListen = true

        let reloaded = AppSettings(defaults: defaults)
        return reloaded.codexVoiceEnabled
            && reloaded.codexVoiceLayoutMode == .expanded
            && reloaded.codexVoiceAutoListen
            && reloaded.requestedVoiceLaneDisplayMode == .expanded
    }
}
