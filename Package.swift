// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "AgentView",
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "agentview",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/AgentView"
        ),
        .testTarget(
            name: "AgentViewTests",
            dependencies: ["agentview"],
            path: "Tests/AgentViewTests"
        ),
    ]
)
