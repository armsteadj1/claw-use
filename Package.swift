// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClawUse",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        // Shared business logic library
        .target(
            name: "CUACore",
            path: "Sources/CUACore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // CLI thin client
        .executableTarget(
            name: "cua",
            dependencies: [
                "CUACore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/CUA",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Daemon
        .executableTarget(
            name: "cuad",
            dependencies: [
                "CUACore",
            ],
            path: "Sources/CUADaemon",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CUATests",
            dependencies: ["CUACore"],
            path: "Tests/CUATests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
