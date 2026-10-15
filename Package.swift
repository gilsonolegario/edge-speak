// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EdgeSpeak",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "EdgeSpeak",
            path: "Sources/EdgeSpeak",
            swiftSettings: [.swiftLanguageMode(.v5)],
            // FoundationModels ships on macOS 26+ only; weak-link it so the
            // macOS 14/15 floor still launches (its use is @available-gated).
            linkerSettings: [.unsafeFlags(["-weak_framework", "FoundationModels"])]
        ),
    ]
)
