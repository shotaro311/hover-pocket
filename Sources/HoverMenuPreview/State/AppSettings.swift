import Combine
import Foundation

@MainActor
final class AppSettings: ObservableObject {
    @Published var displayPlacementMode: DisplayPlacementMode {
        didSet {
            defaults.set(displayPlacementMode.rawValue, forKey: Self.displayPlacementModeKey)
        }
    }

    private let defaults: UserDefaults
    private static let displayPlacementModeKey = "displayPlacementMode"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let rawValue = defaults.string(forKey: Self.displayPlacementModeKey)
        self.displayPlacementMode = rawValue.flatMap(DisplayPlacementMode.init(rawValue:)) ?? .automatic
    }
}
