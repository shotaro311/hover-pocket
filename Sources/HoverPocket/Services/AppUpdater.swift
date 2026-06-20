import Foundation
import Sparkle

private enum UpdateFeedAvailability: Sendable {
    case available
    case unavailable(String)
}

@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    private let updaterController: SPUStandardUpdaterController?
    private let feedURL: URL?
    private let hasPublicKey: Bool
    private var hasStartedUpdater = false

    @Published private(set) var isCheckingFeed = false
    @Published private(set) var lastCheckMessage: String?

    var canCheckForUpdates: Bool {
        updaterController != nil
            && feedURL != nil
            && hasPublicKey
            && !isCheckingFeed
    }

    var statusText: String {
        if isCheckingFeed {
            return "Checking update feed"
        }
        if let lastCheckMessage {
            return lastCheckMessage
        }
        return updaterController == nil
            ? "Update feed is not configured"
            : "Update checks are available"
    }

    var statusSystemImage: String {
        if isCheckingFeed {
            return "arrow.triangle.2.circlepath"
        }
        if lastCheckMessage != nil || updaterController == nil {
            return "exclamationmark.triangle"
        }
        return "arrow.down.circle"
    }

    private init() {
        let feedURLString = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
        let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        feedURL = feedURLString.flatMap(URL.init(string:))
        hasPublicKey = publicKey?.isEmpty == false

        guard feedURL != nil, hasPublicKey else {
            updaterController = nil
            return
        }
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        guard let updaterController, let feedURL, hasPublicKey else {
            lastCheckMessage = "Update feed is not configured"
            return
        }

        isCheckingFeed = true
        lastCheckMessage = nil

        Task {
            let availability = await Self.validateFeed(feedURL)
            isCheckingFeed = false

            switch availability {
            case .available:
                if !hasStartedUpdater {
                    updaterController.startUpdater()
                    hasStartedUpdater = true
                }
                updaterController.checkForUpdates(nil)
            case .unavailable(let message):
                lastCheckMessage = message
            }
        }
    }

    private nonisolated static func validateFeed(_ url: URL) async -> UpdateFeedAvailability {
        if url.isFileURL {
            return FileManager.default.isReadableFile(atPath: url.path)
                ? .available
                : .unavailable("Update feed file was not found")
        }

        guard url.scheme == "http" || url.scheme == "https" else {
            return .unavailable("Update feed URL is invalid")
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 8

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse,
               !(200..<300).contains(httpResponse.statusCode) {
                return .unavailable("Update feed is not published yet")
            }
            guard !data.isEmpty else {
                return .unavailable("Update feed was empty")
            }
            return .available
        } catch {
            return .unavailable("Could not reach update feed")
        }
    }
}
