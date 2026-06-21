import Foundation

struct ControlsDisplay: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case internalDisplay
        case externalDisplay
    }

    let id: String
    let displayID: UInt32
    var name: String
    var kind: Kind
    var brightness: Double
    var isControllable: Bool
}

struct ControlsVolumeState: Equatable, Sendable {
    var level: Double
    var isMuted: Bool

    static let empty = ControlsVolumeState(level: 0, isMuted: false)
}

struct ControlsNowPlayingState: Equatable, Sendable {
    var title: String
    var sourceName: String
    var hasMedia: Bool
    var artworkData: Data?
    var progress: TimeInterval
    var duration: TimeInterval
    var isPlaying: Bool

    static let empty = ControlsNowPlayingState(
        title: "",
        sourceName: "",
        hasMedia: false,
        artworkData: nil,
        progress: 0,
        duration: 0,
        isPlaying: false
    )
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
