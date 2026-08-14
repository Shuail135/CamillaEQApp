// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CamiTune",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "CamiTune", targets: ["CamiTune"])
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
            name: "CamiTune",
            dependencies: ["SystemAudioBridgeC"],
            path: "Sources/CamiTune",
            resources: [
                .copy("icon.png")
            ]
        ),
        .testTarget(
            name: "CamiTuneTests",
            dependencies: ["CamiTune", "SystemAudioBridgeC"]
        )
    ]
)
