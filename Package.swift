// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "HoverPocket",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "HoverPocket", targets: ["HoverPocket"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.3"),
        .package(url: "https://github.com/ejbills/mediaremote-adapter.git", revision: "cf30c4f1af29b5829d859f088f8dbdf12611a046")
    ],
    targets: [
        .executableTarget(
            name: "HoverPocket",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "MediaRemoteAdapter", package: "mediaremote-adapter")
            ],
            path: "Sources/HoverPocket"
        )
    ]
)
