// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentView",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "agentview",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/AgentView",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AgentViewTests",
            dependencies: ["agentview"],
            path: "Tests/AgentViewTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
