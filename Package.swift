// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CamillaApp",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "CamillaApp", targets: ["CamillaApp"])
    ],
    targets: [
        .target(
            name: "SystemAudioBridgeC",
            path: "Sources/SystemAudioBridgeC",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreFoundation")
            ]
        ),
        .executableTarget(
            name: "CamillaApp",
            dependencies: ["SystemAudioBridgeC"],
            path: "Sources/CamillaApp",
            resources: [
                .copy("icon.png")
            ]
        ),
        .testTarget(
            name: "CamillaAppTests",
            dependencies: ["CamillaApp", "SystemAudioBridgeC"]
        )
    ]
)
