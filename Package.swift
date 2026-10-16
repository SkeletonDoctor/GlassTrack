// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GlassTrack",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "GlassTrack",
            path: "Sources/GlassTrack",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
