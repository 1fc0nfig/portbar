// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "portbar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "portbar", targets: ["Portbar"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "Portbar",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Portbar",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PortbarTests",
            dependencies: ["Portbar"],
            path: "Tests/PortbarTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
