// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CamillaEQApp",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "CamillaEQApp", targets: ["CamillaEQApp"])
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
            name: "CamillaEQApp",
            dependencies: ["SystemAudioBridgeC"],
            path: "Sources/CamillaEQApp",
            resources: [
                .copy("icon.png")
            ]
        ),
        .testTarget(
            name: "CamillaEQAppTests",
            dependencies: ["CamillaEQApp", "SystemAudioBridgeC"]
        )
    ]
)
