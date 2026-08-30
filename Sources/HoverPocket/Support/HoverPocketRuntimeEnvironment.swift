import Darwin
import Foundation

enum HoverPocketRuntimeEnvironmentError: Error, Equatable, CustomStringConvertible {
    case invalidArguments(String)
    case invalidBundle(String)
    case invalidRoot(String)

    var description: String {
        switch self {
        case .invalidArguments(let code), .invalidBundle(let code), .invalidRoot(let code):
            return code
        }
    }
}

struct HoverPocketBundleMetadata: Equatable, Sendable {
    let bundleIdentifier: String?
    let isVoiceE2EBuild: Bool
    let keychainServiceSuffix: String?

    static func current(bundle: Bundle = .main) -> HoverPocketBundleMetadata {
        HoverPocketBundleMetadata(
            bundleIdentifier: bundle.bundleIdentifier,
            isVoiceE2EBuild: bundle.object(
                forInfoDictionaryKey: HoverPocketRuntimeEnvironment.voiceE2EBuildInfoKey
            ) as? Bool ?? false,
            keychainServiceSuffix: bundle.object(
                forInfoDictionaryKey: HoverPocketRuntimeEnvironment.keychainServiceSuffixInfoKey
            ) as? String
        )
    }
}

final class HoverPocketRuntimeEnvironment: @unchecked Sendable {
    static let voiceE2EFlag = "--voice-e2e"
    static let voiceE2ERootFlag = "--voice-e2e-root"
    static let voiceE2ERootPrefix = "HoverPocketVoiceE2E-"
    static let voiceE2EBundleIdentifier = "local.codex.hover-pocket.voice-e2e"
    static let voiceE2EBuildInfoKey = "HoverPocketVoiceE2EBuild"
    static let keychainServiceSuffixInfoKey = "HoverPocketKeychainServiceSuffix"
    static let voiceE2EKeychainSuffixPrefix = "voice-e2e-"

    static let shared: HoverPocketRuntimeEnvironment = {
        do {
            return try resolve(
                arguments: CommandLine.arguments,
                bundleMetadata: .current()
            )
        } catch {
            let message = "HoverPocket startup rejected: \(error)\n"
            FileHandle.standardError.write(Data(message.utf8))
            exit(2)
        }
    }()

    let rootDirectory: URL
    let isIsolatedVoiceE2E: Bool
    let externalIntegrationsEnabled: Bool
    let settingsDefaults: any AppSettingsDefaultsStoring

    var voiceE2EReceiptURL: URL {
        rootDirectory.appendingPathComponent("voice-e2e-receipt.json", isDirectory: false)
    }

    var providerRegistry: ProviderRegistry {
        isIsolatedVoiceE2E
            ? ProviderRegistry(providers: [TimerProvider()])
            : .builtIn
    }

    private init(
        rootDirectory: URL,
        isIsolatedVoiceE2E: Bool,
        externalIntegrationsEnabled: Bool,
        settingsDefaults: any AppSettingsDefaultsStoring
    ) {
        self.rootDirectory = rootDirectory
        self.isIsolatedVoiceE2E = isIsolatedVoiceE2E
        self.externalIntegrationsEnabled = externalIntegrationsEnabled
        self.settingsDefaults = settingsDefaults
    }

    func storageDirectory(_ component: String) -> URL {
        rootDirectory.appendingPathComponent(component, isDirectory: true)
    }

    @MainActor
    func applyVoiceE2EDefaults(to settings: AppSettings) {
        guard isIsolatedVoiceE2E else { return }
        let timerID = TimerProvider.pluginID.rawValue
        settings.providerOrderRawValues = [timerID]
        settings.hiddenProviderRawValues = [
            MirrorProvider.pluginID.rawValue,
            ControlsProvider.pluginID.rawValue,
            CalculatorProvider.pluginID.rawValue,
            GoogleCalendarProvider.pluginID.rawValue,
            TodayFocusPocketProvider.pluginID.rawValue,
            ClipboardProvider.pluginID.rawValue,
            StickyNotesProvider.pluginID.rawValue
        ]
        settings.rememberLastSelectedProvider = true
        settings.preferredProviderRawValue = timerID
        settings.lastSelectedProviderRawValue = timerID
        settings.showMirrorMicrophoneCheck = false
        settings.showMirrorOnSecondaryDisplays = false
        settings.aiNativeEnabled = false
        settings.voiceProvider = .codexAppServer
        settings.voiceEnabled = false
        settings.voiceLaneLayoutPreference = .compact
        settings.voiceCalendarAccessEnabled = false
    }

    static func resolve(
        arguments: [String],
        bundleMetadata: HoverPocketBundleMetadata,
        fileManager: FileManager = .default,
        temporaryDirectory: URL = URL(
            fileURLWithPath: NSTemporaryDirectory(),
            isDirectory: true
        )
    ) throws -> HoverPocketRuntimeEnvironment {
        #if DEBUG
        let debugBuild = true
        #else
        let debugBuild = false
        #endif
        return try resolveForBuild(
            arguments: arguments,
            bundleMetadata: bundleMetadata,
            debugBuild: debugBuild,
            fileManager: fileManager,
            temporaryDirectory: temporaryDirectory
        )
    }

    static func resolveForBuild(
        arguments: [String],
        bundleMetadata: HoverPocketBundleMetadata,
        debugBuild: Bool,
        fileManager: FileManager = .default,
        temporaryDirectory: URL
    ) throws -> HoverPocketRuntimeEnvironment {
        let request = try parseVoiceE2ERequest(arguments: arguments)
        guard debugBuild else {
            let suffix = bundleMetadata.keychainServiceSuffix ?? ""
            guard request == nil,
                  !bundleMetadata.isVoiceE2EBuild,
                  bundleMetadata.bundleIdentifier != voiceE2EBundleIdentifier,
                  !suffix.hasPrefix(voiceE2EKeychainSuffixPrefix) else {
                throw HoverPocketRuntimeEnvironmentError.invalidArguments(
                    "voice_e2e_release_rejected"
                )
            }
            return production(fileManager: fileManager)
        }

        guard let request else {
            let suffix = bundleMetadata.keychainServiceSuffix ?? ""
            guard !bundleMetadata.isVoiceE2EBuild,
                  bundleMetadata.bundleIdentifier != voiceE2EBundleIdentifier,
                  !suffix.hasPrefix(voiceE2EKeychainSuffixPrefix) else {
                throw HoverPocketRuntimeEnvironmentError.invalidArguments(
                    "voice_e2e_arguments_required"
                )
            }
            return production(fileManager: fileManager)
        }
        guard !arguments.contains(where: { $0.hasPrefix("--verify") }) else {
            throw HoverPocketRuntimeEnvironmentError.invalidArguments(
                "voice_e2e_verifier_combination_rejected"
            )
        }
        try validateVoiceE2EBundle(bundleMetadata)
        let root = try validateFreshTemporaryRoot(
            request,
            fileManager: fileManager,
            temporaryDirectory: temporaryDirectory
        )
        return HoverPocketRuntimeEnvironment(
            rootDirectory: root,
            isIsolatedVoiceE2E: true,
            externalIntegrationsEnabled: false,
            settingsDefaults: EphemeralAppSettingsDefaults()
        )
    }

    private static func production(fileManager: FileManager) -> HoverPocketRuntimeEnvironment {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return HoverPocketRuntimeEnvironment(
            rootDirectory: base.appendingPathComponent("HoverPocket", isDirectory: true),
            isIsolatedVoiceE2E: false,
            externalIntegrationsEnabled: true,
            settingsDefaults: UserDefaults.standard
        )
    }

    private static func parseVoiceE2ERequest(arguments: [String]) throws -> String? {
        var requested = false
        var root: String?
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case voiceE2EFlag:
                requested = true
            case voiceE2ERootFlag:
                guard index + 1 < arguments.count, root == nil else {
                    throw HoverPocketRuntimeEnvironmentError.invalidArguments(
                        "voice_e2e_root_argument_invalid"
                    )
                }
                index += 1
                root = arguments[index]
            default:
                break
            }
            index += 1
        }
        if !requested {
            guard root == nil else {
                throw HoverPocketRuntimeEnvironmentError.invalidArguments(
                    "voice_e2e_root_without_mode_rejected"
                )
            }
            return nil
        }
        guard let root, !root.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HoverPocketRuntimeEnvironmentError.invalidArguments(
                "voice_e2e_root_required"
            )
        }
        return root
    }

    private static func validateVoiceE2EBundle(_ metadata: HoverPocketBundleMetadata) throws {
        guard metadata.isVoiceE2EBuild else {
            throw HoverPocketRuntimeEnvironmentError.invalidBundle(
                "voice_e2e_bundle_marker_required"
            )
        }
        guard metadata.bundleIdentifier == voiceE2EBundleIdentifier else {
            throw HoverPocketRuntimeEnvironmentError.invalidBundle(
                "voice_e2e_bundle_identifier_rejected"
            )
        }
        let suffix = metadata.keychainServiceSuffix?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard suffix.hasPrefix(voiceE2EKeychainSuffixPrefix),
              suffix.count > voiceE2EKeychainSuffixPrefix.count else {
            throw HoverPocketRuntimeEnvironmentError.invalidBundle(
                "voice_e2e_keychain_suffix_rejected"
            )
        }
    }

    private static func validateFreshTemporaryRoot(
        _ configuredRoot: String,
        fileManager: FileManager,
        temporaryDirectory: URL
    ) throws -> URL {
        let root = URL(fileURLWithPath: configuredRoot, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let temporaryRoot = temporaryDirectory
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard root.deletingLastPathComponent() == temporaryRoot,
              root.lastPathComponent.hasPrefix(voiceE2ERootPrefix),
              root.lastPathComponent.count > voiceE2ERootPrefix.count else {
            throw HoverPocketRuntimeEnvironmentError.invalidRoot(
                "voice_e2e_root_outside_temp_rejected"
            )
        }

        let configuredURL = URL(fileURLWithPath: configuredRoot, isDirectory: true)
        do {
            let values = try configuredURL.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw HoverPocketRuntimeEnvironmentError.invalidRoot(
                    "voice_e2e_root_type_rejected"
                )
            }
            guard try fileManager.contentsOfDirectory(atPath: root.path).isEmpty else {
                throw HoverPocketRuntimeEnvironmentError.invalidRoot(
                    "voice_e2e_root_not_fresh"
                )
            }
        } catch let error as HoverPocketRuntimeEnvironmentError {
            throw error
        } catch {
            throw HoverPocketRuntimeEnvironmentError.invalidRoot(
                "voice_e2e_root_uninspectable"
            )
        }
        return root
    }
}
