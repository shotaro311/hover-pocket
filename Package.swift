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
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.3")
    ],
    targets: [
        .executableTarget(
            name: "HoverPocket",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/HoverPocket"
        )
    ]
)
