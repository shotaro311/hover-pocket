enum DisplayPlacementMode: String, CaseIterable, Identifiable {
    case automatic
    case mainDisplay
    case secondaryDisplay

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .automatic:
            "Auto"
        case .mainDisplay:
            "Main"
        case .secondaryDisplay:
            "Sub"
        }
    }

    var detail: String {
        switch self {
        case .automatic:
            "Uses the display under the pointer, then stays there while open."
        case .mainDisplay:
            "Always uses the primary macOS display."
        case .secondaryDisplay:
            "Uses a secondary display when one is connected."
        }
    }
}
