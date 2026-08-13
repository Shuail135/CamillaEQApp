// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CamillaEQApp",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "CamillaEQApp", targets: ["CamillaEQApp"])
    ],
    targets: [
        .executableTarget(
            name: "CamillaEQApp",
            path: "Sources/CamillaEQApp",
            resources: [
                .copy("icon.png")
            ]
        )
    ]
)
