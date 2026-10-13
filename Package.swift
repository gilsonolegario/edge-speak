// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EdgeSpeak",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "EdgeSpeak",
            path: "Sources/EdgeSpeak",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "EdgeSpeakTests",
            dependencies: ["EdgeSpeak"]
        ),
    ]
)
