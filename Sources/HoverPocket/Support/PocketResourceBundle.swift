import Foundation

extension Bundle {
    static var hoverPocketResources: Bundle {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("HoverPocket_HoverPocket.bundle"),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return .module
    }
}
