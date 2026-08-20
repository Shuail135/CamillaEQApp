// swift-tools-version: 5.9
import PackageDescription
import Foundation

var packageTargets: [Target] = [
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
    )
]

if ProcessInfo.processInfo.environment["CAMITUNE_LOCAL_TESTS"] == "1" {
    packageTargets.append(
        .testTarget(
            name: "CamiTuneTests",
            dependencies: ["CamiTune", "SystemAudioBridgeC"]
        )
    )
}

let package = Package(
    name: "CamiTune",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "CamiTune", targets: ["CamiTune"])
    ],
    targets: packageTargets
)
