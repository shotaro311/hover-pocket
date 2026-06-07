// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "NotchPokke",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "NotchPokke", targets: ["NotchPokke"])
    ],
    targets: [
        .executableTarget(
            name: "NotchPokke",
            path: "Sources/HoverMenuPreview"
        )
    ]
)
