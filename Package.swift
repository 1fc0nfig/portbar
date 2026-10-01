// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "portbar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "portbar", targets: ["Portbar"]),
    ],
    targets: [
        .executableTarget(
            name: "Portbar",
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
