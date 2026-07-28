// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppsAudio",
    platforms: [.macOS("14.4")],
    targets: [
        .executableTarget(
            name: "AppsAudio",
            path: "Sources/AppsAudio",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AppKit")
            ]
        )
    ]
)
