import Foundation
import Sparkle

private enum UpdateFeedAvailability: Sendable {
    case available
    case unavailable(AppTextKey)
}

@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = AppUpdater()

    private var updaterController: SPUStandardUpdaterController?
    private let feedURL: URL?
    private let hasPublicKey: Bool
    private var hasStartedUpdater = false
    private var statusResetTask: DispatchWorkItem?

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
            userDriverDelegate: nil
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

        isCheckingFeed = true
        lastStatusKey = nil

        Task {
            let availability = await Self.validateFeed(feedURL)
            isCheckingFeed = false

            switch availability {
            case .available:
                startUpdaterIfNeeded(updaterController)
                updaterController.checkForUpdates(nil)
            case .unavailable(let message):
                lastStatusKey = message
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
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        statusResetTask?.cancel()
        isCheckingFeed = false
        hasAvailableUpdate = false
        availableUpdateVersion = nil
        lastStatusKey = .updateUnavailable
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        statusResetTask?.cancel()
        isCheckingFeed = false
        hasAvailableUpdate = false
        availableUpdateVersion = nil
        lastStatusKey = .updateUnavailable
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
