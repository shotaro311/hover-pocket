import AppKit
import Foundation
import Sparkle

private enum UpdateFeedAvailability: Sendable {
    case available
    case unavailable(AppTextKey)
}

@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    static let shared = AppUpdater()

    private var updaterController: SPUStandardUpdaterController?
    private let feedURL: URL?
    private let hasPublicKey: Bool
    private var hasStartedUpdater = false
    private var statusResetTask: DispatchWorkItem?
    private var foregroundUpdateUIUntil: Date?
    private var foregroundUpdateTasks: [DispatchWorkItem] = []

    @Published private(set) var isCheckingFeed = false
    @Published private(set) var hasAvailableUpdate = false
    @Published private(set) var availableUpdateVersion: String?
    @Published private(set) var lastStatusKey: AppTextKey?

    var canCheckForUpdates: Bool {
        updaterController != nil
            && feedURL != nil
            && hasPublicKey
            && !isCheckingFeed
    }

    func statusText(language: AppLanguage) -> String {
        if isCheckingFeed {
            return AppText.text(.updateChecking, language: language)
        }
        if hasAvailableUpdate {
            if let availableUpdateVersion {
                return "\(AppText.text(.updateAvailable, language: language)) \(availableUpdateVersion)"
            }
            return AppText.text(.updateAvailable, language: language)
        }
        if let lastStatusKey {
            return AppText.text(lastStatusKey, language: language)
        }
        return updaterController == nil
            ? AppText.text(.updateFeedMissing, language: language)
            : AppText.text(.updateReady, language: language)
    }

    var statusSystemImage: String {
        if isCheckingFeed {
            return "arrow.triangle.2.circlepath"
        }
        if hasAvailableUpdate {
            return "arrow.down.circle.fill"
        }
        if lastStatusKey == .updateFeedMissing || updaterController == nil {
            return "exclamationmark.triangle"
        }
        return "arrow.down.circle"
    }

    private override init() {
        let feedURLString = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
        let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        feedURL = feedURLString.flatMap(URL.init(string:))
        hasPublicKey = publicKey?.isEmpty == false

        super.init()

        guard feedURL != nil, hasPublicKey else {
            return
        }

        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: self
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.refreshAvailableUpdateStatus()
        }
    }

    func checkForUpdates() {
        guard let updaterController, let feedURL, hasPublicKey else {
            lastStatusKey = .updateFeedMissing
            return
        }

        beginForegroundUpdatePresentation()
        isCheckingFeed = true
        lastStatusKey = nil

        Task {
            let availability = await Self.validateFeed(feedURL)
            isCheckingFeed = false

            switch availability {
            case .available:
                startUpdaterIfNeeded(updaterController)
                beginForegroundUpdatePresentation()
                updaterController.checkForUpdates(nil)
            case .unavailable(let message):
                lastStatusKey = message
                finishForegroundUpdatePresentation()
            }
        }
    }

    func refreshAvailableUpdateStatus() {
        guard let updaterController, let feedURL, hasPublicKey, !isCheckingFeed else {
            return
        }

        isCheckingFeed = true
        lastStatusKey = nil

        Task {
            let availability = await Self.validateFeed(feedURL)

            switch availability {
            case .available:
                startUpdaterIfNeeded(updaterController)
                updaterController.updater.checkForUpdateInformation()
                scheduleStatusReset()
            case .unavailable(let message):
                isCheckingFeed = false
                lastStatusKey = message
            }
        }
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        statusResetTask?.cancel()
        isCheckingFeed = false
        hasAvailableUpdate = true
        availableUpdateVersion = item.displayVersionString
        lastStatusKey = nil
        foregroundSparkleUpdateWindowsSoon()
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        statusResetTask?.cancel()
        isCheckingFeed = false
        hasAvailableUpdate = false
        availableUpdateVersion = nil
        lastStatusKey = .updateUnavailable
        foregroundSparkleUpdateWindowsSoon(allowModalFallback: true)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        statusResetTask?.cancel()
        isCheckingFeed = false
        hasAvailableUpdate = false
        availableUpdateVersion = nil
        lastStatusKey = .updateUnavailable
        foregroundSparkleUpdateWindowsSoon(allowModalFallback: true)
    }

    func standardUserDriverWillShowModalAlert() {
        guard shouldForegroundUpdateUI else { return }
        activateApplicationForUpdatePresentation()
    }

    func standardUserDriverDidShowModalAlert() {
        foregroundSparkleUpdateWindowsSoon(allowModalFallback: true)
    }

    @objc(standardUserDriverWillHandleShowingUpdate:forUpdate:state:)
    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard handleShowingUpdate, state.userInitiated || shouldForegroundUpdateUI else { return }
        beginForegroundUpdatePresentation()
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        finishForegroundUpdatePresentation()
    }

    func standardUserDriverWillFinishUpdateSession() {
        finishForegroundUpdatePresentation()
    }

    private func startUpdaterIfNeeded(_ updaterController: SPUStandardUpdaterController) {
        guard !hasStartedUpdater else { return }
        updaterController.startUpdater()
        hasStartedUpdater = true
    }

    private func scheduleStatusReset() {
        statusResetTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.isCheckingFeed else { return }
            self.isCheckingFeed = false
        }
        statusResetTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: task)
    }

    private var shouldForegroundUpdateUI: Bool {
        guard let foregroundUpdateUIUntil else { return false }
        return foregroundUpdateUIUntil > Date()
    }

    private func beginForegroundUpdatePresentation() {
        foregroundUpdateUIUntil = Date().addingTimeInterval(12)
        activateApplicationForUpdatePresentation()
        foregroundSparkleUpdateWindowsSoon()
    }

    private func finishForegroundUpdatePresentation() {
        foregroundUpdateUIUntil = nil
        foregroundUpdateTasks.forEach { $0.cancel() }
        foregroundUpdateTasks.removeAll()
    }

    private func foregroundSparkleUpdateWindowsSoon(allowModalFallback: Bool = false) {
        guard shouldForegroundUpdateUI else { return }

        foregroundUpdateTasks.forEach { $0.cancel() }
        foregroundUpdateTasks.removeAll()

        for delay in [0.05, 0.2, 0.5, 1.0, 1.8, 3.0, 5.0, 8.0] {
            let task = DispatchWorkItem { [weak self] in
                self?.foregroundSparkleUpdateWindows(allowModalFallback: allowModalFallback)
            }
            foregroundUpdateTasks.append(task)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
        }
    }

    private func foregroundSparkleUpdateWindows(allowModalFallback: Bool) {
        guard shouldForegroundUpdateUI else { return }

        var windows = NSApp.windows.filter(Self.isSparkleUpdateWindow)
        if windows.isEmpty, allowModalFallback, let modalWindow = NSApp.modalWindow {
            windows = [modalWindow]
        }
        guard !windows.isEmpty else { return }

        activateApplicationForUpdatePresentation()
        for window in windows {
            window.deminiaturize(nil)
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func activateApplicationForUpdatePresentation() {
        NSApp.unhide(nil)
        if #available(macOS 14.0, *) {
            NSRunningApplication.current.activate(options: [.activateAllWindows])
        } else {
            NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        }
    }

    private static func isSparkleUpdateWindow(_ window: NSWindow) -> Bool {
        let identifier = window.identifier?.rawValue.lowercased() ?? ""
        if identifier == "suupdatealert" || identifier == "sustatus" || identifier.contains("sparkle") {
            return true
        }

        let title = window.title.lowercased()
        return title.contains("software update")
            || title.contains("update")
            || title.contains("アップデート")
    }

    private nonisolated static func validateFeed(_ url: URL) async -> UpdateFeedAvailability {
        if url.isFileURL {
            return FileManager.default.isReadableFile(atPath: url.path)
                ? .available
                : .unavailable(.updateFeedMissing)
        }

        guard url.scheme == "http" || url.scheme == "https" else {
            return .unavailable(.updateFeedMissing)
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 8

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse,
               !(200..<300).contains(httpResponse.statusCode) {
                return .unavailable(.updateFeedMissing)
            }
            guard !data.isEmpty else {
                return .unavailable(.updateFeedMissing)
            }
            return .available
        } catch {
            return .unavailable(.updateFeedMissing)
        }
    }
}
