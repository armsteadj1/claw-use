// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentView",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        // Shared business logic library
        .target(
            name: "AgentViewCore",
            path: "Sources/AgentViewCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // CLI thin client
        .executableTarget(
            name: "agentview",
            dependencies: [
                "AgentViewCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/AgentView",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Daemon
        .executableTarget(
            name: "agentviewd",
            dependencies: [
                "AgentViewCore",
            ],
            path: "Sources/AgentViewDaemon",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AgentViewTests",
            dependencies: ["AgentViewCore"],
            path: "Tests/AgentViewTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
